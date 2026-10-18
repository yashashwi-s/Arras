"""Packaging regressions: wrong checkout, changed source, and pilot/public mixups."""
import json
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from build_provenance import BUILD_INPUTS, prepare, snapshot, stamp
from validate_app_bundle import validate

ROOT = Path(__file__).resolve().parent.parent
TEST_SOURCES = ("Sources/App/One.swift", "Sources/App/Two.swift")


class BuildProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in BUILD_INPUTS:
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, destination)
        project = self.root / 'Arras.xcodeproj/project.pbxproj'
        project.parent.mkdir(exist_ok=True)
        objects = {'project': {'mainGroup': 'group'}, 'group': {'isa': 'PBXGroup', 'children': [], 'sourceTree': '<group>'},
                   'target': {'isa': 'PBXNativeTarget', 'name': 'Arras', 'buildPhases': ['sources']},
                   'sources': {'isa': 'PBXSourcesBuildPhase', 'files': []}}
        for index, name in enumerate(TEST_SOURCES):
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('// fixture')
            reference = 'file' + str(index); build = 'build' + str(index)
            objects[reference] = {'isa': 'PBXFileReference', 'path': name, 'sourceTree': 'SOURCE_ROOT'}
            objects[build] = {'fileRef': reference}
            objects['group']['children'].append(reference); objects['sources']['files'].append(build)
        project.write_text(json.dumps({'objects': objects, 'rootObject': 'project'}))
        def fake_git(root, *arguments):
            return {'--show-toplevel': str(self.root), '--abbrev-ref': 'codex/test',
                    'HEAD': 'a' * 40, '--porcelain': ' M Sources/App/PrivacyView.swift'}[
                        '--porcelain' if arguments[0] == 'status' else arguments[-1]]
        self.git_patch = patch('build_provenance.git', side_effect=fake_git)
        self.git_patch.start()
        self.addCleanup(self.git_patch.stop)
        self.bundle = self.root / 'Arras.app'
        (self.bundle / 'Contents').mkdir(parents=True)
        info = plistlib.loads((ROOT / 'Info.generated.plist').read_bytes())
        configuration = (self.root / 'project.yml').read_text()
        version = re.search(r'MARKETING_VERSION: ([^\s]+)', configuration).group(1)
        build_number = re.search(r'CURRENT_PROJECT_VERSION: ([^\s]+)', configuration).group(1)
        info.update(CFBundleShortVersionString=version, CFBundleVersion=build_number,
                    CFBundleIdentifier='com.yashashwi.tableau',
                    ArrasTelemetryEnabled=re.search(r'ArrasTelemetryEnabled: (\w+)', configuration).group(1).lower() == 'true')
        (self.bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        self.prepared = self.root / 'prepared.json'
        # These fixtures deliberately have no executable/signature. Stub binary tools;
        # provenance still reads the real temporary files and project structure.
        self.signed_entitlements = {"com.apple.security.personal-information.photos-library": True}
        self.binary_sections = "sectname __text\n"
        original_run = subprocess.run
        def codesign_or_run(arguments, *args, **kwargs):
            if arguments[0] == "/usr/bin/codesign":
                return SimpleNamespace(stdout=plistlib.dumps(self.signed_entitlements))
            if arguments[0] == "/usr/bin/otool":
                return SimpleNamespace(stdout=self.binary_sections)
            return original_run(arguments, *args, **kwargs)
        signature = patch("validate_app_bundle.subprocess.run", side_effect=codesign_or_run)
        signature.start()
        self.addCleanup(signature.stop)


    def build(self, pilot='0'):
        prepare(self.root, self.prepared)
        stamp(self.root, self.prepared, self.bundle, pilot)

    def test_current_public_bundle_validates(self):
        self.build()
        validate(self.bundle, self.root / 'project.yml')

    def test_release_rejects_coverage_in_either_architecture(self):
        self.build()
        self.binary_sections = "architecture arm64\nsectname __text\narchitecture x86_64\nsectname __llvm_prf_cnts\n"
        with self.assertRaisesRegex(ValueError, "coverage instrumentation"):
            validate(self.bundle, self.root / 'project.yml')

    def test_missing_signed_photos_entitlement_is_rejected(self):
        self.build()
        self.signed_entitlements = {}
        with self.assertRaisesRegex(ValueError, "Photos Library entitlement"):
            validate(self.bundle, self.root / 'project.yml')

    def test_explicit_private_pilot_validates(self):
        self.build('2203')
        validate(self.bundle, self.root / 'project.yml', '2203')

    def test_public_packaging_rejects_private_pilot(self):
        self.build('2203')
        with self.assertRaisesRegex(ValueError, 'CFBundleVersion'):
            validate(self.bundle, self.root / 'project.yml')

    def test_stamp_rejects_source_changed_during_build(self):
        prepare(self.root, self.prepared)
        (self.root / TEST_SOURCES[0]).write_text('Changed source')
        with self.assertRaisesRegex(ValueError, 'changed during'):
            stamp(self.root, self.prepared, self.bundle)

    def test_validation_rejects_changed_checkout_after_build(self):
        self.build()
        (self.root / TEST_SOURCES[0]).write_text('Changed source')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            validate(self.bundle, self.root / 'project.yml')

    def test_removed_source_still_in_project_is_rejected(self):
        (self.root / TEST_SOURCES[0]).unlink()
        with self.assertRaisesRegex(ValueError, 'membership'):
            prepare(self.root, self.prepared)

    def test_added_source_missing_from_project_is_rejected(self):
        (self.root / 'Sources/App/NewFeature.swift').write_text('old')
        with self.assertRaisesRegex(ValueError, 'membership'):
            prepare(self.root, self.prepared)

    def test_copied_output_source_is_rejected(self):
        with patch('build_provenance.git', return_value=str(self.root.parent)):
            with self.assertRaisesRegex(ValueError, 'repository root'):
                snapshot(self.root)

    def test_missing_generated_source_is_rejected(self):
        path = self.root / 'Arras.xcodeproj/project.pbxproj'
        project = json.loads(path.read_text())
        project['objects']['sources']['files'].pop()
        path.write_text(json.dumps(project))
        with self.assertRaisesRegex(ValueError, 'Regenerate'):
            prepare(self.root, self.prepared)

    def test_retired_pilot_number_is_rejected(self):
        prepare(self.root, self.prepared)
        with self.assertRaisesRegex(ValueError, '2203'):
            stamp(self.root, self.prepared, self.bundle, '2201')

    def test_info_digest_tampering_is_rejected(self):
        self.build()
        info_path = self.bundle / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['ArrasSourceSHA256'] = '0' * 64
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'ArrasSourceSHA256'):
            validate(self.bundle, self.root / 'project.yml')

    def test_manifest_file_inventory_tampering_is_rejected(self):
        self.build()
        path = self.bundle / 'Contents/Resources/ArrasBuildProvenance.json'
        data = json.loads(path.read_text()); data['files'] = {}
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'files does not match'):
            validate(self.bundle, self.root / 'project.yml')


if __name__ == '__main__':
    unittest.main()

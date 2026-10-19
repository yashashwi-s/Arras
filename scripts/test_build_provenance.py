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
        store_path = self.root / 'Sources/AppStore/Store.swift'
        store_path.parent.mkdir(parents=True); store_path.write_text('// Store fixture')
        objects['store-file'] = {'isa': 'PBXFileReference', 'path': 'Sources/AppStore/Store.swift', 'sourceTree': 'SOURCE_ROOT'}
        objects['store-build'] = {'fileRef': 'store-file'}
        objects['group']['children'].append('store-file')
        objects['store-target'] = {'isa': 'PBXNativeTarget', 'name': 'ArrasAppStore', 'buildPhases': ['store-sources']}
        objects['store-sources'] = {'isa': 'PBXSourcesBuildPhase', 'files': objects['sources']['files'] + ['store-build']}
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
            if arguments[0] == "/usr/bin/lipo":
                return SimpleNamespace(stdout="arm64 x86_64")
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

    def build_store(self):
        path = self.bundle / 'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes())
        for key in ('ArrasTelemetryURL', 'ArrasTelemetryReportingDays'):
            info.pop(key, None)
        info.update(ArrasAppStoreBuild=True, ArrasTelemetryEnabled=False,
                    CFBundleIdentifier='com.yashashwi.arras.appstore',
                    NSScreenCaptureUsageDescription='Capture a selected screen region.')
        path.write_bytes(plistlib.dumps(info))
        resources = self.bundle / 'Contents/Resources'; resources.mkdir(exist_ok=True)
        shutil.copyfile(ROOT / 'Sources/AppStore/PrivacyInfo.xcprivacy', resources / 'PrivacyInfo.xcprivacy')
        self.signed_entitlements = plistlib.loads((ROOT / 'Sources/AppStore/ArrasAppStore.entitlements').read_bytes())
        prepare(self.root, self.prepared, 'ArrasAppStore')
        stamp(self.root, self.prepared, self.bundle)

    def test_store_bundle_validates_with_its_explicit_distribution(self):
        self.build_store()
        validate(self.bundle, self.root / 'project.yml', distribution='app-store')

    def test_direct_packaging_rejects_store_bundle(self):
        self.build_store()
        with self.assertRaisesRegex(ValueError, 'ArrasTelemetryEnabled|CFBundleIdentifier|ArrasAppStoreBuild'):
            validate(self.bundle, self.root / 'project.yml')

    def test_store_packaging_rejects_direct_bundle(self):
        self.build()
        with self.assertRaisesRegex(ValueError, 'ArrasTelemetryEnabled|CFBundleIdentifier|ArrasAppStoreBuild'):
            validate(self.bundle, self.root / 'project.yml', distribution='app-store')

    def test_store_stamp_and_validator_reject_telemetry_pilots(self):
        self.build_store()
        with self.assertRaisesRegex(ValueError, 'App Store'):
            stamp(self.root, self.prepared, self.bundle, '2210')
        with self.assertRaisesRegex(ValueError, 'App Store'):
            validate(self.bundle, self.root / 'project.yml', '2210', 'app-store')

    def test_store_cannot_configure_telemetry_endpoint(self):
        self.build_store()
        path = self.bundle / 'Contents/Info.plist'; info = plistlib.loads(path.read_bytes())
        info['ArrasTelemetryURL'] = 'https://example.invalid/telemetry'; path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'must not configure a telemetry'):
            validate(self.bundle, self.root / 'project.yml', distribution='app-store')

    def test_store_privacy_manifest_requires_api_reasons(self):
        self.build_store()
        path = self.bundle / 'Contents/Resources/PrivacyInfo.xcprivacy'; privacy = plistlib.loads(path.read_bytes())
        privacy['NSPrivacyAccessedAPITypes'] = []; path.write_bytes(plistlib.dumps(privacy))
        with self.assertRaisesRegex(ValueError, 'required API reasons'):
            validate(self.bundle, self.root / 'project.yml', distribution='app-store')

    def test_each_store_slice_requires_sandbox_without_debug_exceptions(self):
        self.build_store()
        original_run = subprocess.run
        for extra in ({'com.apple.security.app-sandbox': False},
                      {'com.apple.security.temporary-exception.files.absolute-path.read-write': ['/tmp/']},
                      {'com.apple.security.get-task-allow': True}):
            def altered_slice(arguments, *args, **kwargs):
                if arguments[0] == '/usr/bin/codesign' and 'x86_64' in arguments:
                    return SimpleNamespace(stdout=plistlib.dumps(self.signed_entitlements | extra))
                return original_run(arguments, *args, **kwargs)
            with self.subTest(extra=extra), patch('validate_app_bundle.subprocess.run', side_effect=altered_slice):
                with self.assertRaisesRegex(ValueError, 'x86_64'):
                    validate(self.bundle, self.root / 'project.yml', distribution='app-store')

    def test_source_membership_cannot_leak_between_targets(self):
        path = self.root / 'Arras.xcodeproj/project.pbxproj'; project = json.loads(path.read_text())
        project['objects']['sources']['files'].append('store-build'); path.write_text(json.dumps(project))
        with self.assertRaisesRegex(ValueError, 'membership'):
            prepare(self.root, self.prepared)

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

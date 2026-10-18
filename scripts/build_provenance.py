#!/usr/bin/env python3
"""Bind every Arras build to its checkout and exact application/build inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

BUILD_INPUTS = ('project.yml', 'build.sh', 'scripts/build_provenance.py', 'scripts/validate_app_bundle.py', 'scripts/verify_distribution.py', 'Arras.xcodeproj/project.pbxproj')


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(['git', '-C', str(root), *arguments], text=True).strip()


def snapshot(root: Path) -> dict:
    root = root.resolve()
    if Path(git(root, 'rev-parse', '--show-toplevel')).resolve() != root:
        raise ValueError('Build from the repository root; copied source under output is not a build checkout.')
    paths = sorted(p for p in (root / 'Sources').rglob('*') if p.is_file() and p.name != '.DS_Store')
    paths += [root / name for name in BUILD_INPUTS]
    files = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
    digest = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'schema': 1, 'sourceSHA256': digest, 'files': files,
            'branch': git(root, 'rev-parse', '--abbrev-ref', 'HEAD'),
            'commit': git(root, 'rev-parse', 'HEAD'),
            'dirty': bool(git(root, 'status', '--porcelain', '--untracked-files=normal'))}


def compiled_sources(root: Path) -> set[str]:
    path = root / 'Arras.xcodeproj/project.pbxproj'
    try:
        project = json.loads(path.read_text())
    except json.JSONDecodeError:
        project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)], text=True))
    objects = project['objects']
    paths = {}
    def visit(identifier, parent):
        item = objects[identifier]
        tree = item.get('sourceTree', '<group>')
        if tree not in ('<group>', 'SOURCE_ROOT'):
            return
        path = (root if tree == 'SOURCE_ROOT' else parent) / item.get('path', '')
        if item['isa'] == 'PBXGroup':
            for child in item.get('children', []):
                visit(child, path)
        elif item['isa'] == 'PBXFileReference':
            paths[identifier] = path.resolve()
    visit(objects[project['rootObject']]['mainGroup'], root)
    targets = [v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Arras']
    if len(targets) != 1:
        raise ValueError('Expected exactly one Arras application target; regenerate the project.')
    compiled = []
    for phase_id in targets[0]['buildPhases']:
        phase = objects[phase_id]
        if phase['isa'] != 'PBXSourcesBuildPhase':
            continue
        for build_id in phase['files']:
            source = paths[objects[build_id]['fileRef']]
            if source.suffix == '.swift':
                compiled.append(source.relative_to(root.resolve()).as_posix())
    if len(compiled) != len(set(compiled)):
        raise ValueError('Regenerate Arras.xcodeproj: duplicate application sources.')
    return set(compiled)


def prepare(root: Path, destination: Path) -> None:
    data = snapshot(root)
    expected = {p.relative_to(root).as_posix() for p in (root / 'Sources/App').rglob('*.swift')}
    try:
        actual = compiled_sources(root)
    except (KeyError, ValueError, subprocess.CalledProcessError) as error:
        raise ValueError('Regenerate Arras.xcodeproj with XcodeGen: invalid source membership.') from error
    if not expected or expected != actual:
        raise ValueError('Regenerate Arras.xcodeproj with XcodeGen: application source membership differs from the checkout.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(data, indent=2) + '\n')


def stamp(root: Path, prepared: Path, bundle: Path, pilot_build: str = '0') -> None:
    data = json.loads(prepared.read_text())
    current = snapshot(root)
    if any(data[key] != current[key] for key in ('sourceSHA256', 'branch', 'commit')):
        raise ValueError('Application source changed during the build. Rebuild before packaging.')
    pilot = int(pilot_build)
    if pilot != 0 and pilot < 2203:
        raise ValueError('Private pilot build numbers must be 2203 or newer.')
    info_path = bundle / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    # An explicit build option owns the private pilot; public source defaults remain off.
    info['ArrasPrivateTelemetryPilot'] = pilot != 0
    if pilot:
        info['CFBundleVersion'] = str(pilot)
        info['ArrasTelemetryEnabled'] = True
    info['ArrasSourceSHA256'] = data['sourceSHA256']
    info['ArrasBuildBranch'] = data['branch']
    info['ArrasBuildCommit'] = data['commit']
    data.update({'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                 'privatePilot': pilot != 0, 'telemetryEnabled': info.get('ArrasTelemetryEnabled', False),
                 'sdk': os.environ.get('SDK_VERSION', '')})
    info_path.write_bytes(plistlib.dumps(info))
    destination = bundle / 'Contents/Resources/ArrasBuildProvenance.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(data, indent=2) + '\n')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('prepare', 'stamp'))
    args = parser.parse_args()
    root = Path(os.environ['SRCROOT'])
    prepared = Path(os.environ['DERIVED_FILE_DIR']) / 'ArrasSourceSnapshot.json'
    try:
        if args.mode == 'prepare':
            prepare(root, prepared)
        else:
            stamp(root, prepared, Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME'],
                  os.environ.get('ARRAS_PRIVATE_PILOT_BUILD', '0'))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Build provenance failed: {error}\n')


if __name__ == '__main__':
    main()

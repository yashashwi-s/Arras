#!/usr/bin/env python3
"""Verify ZIP and mounted DMG contain the exact validated app, including symlinks."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
from validate_app_bundle import validate


def inventory(bundle: Path) -> dict:
    result = {}
    for path in sorted(bundle.rglob('*')):
        name = path.relative_to(bundle).as_posix()
        if path.is_symlink():
            result[name] = ['symlink', str(path.readlink())]
        elif path.is_file():
            result[name] = ['file', hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode & 0o777]
    return result


def check_copy(original: Path, copy: Path, project: Path, pilot: str | None) -> None:
    validate(copy, project, pilot)
    if inventory(original) != inventory(copy):
        raise ValueError(f'Packaged app differs from validated build: {copy}')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(copy)], check=True)


def verify(app: Path, archive: Path, dmg: Path, project: Path, pilot: str | None) -> None:
    validate(app, project, pilot)
    with tempfile.TemporaryDirectory(prefix='ArrasPackageVerify-') as directory:
        root = Path(directory)
        subprocess.run(['ditto', '-x', '-k', str(archive), str(root / 'zip')], check=True)
        check_copy(app, root / 'zip' / 'Arras.app', project, pilot)
        mount = root / 'mounted'
        mounted = False
        try:
            result = subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), '-plist', str(dmg)])
            plistlib.loads(result)
            mounted = True
            check_copy(app, mount / 'Arras.app', project, pilot)
            shortcut = mount / 'Applications'
            if not shortcut.is_symlink() or str(shortcut.readlink()) != '/Applications':
                raise ValueError('DMG is missing its Applications shortcut')
        finally:
            if mounted:
                subprocess.run(['hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'zip', 'dmg'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--project', type=Path, default=Path('project.yml'))
    parser.add_argument('--pilot-build')
    args = parser.parse_args()
    try:
        verify(args.app, args.zip, args.dmg, args.project, args.pilot_build)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Distribution verification failed: {error}\n')
    print('ZIP and DMG contain the exact current app; signatures and installation shortcut verified.')

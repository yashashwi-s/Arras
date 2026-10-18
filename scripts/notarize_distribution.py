#!/usr/bin/env python3
"""Sign a copy of a verified build and finalize local artifacts after notarization.

Apple submission IDs survive a pending result or interrupted local wait. An
unknown upload outcome stops for inspection rather than uploading again.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

from validate_app_bundle import validate
from verify_distribution import inventory, verify


class Pending(Exception):
    pass


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def submission_id(value):
    if not isinstance(value, str) or not re.fullmatch(
            r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', value):
        raise ValueError('Invalid Apple submission ID')
    return value.lower()


def unchanged_files(before, after, exceptions=()):
    return {k: v for k, v in before.items() if k not in exceptions} == {
        k: v for k, v in after.items() if k not in exceptions
    }


def require_release_metadata(metadata, info):
    facts = metadata.get('publicRelease', {})
    if (facts.get('signing') != 'developer-id' or facts.get('notarized') is not True
            or facts.get('version') != info.get('CFBundleShortVersionString')):
        raise ValueError('Publication requires matching Developer ID and notarized release metadata')


def locations(args):
    if args.work_dir.is_symlink() or args.output_dir.is_symlink():
        raise ValueError('Work and output directories must not be symlinks')
    source, work, output = args.app.resolve(), args.work_dir.resolve(), args.output_dir.resolve()
    if any(a == b or a in b.parents or b in a.parents
           for a, b in ((work, source), (output, source), (work, output))):
        raise ValueError('Source, work and output directories must be separate')
    return source, work, output


@contextmanager
def exclusive_work(work):
    work.parent.mkdir(parents=True, exist_ok=True)
    path = work.parent / f'.{work.name}.notarization.lock'
    if path.is_symlink():
        raise ValueError('Notarization lock must not be a symlink')
    # Retain the empty lock file: unlinking it can create two independently
    # locked inodes when another invocation is acquiring the same pathname.
    with path.open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Notarization is already running for this work directory')
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


class Distribution:
    def __init__(self, args):
        self.args = args
        self.processor_sha256 = digest(Path(__file__))
        self.project = args.project.resolve()
        self.source, self.work, self.output = locations(args)
        self.state_path = self.work / 'notarization-state.json'
        if self.state_path.is_symlink():
            raise ValueError('Notarization state must not be a symlink')
        self.config = {'source': str(self.source), 'project': str(self.project),
                       'identity': args.identity.upper(), 'teamID': args.team_id,
                       'profile': args.keychain_profile, 'output': str(self.output)}
        if not re.fullmatch(r'[0-9A-F]{40}', self.config['identity']):
            raise ValueError('Use the SHA-1 fingerprint of a Developer ID Application identity')
        if not re.fullmatch(r'[A-Z0-9]{10}', args.team_id) or not args.keychain_profile.strip():
            raise ValueError('A valid team ID and Keychain profile are required')
        validate(self.source, self.project)
        if args.require_release_metadata:
            require_release_metadata(json.loads((self.project.parent / 'product-metadata.json').read_text()),
                plistlib.loads((self.source / 'Contents/Info.plist').read_bytes()))
        subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(self.source)],
                       capture_output=True, text=True, check=True)
        source_inventory = inventory(self.source)
        if self.state_path.exists():
            self.state = json.loads(self.state_path.read_text())
            if (not isinstance(self.state, dict) or type(self.state.get('schema')) is not int
                    or self.state.get('schema') != 1 or self.state.get('config') != self.config
                    or self.state.get('sourceInventory') != source_inventory):
                raise ValueError('Saved notarization state belongs to a different build or configuration')
            if any(type(self.state.get(phase, False)) is not bool
                   for phase in ('signed', 'appStapled', 'packaged', 'complete')):
                raise ValueError('Invalid saved notarization phase')
            if self.state.get('signed') and not isinstance(self.state.get('signedInventory'), dict):
                raise ValueError('Missing signed application inventory')
            for kind in ('app', 'dmg'):
                entry = self.state.get(kind, {})
                if not isinstance(entry, dict):
                    raise ValueError('Invalid saved submission state')
                if entry and (not re.fullmatch(r'[0-9a-f]{64}', str(entry.get('sha256', '')))
                              or type(entry.get('accepted', False)) is not bool):
                    raise ValueError('Invalid saved archive hash or acceptance status')
                if entry.get('accepted') and not entry.get('id'):
                    raise ValueError('Accepted state is missing its Apple submission ID')
                if entry.get('id'):
                    entry['id'] = submission_id(entry['id'])
        else:
            if self.output.exists() or (self.work.exists() and any(self.work.iterdir())):
                raise ValueError('Use an empty work directory and a new output directory')
            self.check_identity()
            if (self.source / 'Contents/CodeResources').exists():
                raise ValueError('Start from a fresh build, rather than re-signing a stapled app')
            self.work.mkdir(parents=True, mode=0o700, exist_ok=True)
            self.state = {'schema': 1, 'config': self.config, 'sourceInventory': source_inventory}
            self.save()
        self.app = self.work / 'Arras.app'
        self.delivery = self.work / 'delivery'

    def save(self):
        temporary = self.state_path.with_suffix('.new')
        if temporary.is_symlink():
            raise ValueError('Temporary state must not be a symlink')
        temporary.write_text(json.dumps(self.state, indent=2) + '\n')
        os.replace(temporary, self.state_path)

    def command(self, label, arguments, *, allow_failure=False):
        self.check_processor()
        result = subprocess.run([str(a) for a in arguments], capture_output=True, text=True)
        (self.work / f'{label}.stdout').write_text(result.stdout)
        (self.work / f'{label}.stderr').write_text(result.stderr)
        if result.returncode and not allow_failure:
            raise RuntimeError(f'{label} failed ({result.returncode}): {result.stderr.strip()}')
        return result

    def check_processor(self):
        if digest(Path(__file__)) != self.processor_sha256:
            raise ValueError('Postprocessor source changed during this run; resume the saved request with the current script')

    def check_identity(self):
        result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                capture_output=True, text=True, check=True)
        matches = re.findall(r'\b([0-9A-Fa-f]{40})\s+"([^"]+)"', result.stdout)
        if not any(key.upper() == self.config['identity']
                   and name.startswith('Developer ID Application: ')
                   and name.endswith('(' + self.config['teamID'] + ')') for key, name in matches):
            raise ValueError('No valid Developer ID Application identity matches this fingerprint and team')

    def check_app_signature(self):
        self.command('app-codesign', ['codesign', '--verify', '--deep', '--strict', '--all-architectures', self.app])
        architectures = self.command('app-architectures', ['lipo', '-archs', self.app / 'Contents/MacOS/Arras']).stdout
        if set(architectures.split()) != {'arm64', 'x86_64'}:
            raise ValueError('The signed app must contain exactly Apple Silicon and Intel slices')
        expected = plistlib.loads((self.project.parent / 'Sources/App/PhotoWidgetOSX.entitlements').read_bytes())
        if expected.get('com.apple.security.get-task-allow') or expected.get('com.apple.security.app-sandbox'):
            raise ValueError('Unexpected debug or sandbox entitlement in direct distribution')
        if expected.get('com.apple.security.personal-information.photos-library') is not True:
            raise ValueError('Direct distribution requires the Photos entitlement')
        for arch in ('arm64', 'x86_64'):
            info = self.command(f'app-signature-{arch}', ['codesign', '-d', '--arch', arch, '--verbose=4', self.app]).stderr
            if (f'TeamIdentifier={self.config["teamID"]}' not in info
                    or 'Authority=Developer ID Application: ' not in info
                    or 'runtime)' not in info or 'Timestamp=' not in info):
                raise ValueError(f'Missing Developer ID, team, Hardened Runtime or secure timestamp in {arch}')
            entitlements = self.command(f'app-entitlements-{arch}',
                ['codesign', '-d', '--arch', arch, '--entitlements', '-', '--xml', self.app]).stdout
            if plistlib.loads(entitlements.encode()) != expected:
                raise ValueError(f'Unexpected signed entitlements in {arch}')
        validate(self.app, self.project)

    def accepted(self, kind, archive):
        self.check_processor()
        entry = self.state.setdefault(kind, {})
        if entry.get('accepted'):
            if kind == 'app' and digest(archive) != entry['sha256']:
                raise ValueError('Accepted app archive changed')
            return
        archive_hash = digest(archive)
        if entry.get('sha256', archive_hash) != archive_hash:
            raise ValueError(f'{kind} archive changed after submission')
        response_path = self.work / f'{kind}-submit.stdout'
        if not entry.get('id'):
            if entry.get('submitStarted'):
                # A complete saved response can survive interruption before state save.
                try:
                    response = json.loads(response_path.read_text())
                    entry['id'] = response['id']
                except (OSError, ValueError, KeyError):
                    raise RuntimeError(f'{kind} upload outcome is unknown; inspect Apple history before resuming')
            else:
                entry.update(sha256=archive_hash, submitStarted=True)
                entry.pop('preUploadFailure', None)
                self.save()
                result = self.command(f'{kind}-submit', ['xcrun', 'notarytool', 'submit', archive,
                    '--keychain-profile', self.config['profile'], '--output-format', 'json', '--no-wait'], allow_failure=True)
                if result.returncode:
                    # This local lookup failure happens before authentication or upload.
                    # Network/service errors retain submitStarted and require inspection.
                    missing_profile = f'Error: No Keychain password item found for profile: {self.config["profile"]}'
                    if (result.returncode == 69 and not result.stdout.strip()
                            and result.stderr.splitlines()[:1] == [missing_profile]):
                        entry.update(submitStarted=False, preUploadFailure='missing-keychain-profile')
                        self.save()
                    raise RuntimeError(f'{kind}-submit failed ({result.returncode}): {result.stderr.strip()}')
                entry['id'] = json.loads(result.stdout)['id']
            entry['id'] = submission_id(entry['id'])
            self.save()
        result = self.command(f'{kind}-info', ['xcrun', 'notarytool', 'info', entry['id'],
            '--keychain-profile', self.config['profile'], '--output-format', 'json'])
        response = json.loads(result.stdout)
        if response.get('id') != entry['id']:
            raise ValueError('Apple returned a different submission ID')
        if response.get('status') == 'In Progress' and self.args.wait_seconds:
            result = self.command(f'{kind}-wait', ['xcrun', 'notarytool', 'wait', entry['id'],
                '--keychain-profile', self.config['profile'], '--timeout', str(self.args.wait_seconds),
                '--output-format', 'json'], allow_failure=True)
            if result.returncode == 124:
                raise Pending(f'{kind} remains pending: {entry["id"]}; resume with the same work directory')
            if result.returncode:
                raise RuntimeError(f'{kind} wait failed; the existing submission ID is preserved')
            response = json.loads(result.stdout)
            if response.get('id') != entry['id']:
                raise ValueError('Apple returned a different submission ID')
        status = response.get('status')
        if status == 'In Progress':
            raise Pending(f'{kind} remains pending: {entry["id"]}; resume with the same work directory')
        if status not in ('Accepted', 'Invalid', 'Rejected'):
            raise ValueError(f'Unexpected Apple status: {status!r}')
        log_path = self.work / f'{kind}-notary-log.json'
        self.command(f'{kind}-log', ['xcrun', 'notarytool', 'log', entry['id'],
            '--keychain-profile', self.config['profile'], log_path])
        log = json.loads(log_path.read_text())
        if status != 'Accepted' or log.get('status') != 'Accepted':
            raise RuntimeError(f'Apple did not accept {kind}; inspect {log_path}')
        if str(log.get('sha256', '')).lower() != entry['sha256']:
            raise ValueError('Apple acceptance is for different archive bytes')
        if any(issue.get('severity') == 'error' for issue in (log.get('issues') or [])):
            raise ValueError('Apple log contains errors')
        entry.update(accepted=True, issues=log.get('issues'))
        self.save()

    def app_policy(self):
        self.check_app_signature()
        self.command('app-ticket', ['xcrun', 'stapler', 'validate', self.app])
        self.command('app-distribution-policy', ['syspolicy_check', 'distribution', self.app])
        result = self.command('app-gatekeeper', ['spctl', '--assess', '--type', 'execute', '--verbose=4', self.app])
        if 'Notarized Developer ID' not in result.stderr:
            raise ValueError('Gatekeeper did not identify a notarized Developer ID app')

    def dmg_policy(self, dmg):
        self.command('dmg-ticket', ['xcrun', 'stapler', 'validate', dmg])
        self.command('dmg-signature', ['codesign', '--verify', '--strict', dmg])
        details = self.command('dmg-signature-details', ['codesign', '-d', '--verbose=4', dmg]).stderr
        if (f'TeamIdentifier={self.config["teamID"]}' not in details
                or 'Authority=Developer ID Application: ' not in details or 'Timestamp=' not in details):
            raise ValueError('Disk image signature does not match the Developer ID team')
        result = self.command('dmg-gatekeeper', ['spctl', '--assess', '--type', 'open', '--verbose=4',
            '--context', 'context:primary-signature', dmg])
        if 'Notarized Developer ID' not in result.stderr:
            raise ValueError('Gatekeeper did not identify a notarized Developer ID disk image')

    def verify_output(self):
        receipt = json.loads((self.output / 'Arras.notarization.json').read_text())
        if not self.state.get('app', {}).get('accepted') or not self.state.get('dmg', {}).get('accepted'):
            raise ValueError('Existing output lacks accepted submissions')
        expected = {'signing': 'developer-id', 'notarized': True, 'teamID': self.config['teamID'],
                    'appSubmissionID': self.state['app']['id'], 'dmgSubmissionID': self.state['dmg']['id'],
                    'appTicketVerified': True, 'dmgTicketVerified': True,
                    'sourceSHA256': plistlib.loads((self.app / 'Contents/Info.plist').read_bytes())['ArrasSourceSHA256']}
        if any(receipt.get(key) != value for key, value in expected.items()):
            raise ValueError('Existing output belongs to a different notarization')
        if receipt.get('files') != {name: digest(self.output / name) for name in ('Arras.app.zip', 'Arras.dmg')}:
            raise ValueError('Existing notarized artifacts changed')
        if not unchanged_files(self.state['signedInventory'], inventory(self.app), ('Contents/CodeResources',)):
            raise ValueError('Completed candidate changed')
        self.app_policy()
        self.dmg_policy(self.output / 'Arras.dmg')
        verify(self.app, self.output / 'Arras.app.zip', self.output / 'Arras.dmg', self.project, None)
        self.check_processor()
        self.state['complete'] = True
        self.save()

    def finish(self):
        self.check_processor()
        # Recover a final directory rename interrupted before its state save.
        # Existing unrelated output is never overwritten or removed.
        if self.output.exists() and not self.delivery.exists():
            self.verify_output()
            print(f'Existing notarized artifacts verified at {self.output}. Nothing was published.')
            return
        if not self.state.get('signed'):
            if self.app.exists():
                raise ValueError('Partial signing output exists; inspect it before retrying')
            self.command('copy-app', ['ditto', self.source, self.app])
            self.command('sign-app', ['codesign', '--force', '--sign', self.config['identity'], '--options', 'runtime',
                '--timestamp', '--entitlements', self.project.parent / 'Sources/App/PhotoWidgetOSX.entitlements', self.app])
            self.check_app_signature()
            before = self.state['sourceInventory']
            after = inventory(self.app)
            if set(before) != set(after) or not unchanged_files(before, after,
                    ('Contents/MacOS/Arras', 'Contents/_CodeSignature/CodeResources')):
                raise ValueError('Signing changed application resources or metadata')
            self.state.update(signed=True, signedInventory=after)
            self.save()
        self.check_app_signature()
        if not unchanged_files(self.state['signedInventory'], inventory(self.app), ('Contents/CodeResources',)):
            raise ValueError('Signed application changed while notarization was pending')
        upload = self.work / 'app-upload.zip'
        if not upload.exists():
            if self.state.get('app', {}).get('submitStarted'):
                raise ValueError('Submitted archive is missing')
            self.command('zip-upload', ['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', self.app, upload])
        self.accepted('app', upload)
        if not self.state.get('appStapled'):
            self.command('app-staple', ['xcrun', 'stapler', 'staple', self.app])
            self.app_policy()
            if not unchanged_files(self.state['signedInventory'], inventory(self.app), ('Contents/CodeResources',)):
                raise ValueError('Stapling changed signed application content')
            self.state['appStapled'] = True
            self.save()
        if not self.state.get('packaged'):
            if self.delivery.exists() or (self.work / 'dmg-stage').exists():
                raise ValueError('Partial packaging output exists; inspect it before retrying')
            self.delivery.mkdir()
            stage = self.work / 'dmg-stage'
            stage.mkdir()
            self.command('copy-dmg-app', ['ditto', self.app, stage / 'Arras.app'])
            (stage / 'Applications').symlink_to('/Applications')
            self.command('zip-delivery', ['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', self.app, self.delivery / 'Arras.app.zip'])
            self.command('create-dmg', ['hdiutil', 'create', '-volname', 'Arras', '-srcfolder', stage, '-format', 'UDZO', self.delivery / 'Arras.dmg'])
            self.command('sign-dmg', ['codesign', '--sign', self.config['identity'], '--timestamp', self.delivery / 'Arras.dmg'])
            verify(self.app, self.delivery / 'Arras.app.zip', self.delivery / 'Arras.dmg', self.project, None)
            self.state['packaged'] = True
            self.save()
        self.accepted('dmg', self.delivery / 'Arras.dmg')
        self.command('dmg-staple', ['xcrun', 'stapler', 'staple', self.delivery / 'Arras.dmg'])
        self.app_policy()
        self.dmg_policy(self.delivery / 'Arras.dmg')
        verify(self.app, self.delivery / 'Arras.app.zip', self.delivery / 'Arras.dmg', self.project, None)
        if inventory(self.source) != self.state['sourceInventory']:
            raise ValueError('Original build changed during notarization')
        self.check_processor()
        receipt = {'schema': 1, 'sourceSHA256': plistlib.loads((self.app / 'Contents/Info.plist').read_bytes())['ArrasSourceSHA256'],
            'postprocessorSHA256': self.processor_sha256, 'teamID': self.config['teamID'],
            'signing': 'developer-id', 'notarized': True, 'appTicketVerified': True, 'dmgTicketVerified': True,
            'appSubmissionID': self.state['app']['id'], 'dmgSubmissionID': self.state['dmg']['id'],
            'notaryIssues': {kind: self.state[kind].get('issues') for kind in ('app', 'dmg')},
            'files': {name: digest(self.delivery / name) for name in ('Arras.app.zip', 'Arras.dmg')}}
        (self.delivery / 'Arras.notarization.json').write_text(json.dumps(receipt, indent=2) + '\n')
        if self.output.exists():
            raise ValueError('Output directory already exists; verified staged artifacts were preserved')
        self.output.parent.mkdir(parents=True, exist_ok=True)
        os.rename(self.delivery, self.output)
        self.state['complete'] = True
        self.save()
        print(f'Notarized ZIP and DMG verified at {self.output}. Nothing was published.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('build/current/Release/Arras.app'))
    parser.add_argument('--project', type=Path, default=Path('project.yml'))
    parser.add_argument('--identity', required=True)
    parser.add_argument('--team-id', required=True)
    parser.add_argument('--keychain-profile', required=True)
    parser.add_argument('--work-dir', type=Path, default=Path('build/notarization'))
    parser.add_argument('--output-dir', type=Path, default=Path('dist/notarized'))
    parser.add_argument('--wait-seconds', type=int, default=0)
    parser.add_argument('--require-release-metadata', action='store_true',
                        help='Require reviewed notarized release facts before publication packaging')
    args = parser.parse_args()
    if not 0 <= args.wait_seconds <= 3600:
        parser.error('--wait-seconds must be between 0 and 3600')
    try:
        _, work, _ = locations(args)
        with exclusive_work(work):
            Distribution(args).finish()
    except Pending as error:
        print(error, file=sys.stderr)
        return 75
    except (ValueError, OSError, RuntimeError, KeyError, TypeError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f'Notarization stopped: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

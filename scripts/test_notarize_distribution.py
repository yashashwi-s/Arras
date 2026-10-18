"""Private fixtures for upload resumption and fail-closed distribution gates."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from notarize_distribution import Distribution, Pending, digest, unchanged_files, require_release_metadata, exclusive_work, locations
from verify_distribution import inventory
import notarize_distribution


REQUEST = 'aae4e5ca-d024-44bd-bf9f-bd8fce50859f'
IDENTITY = 'A' * 40
TEAM = 'K28DKAV937'


class SubmissionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='Arras notary fixture ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / 'app-upload.zip'
        self.archive.write_bytes(b'frozen signed archive fixture')
        self.pipeline = object.__new__(Distribution)
        self.pipeline.processor_sha256 = digest(Path(notarize_distribution.__file__))
        self.pipeline.work = self.root
        self.pipeline.state_path = self.root / 'notarization-state.json'
        self.pipeline.config = {'profile': 'fixture-profile'}
        self.pipeline.args = SimpleNamespace(wait_seconds=0)
        self.pipeline.state = {}
        self.calls = []
        self.status = 'In Progress'
        self.log_hash = digest(self.archive)

        def command(label, arguments, **kwargs):
            self.calls.append((label, arguments))
            if label.endswith('-submit'):
                value = json.dumps({'id': REQUEST, 'message': 'uploaded'})
                (self.root / f'{label}.stdout').write_text(value)
            elif label.endswith('-info') or label.endswith('-wait'):
                value = json.dumps({'id': REQUEST, 'status': self.status})
            elif label.endswith('-log'):
                Path(arguments[-1]).write_text(json.dumps({
                    'status': self.status, 'sha256': self.log_hash, 'issues': None,
                }))
                value = 'log saved'
            else:
                self.fail(f'Unexpected external action: {label}')
            return SimpleNamespace(returncode=0, stdout=value, stderr='')

        self.pipeline.command = command

    def pending(self):
        with self.assertRaises(Pending):
            self.pipeline.accepted('app', self.archive)

    def test_pending_then_accepted_reuses_persisted_id_without_another_upload(self):
        self.pending()
        self.assertEqual(json.loads(self.pipeline.state_path.read_text())['app']['id'], REQUEST)
        self.pipeline.state = json.loads(self.pipeline.state_path.read_text())
        self.status = 'Accepted'
        self.pipeline.accepted('app', self.archive)
        self.assertTrue(self.pipeline.state['app']['accepted'])
        self.assertEqual(sum(label == 'app-submit' for label, _ in self.calls), 1)

    def test_interrupted_state_save_recovers_complete_submission_response(self):
        self.pipeline.state = {'app': {'submitStarted': True, 'sha256': digest(self.archive)}}
        (self.root / 'app-submit.stdout').write_text(json.dumps({'id': REQUEST}))
        self.pending()
        self.assertEqual(self.pipeline.state['app']['id'], REQUEST)
        self.assertNotIn('app-submit', [label for label, _ in self.calls])

    def test_ambiguous_upload_does_not_retry_or_discard_evidence(self):
        self.pipeline.state = {'app': {'submitStarted': True, 'sha256': digest(self.archive)}}
        response = self.root / 'app-submit.stdout'
        response.write_text('{"partial":')
        with self.assertRaisesRegex(RuntimeError, 'outcome is unknown'):
            self.pipeline.accepted('app', self.archive)
        self.assertEqual(self.calls, [])
        self.assertEqual(response.read_text(), '{"partial":')

    def test_missing_local_profile_can_resume_after_credentials_are_restored(self):
        original = self.pipeline.command
        message = 'Error: No Keychain password item found for profile: fixture-profile\n'
        def unavailable(label, arguments, **kwargs):
            if label == 'app-submit':
                self.calls.append((label, arguments))
                (self.root / 'app-submit.stdout').write_text('')
                (self.root / 'app-submit.stderr').write_text(message)
                return SimpleNamespace(returncode=69, stdout='', stderr=message)
            return original(label, arguments, **kwargs)
        self.pipeline.command = unavailable
        with self.assertRaisesRegex(RuntimeError, 'No Keychain password item'):
            self.pipeline.accepted('app', self.archive)
        saved = json.loads(self.pipeline.state_path.read_text())
        self.assertFalse(saved['app']['submitStarted'])
        self.assertEqual(saved['app']['preUploadFailure'], 'missing-keychain-profile')
        self.assertNotIn('id', saved['app'])
        self.assertEqual((self.root / 'app-submit.stderr').read_text(), message)
        self.pipeline.state = saved
        self.pipeline.command = original
        self.status = 'Accepted'
        self.pipeline.accepted('app', self.archive)
        self.assertTrue(self.pipeline.state['app']['accepted'])
        self.assertNotIn('preUploadFailure', self.pipeline.state['app'])

    def test_other_submit_failures_remain_ambiguous_and_do_not_upload_again(self):
        for stdout, stderr in [('', 'Network connection interrupted'),
                               ('partial response', 'Error: No Keychain password item found for profile: fixture-profile\n')]:
            with self.subTest(stdout=stdout, stderr=stderr):
                self.pipeline.state = {}
                self.calls.clear()
                def interrupted(label, arguments, **kwargs):
                    self.calls.append((label, arguments))
                    self.assertEqual(label, 'app-submit')
                    (self.root / 'app-submit.stdout').write_text(stdout)
                    return SimpleNamespace(returncode=69, stdout=stdout, stderr=stderr)
                self.pipeline.command = interrupted
                with self.assertRaisesRegex(RuntimeError, 'app-submit failed'):
                    self.pipeline.accepted('app', self.archive)
                self.assertTrue(self.pipeline.state['app']['submitStarted'])
                with self.assertRaisesRegex(RuntimeError, 'outcome is unknown'):
                    self.pipeline.accepted('app', self.archive)
                self.assertEqual(len(self.calls), 1)

    def test_malformed_saved_response_stops_before_another_apple_call(self):
        self.pipeline.state = {'app': {'submitStarted': True, 'sha256': digest(self.archive)}}
        (self.root / 'app-submit.stdout').write_text(json.dumps({'id': '--force'}))
        with self.assertRaisesRegex(ValueError, 'Invalid Apple submission ID'):
            self.pipeline.accepted('app', self.archive)
        self.assertEqual(self.calls, [])

    def test_archive_change_while_pending_stops_before_apple_request(self):
        self.pending()
        self.calls.clear()
        self.archive.write_bytes(b'changed fixture')
        with self.assertRaisesRegex(ValueError, 'archive changed'):
            self.pipeline.accepted('app', self.archive)
        self.assertEqual(self.calls, [])

    def test_acceptance_for_different_bytes_is_rejected(self):
        self.status = 'Accepted'
        self.log_hash = '0' * 64
        with self.assertRaisesRegex(ValueError, 'different archive bytes'):
            self.pipeline.accepted('app', self.archive)
        self.assertFalse(self.pipeline.state['app'].get('accepted', False))

    def test_rejection_preserves_apple_log_and_does_not_accept_artifact(self):
        self.status = 'Invalid'
        with self.assertRaisesRegex(RuntimeError, 'did not accept'):
            self.pipeline.accepted('app', self.archive)
        self.assertTrue((self.root / 'app-notary-log.json').is_file())
        self.assertFalse(self.pipeline.state['app'].get('accepted', False))

    def test_local_wait_timeout_preserves_pending_submission(self):
        self.pipeline.args.wait_seconds = 60
        original = self.pipeline.command
        def timeout(label, arguments, **kwargs):
            if label == 'app-wait':
                return SimpleNamespace(returncode=124, stdout='', stderr='timeout')
            return original(label, arguments, **kwargs)
        self.pipeline.command = timeout
        self.pending()
        self.assertEqual(json.loads(self.pipeline.state_path.read_text())['app']['id'], REQUEST)

    def test_different_submission_id_cannot_be_accepted(self):
        original = self.pipeline.command
        def wrong_id(label, arguments, **kwargs):
            if label == 'app-info':
                return SimpleNamespace(returncode=0, stdout=json.dumps({'id': 'wrong', 'status': 'Accepted'}), stderr='')
            return original(label, arguments, **kwargs)
        self.pipeline.command = wrong_id
        with self.assertRaisesRegex(ValueError, 'different submission ID'):
            self.pipeline.accepted('app', self.archive)

    def test_accepted_app_archive_remains_immutable(self):
        self.status = 'Accepted'
        self.pipeline.accepted('app', self.archive)
        self.calls.clear()
        self.archive.write_bytes(b'changed after acceptance')
        with self.assertRaisesRegex(ValueError, 'Accepted app archive changed'):
            self.pipeline.accepted('app', self.archive)
        self.assertEqual(self.calls, [])

    def test_changed_processor_stops_before_network_and_preserves_request(self):
        self.pending()
        self.calls.clear()
        before = self.pipeline.state_path.read_bytes()
        self.pipeline.processor_sha256 = '0' * 64
        with self.assertRaisesRegex(ValueError, 'source changed during this run'):
            self.pipeline.accepted('app', self.archive)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.pipeline.state_path.read_bytes(), before)


class IdentityAndContentTests(unittest.TestCase):
    def identity_pipeline(self):
        pipeline = object.__new__(Distribution)
        pipeline.config = {'identity': IDENTITY, 'teamID': TEAM}
        return pipeline

    def test_development_certificate_cannot_be_used_for_distribution(self):
        result = SimpleNamespace(stdout=f'1) {IDENTITY} "Apple Development: Fixture ({TEAM})"')
        with patch('notarize_distribution.subprocess.run', return_value=result):
            with self.assertRaisesRegex(ValueError, 'No valid Developer ID'):
                self.identity_pipeline().check_identity()

    def test_developer_id_must_match_both_fingerprint_and_team(self):
        for key, team in [(IDENTITY, 'OTHERTEAM1'), ('B' * 40, TEAM)]:
            with self.subTest(team=team, key=key):
                result = SimpleNamespace(stdout=f'1) {key} "Developer ID Application: Fixture ({team})"')
                with patch('notarize_distribution.subprocess.run', return_value=result):
                    with self.assertRaises(ValueError):
                        self.identity_pipeline().check_identity()

    def test_matching_developer_id_is_accepted(self):
        result = SimpleNamespace(stdout=f'1) {IDENTITY} "Developer ID Application: Fixture ({TEAM})"')
        with patch('notarize_distribution.subprocess.run', return_value=result):
            self.identity_pipeline().check_identity()

    def test_ticket_exception_does_not_allow_changed_or_extra_resources(self):
        before = {'Contents/Info.plist': ['file', 'original', 420]}
        ticket = {**before, 'Contents/CodeResources': ['file', 'ticket', 420]}
        self.assertTrue(unchanged_files(before, ticket, ('Contents/CodeResources',)))
        self.assertFalse(unchanged_files(before, {**ticket, 'Contents/Info.plist': ['file', 'changed', 420]}, ('Contents/CodeResources',)))
        self.assertFalse(unchanged_files(before, {**ticket, 'Contents/Resources/extra': ['file', 'extra', 420]}, ('Contents/CodeResources',)))

    def test_publication_requires_matching_notarized_release_facts(self):
        facts = {'version': '2.5.0', 'signing': 'developer-id', 'notarized': True}
        info = {'CFBundleShortVersionString': '2.5.0'}
        require_release_metadata({'publicRelease': facts}, info)
        for change in ({'notarized': False}, {'notarized': 'true'}, {'signing': 'ad-hoc'}, {'version': '2.4.9'}):
            with self.subTest(change=change):
                with self.assertRaisesRegex(ValueError, 'Publication requires'):
                    require_release_metadata({'publicRelease': {**facts, **change}}, info)

    def test_work_directory_cannot_contain_or_replace_the_input_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'must be separate'):
                locations(SimpleNamespace(app=root / 'work/Arras.app', work_dir=root / 'work', output_dir=root / 'output'))

    def test_actual_process_lock_blocks_a_second_invocation_and_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory) / 'candidate'
            script = (
                'import fcntl,sys\n'
                'with open(sys.argv[1],"a") as handle:\n'
                ' try: fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)\n'
                ' except BlockingIOError: sys.exit(42)\n'
            )
            lock = work.parent / '.candidate.notarization.lock'
            with exclusive_work(work):
                blocked = subprocess.run([sys.executable, '-c', script, str(lock)], capture_output=True)
                self.assertEqual(blocked.returncode, 42, blocked.stderr)
            available = subprocess.run([sys.executable, '-c', script, str(lock)], capture_output=True)
            self.assertEqual(available.returncode, 0, available.stderr)


class FinalOutputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='Arras final artifact fixture ')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.pipeline = object.__new__(Distribution)
        self.pipeline.processor_sha256 = digest(Path(notarize_distribution.__file__))
        self.pipeline.work = root / 'work'
        self.pipeline.work.mkdir()
        self.pipeline.app = self.pipeline.work / 'Arras.app'
        (self.pipeline.app / 'Contents').mkdir(parents=True)
        (self.pipeline.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'ArrasSourceSHA256': 'a' * 64}))
        self.pipeline.delivery = self.pipeline.work / 'delivery'
        self.pipeline.output = root / 'verified-output'
        self.pipeline.output.mkdir()
        self.pipeline.project = root / 'project.yml'
        self.pipeline.state_path = self.pipeline.work / 'notarization-state.json'
        self.pipeline.config = {'teamID': TEAM}
        self.pipeline.state = {'app': {'accepted': True, 'id': REQUEST},
                               'dmg': {'accepted': True, 'id': 'dee4e5ca-d024-44bd-bf9f-bd8fce50859f'},
                               'signedInventory': inventory(self.pipeline.app)}
        for name in ('Arras.app.zip', 'Arras.dmg'):
            (self.pipeline.output / name).write_bytes(('verified fixture ' + name).encode())
        self.receipt = {'signing': 'developer-id', 'notarized': True, 'teamID': TEAM,
                        'appSubmissionID': REQUEST, 'dmgSubmissionID': self.pipeline.state['dmg']['id'],
                        'appTicketVerified': True, 'dmgTicketVerified': True, 'sourceSHA256': 'a' * 64,
                        'files': {name: digest(self.pipeline.output / name) for name in ('Arras.app.zip', 'Arras.dmg')}}
        self.write_receipt()
        self.pipeline.app_policy = lambda: None
        self.pipeline.dmg_policy = lambda path: None
        self.verify = patch('notarize_distribution.verify')
        self.verify_mock = self.verify.start()
        self.addCleanup(self.verify.stop)

    def write_receipt(self):
        (self.pipeline.output / 'Arras.notarization.json').write_text(json.dumps(self.receipt))

    def test_interrupted_final_rename_is_revalidated_and_state_commits(self):
        original = (self.pipeline.output / 'Arras.app.zip').read_bytes()
        self.pipeline.finish()
        self.assertTrue(json.loads(self.pipeline.state_path.read_text())['complete'])
        self.assertEqual((self.pipeline.output / 'Arras.app.zip').read_bytes(), original)
        self.assertEqual(self.verify_mock.call_args.args[1], self.pipeline.output / 'Arras.app.zip')

    def test_completed_output_can_be_rechecked_without_repackaging_or_upload(self):
        self.pipeline.state['complete'] = True
        self.pipeline.finish()
        self.assertTrue(self.pipeline.state['complete'])
        self.assertEqual(self.verify_mock.call_count, 1)

    def test_wrong_existing_receipt_never_overwrites_artifacts(self):
        original = (self.pipeline.output / 'Arras.dmg').read_bytes()
        self.receipt['appSubmissionID'] = 'other-request'
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, 'different notarization'):
            self.pipeline.finish()
        self.assertEqual((self.pipeline.output / 'Arras.dmg').read_bytes(), original)
        self.verify_mock.assert_not_called()

    def test_changed_existing_artifact_is_rejected_without_repairing_it(self):
        artifact = self.pipeline.output / 'Arras.app.zip'
        artifact.write_bytes(b'changed fixture')
        with self.assertRaisesRegex(ValueError, 'artifacts changed'):
            self.pipeline.finish()
        self.assertEqual(artifact.read_bytes(), b'changed fixture')
        self.verify_mock.assert_not_called()

    def test_unaccepted_state_cannot_promote_existing_output(self):
        self.pipeline.state['dmg']['accepted'] = False
        with self.assertRaisesRegex(ValueError, 'lacks accepted'):
            self.pipeline.finish()
        self.assertFalse(self.pipeline.state.get('complete', False))

    def test_receipt_source_must_match_actual_candidate(self):
        self.receipt['sourceSHA256'] = 'b' * 64
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, 'different notarization'):
            self.pipeline.finish()

    def test_processor_change_during_final_verification_keeps_state_uncommitted(self):
        self.verify_mock.side_effect = lambda *args: setattr(self.pipeline, 'processor_sha256', '0' * 64)
        with self.assertRaisesRegex(ValueError, 'source changed during this run'):
            self.pipeline.finish()
        self.assertFalse(self.pipeline.state.get('complete', False))
        self.assertFalse(self.pipeline.state_path.exists())


if __name__ == '__main__':
    unittest.main()

"""Exercise the actual swap helper's rollback against temporary app directories."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

class RollbackTests(unittest.TestCase):
    def test_replacement_lookup_resolves_directory_aliases(self):
        source = (Path(__file__).resolve().parent.parent / 'Sources/App/Updater.swift').read_text()
        function = re.search(r'        stop_replacement\(\) \{.*?\n        \}', source, re.S).group(0)
        function = function.replace('/bin/ps -axo pid=,comm=', 'printf "%s\\n" "$FIXTURE_PROCESSES"')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            actual = root / 'physical'; actual.mkdir()
            alias = root / 'alias'; alias.symlink_to(actual, target_is_directory=True)
            executable = actual / 'Arras.app/Contents/MacOS/Arras'
            executable.parent.mkdir(parents=True); executable.touch()
            import os
            env = dict(os.environ, FIXTURE_PROCESSES=f'123 {executable}\n456 /Applications/Arras.app/Contents/MacOS/Arras')
            script = 'DEST="$1"\nkill() { if [ "$1" = -TERM ]; then echo "$2"; else return 1; fi; }\n'
            result = subprocess.run(['/bin/sh', '-c', script + function + '\nstop_replacement',
                                     'fixture', str(alias / 'Arras.app')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '123')

    def exercise(self, failure):
        source = (Path(__file__).resolve().parent.parent / 'Sources/App/Updater.swift').read_text()
        function = re.search(r'        restore_previous\(\) \{.*?\n        \}', source, re.S).group(0)
        # Opening the fixture is the sole platform side effect replaced in this harness.
        function = function.replace('/usr/bin/open "$DEST" >/dev/null 2>&1 || true', ':')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); work = root / 'work'; backup = work / 'previous.app'; destination = root / 'Arras.app'
            backup.mkdir(parents=True); destination.mkdir()
            (backup / 'executable').write_text('known good')
            script = 'WORK="$1"; BACKUP="$2"; DEST="$3"\ncleanup() { rm -rf "$WORK"; }\nstop_replacement() { :; }\n'
            if failure == 'move': script += 'mv() { return 1; }\n'
            if failure == 'remove': script += 'rm() { return 1; }\n'
            result = subprocess.run(['/bin/sh', '-c', script + function + '\nrestore_previous', 'fixture', str(work), str(backup), str(destination)])
            if failure:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((backup / 'executable').read_text(), 'known good')
                self.assertTrue(work.exists())
            else:
                self.assertEqual(result.returncode, 0)
                self.assertEqual((destination / 'executable').read_text(), 'known good')
                self.assertFalse(work.exists())
    def test_failed_restore_preserves_backup(self): self.exercise('move')
    def test_failed_destination_removal_preserves_backup(self): self.exercise('remove')
    def test_successful_restore_cleans_work_directory(self): self.exercise(None)

    @unittest.skipUnless(sys.platform == "darwin", "Full swap uses macOS ditto and xattr; run on the macOS build job")
    def test_complete_swap_and_failure_recovery(self):
        source = (Path(__file__).resolve().parent.parent / 'Sources/App/Updater.swift').read_text()
        script = textwrap.dedent(re.search(r'let script = """\n(.*?)\n        """', source, re.S).group(1))
        # Exercise the shipped shell sequence. Replace only app launching and timing;
        # the apps are plain temporary directories and never registered with macOS.
        script = script.replace('/usr/bin/open', '"$FIXTURE_OPEN"')
        script = script.replace('/usr/bin/ditto', '"$FIXTURE_COPY"')
        script = script.replace('#!/bin/sh', '#!/bin/sh\nsleep() { :; }')
        for scenario in ('healthy', 'copy_failure', 'launch_failure', 'no_health'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                work = root / 'work'; new = work / 'new.app'; backup = work / 'previous.app'
                destination = root / 'Arras.app'; health = work / 'health'
                new.mkdir(parents=True); destination.mkdir()
                (new / 'version').write_text('new')
                (destination / 'version').write_text('old')
                launcher = root / 'launch.sh'
                launcher.write_text('''#!/bin/sh
if [ "$(cat "$1/version")" = old ]; then exit 0; fi
case "$FIXTURE_SCENARIO" in
  launch_failure) exit 1 ;;
  no_health) exit 0 ;;
  *) touch "$FIXTURE_HEALTH" ;;
esac
''')
                launcher.chmod(0o755)
                import os
                env = dict(os.environ, FIXTURE_OPEN=str(launcher),
                           FIXTURE_COPY='/usr/bin/false' if scenario == 'copy_failure' else '/usr/bin/ditto',
                           FIXTURE_SCENARIO=scenario, FIXTURE_HEALTH=str(health))
                result = subprocess.run(['/bin/sh', '-c', script, 'fixture', '999999999',
                                         str(new), str(destination), str(backup), str(work), str(health)],
                                        env=env, timeout=10, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0 if scenario == 'healthy' else 1, result.stderr)
                self.assertEqual((destination / 'version').read_text(), 'new' if scenario == 'healthy' else 'old')
                self.assertFalse(work.exists())

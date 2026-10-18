"""Run the real packaging argument construction under the system's Bash.

macOS ships Bash 3.2, where expanding an empty array with nounset aborts.
These tests exercise build.sh's actual shell fragment without invoking Xcode.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class BuildShellTests(unittest.TestCase):
    def validation_arguments(self, pilot):
        source = (Path(__file__).resolve().parent.parent / "build.sh").read_text()
        start = source.index("VALIDATION=")
        end = source.index("\npython3 - ", start)
        fragment = source[start:end]
        with tempfile.TemporaryDirectory(prefix="Arras shell test ") as directory:
            root = Path(directory).resolve()
            scripts = root / "scripts"
            scripts.mkdir()
            # Record the validator's received arguments; no app or user library is touched.
            (scripts / "validate_app_bundle.py").write_text(
                "import json, sys\nprint(json.dumps(sys.argv[1:]))\n"
            )
            result = subprocess.run(
                ["/bin/bash", "-c", 'set -euo pipefail\nPILOT_BUILD="$1"\nAPP_PATH="$2"\n' + fragment,
                 "build-validation-test", str(pilot), str(root / "Release/Arras.app")],
                cwd=root, text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads(result.stdout)
            expected = [str(root / "Release/Arras.app"), "--project", str(root / "project.yml")]
            if pilot:
                expected += ["--pilot-build", str(pilot)]
            self.assertEqual(args, expected)

    def test_public_build_validates_with_nounset_and_paths_containing_spaces(self):
        self.validation_arguments(0)

    def test_pilot_build_passes_its_explicit_build_number(self):
        self.validation_arguments(2210)


if __name__ == "__main__":
    unittest.main()

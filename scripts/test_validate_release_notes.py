"""Focused CLI regression checks for human-authored release rendering."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from validate_release_notes import PRODUCT_FOOTER

SCRIPT = Path(__file__).with_name("validate_release_notes.py")


class ReleaseMarkdownTests(unittest.TestCase):
    def test_preserves_release_text_and_appends_footer(self):
        for details in ([], ["An authored detail with **Markdown**."]):
            with self.subTest(details=details), tempfile.TemporaryDirectory() as directory:
                notes = {
                    "version": "2.4.7",
                    "title": "New Arras icon",
                    "summary": "A human-authored summary with punctuation — unchanged.",
                    "details": details,
                }
                Path(directory, "2.4.7.json").write_text(json.dumps(notes), encoding="utf-8")
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), "--version", "2.4.7",
                     "--notes-dir", directory, "--print-markdown"],
                    check=True, capture_output=True, text=True,
                )
                original = f"# {notes['title']}\n\n{notes['summary']}\n\n"
                if details:
                    original += "## Details\n\n" + "".join(f"- {detail}\n" for detail in details)
                self.assertEqual(result.stdout, original + "\n" + PRODUCT_FOOTER + "\n")


if __name__ == "__main__":
    unittest.main()

"""Focused CLI regression checks for human-authored release rendering."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_release_notes import PRODUCT_FOOTER, product_footer

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

    def test_footer_uses_current_public_distribution_contract(self):
        self.assertIn("macOS 14.0+", PRODUCT_FOOTER)
        self.assertIn("Universal Apple Silicon (`arm64`) and Intel (`x86_64`) release downloads", PRODUCT_FOOTER)
        self.assertIn("[Official website](https://arras.yashashwi.me/)", PRODUCT_FOOTER)
        self.assertIn("[Installation guide](https://arras.yashashwi.me/#install)", PRODUCT_FOOTER)
        self.assertIn("[Source](https://github.com/yashashwi-s/Arras)", PRODUCT_FOOTER)

    def test_footer_reflects_metadata_architecture_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata_path = Path(directory, "product-metadata.json")
            metadata_path.write_text(
                json.dumps(
                    {
                        "minimumMacOS": "15.0",
                        "repositoryUrl": "https://example.test/source",
                        "documentation": {
                            "mainUrl": "https://example.test/",
                            "installationUrl": "https://example.test/install",
                        },
                        "publicRelease": {"architectures": ["arm64"]},
                    }
                ),
                encoding="utf-8",
            )
            footer = product_footer(metadata_path)
            self.assertIn("macOS 15.0+ · Apple Silicon (`arm64`) release downloads", footer)
            self.assertNotIn("Intel", footer)
            self.assertIn("https://example.test/install", footer)


if __name__ == "__main__":
    unittest.main()

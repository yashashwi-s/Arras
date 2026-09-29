"""Focused regression tests for pull-request documentation declarations."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_pr_documentation import validate


class PullRequestDocumentationTests(unittest.TestCase):
    def test_ignores_non_behavior_changes(self):
        validate(["scripts/validate_product_metadata.py"], "")

    def test_requires_changed_docs_for_updated_declaration(self):
        with self.assertRaisesRegex(ValueError, "documentation file"):
            validate(
                ["Sources/App/MenuController.swift"],
                "- [x] Documentation updated: FEATURES.md",
            )

    def test_accepts_a_documented_behavior_change(self):
        validate(
            ["Sources/App/MenuController.swift", "FEATURES.md"],
            "- [x] Documentation updated: FEATURES.md",
        )

    def test_requires_a_real_no_docs_reason(self):
        with self.assertRaisesRegex(ValueError, "written reason"):
            validate(
                ["Sources/App/MenuController.swift"],
                "- [x] No documentation update needed: <!-- Explain why. -->",
            )

    def test_rejects_two_checked_declarations(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            validate(
                ["Sources/App/MenuController.swift", "README.md"],
                "- [x] Documentation updated: README.md\n"
                "- [x] No documentation update needed: Internal refactor",
            )


if __name__ == "__main__":
    unittest.main()

"""Regression checks for the version-independent product contract."""

import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_product_metadata import ValidationError, validate


REPOSITORY = Path(__file__).resolve().parent.parent


class ProductMetadataTests(unittest.TestCase):
    def with_repository_copy(self):
        directory = tempfile.TemporaryDirectory()
        destination = Path(directory.name) / "arras"
        shutil.copytree(
            REPOSITORY,
            destination,
            ignore=shutil.ignore_patterns(".git", "build", "DerivedData", "__pycache__"),
        )
        (destination / "README.md").write_text(
            "# Arras\n\nOpen Anyway with your Mac password or Touch ID.\n",
            encoding="utf-8",
        )
        (destination / "FEATURES.md").write_text("# Arras feature contract\n", encoding="utf-8")
        (destination / "ARCHITECTURE.md").write_text("# Architecture\n", encoding="utf-8")
        (destination / "CHANGELOG.md").write_text("# Changelog\n", encoding="utf-8")
        return directory, destination

    def assert_invalid(self, mutate, expected_message):
        directory, repository = self.with_repository_copy()
        with directory:
            mutate(repository)
            with self.assertRaisesRegex(ValidationError, expected_message):
                validate(repository)

    def test_rejects_malformed_metadata(self):
        self.assert_invalid(
            lambda repository: (repository / "product-metadata.json").write_text("{", encoding="utf-8"),
            "cannot read product-metadata.json",
        )

    def test_rejects_release_architecture_that_omits_intel_downloads(self):
        def mutate(repository):
            path = repository / "product-metadata.json"
            metadata = json.loads(path.read_text(encoding="utf-8"))
            metadata["publicRelease"]["architectures"] = ["arm64"]
            path.write_text(json.dumps(metadata), encoding="utf-8")

        self.assert_invalid(mutate, "publicRelease.architectures")

    def test_rejects_homebrew_as_a_current_distribution_channel(self):
        def mutate(repository):
            path = repository / "product-metadata.json"
            metadata = json.loads(path.read_text(encoding="utf-8"))
            metadata["homebrew"] = {"cask": "arras"}
            path.write_text(json.dumps(metadata), encoding="utf-8")

        self.assert_invalid(mutate, "must not define a Homebrew distribution")

    def test_rejects_versioned_feature_heading(self):
        def mutate(repository):
            path = repository / "FEATURES.md"
            path.write_text("# Arras feature contract\n\n## 2.4.9 shipped scope\n", encoding="utf-8")

        self.assert_invalid(mutate, "FEATURES.md headings")

    def test_rejects_broken_local_document_link(self):
        def mutate(repository):
            path = repository / "README.md"
            path.write_text(path.read_text(encoding="utf-8") + "\n[Missing guide](missing-guide.md)\n", encoding="utf-8")

        self.assert_invalid(mutate, "local link target does not exist")

    def test_rejects_deprecated_consumer_trust_phrases(self):
        phrases = (
            "does not establish that a download is safe",
            "does not establish\nwhether an app is safe",
            "matching checksum verifies bytes, not safety",
            "only proceed if you trust the official download",
            "if you trust that the official download",
            "if you trust the official download",
            "if you trust that download",
            "Do not bypass a warning about detected malware or a damaged app",
            "material distribution limitation",
            "material distribution limitations",
        )
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assert_invalid(
                    lambda repository, phrase=phrase: (
                        repository / "SECURITY.md"
                    ).write_text(
                        (repository / "SECURITY.md").read_text(encoding="utf-8")
                        + f"\n{phrase}\n",
                        encoding="utf-8",
                    ),
                    "deprecated trust or quarantine guidance",
                )

    def test_allows_technical_checksum_quarantine_and_historical_copy(self):
        directory, repository = self.with_repository_copy()
        with directory:
            security = repository / "SECURITY.md"
            security.write_text(
                security.read_text(encoding="utf-8")
                + "\nThe updater checks the matching checksum and removes quarantine from the verified staged bundle.\n",
                encoding="utf-8",
            )
            changelog = repository / "CHANGELOG.md"
            changelog.write_text(
                "# Changelog\n\nDo not bypass a warning about detected malware or a damaged app.\n",
                encoding="utf-8",
            )
            validate(repository)

    def test_requires_first_launch_confirmation_in_readme(self):
        def mutate(repository):
            path = repository / "README.md"
            contents = path.read_text(encoding="utf-8").replace("Open Anyway", "Open the app")
            path.write_text(contents, encoding="utf-8")

        self.assert_invalid(mutate, "README.md must explain the macOS Open Anyway path")

    def test_requires_password_or_touch_id_explanation_in_security(self):
        def mutate(repository):
            path = repository / "SECURITY.md"
            contents = path.read_text(encoding="utf-8").replace("Touch ID", "biometric approval")
            path.write_text(contents, encoding="utf-8")

        self.assert_invalid(mutate, "SECURITY.md must explain the Mac password or Touch ID confirmation")


if __name__ == "__main__":
    unittest.main()

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
        destination.mkdir()
        # The validator needs configuration and documentation, not source,
        # personal recovery copies or unrelated files in the working tree.
        for relative in (
            "product-metadata.json", "project.yml", "build.sh", "LICENSE",
            "appcast.json", "SECURITY.md", ".github/workflows/build-intel.yml",
            ".github/workflows/release.yml",
        ):
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY / relative, target)
        (destination / "README.md").write_text(
            "# Arras\n\nDeveloper ID signed and notarized. Open Anyway with your Mac password or Touch ID.\n",
            encoding="utf-8",
        )
        (destination / "SECURITY.md").write_text(
            "# Security\n\nDeveloper ID signed and notarized. Open Anyway with your Mac password or Touch ID.\n",
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

    @staticmethod
    def set_legacy_distribution(repository):
        path = repository / "product-metadata.json"
        metadata = json.loads(path.read_text())
        metadata["publicRelease"].update(signing="ad-hoc", notarized=False)
        path.write_text(json.dumps(metadata))

    def test_rejects_old_domain_as_current_canonical(self):
        def mutate(repository):
            path = repository / "product-metadata.json"
            metadata = json.loads(path.read_text())
            metadata["canonicalUrl"] = "https://arras.yashashwi.me/"
            path.write_text(json.dumps(metadata))
        self.assert_invalid(mutate, "canonicalUrl must be https://tryarras.tech/")

    def test_requires_current_notarized_installation_in_readme(self):
        def mutate(repository):
            path = repository / "README.md"
            path.write_text(path.read_text().replace("Developer ID signed and notarized.", ""))
        self.assert_invalid(mutate, "README.md must explain Developer ID signing and notarized installation")

    def test_rejects_malformed_metadata(self):
        self.assert_invalid(
            lambda repository: (repository / "product-metadata.json").write_text("{", encoding="utf-8"),
            "cannot read product-metadata.json",
        )

    def test_accepts_developer_id_with_pending_or_completed_notarization(self):
        for notarized in (False, True):
            with self.subTest(notarized=notarized):
                directory, repository = self.with_repository_copy()
                with directory:
                    path = repository / "product-metadata.json"
                    metadata = json.loads(path.read_text(encoding="utf-8"))
                    metadata["publicRelease"].update(signing="developer-id", notarized=notarized)
                    path.write_text(json.dumps(metadata), encoding="utf-8")
                    validate(repository)

    def test_rejects_notarization_without_developer_id(self):
        def mutate(repository):
            path = repository / "product-metadata.json"
            metadata = json.loads(path.read_text(encoding="utf-8"))
            metadata["publicRelease"].update(signing="ad-hoc", notarized=True)
            path.write_text(json.dumps(metadata), encoding="utf-8")

        self.assert_invalid(mutate, "notarized distribution requires Developer ID signing")

    def test_rejects_development_signing_as_a_distribution_identity(self):
        def mutate(repository):
            path = repository / "product-metadata.json"
            metadata = json.loads(path.read_text(encoding="utf-8"))
            metadata["publicRelease"]["signing"] = "apple-development"
            path.write_text(json.dumps(metadata), encoding="utf-8")

        self.assert_invalid(mutate, "publicRelease.signing")

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
            self.set_legacy_distribution(repository)
            path = repository / "README.md"
            contents = path.read_text(encoding="utf-8").replace("Open Anyway", "Open the app")
            path.write_text(contents, encoding="utf-8")

        self.assert_invalid(mutate, "README.md must explain the macOS Open Anyway path")

    def test_requires_password_or_touch_id_explanation_in_security(self):
        def mutate(repository):
            self.set_legacy_distribution(repository)
            path = repository / "SECURITY.md"
            contents = path.read_text(encoding="utf-8").replace("Touch ID", "biometric approval")
            path.write_text(contents, encoding="utf-8")

        self.assert_invalid(mutate, "SECURITY.md must explain the Mac password or Touch ID confirmation")


if __name__ == "__main__":
    unittest.main()

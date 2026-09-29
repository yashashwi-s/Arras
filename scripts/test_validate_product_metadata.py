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
        (destination / "README.md").write_text("# Arras\n", encoding="utf-8")
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


if __name__ == "__main__":
    unittest.main()

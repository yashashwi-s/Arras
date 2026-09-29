#!/usr/bin/env python3
"""Validate Arras's version-independent public product contract."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent.parent


class ValidationError(Exception):
    """A product-contract validation failure."""


def fail(message: str) -> None:
    raise ValidationError(message)


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    return value


def require_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label} must be a boolean")
    return value


def require_https_url(value: Any, label: str, *, allow_fragment: bool = False) -> str:
    url = require_string(value, label)
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or (parsed.fragment and not allow_fragment)
    ):
        fail(f"{label} must be a well-formed HTTPS URL without credentials or a fragment")
    return url


def require_string_list(value: Any, label: str) -> list[str]:
    if (
        not isinstance(value, list)
        or not value
        or any(not isinstance(item, str) or not item.strip() for item in value)
    ):
        fail(f"{label} must be a non-empty array of non-empty strings")
    return value


def load_project_scalars(path: Path) -> dict[tuple[str, ...], str]:
    """Read scalar mapping values from the simple project.yml without PyYAML."""
    scalars: dict[tuple[str, ...], str] = {}
    stack: list[tuple[int, str]] = []
    key_value = re.compile(r"^(\s*)([A-Za-z0-9_.-]+):(?:\s*(.*?))?\s*$")

    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        match = key_value.match(raw_line)
        if match is None:
            continue
        indentation, key, raw_value = match.groups()
        if "\t" in indentation:
            fail(f"project.yml:{line_number}: tabs are not supported in indentation")
        indent = len(indentation)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        path_parts = tuple(item[1] for item in stack) + (key,)
        value = (raw_value or "").split(" #", 1)[0].strip()
        if value:
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            scalars[path_parts] = value
        else:
            stack.append((indent, key))
    return scalars


def project_value(scalars: dict[tuple[str, ...], str], path: tuple[str, ...]) -> str:
    try:
        return scalars[path]
    except KeyError:
        fail(f"project.yml is missing {'.'.join(path)}")


def validate_local_doc_links(root: Path, documents: list[str]) -> None:
    """Reject broken repository-relative Markdown links in required documents."""
    link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)")
    for document in documents:
        document_path = root / document
        for line_number, line in enumerate(document_path.read_text(encoding="utf-8").splitlines(), 1):
            for target in link_pattern.findall(line):
                target = target.strip("<>")
                if target.startswith(("#", "https://", "http://", "mailto:", "tel:")):
                    continue
                relative_target = target.split("#", 1)[0].split("?", 1)[0]
                if not relative_target:
                    continue
                linked_path = (document_path.parent / relative_target).resolve()
                try:
                    linked_path.relative_to(root.resolve())
                except ValueError:
                    fail(f"{document}:{line_number}: local link leaves the repository: {target}")
                if not linked_path.exists():
                    fail(f"{document}:{line_number}: local link target does not exist: {target}")


def validate_documentation(root: Path) -> None:
    documents = ["README.md", "FEATURES.md", "ARCHITECTURE.md", "CHANGELOG.md"]
    for document in documents:
        if not (root / document).is_file():
            fail(f"required documentation is missing: {document}")

    readme = (root / "README.md").read_text(encoding="utf-8")
    if len(readme.splitlines()) > 200:
        fail("README.md exceeds the 200-line budget")
    if re.search(
        r"(?im)^#{1,6}\s+.*\bHomebrew\b|\bbrew\s+(?:tap|trust)\b|\bbrew\s+install\s+--cask\s+arras\b",
        readme,
    ):
        fail("README.md must not advertise Homebrew distribution")

    features = (root / "FEATURES.md").read_text(encoding="utf-8")
    if re.search(r"(?im)^#{1,6}\s+.*\b\d+\.\d+(?:\.\d+)?\b", features):
        fail("FEATURES.md headings must describe durable behavior, not a release version")
    if re.search(r"(?im)^#{1,6}\s+.*\bshipped scope\b", features):
        fail("FEATURES.md must not contain release-specific shipped-scope headings")

    validate_local_doc_links(root, documents)


def validate(repository_root: Path = ROOT) -> None:
    metadata_path = repository_root / "product-metadata.json"
    project_path = repository_root / "project.yml"
    if not metadata_path.is_file():
        fail("product-metadata.json does not exist")
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read product-metadata.json: {error}")

    root = require_mapping(metadata, "product metadata")
    if root.get("schemaVersion") != 2:
        fail("schemaVersion must be 2")
    if root.get("name") != "Arras":
        fail('name must be "Arras"')
    if require_https_url(root.get("canonicalUrl"), "canonicalUrl") != "https://arras.yashashwi.me/":
        fail("canonicalUrl must be https://arras.yashashwi.me/")
    if require_https_url(root.get("repositoryUrl"), "repositoryUrl") != "https://github.com/yashashwi-s/Arras":
        fail("repositoryUrl must be the canonical Arras repository")

    publisher = require_mapping(root.get("publisher"), "publisher")
    if publisher.get("name") != "Yashashwi Singhania":
        fail('publisher.name must be "Yashashwi Singhania"')
    if require_https_url(publisher.get("url"), "publisher.url") != "https://yashashwi.me/":
        fail("publisher.url must be https://yashashwi.me/")
    require_string(root.get("category"), "category")
    require_string(root.get("shortDescription"), "shortDescription")
    require_string(root.get("repositoryDescription"), "repositoryDescription")
    require_string_list(root.get("historicalNames"), "historicalNames")
    if not re.fullmatch(r"\d+\.\d+", require_string(root.get("minimumMacOS"), "minimumMacOS")):
        fail("minimumMacOS must use major.minor form")

    documentation = require_mapping(root.get("documentation"), "documentation")
    expected_documentation = {
        "mainUrl": "https://arras.yashashwi.me/",
        "installationUrl": "https://arras.yashashwi.me/#install",
        "quickStartUrl": "https://arras.yashashwi.me/faqs#how-to-use",
        "faqUrl": "https://arras.yashashwi.me/faqs",
        "securityUrl": "https://arras.yashashwi.me/security",
        "featureContractUrl": "https://github.com/yashashwi-s/Arras/blob/main/FEATURES.md",
        "architectureUrl": "https://github.com/yashashwi-s/Arras/blob/main/ARCHITECTURE.md",
        "securityPolicyUrl": "https://github.com/yashashwi-s/Arras/blob/main/SECURITY.md",
    }
    for key, expected_url in expected_documentation.items():
        if require_https_url(
            documentation.get(key), f"documentation.{key}", allow_fragment=True
        ) != expected_url:
            fail(f"documentation.{key} must be {expected_url}")

    public_release = require_mapping(root.get("publicRelease"), "publicRelease")
    architectures = require_string_list(public_release.get("architectures"), "publicRelease.architectures")
    if architectures != ["arm64", "x86_64"]:
        fail('publicRelease.architectures must be ["arm64", "x86_64"] for the shipped universal artifact')
    if require_https_url(public_release.get("sourceUrl"), "publicRelease.sourceUrl") != "https://github.com/yashashwi-s/Arras/releases/latest":
        fail("publicRelease.sourceUrl must be the GitHub latest-release URL")
    if public_release.get("signing") != "ad-hoc":
        fail('publicRelease.signing must be "ad-hoc"')
    if require_boolean(public_release.get("notarized"), "publicRelease.notarized"):
        fail("publicRelease.notarized must be false")

    source_build = require_mapping(root.get("sourceBuild"), "sourceBuild")
    if require_https_url(source_build.get("sourceUrl"), "sourceBuild.sourceUrl") != "https://github.com/yashashwi-s/Arras":
        fail("sourceBuild.sourceUrl must be the Arras source repository")
    intel_supported = require_boolean(source_build.get("intelSupported"), "sourceBuild.intelSupported")
    intel_workflow = repository_root / ".github" / "workflows" / "build-intel.yml"
    if intel_supported:
        if not intel_workflow.is_file():
            fail("sourceBuild.intelSupported is true but the Intel build workflow is missing")
        workflow_text = intel_workflow.read_text(encoding="utf-8")
        if "ARCHS=x86_64" not in workflow_text:
            fail("the Intel build workflow does not explicitly build x86_64")

    release_workflow = repository_root / ".github" / "workflows" / "release.yml"
    if not release_workflow.is_file():
        fail("the release workflow is missing")
    release_workflow_text = release_workflow.read_text(encoding="utf-8")
    if "ARCHS=\"arm64 x86_64\"" not in release_workflow_text:
        fail("the release workflow must explicitly build the public universal architecture set")

    license_data = require_mapping(root.get("license"), "license")
    if license_data.get("spdx") != "MIT":
        fail('license.spdx must be "MIT"')
    require_https_url(license_data.get("url"), "license.url")
    if not (repository_root / "LICENSE").is_file():
        fail("LICENSE does not exist")
    require_boolean(root.get("telemetry"), "telemetry")

    feature_contract = require_string(root.get("featureContractPath"), "featureContractPath")
    feature_path = (repository_root / feature_contract).resolve()
    try:
        feature_path.relative_to(repository_root.resolve())
    except ValueError:
        fail("featureContractPath must stay inside the repository")
    if not feature_path.is_file():
        fail(f"featureContractPath does not exist: {feature_contract}")

    if "homebrew" in root:
        fail("product metadata must not define a Homebrew distribution")

    scalars = load_project_scalars(project_path)
    project_bundle = project_value(
        scalars,
        ("targets", "Arras", "settings", "base", "PRODUCT_BUNDLE_IDENTIFIER"),
    )
    if root.get("bundleIdentifier") != project_bundle:
        fail(f"bundleIdentifier must match project.yml ({project_bundle})")
    deployment_target = project_value(scalars, ("options", "deploymentTarget", "macOS"))
    build_target = project_value(scalars, ("settings", "base", "MACOSX_DEPLOYMENT_TARGET"))
    if deployment_target != build_target:
        fail("project.yml deploymentTarget.macOS and MACOSX_DEPLOYMENT_TARGET disagree")
    if root.get("minimumMacOS") != deployment_target:
        fail(f"minimumMacOS must match project.yml ({deployment_target})")
    validate_documentation(repository_root)


def main() -> int:
    try:
        validate()
    except ValidationError as error:
        print(f"product metadata validation failed: {error}", file=sys.stderr)
        return 1
    print("product-metadata.json is valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

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
METADATA_PATH = ROOT / "product-metadata.json"
PROJECT_PATH = ROOT / "project.yml"


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


def require_https_url(value: Any, label: str) -> str:
    url = require_string(value, label)
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
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


def validate() -> None:
    if not METADATA_PATH.is_file():
        fail("product-metadata.json does not exist")
    try:
        metadata = json.loads(METADATA_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read product-metadata.json: {error}")

    root = require_mapping(metadata, "product metadata")
    if root.get("schemaVersion") != 1:
        fail("schemaVersion must be 1")
    if root.get("name") != "Arras":
        fail('name must be "Arras"')
    if require_https_url(root.get("canonicalUrl"), "canonicalUrl") != "https://arras.yashashwi.me/":
        fail("canonicalUrl must be https://arras.yashashwi.me/")
    if require_https_url(root.get("repositoryUrl"), "repositoryUrl") != "https://github.com/yashashwi-s/Arras":
        fail("repositoryUrl must be the canonical Arras repository")

    publisher = require_mapping(root.get("publisher"), "publisher")
    require_string(publisher.get("name"), "publisher.name")
    require_https_url(publisher.get("url"), "publisher.url")
    require_string(root.get("category"), "category")
    require_string(root.get("shortDescription"), "shortDescription")
    require_string(root.get("repositoryDescription"), "repositoryDescription")
    require_string_list(root.get("historicalNames"), "historicalNames")
    if not re.fullmatch(r"\d+\.\d+", require_string(root.get("minimumMacOS"), "minimumMacOS")):
        fail("minimumMacOS must use major.minor form")

    public_release = require_mapping(root.get("publicRelease"), "publicRelease")
    architectures = require_string_list(public_release.get("architectures"), "publicRelease.architectures")
    if architectures != ["arm64"]:
        fail('publicRelease.architectures must be ["arm64"] for the shipped artifact')
    require_boolean(public_release.get("notarized"), "publicRelease.notarized")

    source_build = require_mapping(root.get("sourceBuild"), "sourceBuild")
    intel_supported = require_boolean(source_build.get("intelSupported"), "sourceBuild.intelSupported")
    intel_workflow = ROOT / ".github" / "workflows" / "build-intel.yml"
    if intel_supported:
        if not intel_workflow.is_file():
            fail("sourceBuild.intelSupported is true but the Intel build workflow is missing")
        workflow_text = intel_workflow.read_text(encoding="utf-8")
        if "ARCHS=x86_64" not in workflow_text:
            fail("the Intel build workflow does not explicitly build x86_64")

    license_data = require_mapping(root.get("license"), "license")
    if license_data.get("spdx") != "MIT":
        fail('license.spdx must be "MIT"')
    require_https_url(license_data.get("url"), "license.url")
    if not (ROOT / "LICENSE").is_file():
        fail("LICENSE does not exist")
    require_boolean(root.get("telemetry"), "telemetry")

    feature_contract = require_string(root.get("featureContractPath"), "featureContractPath")
    feature_path = (ROOT / feature_contract).resolve()
    try:
        feature_path.relative_to(ROOT.resolve())
    except ValueError:
        fail("featureContractPath must stay inside the repository")
    if not feature_path.is_file():
        fail(f"featureContractPath does not exist: {feature_contract}")

    homebrew = require_mapping(root.get("homebrew"), "homebrew")
    if homebrew.get("tap") != "yashashwi-s/tap":
        fail('homebrew.tap must be "yashashwi-s/tap"')
    if require_https_url(homebrew.get("tapRepository"), "homebrew.tapRepository") != "https://github.com/yashashwi-s/homebrew-tap":
        fail("homebrew.tapRepository must be the canonical tap repository")
    if homebrew.get("cask") != "arras":
        fail('homebrew.cask must be "arras"')
    if homebrew.get("trustScope") != "tap":
        fail('homebrew.trustScope must be "tap"')
    expected_commands = [
        "brew tap yashashwi-s/tap",
        "brew trust yashashwi-s/tap",
        "brew install --cask arras",
    ]
    commands = require_string_list(homebrew.get("commands"), "homebrew.commands")
    if commands != expected_commands:
        fail(f"homebrew.commands must exactly equal {expected_commands!r}")
    if any("brew trust --cask" in command for command in commands):
        fail("homebrew.commands must not contain cask-level trust")

    scalars = load_project_scalars(PROJECT_PATH)
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

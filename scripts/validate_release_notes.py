#!/usr/bin/env python3
"""Validate the human-authored release metadata consumed by the updater.

Each public version owns one JSON file at release-notes/<version>.json. The release
workflow deliberately reads this file instead of asking GitHub or an AI service to
invent copy. Keeping the contract here also lets pull-request CI catch a placeholder
before a tag is pushed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, NoReturn


VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
PLACEHOLDER_RE = re.compile(
    r"\b(?:todo|tbd|placeholder|fill\s+this\s+in|coming\s+soon|lorem\s+ipsum|n/?a)\b",
    re.IGNORECASE,
)


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def validate(path: Path, expected_version: str) -> dict[str, Any]:
    if not path.is_file():
        fail(f"missing human-authored release notes: {path}")

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{path} is not valid UTF-8 JSON: {error}")

    if not isinstance(data, dict):
        fail(f"{path} must contain a JSON object")

    for key in ("version", "title", "summary"):
        if not isinstance(data.get(key), str) or not data[key].strip():
            fail(f"{path} must contain a non-empty string field: {key}")

    version = data["version"].strip()
    title = data["title"].strip()
    summary = data["summary"].strip()

    if not VERSION_RE.fullmatch(version):
        fail(f"{path}: version must be major.minor.patch (got {version!r})")
    if version != expected_version:
        fail(f"{path}: metadata version {version} does not match expected {expected_version}")
    if path.stem != version:
        fail(f"{path}: filename must be {version}.json")
    if len(title) < 3 or len(title) > 80:
        fail(f"{path}: title must be between 3 and 80 characters")
    if len(summary) < 20 or len(summary) > 280:
        fail(f"{path}: summary must be between 20 and 280 characters")
    if "\n" in title or "\r" in title or "\n" in summary or "\r" in summary:
        fail(f"{path}: title and summary must each fit on one line")
    if PLACEHOLDER_RE.search(title) or PLACEHOLDER_RE.search(summary):
        fail(f"{path}: title/summary still contains placeholder copy")

    details = data.get("details")
    if details is not None:
        if not isinstance(details, list) or not all(isinstance(entry, str) and entry.strip() for entry in details):
            fail(f"{path}: details must be a list of non-empty strings when present")
        if any("\n" in entry or "\r" in entry for entry in details):
            fail(f"{path}: details entries must each fit on one line")
        if any(PLACEHOLDER_RE.search(entry) for entry in details):
            fail(f"{path}: details still contains placeholder copy")

    return {
        "version": version,
        "title": title,
        "summary": summary,
        "details": details or [],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="public version to validate")
    parser.add_argument("--notes-dir", type=Path, default=Path("release-notes"))
    parser.add_argument(
        "--all",
        action="store_true",
        help="also validate every release-notes/*.json file in the directory",
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument(
        "--print-json",
        action="store_true",
        help="print the normalized current-version metadata after validation",
    )
    output.add_argument(
        "--print-markdown",
        action="store_true",
        help="print a GitHub release body from the validated metadata",
    )
    args = parser.parse_args()

    try:
        current = validate(args.notes_dir / f"{args.version}.json", args.version)
        if args.all:
            for path in sorted(args.notes_dir.glob("*.json")):
                validate(path, path.stem)
    except ValueError as error:
        print(f"release-notes validation failed: {error}", file=sys.stderr)
        return 1

    if args.print_json:
        print(json.dumps(current, ensure_ascii=False, separators=(",", ":")))
    elif args.print_markdown:
        print(f"# {current['title']}\n")
        print(f"{current['summary']}\n")
        if current["details"]:
            print("## Details\n")
            for detail in current["details"]:
                print(f"- {detail}")
    else:
        print(f"validated human-authored release notes for {args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

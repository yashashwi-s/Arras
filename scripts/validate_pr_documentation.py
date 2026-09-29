#!/usr/bin/env python3
"""Require an accountable documentation decision for App behavior changes."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


DOCUMENTS = {"README.md", "FEATURES.md", "ARCHITECTURE.md", "SECURITY.md", "CONTRIBUTING.md"}
BEHAVIOR_SOURCE_PREFIX = "Sources/App/"
DECLARATIONS = {
    "updated": re.compile(r"(?m)^- \[x\] Documentation updated:\s*(.*)$"),
    "not_needed": re.compile(r"(?m)^- \[x\] No documentation update needed:\s*(.*)$"),
}


def fail(message: str) -> None:
    raise ValueError(message)


def visible_text(value: str) -> str:
    return re.sub(r"<!--.*?-->", "", value, flags=re.DOTALL).strip()


def validate(changed_paths: list[str], pr_body: str) -> None:
    if not any(path.startswith(BEHAVIOR_SOURCE_PREFIX) for path in changed_paths):
        return

    matches = {name: pattern.findall(pr_body) for name, pattern in DECLARATIONS.items()}
    checked = sum(len(values) for values in matches.values())
    if checked != 1:
        fail("App behavior changes require exactly one checked documentation declaration")

    if matches["updated"]:
        if not any(path in DOCUMENTS for path in changed_paths):
            fail("'Documentation updated' requires a documentation file in this pull request")
        return

    if not visible_text(matches["not_needed"][0]):
        fail("'No documentation update needed' requires a written reason")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changed-files", required=True, type=Path)
    parser.add_argument("--pr-body-file", required=True, type=Path)
    args = parser.parse_args()
    try:
        changed_paths = args.changed_files.read_text(encoding="utf-8").splitlines()
        pr_body = args.pr_body_file.read_text(encoding="utf-8")
        validate(changed_paths, pr_body)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        print(f"PR documentation validation failed: {error}", file=sys.stderr)
        return 1
    print("PR documentation declaration is valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

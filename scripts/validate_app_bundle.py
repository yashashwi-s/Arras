#!/usr/bin/env python3
"""Check the built app metadata before an artifact can be installed or packaged."""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path
from build_provenance import snapshot


def validate(bundle: Path, project: Path, pilot_build: str | None = None) -> None:
    configuration = project.read_text()
    def setting(name: str) -> str:
        match = re.search(rf"^\s*{name}:\s*[\"']?([^\s\"']+)", configuration, re.MULTILINE)
        if not match:
            raise ValueError(f"Missing {name} in {project}")
        return match.group(1)

    with (bundle / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    expected = {
        "CFBundleShortVersionString": setting("MARKETING_VERSION"),
        "CFBundleVersion": pilot_build or setting("CURRENT_PROJECT_VERSION"),
        "ArrasPrivateTelemetryPilot": pilot_build is not None,
        "ArrasTelemetryEnabled": pilot_build is not None or setting("ArrasTelemetryEnabled").lower() == "true",
        "CFBundleIdentifier": "com.yashashwi.tableau",
        "LSUIElement": True,
        "LSApplicationCategoryType": "public.app-category.photography",
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"{key}: expected {value!r}, found {info.get(key)!r}")
    if pilot_build is not None and (not pilot_build.isdecimal() or int(pilot_build) < 2203):
        raise ValueError("Private pilot build must be 2203 or newer")
    provenance = json.loads((bundle / "Contents/Resources/ArrasBuildProvenance.json").read_text())
    current = snapshot(project.resolve().parent)
    for key in ("schema", "sourceSHA256", "files", "branch", "commit"):
        if provenance.get(key) != current[key]:
            raise ValueError(f"Build provenance {key} does not match this checkout; rebuild it")
    for key, expected_value in {
        "ArrasSourceSHA256": current["sourceSHA256"],
        "ArrasBuildBranch": current["branch"],
        "ArrasBuildCommit": current["commit"],
    }.items():
        if info.get(key) != expected_value:
            raise ValueError(f"Missing or incorrect {key}")
    for key, value in {"version": expected["CFBundleShortVersionString"],
                       "build": expected["CFBundleVersion"],
                       "privatePilot": expected["ArrasPrivateTelemetryPilot"],
                       "telemetryEnabled": expected["ArrasTelemetryEnabled"]}.items():
        if provenance.get(key) != value:
            raise ValueError(f"Build provenance {key} disagrees with app metadata")
    if info.get("ArrasTelemetryReportingDays") != int(setting("ArrasTelemetryReportingDays")):
        raise ValueError("Telemetry reporting cadence differs from project configuration")
    if info.get("ArrasTelemetryURL") != setting("ArrasTelemetryURL"):
        raise ValueError("Unexpected production telemetry endpoint")
    if not str(info.get("NSPhotoLibraryUsageDescription", "")).strip():
        raise ValueError("Missing Photos library permission description")
    signed_entitlements = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
        capture_output=True, check=True,
    ).stdout
    entitlements = plistlib.loads(signed_entitlements)
    if entitlements.get("com.apple.security.personal-information.photos-library") is not True:
        raise ValueError("Missing signed Photos Library entitlement required by Hardened Runtime")
    executable = bundle / "Contents/MacOS" / "Arras"
    sections = subprocess.run(
        ["/usr/bin/otool", "-l", str(executable)],
        capture_output=True, text=True, check=True,
    ).stdout
    if re.search(r"\bsectname\s+__llvm_(?:prf|cov)\w*", sections):
        raise ValueError("Release executable contains test coverage instrumentation")
    declarations = info.get("UTExportedTypeDeclarations", [])
    archive = next((entry for entry in declarations
                    if entry.get("UTTypeIdentifier") == "com.yashashwi.arras.layout"), None)
    if not archive or not {"arras", "tableau"}.issubset(
        archive.get("UTTypeTagSpecification", {}).get("public.filename-extension", [])
    ):
        raise ValueError("Missing current/legacy archive type registration")
    if not any("com.yashashwi.arras.layout" in entry.get("LSItemContentTypes", [])
               for entry in info.get("CFBundleDocumentTypes", [])):
        raise ValueError("Missing archive document handler registration")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--project", type=Path, default=Path("project.yml"))
    parser.add_argument("--pilot-build", help="Explicit private pilot build number; public builds reject pilots")
    args = parser.parse_args()
    try:
        validate(args.bundle, args.project, args.pilot_build)
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Invalid app bundle: {error}\n")
    print(f"Validated current source and app metadata: {args.bundle}")

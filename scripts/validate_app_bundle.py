#!/usr/bin/env python3
"""Check the built app metadata before an artifact can be installed or packaged."""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path
from build_provenance import snapshot


def validate(bundle: Path, project: Path, pilot_build: str | None = None, distribution: str = "direct") -> None:
    if distribution not in ("direct", "app-store"):
        raise ValueError("Unknown distribution")
    app_store = distribution == "app-store"
    if app_store and pilot_build is not None:
        raise ValueError("App Store builds cannot enable a telemetry pilot")
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
        "ArrasTelemetryEnabled": False if app_store else pilot_build is not None or setting("ArrasTelemetryEnabled").lower() == "true",
        "CFBundleIdentifier": "com.yashashwi.arras.appstore" if app_store else "com.yashashwi.tableau",
        "ArrasAppStoreBuild": app_store,
        "LSUIElement": True,
        "LSApplicationCategoryType": "public.app-category.photography",
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"{key}: expected {value!r}, found {info.get(key)!r}")
    if pilot_build is not None and (not pilot_build.isdecimal() or int(pilot_build) < 2203):
        raise ValueError("Private pilot build must be 2203 or newer")
    provenance = json.loads((bundle / "Contents/Resources/ArrasBuildProvenance.json").read_text())
    if provenance.get("distribution") != distribution or provenance.get("target") != ("ArrasAppStore" if app_store else "Arras"):
        raise ValueError("Build provenance has the wrong distribution target")
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
    if app_store:
        if "ArrasTelemetryURL" in info or "ArrasTelemetryReportingDays" in info:
            raise ValueError("App Store bundle must not configure a telemetry endpoint or reporting cadence")
        if not str(info.get("NSScreenCaptureUsageDescription", "")).strip():
            raise ValueError("Missing screen capture permission description")
        privacy = plistlib.loads((bundle / "Contents/Resources/PrivacyInfo.xcprivacy").read_bytes())
        if privacy.get("NSPrivacyTracking") is not False or privacy.get("NSPrivacyCollectedDataTypes") != []:
            raise ValueError("App Store privacy manifest must declare no tracking or collected data")
        declared = {entry.get("NSPrivacyAccessedAPIType"): set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
                    for entry in privacy.get("NSPrivacyAccessedAPITypes", [])}
        for category, reasons in {
            "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
            "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
        }.items():
            if not reasons.issubset(declared.get(category, set())):
                raise ValueError(f"Privacy manifest is missing required API reasons for {category}")
    else:
        if info.get("ArrasTelemetryReportingDays") != int(setting("ArrasTelemetryReportingDays")):
            raise ValueError("Telemetry reporting cadence differs from project configuration")
        if info.get("ArrasTelemetryURL") != setting("ArrasTelemetryURL"):
            raise ValueError("Unexpected production telemetry endpoint")
    if not str(info.get("NSPhotoLibraryUsageDescription", "")).strip():
        raise ValueError("Missing Photos library permission description")
    executable = bundle / "Contents/MacOS/Arras"
    architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True).split()
    if app_store and set(architectures) != {"arm64", "x86_64"}:
        raise ValueError("App Store release must include Apple Silicon and Intel")
    for arch in architectures:
        signed_entitlements = subprocess.run(
            ["/usr/bin/codesign", "-d", "--arch", arch, "--entitlements", ":-", str(bundle)],
            capture_output=True, check=True,
        ).stdout
        entitlements = plistlib.loads(signed_entitlements)
        if entitlements.get("com.apple.security.personal-information.photos-library") is not True:
            raise ValueError(f"Missing signed Photos Library entitlement in {arch}")
        if bool(entitlements.get("com.apple.security.app-sandbox")) != app_store:
            raise ValueError(f"Unexpected app-sandbox entitlement for {distribution} in {arch}")
        if app_store:
            for key in ("com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope",
                        "com.apple.security.network.client"):
                if entitlements.get(key) is not True:
                    raise ValueError(f"Missing signed App Store entitlement in {arch}: {key}")
        for key, value in entitlements.items():
            if value and (key.startswith("com.apple.security.temporary-exception.")
                          or key.startswith("com.apple.security.cs.") or key == "com.apple.security.get-task-allow"):
                raise ValueError(f"Release contains a debug or runtime exception in {arch}: {key}")
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
    parser.add_argument("--distribution", choices=("direct", "app-store"), default="direct")
    args = parser.parse_args()
    try:
        validate(args.bundle, args.project, args.pilot_build, args.distribution)
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Invalid app bundle: {error}\n")
    print(f"Validated current source and app metadata: {args.bundle}")

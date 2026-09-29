#!/usr/bin/env python3
"""Read-only audit of the latest public Arras release and update feed."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import plistlib
import struct
import sys
import urllib.request
from urllib.parse import urlsplit
import zipfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
CPU_NAMES = {0x01000007: "x86_64", 0x0100000C: "arm64"}


def read_url(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "arras-release-audit"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def macho_architectures(data: bytes) -> list[str]:
    """Read CPU types from a 64-bit thin or universal Mach-O executable."""
    if len(data) < 8:
        raise ValueError("Mach-O executable is too short")
    magic = struct.unpack(">I", data[:4])[0]
    cpu_types: list[int]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        if len(data) < 8:
            raise ValueError("fat Mach-O header is too short")
        count = struct.unpack(">I", data[4:8])[0]
        entry_size = 24 if magic == 0xCAFEBABF else 20
        if len(data) < 8 + count * entry_size:
            raise ValueError("fat Mach-O architecture table is truncated")
        cpu_types = [struct.unpack(">I", data[8 + index * entry_size:12 + index * entry_size])[0] for index in range(count)]
    elif magic in (0xFEEDFACF, 0xCFFAEDFE):
        byte_order = ">" if magic == 0xFEEDFACF else "<"
        cpu_types = [struct.unpack(byte_order + "I", data[4:8])[0]]
    else:
        raise ValueError(f"unrecognized Mach-O magic 0x{magic:08x}")
    try:
        return [CPU_NAMES[cpu] for cpu in cpu_types]
    except KeyError as error:
        raise ValueError(f"unsupported Mach-O CPU type 0x{error.args[0]:08x}") from error


def fail(report: dict[str, Any], message: str) -> None:
    report["checks"].append({"ok": False, "message": message})


def check(report: dict[str, Any], condition: bool, message: str) -> None:
    report["checks"].append({"ok": condition, "message": message})


def audit(release: dict[str, Any], appcast: dict[str, Any], metadata: dict[str, Any], zip_data: bytes, dmg_data: bytes) -> dict[str, Any]:
    report: dict[str, Any] = {"release": release.get("tag_name"), "checks": [], "limitations": ["The DMG digest is verified, but its mounted app is not inspected in this cross-platform audit."]}
    version = str(release.get("tag_name", "")).removeprefix("v")
    assets = {asset.get("name"): asset for asset in release.get("assets", []) if isinstance(asset, dict)}
    zip_asset, dmg_asset = assets.get("Arras.app.zip"), assets.get("Arras.dmg")
    check(report, bool(zip_asset and dmg_asset), "latest release supplies Arras.app.zip and Arras.dmg")
    if not zip_asset or not dmg_asset:
        report["ok"] = False
        return report
    zip_digest = zip_asset.get("digest", "").removeprefix("sha256:")
    dmg_digest = dmg_asset.get("digest", "").removeprefix("sha256:")
    check(report, sha256(zip_data) == zip_digest, "downloaded ZIP matches GitHub asset digest")
    check(report, sha256(dmg_data) == dmg_digest, "downloaded DMG matches GitHub asset digest")
    check(report, appcast.get("latestVersion") == version, "appcast version matches latest release tag")
    check(report, appcast.get("sha256") == zip_digest, "appcast SHA-256 matches the ZIP asset digest")
    feed_url, asset_url = urlsplit(str(appcast.get("downloadURL", ""))), urlsplit(str(zip_asset.get("browser_download_url", "")))
    check(report, (feed_url.scheme, feed_url.netloc, feed_url.path) == (asset_url.scheme, asset_url.netloc, asset_url.path), "appcast URL targets the ZIP asset (query tracking is allowed)")
    try:
        with zipfile.ZipFile(io.BytesIO(zip_data)) as archive:
            names = archive.namelist()
            info_name = next(name for name in names if name.endswith("Arras.app/Contents/Info.plist"))
            executable_name = next(name for name in names if name.endswith("Arras.app/Contents/MacOS/Arras"))
            info = plistlib.loads(archive.read(info_name))
            architectures = macho_architectures(archive.read(executable_name))
        report["zipArchitectures"] = architectures
        check(report, info.get("CFBundleIdentifier") == metadata.get("bundleIdentifier"), "ZIP bundle identifier matches product metadata")
        check(report, info.get("CFBundleShortVersionString") == version, "ZIP marketing version matches release tag")
        check(report, info.get("LSMinimumSystemVersion") == metadata.get("minimumMacOS"), "ZIP minimum macOS matches product metadata")
        expected_architectures = metadata.get("publicRelease", {}).get("architectures", [])
        check(report, set(architectures) == set(expected_architectures), "ZIP Mach-O architectures match public-release metadata")
    except (KeyError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        fail(report, f"could not inspect ZIP app payload: {error}")
    report["ok"] = all(item["ok"] for item in report["checks"])
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-json", type=Path)
    parser.add_argument("--appcast", type=Path)
    parser.add_argument("--zip", dest="zip_path", type=Path)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--output", type=Path, default=Path("release-audit.json"))
    args = parser.parse_args()
    try:
        metadata = json.loads((ROOT / "product-metadata.json").read_text())
        release = json.loads(args.release_json.read_text()) if args.release_json else json.loads(read_url("https://api.github.com/repos/yashashwi-s/Arras/releases/latest"))
        appcast = json.loads(args.appcast.read_text()) if args.appcast else json.loads(read_url("https://raw.githubusercontent.com/yashashwi-s/Arras/main/appcast.json"))
        assets = {asset["name"]: asset for asset in release["assets"]}
        zip_data = args.zip_path.read_bytes() if args.zip_path else read_url(assets["Arras.app.zip"]["browser_download_url"])
        dmg_data = args.dmg.read_bytes() if args.dmg else read_url(assets["Arras.dmg"]["browser_download_url"])
        report = audit(release, appcast, metadata, zip_data, dmg_data)
    except Exception as error:
        report = {"ok": False, "checks": [{"ok": False, "message": str(error)}]}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())

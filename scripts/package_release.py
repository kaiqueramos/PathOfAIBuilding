#!/usr/bin/env python3
"""Build a clean Windows portable archive from a release manifest."""

from __future__ import annotations

import argparse
import configparser
import hashlib
import re
import shutil
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_ARCHIVE = ROOT / "runtime-win32.zip"
DEFAULT_OUTPUT_DIR = ROOT / "dist"
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
EXPECTED_SOURCE_PREFIX = (
    "https://raw.githubusercontent.com/kaiqueramos/PathOfAIBuilding/{branch}/"
)
FORBIDDEN_NAMES = {
    ".env",
    "ai_config.json",
    "ai_debug.log",
    "poe_api_response.json",
    "settings.xml",
}
DOC_FILES = ("README.md", "AI_SECURITY.md", "ai_config.example.json")


def normalized_sha1(path: Path) -> str:
    data = path.read_bytes()
    if b"\0" not in data:
        data = re.sub(rb"\r\n?|\n", b"\r\n", data)
    return hashlib.sha1(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_extract(archive: zipfile.ZipFile, destination: Path) -> None:
    root = destination.resolve()
    for member in archive.infolist():
        member_path = PurePosixPath(member.filename)
        if member_path.is_absolute() or ".." in member_path.parts:
            raise ValueError(f"Unsafe runtime archive member: {member.filename}")
        target = (destination / Path(*member_path.parts)).resolve()
        if target != root and root not in target.parents:
            raise ValueError(f"Runtime archive member escapes staging: {member.filename}")
    archive.extractall(destination)


def load_manifest(version: str, branch: str, platform: str) -> tuple[ET.ElementTree, ET.Element]:
    tree = ET.parse(ROOT / "manifest.xml")
    root = tree.getroot()
    if root.tag != "PoBVersion":
        raise ValueError("manifest.xml root must be PoBVersion")
    version_node = root.find("Version")
    if version_node is None:
        raise ValueError("manifest.xml has no Version element")
    manifest_version = version_node.get("number")
    if manifest_version != version:
        raise ValueError(
            f"Manifest version {manifest_version!r} does not match package version {version!r}"
        )
    for source_node in root.findall("Source"):
        source_url = source_node.get("url", "")
        if not source_url.startswith(EXPECTED_SOURCE_PREFIX):
            raise ValueError(f"Manifest source does not use the fork: {source_url!r}")
    version_node.set("branch", branch)
    version_node.set("platform", platform)
    return tree, root


def source_paths() -> dict[str, Path]:
    config = configparser.ConfigParser()
    if not config.read(ROOT / "manifest.cfg"):
        raise ValueError("manifest.cfg could not be read")
    return {
        section: (ROOT / config[section]["path"]).resolve()
        for section in config.sections()
    }


def source_for(part_root: Path, manifest_name: str) -> Path:
    encoded = part_root / Path(*PurePosixPath(manifest_name).parts)
    if encoded.is_file():
        return encoded
    decoded_name = manifest_name.replace("{space}", " ")
    decoded = part_root / Path(*PurePosixPath(decoded_name).parts)
    if decoded.is_file():
        return decoded
    raise FileNotFoundError(f"Manifest source file is missing: {manifest_name}")


def assert_safe_destination(relative: Path) -> None:
    if relative.name.lower() in FORBIDDEN_NAMES:
        raise ValueError(f"Sensitive file cannot enter release archive: {relative}")
    lowered_parts = {part.lower() for part in relative.parts}
    if ".git" in lowered_parts or "builds" in lowered_parts:
        raise ValueError(f"Private development path cannot enter release archive: {relative}")
    if relative.suffix.lower() in {".ai_key", ".pem", ".p12", ".pfx"}:
        raise ValueError(f"Secret-bearing file cannot enter release archive: {relative}")


def validate_staging(staging: Path) -> None:
    for path in staging.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Release archive cannot contain a symlink: {path}")
        if path.is_file():
            assert_safe_destination(path.relative_to(staging))
    required = {
        "Path of Building.exe",
        "manifest.xml",
        "Modules/AIBridge.lua",
        "Modules/AIConfig.lua",
        "Classes/AIChatTab.lua",
        "Classes/AIConfigPanel.lua",
    }
    missing = sorted(name for name in required if not (staging / name).is_file())
    if missing:
        raise ValueError(f"Release archive is missing required files: {', '.join(missing)}")


def copy_manifest_files(manifest_root: ET.Element, staging: Path) -> int:
    parts = source_paths()
    copied = 0
    for node in manifest_root.findall("File"):
        part = node.get("part")
        name = node.get("name")
        expected_sha1 = node.get("sha1")
        if not part or not name or not expected_sha1:
            raise ValueError("Manifest File entry is missing part, name, or sha1")
        if part not in parts:
            raise ValueError(f"Manifest references unknown part: {part}")
        source = source_for(parts[part], name)
        actual_sha1 = normalized_sha1(source)
        if actual_sha1 != expected_sha1:
            raise ValueError(
                f"Stale manifest hash for {part}/{name}: expected {expected_sha1}, got {actual_sha1}"
            )
        relative = Path(*PurePosixPath(name.replace("{space}", " ")).parts)
        assert_safe_destination(relative)
        destination = staging / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        copied += 1
    return copied


def add_release_docs(staging: Path) -> None:
    for name in DOC_FILES:
        source = ROOT / name
        if not source.is_file():
            raise FileNotFoundError(f"Release documentation is missing: {name}")
        shutil.copy2(source, staging / name)


def write_local_manifest(tree: ET.ElementTree, staging: Path) -> None:
    ET.indent(tree, "\t")
    tree.write(staging / "manifest.xml", encoding="UTF-8", xml_declaration=True)


def zip_staging(staging: Path, output: Path) -> None:
    with zipfile.ZipFile(
        output,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        strict_timestamps=False,
    ) as archive:
        for path in sorted(staging.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(staging).as_posix()
            info = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
            mode = 0o755 if path.suffix.lower() == ".exe" else 0o644
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with path.open("rb") as source, archive.open(info, "w") as target:
                shutil.copyfileobj(source, target, length=1024 * 1024)


def build_release(version: str, branch: str, output_dir: Path) -> Path:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"Invalid release version: {version!r}")
    if not re.fullmatch(r"[0-9A-Za-z._/-]+", branch) or ".." in branch:
        raise ValueError(f"Invalid update branch: {branch!r}")
    if not RUNTIME_ARCHIVE.is_file():
        raise FileNotFoundError(f"Runtime archive is missing: {RUNTIME_ARCHIVE}")

    tree, manifest_root = load_manifest(version, branch, "win32")
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"PathOfAIBuilding-v{version}-Windows-Portable.zip"

    with tempfile.TemporaryDirectory(prefix="pathofaibuilding-release-") as temp:
        staging = Path(temp) / "PathOfAIBuilding"
        staging.mkdir()
        with zipfile.ZipFile(RUNTIME_ARCHIVE) as runtime:
            safe_extract(runtime, staging)
        copied = copy_manifest_files(manifest_root, staging)
        add_release_docs(staging)
        write_local_manifest(tree, staging)
        validate_staging(staging)
        zip_staging(staging, output)

    digest = sha256_file(output)
    print(f"Created {output} ({copied} manifest files)")
    print(f"SHA256 {digest}")
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Release version, e.g. 1.0.0")
    parser.add_argument(
        "--branch",
        default="release",
        help="Stable branch used by the built-in updater (default: release)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help="Directory for the generated zip",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    build_release(args.version, args.branch, args.output_dir.resolve())


if __name__ == "__main__":
    main()

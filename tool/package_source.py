#!/usr/bin/env python3
"""Package selected Flutter sources and verify an independent extraction.

Run from any directory: python3 tool/package_source.py
Only the Python standard library is required. The archive always uses APP/ as
its root, and stable metadata makes identical source inputs reproducible.
This checks packaging integrity; it does not compile or test the application.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tarfile
import tempfile


ROOT_FILES = (
    ".gitignore", ".metadata", "README.md", "analysis_options.yaml",
    "pubspec.yaml", "pubspec.lock",
)
SOURCE_DIRS = ("android", "lib", "test", "assets", "tool", "docs", "web", "firmware")
EXCLUDED_DIRS = {
    ".git", ".hg", ".svn", ".idea", ".vscode", ".dart_tool",
    ".gradle", ".kotlin", ".cxx", ".pub", ".pub-cache", ".build",
    "build", "coverage", "releases", "node_modules", "__pycache__",
}
EXCLUDED_NAMES = {
    "local.properties", "key.properties", ".DS_Store",
    ".flutter-plugins", ".flutter-plugins-dependencies",
    "GeneratedPluginRegistrant.java", "GeneratedPluginRegistrant.kt",
    "generated_plugin_registrant.dart",
}
EXCLUDED_SUFFIXES = {
    ".iml", ".ipr", ".iws", ".pyc", ".pyo", ".swp", ".class",
    ".keystore", ".jks", ".p12", ".pfx", ".pem", ".key", ".apk", ".aab",
}
ARCHIVE_NAME = "ESP-INK-Flutter-source.tar.gz"
MANIFEST_NAME = "SOURCE_SHA256SUMS"
REPORT_NAME = "source-package.json"


def regular_file(path: Path) -> None:
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"Expected a regular file, not a symlink/device: {path}")


def real_directory(path: Path) -> None:
    """Do not follow an existing directory symlink, including output folders."""
    if path.is_symlink():
        raise ValueError(f"Directory symlinks are not allowed: {path}")
    if not path.exists():
        path.mkdir()
    if not path.is_dir():
        raise ValueError(f"Expected a directory: {path}")


def digest_file(path: Path) -> str:
    regular_file(path)
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def version_from_pubspec(text: str) -> str:
    match = re.search(r"^version:\s*['\"]?([0-9][0-9A-Za-z.+-]*)", text, re.M)
    if not match:
        raise ValueError("pubspec.yaml has no readable version")
    return match.group(1)


def excluded(relative: Path) -> bool:
    return (
        any(part in EXCLUDED_DIRS for part in relative.parts)
        or relative.name in EXCLUDED_NAMES
        or relative.name.startswith(".env")
        or relative.suffix.lower() in EXCLUDED_SUFFIXES
        or relative.parts[:3] in {
            ("android", "app", "debug"),
            ("android", "app", "profile"),
            ("android", "app", "release"),
        }
    )


def source_files(root: Path) -> list[Path]:
    selected = [root / name for name in ROOT_FILES]
    for name in SOURCE_DIRS:
        directory = root / name
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError(f"Required source directory is absent or a symlink: {directory}")
        for current, dirs, files in os.walk(directory, followlinks=False):
            current = Path(current)
            for child in list(dirs):
                candidate = current / child
                if excluded(candidate.relative_to(root)):
                    dirs.remove(child)
                elif candidate.is_symlink():
                    raise ValueError(f"Source directory symlinks are not allowed: {candidate}")
            for child in files:
                candidate = current / child
                if not excluded(candidate.relative_to(root)):
                    selected.append(candidate)
    for path in selected:
        regular_file(path)
        if any(c in path.relative_to(root).as_posix() for c in "\n\r\\"):
            raise ValueError(f"Filename cannot be represented in SHA256SUMS: {path}")
    return sorted(selected, key=lambda p: p.relative_to(root).as_posix())


def checksum_text(hashes: dict[str, str]) -> bytes:
    return "".join(f"{hashes[name]}  {name}\n" for name in sorted(hashes)).encode("utf-8")


def atomic_write(path: Path, contents: bytes) -> None:
    if path.is_symlink():
        raise ValueError(f"Refusing to replace a symlink: {path}")
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    temporary = Path(temporary)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def keep_old_copy(source: Path, destination: Path) -> None:
    """Create a historical copy once; never overwrite an existing copy."""
    if destination.exists() or destination.is_symlink():
        regular_file(destination)
        return
    regular_file(source)
    created = False
    try:
        with destination.open("xb") as target:
            created = True
            with source.open("rb") as original:
                shutil.copyfileobj(original, target)
                target.flush()
                os.fsync(target.fileno())
    except Exception:
        if created:
            destination.unlink(missing_ok=True)
        raise


def preserve_previous_release(releases: Path, current_version: str) -> None:
    previous = releases / ARCHIVE_NAME
    if not previous.exists():
        return
    regular_file(previous)
    with tarfile.open(previous, "r:gz") as archive:
        member = archive.getmember("APP/pubspec.yaml")
        if not member.isfile() or member.size > 1024 * 1024:
            raise ValueError("Old archive has an invalid APP/pubspec.yaml")
        with archive.extractfile(member) as stream:
            previous_version = version_from_pubspec(stream.read().decode("utf-8"))
    if previous_version == current_version:
        return
    # Historical public filenames use the release version, without build number.
    version = previous_version.split("+", 1)[0]
    keep_old_copy(previous, releases / f"ESP-INK-{version}-source.tar.gz")
    report = releases / REPORT_NAME
    if report.exists():
        keep_old_copy(report, releases / f"source-package-{version}.json")


def write_archive(path: Path, root: Path, paths: list[Path], manifest: bytes) -> None:
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    if epoch < 0:
        raise ValueError("SOURCE_DATE_EPOCH must be nonnegative")
    with path.open("wb") as raw, gzip.GzipFile(
        fileobj=raw, mode="wb", filename="", mtime=epoch
    ) as compressed, tarfile.open(
        fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT
    ) as archive:
        entries = {p.relative_to(root).as_posix(): p for p in paths}
        entries[MANIFEST_NAME] = None
        for name, source in sorted(entries.items()):
            info = tarfile.TarInfo(f"APP/{name}")
            info.mtime = epoch
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            if source is None:
                info.size, info.mode = len(manifest), 0o644
                archive.addfile(info, io.BytesIO(manifest))
            else:
                regular_file(source)
                with source.open("rb") as stream:
                    metadata = os.fstat(stream.fileno())
                    info.size = metadata.st_size
                    info.mode = 0o755 if metadata.st_mode & 0o111 else 0o644
                    archive.addfile(info, stream)


def verify_archive(archive_path: Path, destination: Path, expected: dict[str, str]) -> int:
    """Extract only regular APP/ files; reject traversal, duplicates and links."""
    names = set()
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if (
                not member.isfile() or path.is_absolute()
                or not path.parts or path.parts[0] != "APP"
                or ".." in path.parts or member.name in names
            ):
                raise ValueError(f"Unsafe or duplicate archive member: {member.name}")
            names.add(member.name)
            output = destination.joinpath(*path.parts)
            output.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, output.open("xb") as target:
                shutil.copyfileobj(source, target)
            output.chmod(member.mode)
    actual = {
        p.relative_to(destination / "APP").as_posix(): digest_file(p)
        for p in (destination / "APP").rglob("*") if p.is_file()
    }
    symlinks = sum(p.is_symlink() for p in destination.rglob("*"))
    if actual != expected or symlinks:
        raise ValueError("Round-trip file hashes or symlink checks failed")
    return symlinks


def package(root: Path) -> dict:
    root = root.absolute()
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"Project root must be an actual directory: {root}")
    releases = root / "releases"
    real_directory(releases)
    for name in (ARCHIVE_NAME, REPORT_NAME, "SHA256SUMS"):
        if (releases / name).is_symlink():
            raise ValueError(f"Output symlinks are not allowed: {releases / name}")
    paths = source_files(root)
    version = version_from_pubspec((root / "pubspec.yaml").read_text(encoding="utf-8"))
    hashes = {p.relative_to(root).as_posix(): digest_file(p) for p in paths}
    manifest = checksum_text(hashes)
    expected = {**hashes, MANIFEST_NAME: hashlib.sha256(manifest).hexdigest()}
    real_directory(root / "build")
    verification = root / "build" / "source-verify"
    real_directory(verification)
    fd, temporary = tempfile.mkstemp(prefix=".source-", suffix=".tar.gz", dir=releases)
    os.close(fd)
    temporary = Path(temporary)
    try:
        write_archive(temporary, root, paths, manifest)
        with tempfile.TemporaryDirectory(prefix="roundtrip-", dir=verification) as unpacked:
            symlinks = verify_archive(temporary, Path(unpacked), expected)
        if source_files(root) != paths or any(
            digest_file(p) != hashes[p.relative_to(root).as_posix()] for p in paths
        ):
            raise ValueError("Source files changed while packaging; retry when edits finish")
        apk_hashes = {
            p.name: digest_file(p) for p in sorted(releases.glob("*.apk"))
        }
        report = {
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
            "version": version,
            "archive": ARCHIVE_NAME,
            "archive_sha256": digest_file(temporary),
            "archive_bytes": temporary.stat().st_size,
            "files": len(expected),
            "source_files_listed_in_manifest": len(hashes),
            "manifest": MANIFEST_NAME,
            "manifest_sha256": expected[MANIFEST_NAME],
            "all_unpacked_file_hashes_match": True,
            "symlinks": symlinks,
            "roundtrip_directory": "build/source-verify (temporary copy removed)",
            "release_apk_sha256": apk_hashes,
            "validation_scope": "Packaging integrity only; compilation and runtime checks are separate.",
            "included_root_files": list(ROOT_FILES),
            "included_directories": list(SOURCE_DIRS),
            "omitted": [
                "build and SDK/dependency caches", "VCS and IDE state",
                "android/local.properties", "GeneratedPluginRegistrant",
                "keystores and signing credentials", "release artifacts and current packaging report",
            ],
        }
        preserve_previous_release(releases, version)
        atomic_write(root / MANIFEST_NAME, manifest)
        temporary.chmod(0o644)
        os.replace(temporary, releases / ARCHIVE_NAME)
        atomic_write(releases / REPORT_NAME, (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
        release_paths = sorted({
            *releases.glob("*.apk"), *releases.glob("*.tar.gz"), *releases.glob("*.bin"),
            *releases.glob("source-package*.json"),
        })
        atomic_write(releases / "SHA256SUMS", checksum_text({
            p.name: digest_file(p) for p in release_paths if not p.name.startswith(".")
        }))
        return report
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help="Flutter APP root (defaults to this script's project)")
    args = parser.parse_args()
    try:
        report = package(args.root)
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

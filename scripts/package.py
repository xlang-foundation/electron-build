#!/usr/bin/env python3
"""Create an Electron distribution with the XLang runtime bridge injected."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


_SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
_VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+-]*$")


def read_revision(path: Path) -> str:
    revision = path.read_text(encoding="utf-8").strip().lower()
    if not _SHA_RE.fullmatch(revision):
        raise ValueError(f"{path} does not contain a full Git SHA")
    return revision


def read_version(path: Path) -> str:
    version = path.read_text(encoding="utf-8").strip()
    if not _VERSION_RE.fullmatch(version):
        raise ValueError(f"{path} contains an unsafe Electron version: {version!r}")
    return version.removeprefix("v")


def runtime_prefix(platform: str) -> PurePosixPath:
    if platform == "darwin":
        return PurePosixPath("Electron.app/Contents/Resources/xlang")
    return PurePosixPath("resources/xlang")


def runtime_engine_name(platform: str, source: Path) -> str:
    prefix = "" if platform == "win32" else "lib"
    return f"{prefix}xlang_eng{source.suffix}"


def _zip_info(name: str) -> ZipInfo:
    info = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    return info


def _atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def create_distribution(
    *,
    dist_zip: Path,
    output_zip: Path,
    platform: str,
    files: dict[str, Path],
) -> None:
    dist_zip = dist_zip.resolve()
    output_zip = output_zip.resolve()
    if dist_zip == output_zip:
        raise ValueError("The source dist.zip and output archive must be different files")
    if not dist_zip.is_file():
        raise FileNotFoundError(f"Electron distribution was not found: {dist_zip}")

    for label, source in files.items():
        if not source.is_file():
            raise FileNotFoundError(f"{label} was not found: {source}")

    prefix = runtime_prefix(platform)
    archive_sources = {
        str(
            prefix
            / f"electron_xlang_bridge{Path(files['bridge']).suffix}"
        ): files["bridge"],
        str(prefix / runtime_engine_name(platform, files["engine"])): files["engine"],
    }
    if "license" in files:
        archive_sources[str(prefix / "LICENSE")] = files["license"]
    if "notice" in files:
        archive_sources[str(prefix / "NOTICE")] = files["notice"]

    output_zip.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(
        dir=output_zip.parent, prefix=f".{output_zip.name}.", suffix=".tmp"
    )
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        shutil.copyfile(dist_zip, temporary)
        with ZipFile(temporary, "a", allowZip64=True) as archive:
            existing = {name.casefold() for name in archive.namelist()}
            collisions = [
                name for name in archive_sources if name.casefold() in existing
            ]
            if collisions:
                raise ValueError(
                    "Electron dist.zip already contains XLang runtime entries: "
                    + ", ".join(collisions)
                )
            for archive_name, source in archive_sources.items():
                archive.writestr(
                    _zip_info(archive_name),
                    source.read_bytes(),
                    compress_type=ZIP_DEFLATED,
                    compresslevel=9,
                )
        os.replace(temporary, output_zip)
    finally:
        temporary.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist-zip", required=True, type=Path)
    parser.add_argument("--bridge", required=True, type=Path)
    parser.add_argument("--engine", required=True, type=Path)
    parser.add_argument("--license", dest="license_file", type=Path)
    parser.add_argument("--notice", type=Path)
    parser.add_argument("--electron-ref", required=True, type=Path)
    parser.add_argument("--xlang-ref", required=True, type=Path)
    parser.add_argument("--version-file", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--platform", choices=("win32", "linux", "darwin"), default="win32"
    )
    parser.add_argument("--arch", choices=("x64", "arm64"), default="x64")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    electron_revision = read_revision(args.electron_ref)
    xlang_revision = read_revision(args.xlang_ref)
    version = read_version(args.version_file)
    filename = (
        f"electron-xlang-v{version}-{args.platform}-{args.arch}"
        f"-e{electron_revision[:7]}-x{xlang_revision[:7]}.zip"
    )
    output_zip = args.output_dir / filename

    files = {
        "bridge": args.bridge,
        "engine": args.engine,
    }
    if args.license_file is not None:
        files["license"] = args.license_file
    if args.notice is not None:
        files["notice"] = args.notice

    create_distribution(
        dist_zip=args.dist_zip,
        output_zip=output_zip,
        platform=args.platform,
        files=files,
    )
    digest = sha256_file(output_zip)
    checksum = output_zip.with_suffix(output_zip.suffix + ".sha256")
    _atomic_write_text(checksum, f"{digest}  {output_zip.name}\n")

    print(output_zip)
    print(checksum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

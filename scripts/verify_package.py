#!/usr/bin/env python3
"""Validate and smoke-test a packaged Windows Electron + XLang distribution."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
from typing import Iterable
from zipfile import BadZipFile, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_PATTERN = re.compile(
    r"^electron-xlang-v"
    r"(?P<version>[0-9A-Za-z][0-9A-Za-z.+-]*)"
    r"-win32-x64-e(?P<electron>[0-9a-fA-F]{7})"
    r"-x(?P<xlang>[0-9a-fA-F]{7})\.zip$"
)
REVISION_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
VERSION_PATTERN = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+-]*$")
CHECKSUM_PATTERN = re.compile(
    r"^(?P<digest>[0-9a-fA-F]{64})[ \t]+[*]?(?P<filename>[^\r\n/\\]+)\r?\n?$"
)
REQUIRED_FILES = (
    "electron.exe",
    "resources/xlang/electron_xlang_bridge.dll",
    "resources/xlang/xlang_eng.dll",
    "resources/xlang/LICENSE",
    "resources/xlang/NOTICE",
)
_WINDOWS_RESERVED_NAMES = {
    "con",
    "prn",
    "aux",
    "nul",
    *(f"com{number}" for number in range(1, 10)),
    *(f"lpt{number}" for number in range(1, 10)),
}
_OVERRIDE_ENVIRONMENT = (
    "ELECTRON_RUN_AS_NODE",
    "ELECTRON_XLANG_LIBRARY_PATH",
    "XLANG_RUNTIME_DIR",
    "XLANG_BRIDGE_PATH",
)


class VerificationError(RuntimeError):
    """A packaged distribution did not satisfy its release contract."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_revision(path: Path) -> str:
    revision = path.read_text(encoding="utf-8").strip().lower()
    if not REVISION_PATTERN.fullmatch(revision):
        raise VerificationError(f"{path} does not contain a full Git SHA")
    return revision


def read_version(path: Path) -> str:
    version = path.read_text(encoding="utf-8").strip().removeprefix("v")
    if not VERSION_PATTERN.fullmatch(version):
        raise VerificationError(f"{path} contains an unsafe version: {version!r}")
    return version


def expected_archive_name(
    version: str, electron_revision: str, xlang_revision: str
) -> str:
    if not VERSION_PATTERN.fullmatch(version):
        raise VerificationError(f"Unsafe Electron version: {version!r}")
    return (
        f"electron-xlang-v{version}-win32-x64"
        f"-e{electron_revision[:7]}-x{xlang_revision[:7]}.zip"
    )


def _matching_archives(
    artifact_directory: Path,
    electron_revision: str,
    xlang_revision: str,
) -> list[Path]:
    if not artifact_directory.is_dir():
        raise VerificationError(
            f"Artifact directory was not found: {artifact_directory}"
        )

    matches: list[Path] = []
    for candidate in artifact_directory.iterdir():
        if not candidate.is_file():
            continue
        parsed = ARTIFACT_PATTERN.fullmatch(candidate.name)
        if parsed is None:
            continue
        if parsed.group("electron").lower() != electron_revision[:7]:
            continue
        if parsed.group("xlang").lower() != xlang_revision[:7]:
            continue
        matches.append(candidate)
    return matches


def select_archive(
    *,
    artifact_directory: Path,
    electron_revision: str,
    xlang_revision: str,
    version: str | None = None,
) -> Path:
    """Select an exact-version artifact, or the newest artifact for the pins."""

    artifact_directory = artifact_directory.resolve()
    if version is not None:
        candidate = artifact_directory / expected_archive_name(
            version, electron_revision, xlang_revision
        )
        if not candidate.is_file():
            raise VerificationError(f"Version-specific artifact was not found: {candidate}")
        return candidate

    matches = _matching_archives(
        artifact_directory, electron_revision, xlang_revision
    )
    if not matches:
        raise VerificationError(
            "No Windows x64 artifact matches the pinned Electron and XLang revisions "
            f"under {artifact_directory}"
        )
    return max(matches, key=lambda path: (path.stat().st_mtime_ns, path.name.casefold()))


def verify_checksum(archive_path: Path) -> Path:
    checksum_path = archive_path.with_suffix(archive_path.suffix + ".sha256")
    if not checksum_path.is_file():
        raise VerificationError(f"Checksum file was not found: {checksum_path}")

    try:
        checksum_text = checksum_path.read_text(encoding="ascii")
    except UnicodeDecodeError as error:
        raise VerificationError(f"Checksum file is not ASCII: {checksum_path}") from error

    parsed = CHECKSUM_PATTERN.fullmatch(checksum_text)
    if parsed is None:
        raise VerificationError(
            f"Checksum file must contain one SHA-256 and one local filename: {checksum_path}"
        )
    if parsed.group("filename") != archive_path.name:
        raise VerificationError(
            "Checksum filename does not match the selected artifact: "
            f"{parsed.group('filename')!r} != {archive_path.name!r}"
        )

    expected = parsed.group("digest").lower()
    actual = sha256_file(archive_path)
    if actual != expected:
        raise VerificationError(
            f"SHA-256 mismatch for {archive_path}: expected {expected}, got {actual}"
        )
    return checksum_path


def _try_unlink(path: Path) -> bool:
    try:
        path.unlink(missing_ok=True)
    except OSError:
        return False
    return not path.exists()


def _copy_file_synced(source: Path, destination_directory: Path) -> Path:
    handle, temporary_name = tempfile.mkstemp(
        dir=destination_directory,
        prefix=f".{source.name}.",
        suffix=".publish.tmp",
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(handle, "wb") as output_stream:
            with source.open("rb") as input_stream:
                shutil.copyfileobj(
                    input_stream, output_stream, length=1024 * 1024
                )
                output_stream.flush()
                os.fsync(output_stream.fileno())
    except BaseException:
        _try_unlink(temporary)
        raise
    return temporary


def publish_verified_archive(
    archive_path: Path, output_directory: Path
) -> tuple[Path, Path]:
    """Publish a verified ZIP pair without overwriting a prior artifact.

    The checksum is linked first and the ZIP is linked last, making the ZIP
    the publication marker. A failure before the ZIP link removes the newly
    linked checksum. Both source files remain in their staging directory.
    """

    archive_path = archive_path.resolve()
    checksum_path = verify_checksum(archive_path)
    source_digest = sha256_file(archive_path)

    output_directory = output_directory.resolve()
    output_directory.mkdir(parents=True, exist_ok=True)
    output_archive = output_directory / archive_path.name
    output_checksum = output_archive.with_suffix(output_archive.suffix + ".sha256")

    checksum_already_published = False
    if output_archive.exists():
        if output_archive.is_file() and output_checksum.is_file():
            try:
                verify_checksum(output_archive)
            except VerificationError as error:
                raise VerificationError(
                    "Refusing to replace an existing artifact pair: "
                    f"{output_archive}"
                ) from error
            if (
                sha256_file(output_archive) == source_digest
                and output_checksum.read_bytes() == checksum_path.read_bytes()
            ):
                return output_archive, output_checksum
        raise VerificationError(
            "Refusing to replace or complete an existing artifact path: "
            f"{output_archive}"
        )
    if output_checksum.exists():
        if (
            output_checksum.is_file()
            and output_checksum.read_bytes() == checksum_path.read_bytes()
        ):
            # Recover a checksum-first transaction interrupted before its ZIP
            # publication marker was linked. The current run has independently
            # verified and smoke-tested the same staged pair.
            checksum_already_published = True
        else:
            raise VerificationError(
                "Refusing to replace an existing artifact checksum: "
                f"{output_checksum}"
            )

    temporary_archive: Path | None = None
    temporary_checksum: Path | None = None
    checksum_published = False
    try:
        temporary_archive = _copy_file_synced(archive_path, output_directory)
        if not checksum_already_published:
            temporary_checksum = _copy_file_synced(
                checksum_path, output_directory
            )
        if sha256_file(temporary_archive) != source_digest:
            raise VerificationError(
                f"Staged publish copy changed while copying: {archive_path}"
            )
        if (
            temporary_checksum is not None
            and temporary_checksum.read_bytes() != checksum_path.read_bytes()
        ):
            raise VerificationError(
                f"Staged checksum changed while copying: {checksum_path}"
            )

        # Hard links provide atomic, no-overwrite publication on the same
        # filesystem. Expose the ZIP last so consumers never select a ZIP
        # before its checksum sibling exists.
        if temporary_checksum is not None:
            os.link(temporary_checksum, output_checksum)
            checksum_published = True
        try:
            os.link(temporary_archive, output_archive)
        except BaseException:
            if checksum_published and _try_unlink(output_checksum):
                checksum_published = False
            raise
    except OSError as error:
        raise VerificationError(
            f"Could not publish verified artifact pair to {output_directory}: {error}"
        ) from error
    finally:
        if checksum_published and not output_archive.is_file():
            _try_unlink(output_checksum)
        if temporary_checksum is not None:
            _try_unlink(temporary_checksum)
        if temporary_archive is not None:
            _try_unlink(temporary_archive)

    return output_archive, output_checksum


def _validated_member_name(info: ZipInfo) -> tuple[str, tuple[str, ...]]:
    name = info.filename
    if not name or "\\" in name or "\0" in name or name.startswith("/"):
        raise VerificationError(f"Unsafe ZIP member name: {name!r}")

    trimmed = name[:-1] if name.endswith("/") else name
    parts = tuple(trimmed.split("/"))
    if not trimmed or any(part in ("", ".", "..") for part in parts):
        raise VerificationError(f"Unsafe ZIP member name: {name!r}")
    if PurePosixPath(trimmed).is_absolute():
        raise VerificationError(f"Absolute ZIP member name: {name!r}")

    for part in parts:
        if ":" in part or part.rstrip(" .") != part:
            raise VerificationError(f"Windows-unsafe ZIP member name: {name!r}")
        device_name = part.split(".", 1)[0].casefold()
        if device_name in _WINDOWS_RESERVED_NAMES:
            raise VerificationError(f"Reserved Windows ZIP member name: {name!r}")

    return trimmed, parts


def inspect_archive(archive_path: Path) -> list[ZipInfo]:
    """Validate ZIP integrity, safe paths, uniqueness, and required payloads."""

    try:
        with ZipFile(archive_path, "r") as archive:
            bad_member = archive.testzip()
            if bad_member is not None:
                raise VerificationError(
                    f"ZIP CRC validation failed for member: {bad_member}"
                )

            infos = archive.infolist()
            members: dict[str, tuple[str, bool]] = {}
            for info in infos:
                normalized, parts = _validated_member_name(info)
                folded = normalized.casefold()
                if folded in members:
                    previous = members[folded][0]
                    raise VerificationError(
                        "ZIP contains case-insensitive duplicate members: "
                        f"{previous!r} and {info.filename!r}"
                    )

                unix_mode = info.external_attr >> 16
                if stat.S_ISLNK(unix_mode):
                    raise VerificationError(
                        f"ZIP symbolic links are not allowed: {info.filename!r}"
                    )
                if info.flag_bits & 0x1:
                    raise VerificationError(
                        f"Encrypted ZIP members are not allowed: {info.filename!r}"
                    )

                is_directory = info.is_dir()
                for index in range(1, len(parts)):
                    parent = "/".join(parts[:index]).casefold()
                    if parent in members and not members[parent][1]:
                        raise VerificationError(
                            "ZIP member is nested below a file: "
                            f"{info.filename!r} below {members[parent][0]!r}"
                        )
                members[folded] = (info.filename, is_directory)

            for folded, (original, is_directory) in members.items():
                if is_directory:
                    continue
                parts = folded.split("/")
                for index in range(1, len(parts)):
                    parent = "/".join(parts[:index])
                    if parent in members and not members[parent][1]:
                        raise VerificationError(
                            "ZIP member is nested below a file: "
                            f"{original!r} below {members[parent][0]!r}"
                        )

            for required in REQUIRED_FILES:
                found = members.get(required.casefold())
                if found is None or found[1]:
                    raise VerificationError(
                        f"Required packaged file is missing: {required}"
                    )
            return infos
    except BadZipFile as error:
        raise VerificationError(f"Invalid ZIP archive: {archive_path}") from error


def extract_archive(
    archive_path: Path, destination: Path, infos: Iterable[ZipInfo]
) -> None:
    """Extract prevalidated members without allowing writes outside destination."""

    destination = destination.resolve()
    if destination.exists():
        raise VerificationError(f"Extraction destination already exists: {destination}")
    destination.mkdir(parents=True)

    with ZipFile(archive_path, "r") as archive:
        for info in infos:
            _, parts = _validated_member_name(info)
            target = destination.joinpath(*parts)
            resolved_target = target.resolve(strict=False)
            try:
                resolved_target.relative_to(destination)
            except ValueError as error:
                raise VerificationError(
                    f"ZIP member escapes extraction root: {info.filename!r}"
                ) from error

            if info.is_dir():
                resolved_target.mkdir(parents=True, exist_ok=True)
                continue

            resolved_target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info, "r") as source, resolved_target.open("xb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)


def smoke_environment(test_module: Path) -> dict[str, str]:
    """Create an environment that exercises packaged default XLang discovery."""

    environment = os.environ.copy()
    for name in _OVERRIDE_ENVIRONMENT:
        environment.pop(name, None)
    environment["XLANG_TEST_MODULE"] = str(test_module.resolve())
    return environment


def run_packaged_smoke(
    *,
    archive_path: Path,
    infos: Iterable[ZipInfo],
    smoke_app: Path,
    test_module: Path,
    timeout_seconds: int,
) -> None:
    if not smoke_app.is_dir():
        raise VerificationError(f"Electron smoke app was not found: {smoke_app}")
    if not test_module.is_file():
        raise VerificationError(f"External XLang test module was not found: {test_module}")

    with tempfile.TemporaryDirectory(prefix="electron-xlang-package-") as temporary:
        extraction_root = Path(temporary) / "distribution"
        extract_archive(archive_path, extraction_root, infos)
        electron = extraction_root / "electron.exe"
        if not electron.is_file():
            raise VerificationError(f"Packaged Electron executable is missing: {electron}")

        try:
            completed = subprocess.run(
                [str(electron), str(smoke_app.resolve())],
                cwd=extraction_root,
                env=smoke_environment(test_module),
                check=False,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired as error:
            raise VerificationError(
                f"Packaged Electron XLang smoke timed out after {timeout_seconds} seconds"
            ) from error
        if completed.returncode != 0:
            raise VerificationError(
                "Packaged Electron XLang smoke failed with exit code "
                f"{completed.returncode}"
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifact-dir",
        type=Path,
        default=ROOT / "artifacts" / "win32-x64",
    )
    parser.add_argument("--archive", type=Path)
    version_group = parser.add_mutually_exclusive_group()
    version_group.add_argument("--version")
    version_group.add_argument("--version-file", type=Path)
    parser.add_argument(
        "--electron-ref", type=Path, default=ROOT / "config" / "electron.ref"
    )
    parser.add_argument("--xlang-ref", type=Path, default=ROOT / "config" / "xlang.ref")
    parser.add_argument(
        "--smoke-app", type=Path, default=ROOT / "tests" / "xlang-smoke"
    )
    parser.add_argument("--test-module", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=60)
    parser.add_argument(
        "--publish-dir",
        type=Path,
        help="publish the verified pair here only after the packaged smoke passes",
    )
    return parser.parse_args()


def main() -> int:
    if os.name != "nt":
        raise VerificationError("The packaged-distribution smoke currently requires Windows")

    args = parse_args()
    if args.timeout_seconds <= 0:
        raise VerificationError("--timeout-seconds must be positive")

    electron_revision = read_revision(args.electron_ref)
    xlang_revision = read_revision(args.xlang_ref)
    version = args.version
    if args.version_file is not None:
        version = read_version(args.version_file)

    if args.archive is not None:
        if version is not None:
            raise VerificationError("--archive cannot be combined with a version selector")
        archive_path = args.archive.resolve()
        if not archive_path.is_file():
            raise VerificationError(f"Artifact was not found: {archive_path}")
    else:
        archive_path = select_archive(
            artifact_directory=args.artifact_dir,
            electron_revision=electron_revision,
            xlang_revision=xlang_revision,
            version=version,
        )

    checksum_path = verify_checksum(archive_path)
    infos = inspect_archive(archive_path)
    run_packaged_smoke(
        archive_path=archive_path,
        infos=infos,
        smoke_app=args.smoke_app,
        test_module=args.test_module,
        timeout_seconds=args.timeout_seconds,
    )

    print(f"Verified archive:  {archive_path}")
    print(f"Verified checksum: {checksum_path}")
    print("Packaged Electron default XLang discovery smoke passed")
    if args.publish_dir is not None:
        published_archive, published_checksum = publish_verified_archive(
            archive_path, args.publish_dir
        )
        print(f"Published archive:  {published_archive}")
        print(f"Published checksum: {published_checksum}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except VerificationError as error:
        raise SystemExit(f"error: {error}") from error

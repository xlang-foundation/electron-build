from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "electron_xlang_verify_package", ROOT / "scripts" / "verify_package.py"
)
assert SPEC is not None and SPEC.loader is not None
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class VerifyPackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = self.root / (
            "electron-xlang-v0.0.0-xlang.abcdef0-win32-x64"
            "-e0123456-xfedcba9.zip"
        )
        self._write_archive(self.archive)
        self._write_checksum(self.archive)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _write_archive(path: Path, *, omit: str | None = None) -> None:
        with ZipFile(path, "w") as archive:
            for required in VERIFY.REQUIRED_FILES:
                if required != omit:
                    archive.writestr(required, required.encode("ascii"))

    @staticmethod
    def _write_checksum(path: Path) -> None:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        path.with_suffix(path.suffix + ".sha256").write_text(
            f"{digest}  {path.name}\n", encoding="ascii"
        )

    def test_checksum_and_required_payload_validate(self) -> None:
        checksum = VERIFY.verify_checksum(self.archive)
        infos = VERIFY.inspect_archive(self.archive)

        self.assertEqual(checksum.name, self.archive.name + ".sha256")
        self.assertEqual(
            {info.filename for info in infos}, set(VERIFY.REQUIRED_FILES)
        )

    def test_checksum_rejects_content_change(self) -> None:
        with self.archive.open("ab") as stream:
            stream.write(b"changed")

        with self.assertRaisesRegex(VERIFY.VerificationError, "SHA-256 mismatch"):
            VERIFY.verify_checksum(self.archive)

    def test_checksum_rejects_different_filename(self) -> None:
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.archive.with_suffix(".zip.sha256").write_text(
            f"{digest}  other.zip\n", encoding="ascii"
        )

        with self.assertRaisesRegex(VERIFY.VerificationError, "filename"):
            VERIFY.verify_checksum(self.archive)

    def test_publish_exposes_verified_pair_and_preserves_staging(self) -> None:
        output_directory = self.root / "public"

        output_archive, output_checksum = VERIFY.publish_verified_archive(
            self.archive, output_directory
        )

        self.assertEqual(output_archive.read_bytes(), self.archive.read_bytes())
        self.assertEqual(
            output_checksum.read_bytes(),
            self.archive.with_suffix(".zip.sha256").read_bytes(),
        )
        self.assertTrue(self.archive.is_file())
        self.assertTrue(self.archive.with_suffix(".zip.sha256").is_file())
        self.assertFalse(
            any(path.name.endswith(".publish.tmp") for path in output_directory.iterdir())
        )

    def test_publish_is_idempotent_but_never_overwrites_prior_pair(self) -> None:
        output_directory = self.root / "public"
        first = VERIFY.publish_verified_archive(self.archive, output_directory)
        second = VERIFY.publish_verified_archive(self.archive, output_directory)
        self.assertEqual(first, second)

        prior_archive = first[0]
        prior_checksum = first[1]
        prior_archive.write_bytes(b"prior-good-artifact")
        digest = hashlib.sha256(prior_archive.read_bytes()).hexdigest()
        prior_checksum.write_text(
            f"{digest}  {prior_archive.name}\n", encoding="ascii"
        )
        prior_bytes = prior_archive.read_bytes()
        prior_checksum_bytes = prior_checksum.read_bytes()

        with self.assertRaisesRegex(VERIFY.VerificationError, "Refusing to replace"):
            VERIFY.publish_verified_archive(self.archive, output_directory)

        self.assertEqual(prior_archive.read_bytes(), prior_bytes)
        self.assertEqual(prior_checksum.read_bytes(), prior_checksum_bytes)

    def test_publish_link_failure_leaves_no_public_zip(self) -> None:
        output_directory = self.root / "public"
        output_directory.mkdir()
        real_link = os.link
        calls = 0

        def fail_archive_link(source: Path, destination: Path) -> None:
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("simulated archive publication failure")
            real_link(source, destination)

        with mock.patch.object(VERIFY.os, "link", side_effect=fail_archive_link):
            with self.assertRaisesRegex(
                VERIFY.VerificationError, "Could not publish"
            ):
                VERIFY.publish_verified_archive(self.archive, output_directory)

        self.assertFalse((output_directory / self.archive.name).exists())
        self.assertFalse(
            (output_directory / (self.archive.name + ".sha256")).exists()
        )
        self.assertEqual(list(output_directory.iterdir()), [])

    def test_publish_recovers_matching_checksum_after_cleanup_is_blocked(
        self,
    ) -> None:
        output_directory = self.root / "public"
        output_directory.mkdir()
        output_checksum = output_directory / (self.archive.name + ".sha256")
        real_link = os.link
        real_try_unlink = VERIFY._try_unlink
        calls = 0

        def fail_archive_link(source: Path, destination: Path) -> None:
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("simulated archive publication failure")
            real_link(source, destination)

        def block_checksum_cleanup(path: Path) -> bool:
            if path == output_checksum:
                return False
            return real_try_unlink(path)

        with mock.patch.object(VERIFY.os, "link", side_effect=fail_archive_link):
            with mock.patch.object(
                VERIFY, "_try_unlink", side_effect=block_checksum_cleanup
            ):
                with self.assertRaisesRegex(
                    VERIFY.VerificationError, "Could not publish"
                ):
                    VERIFY.publish_verified_archive(
                        self.archive, output_directory
                    )

        self.assertFalse((output_directory / self.archive.name).exists())
        self.assertTrue(output_checksum.is_file())

        output_archive, recovered_checksum = VERIFY.publish_verified_archive(
            self.archive, output_directory
        )
        self.assertTrue(output_archive.is_file())
        self.assertEqual(recovered_checksum, output_checksum)
        VERIFY.verify_checksum(output_archive)

    def test_rejects_case_insensitive_duplicate(self) -> None:
        with ZipFile(self.archive, "a") as archive:
            archive.writestr("Resources/XLANG/XLANG_ENG.DLL", b"duplicate")

        with self.assertRaisesRegex(
            VERIFY.VerificationError, "case-insensitive duplicate"
        ):
            VERIFY.inspect_archive(self.archive)

    def test_rejects_missing_required_file(self) -> None:
        self._write_archive(self.archive, omit="resources/xlang/NOTICE")

        with self.assertRaisesRegex(VERIFY.VerificationError, "NOTICE"):
            VERIFY.inspect_archive(self.archive)

    def test_rejects_member_with_bad_crc(self) -> None:
        with ZipFile(self.archive, "r") as archive:
            info = archive.getinfo("electron.exe")
        payload = bytearray(self.archive.read_bytes())
        filename_length, extra_length = struct.unpack_from(
            "<HH", payload, info.header_offset + 26
        )
        data_offset = info.header_offset + 30 + filename_length + extra_length
        payload[data_offset] ^= 0x01
        self.archive.write_bytes(payload)

        with self.assertRaisesRegex(VERIFY.VerificationError, "CRC"):
            VERIFY.inspect_archive(self.archive)

    def test_rejects_path_traversal(self) -> None:
        with ZipFile(self.archive, "a") as archive:
            archive.writestr("../outside.txt", b"escape")

        with self.assertRaisesRegex(VERIFY.VerificationError, "Unsafe ZIP member"):
            VERIFY.inspect_archive(self.archive)

    def test_extracts_only_into_new_destination(self) -> None:
        infos = VERIFY.inspect_archive(self.archive)
        destination = self.root / "unique-extraction"
        VERIFY.extract_archive(self.archive, destination, infos)

        self.assertEqual(
            (destination / "resources/xlang/xlang_eng.dll").read_bytes(),
            b"resources/xlang/xlang_eng.dll",
        )
        with self.assertRaisesRegex(VERIFY.VerificationError, "already exists"):
            VERIFY.extract_archive(self.archive, destination, infos)

    def test_selects_exact_version_for_current_pins(self) -> None:
        selected = VERIFY.select_archive(
            artifact_directory=self.root,
            electron_revision="0123456" + ("0" * 33),
            xlang_revision="fedcba9" + ("0" * 33),
            version="0.0.0-xlang.abcdef0",
        )

        self.assertEqual(selected, self.archive)

    def test_selects_newest_matching_pinned_artifact(self) -> None:
        older = self.root / (
            "electron-xlang-v0.0.0-xlang.1111111-win32-x64"
            "-e0123456-xfedcba9.zip"
        )
        newer = self.root / (
            "electron-xlang-v0.0.0-xlang.2222222-win32-x64"
            "-e0123456-xfedcba9.zip"
        )
        self._write_archive(older)
        self._write_archive(newer)
        os.utime(self.archive, (1, 1))
        os.utime(older, (2, 2))
        os.utime(newer, (3, 3))

        selected = VERIFY.select_archive(
            artifact_directory=self.root,
            electron_revision="0123456" + ("0" * 33),
            xlang_revision="fedcba9" + ("0" * 33),
        )

        self.assertEqual(selected, newer)

    def test_smoke_environment_removes_runtime_path_overrides(self) -> None:
        module = self.root / "xlang_bridge_event_test.dll"
        with mock.patch.dict(
            os.environ,
            {
                "ELECTRON_RUN_AS_NODE": "1",
                "ELECTRON_XLANG_LIBRARY_PATH": "wrong-library",
                "XLANG_RUNTIME_DIR": "wrong-runtime",
                "XLANG_BRIDGE_PATH": "wrong-bridge",
                "UNRELATED": "preserved",
            },
            clear=True,
        ):
            environment = VERIFY.smoke_environment(module)

        self.assertEqual(environment["XLANG_TEST_MODULE"], str(module.resolve()))
        self.assertEqual(environment["UNRELATED"], "preserved")
        for name in VERIFY._OVERRIDE_ENVIRONMENT:
            self.assertNotIn(name, environment)

    def test_packaged_smoke_uses_unique_temporary_extraction_and_cleans_it(self) -> None:
        smoke_app = self.root / "smoke-app"
        smoke_app.mkdir()
        test_module = self.root / "xlang_bridge_event_test.dll"
        test_module.write_bytes(b"module")
        infos = VERIFY.inspect_archive(self.archive)

        with mock.patch.object(
            VERIFY.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=0),
        ) as run:
            VERIFY.run_packaged_smoke(
                archive_path=self.archive,
                infos=infos,
                smoke_app=smoke_app,
                test_module=test_module,
                timeout_seconds=30,
            )

        command = run.call_args.args[0]
        extracted_root = Path(command[0]).parent
        self.assertEqual(Path(command[1]), smoke_app.resolve())
        self.assertFalse(extracted_root.exists())
        environment = run.call_args.kwargs["env"]
        self.assertEqual(
            environment["XLANG_TEST_MODULE"], str(test_module.resolve())
        )
        for name in VERIFY._OVERRIDE_ENVIRONMENT:
            self.assertNotIn(name, environment)


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "electron_xlang_package", ROOT / "scripts" / "package.py"
)
assert SPEC is not None and SPEC.loader is not None
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class PackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.dist = self.root / "dist.zip"
        with ZipFile(self.dist, "w") as archive:
            archive.writestr("electron.exe", b"electron")

        self.bridge = self.root / "electron_xlang_bridge.dll"
        self.engine = self.root / "xlang3_runtime.dll"
        self.license = self.root / "LICENSE"
        self.notice = self.root / "NOTICE"
        self.bridge.write_bytes(b"bridge")
        self.engine.write_bytes(b"engine")
        self.license.write_text("license", encoding="utf-8")
        self.notice.write_text("notice", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_injects_windows_runtime_without_rewriting_source(self) -> None:
        original = self.dist.read_bytes()
        output = self.root / "electron-xlang.zip"
        PACKAGE.create_distribution(
            dist_zip=self.dist,
            output_zip=output,
            platform="win32",
            files={
                "bridge": self.bridge,
                "engine": self.engine,
                "license": self.license,
                "notice": self.notice,
            },
        )

        self.assertEqual(self.dist.read_bytes(), original)
        with ZipFile(output) as archive:
            self.assertEqual(archive.read("electron.exe"), b"electron")
            self.assertEqual(
                archive.read("resources/xlang/electron_xlang_bridge.dll"), b"bridge"
            )
            self.assertEqual(archive.read("resources/xlang/xlang3_runtime.dll"), b"engine")
            self.assertEqual(archive.read("resources/xlang/LICENSE"), b"license")
            self.assertEqual(archive.read("resources/xlang/NOTICE"), b"notice")

    def test_uses_app_bundle_resource_path_on_macos(self) -> None:
        output = self.root / "electron-xlang-mac.zip"
        bridge = self.bridge.with_suffix(".dylib")
        engine = self.engine.with_suffix(".dylib")
        bridge.write_bytes(b"bridge")
        engine.write_bytes(b"engine")
        PACKAGE.create_distribution(
            dist_zip=self.dist,
            output_zip=output,
            platform="darwin",
            files={"bridge": bridge, "engine": engine},
        )

        with ZipFile(output) as archive:
            self.assertIn(
                "Electron.app/Contents/Resources/xlang/electron_xlang_bridge.dylib",
                archive.namelist(),
            )
            self.assertIn(
                "Electron.app/Contents/Resources/xlang/libxlang3_runtime.dylib",
                archive.namelist(),
            )

    def test_preserves_unix_engine_library_prefix(self) -> None:
        output = self.root / "electron-xlang-linux.zip"
        bridge = self.root / "electron_xlang_bridge.so"
        engine = self.root / "libxlang3_runtime.so"
        bridge.write_bytes(b"bridge")
        engine.write_bytes(b"engine")
        PACKAGE.create_distribution(
            dist_zip=self.dist,
            output_zip=output,
            platform="linux",
            files={"bridge": bridge, "engine": engine},
        )

        with ZipFile(output) as archive:
            self.assertIn(
                "resources/xlang/electron_xlang_bridge.so", archive.namelist()
            )
            self.assertIn("resources/xlang/libxlang3_runtime.so", archive.namelist())

    def test_rejects_existing_runtime_entry(self) -> None:
        with ZipFile(self.dist, "a") as archive:
            archive.writestr(
                "resources/xlang/electron_xlang_bridge.dll", b"old bridge"
            )
        with self.assertRaisesRegex(ValueError, "already contains"):
            PACKAGE.create_distribution(
                dist_zip=self.dist,
                output_zip=self.root / "collision.zip",
                platform="win32",
                files={"bridge": self.bridge, "engine": self.engine},
            )

    def test_sha256_file_is_stable(self) -> None:
        sample = self.root / "sample.bin"
        sample.write_bytes(b"abc")
        self.assertEqual(
            PACKAGE.sha256_file(sample),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        )


if __name__ == "__main__":
    unittest.main()

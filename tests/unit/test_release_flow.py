from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseFlowTests(unittest.TestCase):
    def test_windows_electron_version_ends_in_numeric_prerelease_component(
        self,
    ) -> None:
        source = (ROOT / "scripts" / "build.ps1").read_text(encoding="utf-8")

        self.assertIn(
            '$electronVersion = "0.0.0-xlang.$shortElectronRevision.0"',
            source,
        )
        self.assertNotIn(
            '$electronVersion = "0.0.0-xlang.$shortElectronRevision"\n',
            source,
        )

    def test_build_packages_to_unique_staging_before_tests(self) -> None:
        source = (ROOT / "scripts" / "build.ps1").read_text(encoding="utf-8")

        self.assertIn(
            '$runIdentifier = "$PID-$([Guid]::NewGuid().ToString(\'N\'))"',
            source,
        )
        self.assertIn("'--output-dir', $packageStagingDirectory", source)
        self.assertNotIn("'--output-dir', $artifactDirectory", source)
        self.assertIn("'-PackageArtifactDirectory', $packageStagingDirectory", source)
        self.assertIn("'-PublishPackage'", source)
        self.assertIn("Remove-AbandonedPackageStaging", source)
        self.assertIn(
            "'^(?<pid>[0-9]+)-[0-9a-fA-F]{32}$'",
            source,
        )
        self.assertIn("Get-Process -Id $ownerProcessId", source)
        self.assertIn("[System.IO.FileAttributes]::ReparsePoint", source)
        self.assertLess(
            source.index("'--output-dir', $packageStagingDirectory"),
            source.index("'-PublishPackage'"),
        )

    def test_publish_requires_verification_and_staging(self) -> None:
        source = (ROOT / "scripts" / "test.ps1").read_text(encoding="utf-8")

        self.assertIn("-PublishPackage requires -VerifyPackage.", source)
        self.assertIn(
            "-PublishPackage requires a staging -PackageArtifactDirectory.",
            source,
        )
        self.assertIn("out\\package-staging\\win32-x64", source)
        self.assertIn("'--publish-dir'", source)

    def test_skip_tests_cannot_publish_a_package(self) -> None:
        source = (ROOT / "scripts" / "build.ps1").read_text(encoding="utf-8")

        self.assertIn("$SkipTests -and -not $SkipPackage", source)
        self.assertIn("only tested packages are published", source)

    def test_skipped_build_steps_cannot_publish_a_package(self) -> None:
        source = (ROOT / "scripts" / "build.ps1").read_text(encoding="utf-8")

        self.assertIn(
            "-not $SkipPackage -and ($SkipXLang -or $SkipBridge -or $SkipElectron)",
            source,
        )
        self.assertIn(
            "published artifacts must be rebuilt from the pinned sources",
            source,
        )

    def test_packaged_smoke_precedes_publication(self) -> None:
        source = (ROOT / "scripts" / "verify_package.py").read_text(encoding="utf-8")
        main_source = source[source.index("def main() -> int:") :]

        self.assertLess(
            main_source.index("run_packaged_smoke("),
            main_source.index("publish_verified_archive("),
        )


if __name__ == "__main__":
    unittest.main()

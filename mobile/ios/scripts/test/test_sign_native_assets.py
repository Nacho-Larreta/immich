#!/usr/bin/env python3

import json
import os
import plistlib
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


IOS_ROOT = Path(__file__).resolve().parents[2]
SIGNER = IOS_ROOT / "scripts" / "sign_native_assets.py"
PROJECT = IOS_ROOT / "Runner.xcodeproj" / "project.pbxproj"


class NativeAssetSigningTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.build_dir = self.root / "Build"
        self.frameworks_dir = self.build_dir / "Nacho Fotos.app" / "Frameworks"
        self.assets_dir = (
            self.frameworks_dir / "App.framework" / "flutter_assets"
        )
        self.assets_dir.mkdir(parents=True)
        self.log = self.root / "codesign.log"
        self.codesign = self.root / "fake_codesign.py"
        self.codesign.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import os
                from pathlib import Path
                import sys

                with Path(os.environ["FAKE_CODESIGN_LOG"]).open("a") as output:
                    output.write(" ".join(sys.argv[1:]) + "\\n")

                if "--display" in sys.argv:
                    nested_ad_hoc = (
                        os.environ.get("FAKE_NESTED_ADHOC") == "YES"
                        and Path(sys.argv[-1]).name == "NestedTool"
                    )
                    team = "not set" if nested_ad_hoc else os.environ.get("FAKE_SIGNED_TEAM", "TEAM123")
                    signature = "Signature=adhoc" if nested_ad_hoc else os.environ.get("FAKE_SIGNATURE", "Authority=Apple Development: Test")
                    print(signature, file=sys.stderr)
                    print(f"TeamIdentifier={team}", file=sys.stderr)
                """
            )
        )
        self.codesign.chmod(0o755)

    def tearDown(self):
        self.temp_dir.cleanup()

    def environment(self, **overrides):
        environment = os.environ.copy()
        environment.update(
            {
                "PLATFORM_NAME": "iphoneos",
                "CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGNING_REQUIRED": "YES",
                "TARGET_BUILD_DIR": str(self.build_dir),
                "FRAMEWORKS_FOLDER_PATH": "Nacho Fotos.app/Frameworks",
                "EXPANDED_CODE_SIGN_IDENTITY": "SIGNING-IDENTITY",
                "DEVELOPMENT_TEAM": "TEAM123",
                "NATIVE_ASSET_CODESIGN": str(self.codesign),
                "FAKE_CODESIGN_LOG": str(self.log),
            }
        )
        environment.update(overrides)
        return environment

    def write_manifest(self, assets):
        manifest = {
            "format-version": [1, 0, 0],
            "native-assets": {"ios_arm64": assets},
        }
        (self.assets_dir / "NativeAssetsManifest.json").write_text(
            json.dumps(manifest)
        )

    def create_framework(self, name, bundle_identifier=None):
        framework = self.frameworks_dir / f"{name}.framework"
        framework.mkdir(parents=True, exist_ok=True)
        (framework / name).write_bytes(b"binary")
        identifier = bundle_identifier or (
            "io.flutter.flutter.native-assets." + name.replace("_", "-").lower()
        )
        with (framework / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": identifier}, output)
        return framework

    def run_signer(self, **overrides):
        return subprocess.run(
            [sys.executable, str(SIGNER)],
            env=self.environment(**overrides),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_zero_native_assets_is_a_successful_no_op(self):
        self.write_manifest({})

        result = self.run_signer(EXPANDED_CODE_SIGN_IDENTITY="")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.log.exists())

    def test_signs_and_strictly_verifies_each_manifest_framework(self):
        objective_c = self.create_framework("objective_c")
        sqlite3 = self.create_framework("sqlite3")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ],
                "package:sqlite3/src/ffi/libsqlite3.g.dart": [
                    "absolute",
                    "sqlite3.framework/sqlite3",
                ],
            }
        )

        result = self.run_signer()

        self.assertEqual(0, result.returncode, result.stderr)
        commands = self.log.read_text().splitlines()
        self.assertEqual(6, len(commands))
        for framework in (objective_c, sqlite3):
            framework = framework.resolve()
            self.assertIn(
                f"--force --sign SIGNING-IDENTITY --timestamp=none {framework}",
                commands,
            )
            self.assertIn(
                f"--verify --deep --strict --verbose=2 {framework}",
                commands,
            )
            self.assertIn(
                f"--display --verbose=4 {framework}",
                commands,
            )

    def test_fails_closed_when_a_manifest_framework_is_missing(self):
        self.write_manifest(
            {
                "package:missing/missing.dylib": [
                    "absolute",
                    "missing.framework/missing",
                ]
            }
        )

        result = self.run_signer()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("native asset framework is missing", result.stderr)
        self.assertFalse(self.log.exists())

    def test_fails_closed_when_the_manifest_binary_is_unresolved(self):
        framework = self.create_framework("objective_c")
        (framework / "objective_c").unlink()
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("native asset framework is unresolved", result.stderr)
        self.assertFalse(self.log.exists())

    def test_rejects_absolute_or_parent_frameworks_folder_paths(self):
        for frameworks_path in (str(self.frameworks_dir), "../Frameworks"):
            with self.subTest(frameworks_path=frameworks_path):
                result = self.run_signer(FRAMEWORKS_FOLDER_PATH=frameworks_path)

                self.assertNotEqual(0, result.returncode)
                self.assertIn("FRAMEWORKS_FOLDER_PATH", result.stderr)

    def test_rejects_frameworks_root_symlink_escape(self):
        outside = self.root / "OutsideFrameworks"
        outside.mkdir()
        (self.build_dir / "EscapedFrameworks").symlink_to(
            outside, target_is_directory=True
        )

        result = self.run_signer(FRAMEWORKS_FOLDER_PATH="EscapedFrameworks")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("escapes TARGET_BUILD_DIR", result.stderr)

    def test_rejects_native_asset_binary_symlink(self):
        framework = self.create_framework("objective_c")
        outside_binary = self.root / "objective_c"
        outside_binary.write_bytes(b"binary")
        (framework / "objective_c").unlink()
        (framework / "objective_c").symlink_to(outside_binary)
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("symlink", result.stderr)

    def test_rejects_app_or_unrelated_framework_descriptors(self):
        cases = (
            (
                "App.framework/App",
                "App",
                "io.flutter.flutter.app",
                "native asset framework descriptor",
            ),
            (
                "Unrelated.framework/Unrelated",
                "Unrelated",
                "com.example.unrelated",
                "native asset bundle identifier",
            ),
        )
        for descriptor, name, bundle_identifier, expected_error in cases:
            with self.subTest(descriptor=descriptor):
                self.create_framework(name, bundle_identifier)
                self.write_manifest(
                    {"package:test/test.dylib": ["absolute", descriptor]}
                )

                result = self.run_signer()

                self.assertNotEqual(0, result.returncode)
                self.assertIn(expected_error, result.stderr)

    def test_rejects_non_exact_framework_descriptor_shapes(self):
        self.create_framework("objective_c")
        for descriptor in (
            "Nested/objective_c.framework/objective_c",
            "objective_c.framework/other",
            "objective_c.framework/objective_c/extra",
            "./objective_c.framework/objective_c",
            "objective_c.framework//objective_c",
        ):
            with self.subTest(descriptor=descriptor):
                self.write_manifest(
                    {"package:test/test.dylib": ["absolute", descriptor]}
                )

                result = self.run_signer()

                self.assertNotEqual(0, result.returncode)
                self.assertIn("<name>.framework/<name>", result.stderr)

    def test_rejects_wrong_native_asset_bundle_identifier(self):
        self.create_framework(
            "objective_c", "io.flutter.flutter.native-assets.wrong-name"
        )
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("bundle identifier", result.stderr)

    def test_audits_nested_code_and_rejects_nested_ad_hoc_signature(self):
        framework = self.create_framework("objective_c")
        nested_tool = framework / "NestedTool"
        nested_tool.write_bytes(bytes.fromhex("cffaedfe") + b"nested")
        nested_tool.chmod(0o755)
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer(FAKE_NESTED_ADHOC="YES")

        self.assertNotEqual(0, result.returncode)
        commands = self.log.read_text().splitlines()
        self.assertIn(
            f"--verify --deep --strict --verbose=2 {framework.resolve()}",
            commands,
        )
        self.assertIn(
            f"--verify --strict --verbose=2 {nested_tool.resolve()}",
            commands,
        )
        self.assertIn("valid signing team", result.stderr)

    def test_requires_development_team_when_assets_exist(self):
        self.create_framework("objective_c")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer(DEVELOPMENT_TEAM="")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("DEVELOPMENT_TEAM is required", result.stderr)
        self.assertFalse(self.log.exists())

    def test_missing_manifest_fails_when_native_asset_framework_exists(self):
        self.create_framework("objective_c")

        result = self.run_signer()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("manifest is missing", result.stderr)
        self.assertFalse(self.log.exists())

    def test_manifest_must_include_every_native_asset_framework(self):
        self.create_framework("objective_c")
        self.create_framework("sqlite3")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("omits native asset framework", result.stderr)
        self.assertFalse(self.log.exists())

    def test_fails_closed_when_signing_identity_is_absent(self):
        self.create_framework("objective_c")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer(EXPANDED_CODE_SIGN_IDENTITY="")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("signing identity is required", result.stderr)
        self.assertFalse(self.log.exists())

    def test_rejects_ad_hoc_or_teamless_signatures(self):
        self.create_framework("objective_c")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer(
            FAKE_SIGNATURE="Signature=adhoc", FAKE_SIGNED_TEAM="not set"
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("valid signing team", result.stderr)

    def test_rejects_a_signature_from_another_team(self):
        self.create_framework("objective_c")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer(FAKE_SIGNED_TEAM="OTHERTEAM")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("does not match DEVELOPMENT_TEAM", result.stderr)

    def test_simulator_build_is_unchanged(self):
        result = self.run_signer(PLATFORM_NAME="iphonesimulator")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.log.exists())

    def test_signing_phase_is_immediately_after_flutter_thin_binary(self):
        project = PROJECT.read_text()
        runner_phase_list = project.split("97C146ED1CF9000F007C117D /* Runner */ = {", 1)[
            1
        ].split("buildRules = (", 1)[0]

        thin_binary = runner_phase_list.index("/* Thin Binary */")
        native_signing = runner_phase_list.index("/* Sign Flutter Native Assets */")
        pods_embedding = runner_phase_list.index("/* [CP] Embed Pods Frameworks */")

        self.assertLess(thin_binary, native_signing)
        self.assertLess(native_signing, pods_embedding)
        between = runner_phase_list[thin_binary:native_signing]
        self.assertEqual(1, between.count("\n"))


if __name__ == "__main__":
    unittest.main()

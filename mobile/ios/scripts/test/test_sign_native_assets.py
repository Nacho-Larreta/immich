#!/usr/bin/env python3

import json
import os
import plistlib
import subprocess
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
        self.platform_log = self.root / "platform-tools.log"
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
        self.lipo = self.root / "fake_lipo.py"
        self.lipo.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                from pathlib import Path
                import sys

                with Path(os.environ["FAKE_PLATFORM_LOG"]).open("a") as output:
                    output.write("lipo " + " ".join(sys.argv[1:]) + "\\n")

                if os.environ.get("FAKE_LIPO_FAIL") == "YES":
                    sys.exit(1)
                outputs = json.loads(
                    os.environ.get("FAKE_LIPO_ARCHS_BY_BINARY", "{}")
                )
                print(
                    outputs.get(
                        Path(sys.argv[-1]).name,
                        os.environ.get("FAKE_LIPO_ARCHS", "arm64"),
                    )
                )
                """
            )
        )
        self.lipo.chmod(0o755)
        self.vtool = self.root / "fake_vtool.py"
        self.vtool.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                from pathlib import Path
                import sys

                with Path(os.environ["FAKE_PLATFORM_LOG"]).open("a") as output:
                    output.write("vtool " + " ".join(sys.argv[1:]) + "\\n")

                architecture = sys.argv[sys.argv.index("-arch") + 1]
                binary_name = Path(sys.argv[-1]).name
                key = f"{binary_name}:{architecture}"
                failures = json.loads(os.environ.get("FAKE_VTOOL_FAILURES", "[]"))
                if key in failures:
                    sys.exit(1)
                platforms = json.loads(
                    os.environ.get("FAKE_VTOOL_PLATFORMS", "{}")
                )
                value = platforms.get(
                    key, os.environ.get("FAKE_VTOOL_PLATFORM", "IOS")
                )
                for platform in value.split(",") if value else []:
                    print(f" platform {platform}")
                """
            )
        )
        self.vtool.chmod(0o755)

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
                "NATIVE_ASSET_LIPO": str(self.lipo),
                "NATIVE_ASSET_VTOOL": str(self.vtool),
                "FAKE_CODESIGN_LOG": str(self.log),
                "FAKE_PLATFORM_LOG": str(self.platform_log),
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
        (framework / name).write_bytes(bytes.fromhex("cffaedfe") + b"binary")
        identifier = bundle_identifier or (
            "io.flutter.flutter.native-assets." + name.replace("_", "-").lower()
        )
        with (framework / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": identifier}, output)
        return framework

    def run_signer(self, **overrides):
        return subprocess.run(
            ["/usr/bin/python3", str(SIGNER)],
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

    def test_device_rejects_simulator_binary_before_any_signing(self):
        self.create_framework("objective_c")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )

        result = self.run_signer(FAKE_VTOOL_PLATFORM="IOSSIMULATOR")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("IOSSIMULATOR", result.stderr)
        self.assertIn("expected IOS", result.stderr)
        self.assertFalse(self.log.exists())

    def test_simulator_rejects_device_binary_without_a_signing_identity(self):
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
            PLATFORM_NAME="iphonesimulator",
            EXPANDED_CODE_SIGN_IDENTITY="",
            FAKE_VTOOL_PLATFORM="IOS",
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("IOS", result.stderr)
        self.assertIn("expected IOSSIMULATOR", result.stderr)
        self.assertFalse(self.log.exists())

    def test_simulator_validates_matching_binary_without_a_signing_identity(self):
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
            PLATFORM_NAME="iphonesimulator",
            EXPANDED_CODE_SIGN_IDENTITY="",
            DEVELOPMENT_TEAM="",
            FAKE_VTOOL_PLATFORM="IOSSIMULATOR",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.log.exists())
        platform_commands = self.platform_log.read_text().splitlines()
        lipo_commands = [
            line for line in platform_commands if line.startswith("lipo ")
        ]
        vtool_commands = [
            line for line in platform_commands if line.startswith("vtool ")
        ]
        self.assertEqual(1, len(lipo_commands))
        self.assertEqual(1, len(vtool_commands))
        self.assertIn(
            "vtool -arch arm64 -show-build ", platform_commands[1]
        )

    def test_rejects_a_mismatched_slice_in_a_multi_arch_binary(self):
        self.create_framework("objective_c")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )
        platforms = json.dumps(
            {
                "objective_c:arm64": "IOS",
                "objective_c:x86_64": "IOSSIMULATOR",
            }
        )

        result = self.run_signer(
            FAKE_LIPO_ARCHS="arm64 x86_64",
            FAKE_VTOOL_PLATFORMS=platforms,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("x86_64", result.stderr)
        self.assertFalse(self.log.exists())

    def test_rejects_a_non_mach_o_primary_binary(self):
        framework = self.create_framework("objective_c")
        (framework / "objective_c").write_bytes(b"not-mach-o")
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
        self.assertIn("primary binary is not Mach-O", result.stderr)
        self.assertFalse(self.platform_log.exists())
        self.assertFalse(self.log.exists())

    def test_rejects_a_mismatched_nested_mach_o_before_signing(self):
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
        platforms = json.dumps(
            {
                "objective_c:arm64": "IOS",
                "NestedTool:arm64": "IOSSIMULATOR",
            }
        )

        result = self.run_signer(FAKE_VTOOL_PLATFORMS=platforms)

        self.assertNotEqual(0, result.returncode)
        self.assertIn("NestedTool", result.stderr)
        self.assertFalse(self.log.exists())

    def test_platform_inspection_failures_are_closed_before_signing(self):
        self.create_framework("objective_c")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ]
            }
        )
        cases = (
            ({"FAKE_LIPO_FAIL": "YES"}, "architecture inspection failed"),
            ({"FAKE_LIPO_ARCHS": ""}, "no architectures"),
            (
                {"FAKE_LIPO_ARCHS": "arm64 arm64"},
                "architecture inspection is ambiguous",
            ),
            (
                {"FAKE_VTOOL_FAILURES": json.dumps(["objective_c:arm64"])},
                "platform inspection failed",
            ),
            ({"FAKE_VTOOL_PLATFORM": ""}, "no SDK platform"),
            ({"FAKE_VTOOL_PLATFORM": "IOS,IOS"}, "ambiguous SDK platform"),
        )
        for overrides, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                if self.log.exists():
                    self.log.unlink()
                result = self.run_signer(**overrides)

                self.assertNotEqual(0, result.returncode)
                self.assertIn(expected_error, result.stderr)
                self.assertFalse(self.log.exists())

    def test_validates_every_framework_before_the_first_codesign(self):
        self.create_framework("objective_c")
        self.create_framework("sqlite3")
        self.write_manifest(
            {
                "package:objective_c/objective_c.dylib": [
                    "absolute",
                    "objective_c.framework/objective_c",
                ],
                "package:sqlite3/sqlite3.dylib": [
                    "absolute",
                    "sqlite3.framework/sqlite3",
                ],
            }
        )
        platforms = json.dumps(
            {
                "objective_c:arm64": "IOS",
                "sqlite3:arm64": "IOSSIMULATOR",
            }
        )

        result = self.run_signer(FAKE_VTOOL_PLATFORMS=platforms)

        self.assertNotEqual(0, result.returncode)
        self.assertIn("sqlite3", result.stderr)
        self.assertFalse(self.log.exists())

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

    def test_simulator_build_without_native_assets_is_a_successful_no_op(self):
        self.write_manifest({})
        result = self.run_signer(PLATFORM_NAME="iphonesimulator")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.log.exists())

    def test_signing_phase_is_immediately_after_flutter_thin_binary(self):
        project = PROJECT.read_text()
        runner_phase_list = project.split("97C146ED1CF9000F007C117D /* Runner */ = {", 1)[
            1
        ].split("buildRules = (", 1)[0]

        thin_binary = runner_phase_list.index("/* Thin Binary */")
        native_signing = runner_phase_list.index(
            "/* Validate and Sign Flutter Native Assets */"
        )
        pods_embedding = runner_phase_list.index("/* [CP] Embed Pods Frameworks */")

        self.assertLess(thin_binary, native_signing)
        self.assertLess(native_signing, pods_embedding)
        between = runner_phase_list[thin_binary:native_signing]
        self.assertEqual(1, between.count("\n"))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3

import json
import os
import plistlib
import re
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath


NATIVE_ASSET_BUNDLE_PREFIX = "io.flutter.flutter.native-assets."
MACH_O_MAGICS = {
    bytes.fromhex(value)
    for value in (
        "feedface",
        "cefaedfe",
        "feedfacf",
        "cffaedfe",
        "cafebabe",
        "bebafeca",
        "cafebabf",
        "bfbafeca",
    )
}


class NativeAssetSigningError(Exception):
    pass


def signing_is_required(environment):
    return (
        environment.get("PLATFORM_NAME") == "iphoneos"
        and environment.get("CODE_SIGNING_ALLOWED") == "YES"
        and environment.get("CODE_SIGNING_REQUIRED", "YES") != "NO"
    )


def resolve_frameworks_root(environment):
    target_build_dir = environment.get("TARGET_BUILD_DIR", "").strip()
    frameworks_folder_path = environment.get("FRAMEWORKS_FOLDER_PATH", "").strip()
    if not target_build_dir:
        raise NativeAssetSigningError("TARGET_BUILD_DIR is unavailable")
    if not frameworks_folder_path:
        raise NativeAssetSigningError("FRAMEWORKS_FOLDER_PATH is unavailable")

    target_root = Path(target_build_dir).resolve()
    if not target_root.is_dir():
        raise NativeAssetSigningError("TARGET_BUILD_DIR is not a directory")

    relative_folder = PurePosixPath(frameworks_folder_path)
    if relative_folder.is_absolute() or ".." in relative_folder.parts:
        raise NativeAssetSigningError(
            "FRAMEWORKS_FOLDER_PATH must be a relative path without parent traversal"
        )

    frameworks_root = (target_root / Path(*relative_folder.parts)).resolve()
    try:
        relative_root = frameworks_root.relative_to(target_root)
    except ValueError as error:
        raise NativeAssetSigningError(
            "frameworks root escapes TARGET_BUILD_DIR through a symlink"
        ) from error
    if relative_root == Path("."):
        raise NativeAssetSigningError(
            "frameworks root must be strictly below TARGET_BUILD_DIR"
        )
    if not frameworks_root.is_dir():
        raise NativeAssetSigningError("frameworks root is not a directory")
    return frameworks_root


def load_manifest(manifest_path):
    if not manifest_path.exists():
        return None
    if manifest_path.is_symlink():
        raise NativeAssetSigningError("native asset manifest must not be a symlink")
    try:
        return json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise NativeAssetSigningError("native asset manifest is unreadable") from error


def native_asset_paths(manifest):
    platforms = manifest.get("native-assets") if isinstance(manifest, dict) else None
    if not isinstance(platforms, dict):
        raise NativeAssetSigningError("native asset manifest has an invalid shape")

    paths = []
    for platform, assets in platforms.items():
        if not platform.startswith("ios_"):
            continue
        if not isinstance(assets, dict):
            raise NativeAssetSigningError("native asset manifest has an invalid iOS entry")
        for descriptor in assets.values():
            if (
                not isinstance(descriptor, list)
                or len(descriptor) != 2
                or descriptor[0] != "absolute"
                or not isinstance(descriptor[1], str)
            ):
                raise NativeAssetSigningError(
                    "native asset manifest has an unsupported iOS descriptor"
                )
            paths.append(descriptor[1])
    return paths


def descriptor_framework_name(asset_path):
    path = PurePosixPath(asset_path)
    if path.is_absolute() or len(path.parts) != 2:
        raise NativeAssetSigningError(
            "native asset framework descriptor must be <name>.framework/<name>"
        )

    framework_component, binary_name = path.parts
    if not framework_component.endswith(".framework"):
        raise NativeAssetSigningError(
            "native asset framework descriptor must be <name>.framework/<name>"
        )
    framework_name = framework_component[: -len(".framework")]
    canonical_descriptor = f"{framework_name}.framework/{framework_name}"
    if (
        not framework_name
        or framework_name == "App"
        or binary_name != framework_name
        or asset_path != canonical_descriptor
        or re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", framework_name) is None
    ):
        raise NativeAssetSigningError(
            "native asset framework descriptor must be <name>.framework/<name>"
        )
    return framework_name


def expected_bundle_identifier(framework_name):
    normalized_name = framework_name.replace("_", "-").lower()
    return NATIVE_ASSET_BUNDLE_PREFIX + normalized_name


def read_bundle_identifier(framework):
    info_plist = framework / "Info.plist"
    if info_plist.is_symlink():
        raise NativeAssetSigningError("native asset Info.plist must not be a symlink")
    try:
        with info_plist.open("rb") as input_file:
            bundle_identifier = plistlib.load(input_file).get("CFBundleIdentifier")
    except (OSError, plistlib.InvalidFileException) as error:
        raise NativeAssetSigningError(
            f"native asset Info.plist is unreadable: {framework.name}"
        ) from error
    if not isinstance(bundle_identifier, str):
        raise NativeAssetSigningError(
            f"native asset bundle identifier is missing: {framework.name}"
        )
    return bundle_identifier


def require_path_inside(path, root, error_message):
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError as error:
        raise NativeAssetSigningError(error_message) from error


def validate_framework_symlinks(framework):
    if framework.is_symlink():
        raise NativeAssetSigningError(
            f"native asset framework must not be a symlink: {framework.name}"
        )
    for descendant in framework.rglob("*"):
        if descendant.is_symlink():
            require_path_inside(
                descendant,
                framework,
                f"native asset symlink escapes its framework: {descendant.name}",
            )


def validate_native_framework(frameworks_root, framework_name, framework):
    expected_framework = frameworks_root / f"{framework_name}.framework"
    if framework != expected_framework or framework.parent != frameworks_root:
        raise NativeAssetSigningError(
            "native asset framework must be an immediate child of the app Frameworks directory"
        )
    if not framework.is_dir():
        raise NativeAssetSigningError(
            f"native asset framework is missing: {framework.name}"
        )
    validate_framework_symlinks(framework)

    binary = framework / framework_name
    if binary.is_symlink():
        raise NativeAssetSigningError(
            f"native asset binary must not be a symlink: {binary.name}"
        )
    if not binary.is_file():
        raise NativeAssetSigningError(
            f"native asset framework is unresolved: {framework.name}"
        )
    require_path_inside(
        binary,
        framework,
        f"native asset binary escapes its framework: {binary.name}",
    )

    bundle_identifier = read_bundle_identifier(framework)
    if bundle_identifier != expected_bundle_identifier(framework_name):
        raise NativeAssetSigningError(
            f"native asset bundle identifier does not match its framework: {framework.name}"
        )
    return framework, binary


def scan_native_asset_frameworks(frameworks_root):
    native_frameworks = {}
    framework_paths = []
    for directory, child_directories, _ in os.walk(
        frameworks_root, followlinks=False
    ):
        for child_directory in child_directories:
            if child_directory.endswith(".framework"):
                framework_paths.append(Path(directory) / child_directory)

    for framework in framework_paths:
        require_path_inside(
            framework,
            frameworks_root,
            "framework symlink escapes the app Frameworks directory",
        )
        info_plist = framework / "Info.plist"
        if not info_plist.is_file():
            continue
        bundle_identifier = read_bundle_identifier(framework)
        if not bundle_identifier.startswith(NATIVE_ASSET_BUNDLE_PREFIX):
            continue
        framework_name = framework.name[: -len(".framework")]
        validated_framework, _ = validate_native_framework(
            frameworks_root, framework_name, framework
        )
        native_frameworks[validated_framework] = bundle_identifier
    return native_frameworks


def resolve_manifest_frameworks(frameworks_root, asset_paths):
    frameworks = {}
    for asset_path in asset_paths:
        framework_name = descriptor_framework_name(asset_path)
        framework = frameworks_root / f"{framework_name}.framework"
        validated_framework, binary = validate_native_framework(
            frameworks_root, framework_name, framework
        )
        frameworks[validated_framework] = binary
    return frameworks


def require_complete_manifest(discovered, declared):
    omitted = set(discovered) - set(declared)
    if omitted:
        raise NativeAssetSigningError(
            "native asset manifest omits native asset framework bundles"
        )


def is_mach_o(path):
    try:
        with path.open("rb") as input_file:
            return input_file.read(4) in MACH_O_MAGICS
    except OSError as error:
        raise NativeAssetSigningError(
            f"native asset code object is unreadable: {path.name}"
        ) from error


def nested_code_objects(framework, primary_binary):
    code_objects = []
    for candidate in framework.rglob("*"):
        if candidate.is_symlink() or not candidate.is_file():
            continue
        if candidate.resolve() == primary_binary.resolve():
            continue
        mode = candidate.stat().st_mode
        executable = bool(mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
        if executable or is_mach_o(candidate):
            code_objects.append(candidate.resolve())
    return sorted(set(code_objects))


def run_codesign(codesign, arguments, failure_message):
    result = subprocess.run(
        [str(codesign), *arguments],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise NativeAssetSigningError(failure_message)
    return result


def verify_signing_team(codesign, code_object, expected_team):
    result = run_codesign(
        codesign,
        ["--display", "--verbose=4", str(code_object)],
        f"native asset signature metadata is unreadable: {code_object.name}",
    )
    metadata = f"{result.stdout}\n{result.stderr}"
    team_match = re.search(r"^TeamIdentifier=(.+)$", metadata, re.MULTILINE)
    team = team_match.group(1).strip() if team_match else ""
    if "Signature=adhoc" in metadata or not team or team == "not set":
        raise NativeAssetSigningError(
            f"native asset code object has no valid signing team: {code_object.name}"
        )
    if team != expected_team:
        raise NativeAssetSigningError(
            f"native asset signing team does not match DEVELOPMENT_TEAM: {code_object.name}"
        )


def sign_framework(codesign, identity, expected_team, framework, primary_binary):
    run_codesign(
        codesign,
        ["--force", "--sign", identity, "--timestamp=none", str(framework)],
        f"native asset signing failed: {framework.name}",
    )
    run_codesign(
        codesign,
        ["--verify", "--deep", "--strict", "--verbose=2", str(framework)],
        f"native asset signature verification failed: {framework.name}",
    )
    verify_signing_team(codesign, framework, expected_team)

    for code_object in nested_code_objects(framework, primary_binary):
        run_codesign(
            codesign,
            ["--verify", "--strict", "--verbose=2", str(code_object)],
            f"nested native asset signature verification failed: {code_object.name}",
        )
        verify_signing_team(codesign, code_object, expected_team)


def sign_native_assets(environment):
    if not signing_is_required(environment):
        return

    frameworks_root = resolve_frameworks_root(environment)
    manifest_path = (
        frameworks_root / "App.framework" / "flutter_assets" / "NativeAssetsManifest.json"
    )
    require_path_inside(
        manifest_path,
        frameworks_root,
        "native asset manifest escapes the app Frameworks directory",
    )
    manifest = load_manifest(manifest_path)
    discovered_frameworks = scan_native_asset_frameworks(frameworks_root)
    if manifest is None:
        if discovered_frameworks:
            raise NativeAssetSigningError(
                "native asset manifest is missing while native asset frameworks exist"
            )
        return

    declared_frameworks = resolve_manifest_frameworks(
        frameworks_root, native_asset_paths(manifest)
    )
    require_complete_manifest(discovered_frameworks, declared_frameworks)
    if not declared_frameworks:
        return

    identity = environment.get("EXPANDED_CODE_SIGN_IDENTITY", "").strip()
    if not identity or identity == "-":
        raise NativeAssetSigningError(
            "a non-ad-hoc signing identity is required for native assets"
        )
    expected_team = environment.get("DEVELOPMENT_TEAM", "").strip()
    if not expected_team:
        raise NativeAssetSigningError(
            "DEVELOPMENT_TEAM is required when native assets exist"
        )

    codesign = Path(environment.get("NATIVE_ASSET_CODESIGN", "/usr/bin/codesign"))
    if not codesign.is_file() or not os.access(codesign, os.X_OK):
        raise NativeAssetSigningError("codesign executable is unavailable")

    for framework, primary_binary in sorted(declared_frameworks.items()):
        sign_framework(
            codesign, identity, expected_team, framework, primary_binary
        )


def main():
    try:
        sign_native_assets(os.environ)
    except NativeAssetSigningError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

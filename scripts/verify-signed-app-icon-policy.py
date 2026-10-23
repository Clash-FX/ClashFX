#!/usr/bin/env python3
"""Compile the production icon-persistence policy against inert fake bundles."""

from pathlib import Path
import argparse
import subprocess
import tempfile
import textwrap


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ClashFX/General/Utils/AppLogoTool.swift"


def extract_policy(source: str) -> str:
    marker = "    static var canPersistBundleIcon: Bool {"
    start = source.find(marker)
    if start < 0:
        raise RuntimeError(f"Could not find production property in {SOURCE}")

    # The property has no other declaration-level closing brace at this indent.
    end_marker = "\n    }"
    end = source.find(end_marker, start + len(marker))
    if end < 0:
        raise RuntimeError(f"Could not find end of production property in {SOURCE}")
    return source[start : end + len(end_marker)]


def compile_harness(directory: Path, policy: str, debug: bool) -> Path:
    swift_source = directory / ("debug-policy.swift" if debug else "release-policy.swift")
    executable = directory / ("debug-policy" if debug else "release-policy")
    swift_source.write_text(
        textwrap.dedent(
            f"""\
            import Foundation

            struct FakeBundle {{
                let bundlePath: String
                var bundleURL: URL {{ URL(fileURLWithPath: bundlePath) }}
            }}

            enum Bundle {{
                static var main = FakeBundle(bundlePath: "")
            }}

            enum AppLogoTool {{
            {textwrap.indent(policy, "    ")}
            }}

            Bundle.main = FakeBundle(bundlePath: CommandLine.arguments[1])
            let actual = AppLogoTool.canPersistBundleIcon
            let expected = CommandLine.arguments[2] == "true"
            guard actual == expected else {{
                fputs("expected \\(expected), got \\(actual) for \\(CommandLine.arguments[1])\\n", stderr)
                exit(1)
            }}
            print("\\(CommandLine.arguments[3]): \\(actual)")
            """
        ),
        encoding="utf-8",
    )
    command = ["swiftc"]
    if debug:
        command.append("-D")
        command.append("DEBUG")
    command.extend([str(swift_source), "-o", str(executable)])
    subprocess.run(command, check=True, cwd=ROOT)
    return executable


def run_case(executable: Path, bundle_path: Path, expected: bool, label: str) -> None:
    subprocess.run(
        [str(executable), str(bundle_path), str(expected).lower(), label],
        check=True,
        cwd=ROOT,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    policy = extract_policy(SOURCE.read_text(encoding="utf-8"))
    if args.negative_control:
        policy = policy.replace("return !FileManager.default.fileExists(atPath: signatureResourcesPath)", "return true")
    with tempfile.TemporaryDirectory(prefix="clashfx-icon-policy-") as temporary:
        root = Path(temporary)
        signed_bundle = root / "ReleaseSigned" / "ClashFX.app"
        signed_bundle.joinpath("Contents/_CodeSignature/CodeResources").mkdir(parents=True)

        unsigned_bundle = root / "ReleaseUnsigned" / "ClashFX.app"
        unsigned_bundle.mkdir(parents=True)

        build_products_bundle = root / "Build" / "Products" / "Release" / "ClashFX.app"
        build_products_bundle.mkdir(parents=True)

        derived_data_bundle = root / "DerivedData" / "Build" / "Products" / "Release" / "ClashFX.app"
        derived_data_bundle.mkdir(parents=True)

        release = compile_harness(root, policy, debug=False)
        run_case(release, signed_bundle, False, "signed Release refused")
        run_case(release, unsigned_bundle, True, "unsigned Release allowed")
        run_case(release, build_products_bundle, False, "Build/Products refused")
        run_case(release, derived_data_bundle, False, "DerivedData refused")

        debug = compile_harness(root, policy, debug=True)
        run_case(debug, unsigned_bundle, False, "Debug refused")


if __name__ == "__main__":
    main()

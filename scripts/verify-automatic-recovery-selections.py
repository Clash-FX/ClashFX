#!/usr/bin/env python3
"""Run the Foundation-only automatic recovery selection policy XCTest suite."""
import platform
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "ClashFX/General/Utils/RuntimeProxySelectionRestoreSequence.swift"
TESTS = ROOT / "ClashFXTests/AutomaticRecoverySelectionTests.swift"

HARNESS = """import Darwin
import XCTest

// Apple XCTest does not export SwiftPM's XCTMain entry point, so keep the same
// test-suite entry shape with a small native XCTest runner adapter.
private func XCTMain(_ suites: [XCTestSuite]) {
    var succeeded = true
    for suite in suites {
        suite.run()
        if suite.testRun?.hasSucceeded != true { succeeded = false }
    }
    Darwin.exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
}

XCTMain([AutomaticRecoverySelectionTests.defaultTestSuite])
"""


def main():
    architecture = platform.machine()
    if architecture not in {"arm64", "x86_64"}:
        raise RuntimeError(f"Unsupported macOS host architecture: {architecture}")
    developer_dir = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    macos_developer = developer_dir / "Platforms/MacOSX.platform/Developer"
    module_path = macos_developer / "usr/lib"
    framework_path = macos_developer / "Library/Frameworks"

    with tempfile.TemporaryDirectory(prefix="clashfx-automatic-recovery-selection-") as directory:
        directory = Path(directory)
        harness = directory / "main.swift"
        harness.write_text(HARNESS)
        binary = directory / "automatic-recovery-selection-tests"

        # Check the production sources against the oldest supported macOS target.
        subprocess.run(
            [
                "swiftc",
                "-swift-version",
                "5",
                "-target",
                "x86_64-apple-macosx10.14",
                "-typecheck",
                str(POLICY),
            ],
            check=True,
        )

        subprocess.run(
            [
                "swiftc",
                "-swift-version",
                "5",
                "-target",
                f"{architecture}-apple-macosx14.0",
                "-framework",
                "XCTest",
                "-I",
                str(module_path),
                "-F",
                str(framework_path),
                "-L",
                str(module_path),
                str(POLICY),
                str(TESTS),
                str(harness),
                "-o",
                str(binary),
            ],
            check=True,
        )
        environment = dict(os.environ)
        environment["DYLD_FRAMEWORK_PATH"] = str(framework_path)
        environment["DYLD_LIBRARY_PATH"] = str(module_path)
        subprocess.run([str(binary)], check=True, timeout=30, env=environment)

    print("Automatic recovery selection policy checks passed; macOS 10.14 typecheck passed")


if __name__ == "__main__":
    main()

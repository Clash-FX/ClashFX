#!/usr/bin/env python3
"""Run ClashFX Go tests through the fail-closed Mihomo overlay."""

from __future__ import annotations

import argparse
import pathlib
import os
import tempfile
import subprocess
import sys

from core_overlay import core_modfile
from core_runtime_apply_overlay import patch_runtime_http_apply_test


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, help="Go test regular expression")
    parser.add_argument("--runtime-http", action="store_true", help="also run isolated upstream HTTP mutation regressions")
    args = parser.parse_args()

    module_root = pathlib.Path(__file__).resolve().parent
    with core_modfile() as modfile, tempfile.TemporaryDirectory(prefix="clashfx-core-test-home-") as test_home:
        test_env = dict(os.environ, HOME=test_home,
            GOPATH=subprocess.check_output(["go", "env", "GOPATH"], text=True).strip(),
            GOCACHE=subprocess.check_output(["go", "env", "GOCACHE"], text=True).strip())
        if args.runtime_http:
            patch_runtime_http_apply_test(module_root / ".clashfx-core-workaround" / "mihomo")
        command = [
            "go",
            "test",
            f"-modfile={modfile}",
            "./...",
            "-run",
            args.run,
            "-count=1",
        ]
        result = subprocess.run(command, cwd=module_root, env=test_env, check=False).returncode
        if result != 0 or not args.runtime_http:
            return result
        return subprocess.run([
            "go", "test", f"-modfile={modfile}", "github.com/metacubex/mihomo/hub/route",
            "-run", "^(TestRuntimeHTTP|TestConcurrentApplyConfigAndValidate)", "-count=1",
        ], cwd=module_root, env=test_env, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())

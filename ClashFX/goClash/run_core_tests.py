#!/usr/bin/env python3
"""Run ClashFX Go tests through the fail-closed Mihomo overlay."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

from core_overlay import core_modfile


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, help="Go test regular expression")
    args = parser.parse_args()

    module_root = pathlib.Path(__file__).resolve().parent
    with core_modfile() as modfile:
        command = [
            "go",
            "test",
            f"-modfile={modfile}",
            "./...",
            "-run",
            args.run,
            "-count=1",
        ]
        return subprocess.run(command, cwd=module_root, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())

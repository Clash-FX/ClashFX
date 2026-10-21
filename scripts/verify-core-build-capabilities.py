#!/usr/bin/env python3
"""Check compiled core features without loading any profile or starting listeners."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

REQUIRED = {"with_gvisor"}

def verify(core):
    core = Path(core).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="clashfx-core-features-") as home:
        result = subprocess.run([str(core), "--features"], env=dict(os.environ, HOME=home),
            capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError("Bundled core cannot report build capabilities. Rebuild with build_clash_universal.py --native for local testing.")
    try:
        data = json.loads(result.stdout)
        tags = data.get("features") or []
        if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags):
            raise ValueError("invalid feature types")
    except (ValueError, AttributeError):
        raise RuntimeError("Bundled core returned invalid build-capability metadata")
    missing = REQUIRED - set(tags)
    if missing:
        raise RuntimeError("Bundled core is missing " + ", ".join(sorted(missing)) + ". Rebuild the core before running ClashFX.")
    print("Core compiled capabilities verified: " + ", ".join(sorted(REQUIRED)))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", required=True, type=Path)
    args = parser.parse_args()
    try:
        verify(args.core)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, "error: " + str(error) + "\n")

if __name__ == "__main__":
    main()

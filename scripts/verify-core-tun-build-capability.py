#!/usr/bin/env python3
"""Exercise compiled TUN capability gates; never apply a supported TUN config."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def verify(tagged, untagged):
    checks = 0
    with tempfile.TemporaryDirectory(prefix="clashfx-tun-capability-") as directory:
        home = Path(directory)
        env = dict(os.environ, HOME=str(home))
        for core, supported in [(tagged, True), (untagged, False)]:
            result = subprocess.run([str(core), "--features"], env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == 0, "feature query failed"
            assert ("with_gvisor" in (json.loads(result.stdout).get("features") or [])) == supported
            checks += 1
            for enabled, stack in [(True, "gvisor"), (True, "mixed"), (True, None), (False, "gvisor"), (True, "system")]:
                tun = {"enable": enabled}
                if stack is not None:
                    tun["stack"] = stack
                config = {"mixed-port": 0, "external-controller": "", "dns": {"enable": False}, "tun": tun, "rules": ["MATCH,DIRECT"]}
                path = home / "config.yaml"
                path.write_text(json.dumps(config))
                unsupported = enabled and stack != "system" and not supported
                # Normal startup is exercised ONLY for the guaranteed rejection path.
                modes = [["-t"], []] if unsupported else [["-t"]]
                for mode in modes:
                    result = subprocess.run([str(core), *mode, "-d", str(home), "-f", str(path)], env=env, capture_output=True, text=True, timeout=15)
                    assert result.returncode == (1 if unsupported else 0), f"unexpected exit: supported={supported}, enabled={enabled}, stack={stack}, mode={mode}"
                    if unsupported:
                        assert "unsupported_tun_stack_build" in result.stderr, "missing diagnostic"
                        assert "mihomo-bin started" not in result.stdout, "false startup publication"
                    checks += 1
    print(f"Real core TUN capability matrix passed: {checks} checks; no TUN configuration applied")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", required=True, type=Path)
    parser.add_argument("--without-gvisor-core", required=True, type=Path)
    args = parser.parse_args()
    verify(args.core.resolve(strict=True), args.without_gvisor_core.resolve(strict=True))


if __name__ == "__main__":
    main()

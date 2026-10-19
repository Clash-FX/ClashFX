#!/usr/bin/env python3
"""Close TProxy sockets when constructor setup fails."""

from __future__ import annotations

import hashlib
import os
import pathlib
import stat
import subprocess


TPROXY_CONSTRUCTOR_SOURCE_SHA256 = {
    "listener/tproxy/tproxy.go": "791a046fa0f811f3b529bc8e43b2cc9729bd7cdcfa7d7e9c2d35600235a29e00",
    "listener/tproxy/udp.go": "57329c789e9eca5e74fa957c6973a2757093d9bec156f1f18a8b0d9090c29f5e",
}


def _replace_once(source: str, original: str, replacement: str, label: str) -> str:
    count = source.count(original)
    if count != 1:
        raise RuntimeError(
            f"Expected one {label} in pinned Mihomo source; found {count}"
        )
    return source.replace(original, replacement, 1)


def _gofmt(source: str, label: str) -> str:
    result = subprocess.run(
        ["gofmt"],
        input=source.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"gofmt failed for {label}: {result.stderr.decode('utf-8', errors='replace')}"
        )
    return result.stdout.decode("utf-8")


def patch_tproxy_constructor_cleanup(mihomo_root: str | os.PathLike[str]) -> None:
    """Close raw TCP and UDP sockets unless their TProxy listener is returned."""
    root = pathlib.Path(mihomo_root)
    originals: dict[str, str] = {}
    for relative_path, expected_hash in TPROXY_CONSTRUCTOR_SOURCE_SHA256.items():
        source_path = root / relative_path
        original = source_path.read_bytes()
        actual_hash = hashlib.sha256(original).hexdigest()
        if actual_hash != expected_hash:
            raise RuntimeError(
                f"Pinned TProxy constructor source changed at {source_path}; "
                "review the ClashFX TProxy constructor cleanup overlay"
            )
        originals[relative_path] = original.decode("utf-8")

    patched: dict[str, str] = {}

    relative_path = "listener/tproxy/tproxy.go"
    source = _replace_once(
        originals[relative_path],
        """\tif err != nil {
		return nil, err
	}

	tl := l.(*net.TCPListener)""",
        """\tif err != nil {
		return nil, err
	}

	constructorSucceeded := false
	defer func() {
		if !constructorSucceeded {
			_ = l.Close()
		}
	}()

	tl := l.(*net.TCPListener)""",
        "TCP TProxy raw-socket ownership guard",
    )
    source = _replace_once(
        source,
        "\treturn rl, nil\n}",
        "\tconstructorSucceeded = true\n\treturn rl, nil\n}",
        "TCP TProxy ownership transfer",
    )
    patched[relative_path] = _gofmt(source, relative_path)

    relative_path = "listener/tproxy/udp.go"
    source = _replace_once(
        originals[relative_path],
        """\tif err != nil {
		return nil, err
	}

	rl := &UDPListener{""",
        """\tif err != nil {
		return nil, err
	}

	constructorSucceeded := false
	defer func() {
		if !constructorSucceeded {
			_ = l.Close()
		}
	}()

	rl := &UDPListener{""",
        "UDP TProxy raw-socket ownership guard",
    )
    source = _replace_once(
        source,
        "\treturn rl, nil\n}",
        "\tconstructorSucceeded = true\n\treturn rl, nil\n}",
        "UDP TProxy ownership transfer",
    )
    patched[relative_path] = _gofmt(source, relative_path)

    # Format and validate both sources before writing either copied module file.
    for relative_path, source in patched.items():
        source_path = root / relative_path
        os.chmod(source_path, source_path.stat().st_mode | stat.S_IWUSR)
        source_path.write_text(source, encoding="utf-8")

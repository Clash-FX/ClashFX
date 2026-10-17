#!/usr/bin/env python3
"""Close partially constructed multi-address Mihomo listeners on failure."""

from __future__ import annotations

import hashlib
import os
import pathlib
import stat
import subprocess


LISTENER_CONSTRUCTOR_SOURCE_SHA256 = {
    "listener/sing_shadowsocks/server.go": "53271df34a3fc29ea9d5f0692778c3c47037dddf695accdf380c560e836d77fa",
    "listener/sing_vmess/server.go": "ded54fbaffa58de208a7ae0465fa2d64feb3bbc94403961c6de5e0eb2a76822a",
    "listener/tuic/server.go": "84fb41ac691fac96c67657eb39e4d9cd6e2f9b349eeaf0c5177805116fcf54a6",
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


def patch_listener_constructor_cleanup(mihomo_root: str | os.PathLike[str]) -> None:
    """Patch pinned sing SS, sing VMess, and TUIC listener constructors.

    Until each constructor returns successfully, its partially built Listener
    owns every socket/resource already appended to it. Error returns close that
    partial Listener; a successful return transfers ownership to the caller.
    """
    root = pathlib.Path(mihomo_root)
    originals: dict[str, str] = {}
    for relative_path, expected_hash in LISTENER_CONSTRUCTOR_SOURCE_SHA256.items():
        source_path = root / relative_path
        original = source_path.read_bytes()
        actual_hash = hashlib.sha256(original).hexdigest()
        if actual_hash != expected_hash:
            raise RuntimeError(
                f"Pinned listener constructor source changed at {source_path}; "
                "review the ClashFX listener constructor cleanup overlay"
            )
        originals[relative_path] = original.decode("utf-8")

    patched: dict[str, str] = {}

    relative_path = "listener/sing_shadowsocks/server.go"
    source = _replace_once(
        originals[relative_path],
        "var sl *Listener\n\tvar err error",
        "var sl *Listener\n\tvar err error\n\tconstructorSucceeded := false",
        "Shadowsocks listener ownership state",
    )
    source = _replace_once(
        source,
        """\t\tdefer func() {
\t\t\t_listener = sl
\t\t}()""",
        """\t\tdefer func() {
\t\t\tif constructorSucceeded {
\t\t\t\t_listener = sl
\t\t\t} else {
\t\t\t\t_listener = nil
\t\t\t}
\t\t}()""",
        "Shadowsocks singleton ownership commit",
    )
    source = _replace_once(
        source,
        "\tsl = &Listener{}\n\tsl.config = config",
        """\tsl = &Listener{}
\tsl.config = config
\tdefer func() {
\t\tif !constructorSucceeded {
\t\t\t_ = sl.Close()
\t\t}
\t}()""",
        "Shadowsocks partial-listener ownership guard",
    )
    source = _replace_once(
        source,
        """\t\t\t\t\tif err != nil {
\t\t\t\t\t\tbuff.Release()
\t\t\t\t\t\tif sl.closed {""",
        """\t\t\t\t\tif err != nil {
\t\t\t\t\t\tif buff != nil {
\t\t\t\t\t\t\tbuff.Release()
\t\t\t\t\t\t}
\t\t\t\t\t\tif sl.closed {""",
        "Shadowsocks closed-packet buffer cleanup",
    )
    source = _replace_once(
        source,
        "\treturn sl, nil\n}",
        "\tconstructorSucceeded = true\n\treturn sl, nil\n}",
        "Shadowsocks listener ownership commit",
    )
    patched[relative_path] = _gofmt(source, relative_path)

    relative_path = "listener/sing_vmess/server.go"
    source = _replace_once(
        originals[relative_path],
        "func New(config LC.VmessServer, tunnel C.Tunnel, additions ...inbound.Addition) (sl *Listener, err error) {",
        """func New(config LC.VmessServer, tunnel C.Tunnel, additions ...inbound.Addition) (*Listener, error) {
\tvar sl *Listener
\tvar err error
\tconstructorSucceeded := false""",
        "VMess stable listener ownership state",
    )
    source = _replace_once(
        source,
        """\t\tdefer func() {
\t\t\t_listener = sl
\t\t}()""",
        """\t\tdefer func() {
\t\t\tif constructorSucceeded {
\t\t\t\t_listener = sl
\t\t\t} else {
\t\t\t\t_listener = nil
\t\t\t}
\t\t}()""",
        "VMess singleton ownership commit",
    )
    source = _replace_once(
        source,
        "\tsl = &Listener{false, config, nil, service}",
        """\tsl = &Listener{false, config, nil, service}
\tconstructorListener := sl
\tdefer func() {
\t\tif !constructorSucceeded {
\t\t\t_ = constructorListener.Close()
\t\t}
\t}()""",
        "VMess partial-listener ownership guard",
    )
    source = _replace_once(
        source,
        "\treturn sl, nil\n}",
        "\tconstructorSucceeded = true\n\treturn sl, nil\n}",
        "VMess listener ownership commit",
    )
    patched[relative_path] = _gofmt(source, relative_path)

    relative_path = "listener/tuic/server.go"
    source = _replace_once(
        originals[relative_path],
        "\tsl := &Listener{false, config, nil, nil}",
        """\tsl := &Listener{false, config, nil, nil}
\tconstructorSucceeded := false
\tdefer func() {
\t\tif !constructorSucceeded {
\t\t\t_ = sl.Close()
\t\t}
\t}()""",
        "TUIC partial-listener ownership guard",
    )
    source = _replace_once(
        source,
        "\treturn sl, nil\n}",
        "\tconstructorSucceeded = true\n\treturn sl, nil\n}",
        "TUIC listener ownership commit",
    )
    patched[relative_path] = _gofmt(source, relative_path)

    # Validate and format every target before changing any of the copied module.
    for relative_path, source in patched.items():
        source_path = root / relative_path
        os.chmod(source_path, source_path.stat().st_mode | stat.S_IWUSR)
        source_path.write_text(source, encoding="utf-8")

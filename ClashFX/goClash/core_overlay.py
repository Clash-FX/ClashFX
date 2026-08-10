#!/usr/bin/env python3
"""Build the bundled mihomo core with ClashFX's temporary upstream fixes.

Keep the workaround small and fail closed when the pinned dependency changes so
an upstream update cannot silently drop or misapply it.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
from contextlib import contextmanager
from typing import Iterator


SING_MODULE = "github.com/metacubex/sing"
EXPECTED_SING_VERSION = "v0.5.7"
MIHOMO_MODULE = "github.com/metacubex/mihomo"
EXPECTED_MIHOMO_VERSION = "v1.19.24"
MODULE_ROOT = pathlib.Path(__file__).resolve().parent
ORIGINAL_IS_CLOSED = (
    "return IsMulti(err, io.EOF, net.ErrClosed, io.ErrClosedPipe, os.ErrClosed, "
    "syscall.EPIPE, syscall.ECONNRESET, syscall.ENOTCONN)"
)
PATCHED_IS_CLOSED = (
    "return IsMulti(err, io.EOF, net.ErrClosed, io.ErrClosedPipe, os.ErrClosed, "
    "syscall.EPIPE, syscall.ECONNRESET, syscall.ENOTCONN, syscall.ENOTSOCK)"
)
ORIGINAL_URL_TEST = """func (u *URLTest) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (map[string]uint16, error) {
	return u.GroupBase.URLTest(ctx, u.testUrl, expectedStatus)
}"""
PATCHED_URL_TEST = """func (u *URLTest) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (map[string]uint16, error) {
	// Now() can run while the candidates are still being tested and cache a
	// partial choice for ten seconds. Clear that value once all results are in
	// so the next selection uses the complete result set and tolerance.
	u.fastSingle.Reset()
	defer u.fastSingle.Reset()
	return u.GroupBase.URLTest(ctx, u.testUrl, expectedStatus)
}"""


def _remove_tree(path: pathlib.Path) -> None:
    if not path.exists():
        return
    for root, directories, files in os.walk(path):
        root_path = pathlib.Path(root)
        os.chmod(root_path, root_path.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
        for name in directories + files:
            child = root_path / name
            os.chmod(child, child.stat().st_mode | stat.S_IWUSR)
    shutil.rmtree(path)


def _resolve_module(module: str, expected_version: str) -> pathlib.Path:
    subprocess.check_call(
        ["go", "mod", "download", module],
        cwd=MODULE_ROOT,
    )
    module_info = subprocess.check_output(
        ["go", "list", "-m", "-f", "{{.Version}}\n{{.Dir}}", module],
        text=True,
        cwd=MODULE_ROOT,
    ).splitlines()
    if len(module_info) != 2:
        raise RuntimeError(f"Unable to resolve {module}")

    version, module_dir = module_info
    if version != expected_version:
        raise RuntimeError(
            f"Review the ClashFX core overlay before updating {module}: "
            f"expected {expected_version}, found {version}"
        )
    return pathlib.Path(module_dir)


@contextmanager
def core_modfile() -> Iterator[str]:
    # A fresh CI runner has the version in go.sum but no extracted module
    # directory yet. Download the pinned module before asking Go for its path.
    sing_source_module = _resolve_module(SING_MODULE, EXPECTED_SING_VERSION)
    mihomo_source_module = _resolve_module(MIHOMO_MODULE, EXPECTED_MIHOMO_VERSION)

    sing_source = sing_source_module / "common" / "exceptions" / "error.go"
    sing_original = sing_source.read_text(encoding="utf-8")
    if sing_original.count(ORIGINAL_IS_CLOSED) != 1:
        raise RuntimeError(
            f"The expected IsClosed implementation changed in {sing_source}; "
            "review the ClashFX overlay"
        )

    mihomo_source = mihomo_source_module / "adapter" / "outboundgroup" / "urltest.go"
    mihomo_original = mihomo_source.read_text(encoding="utf-8")
    if mihomo_original.count(ORIGINAL_URL_TEST) != 1:
        raise RuntimeError(
            f"The expected URLTest implementation changed in {mihomo_source}; "
            "review the ClashFX overlay"
        )

    temp_dir = pathlib.Path(tempfile.mkdtemp(prefix="clashfx-core-workaround-"))
    workaround_root = MODULE_ROOT / ".clashfx-core-workaround"
    if workaround_root.exists():
        _remove_tree(temp_dir)
        raise RuntimeError(
            f"Temporary core workaround already exists at {workaround_root}; "
            "another build may be running"
        )
    try:
        workaround_root.mkdir()
        sing_replacement_module = workaround_root / "sing"
        shutil.copytree(sing_source_module, sing_replacement_module)
        sing_replacement = sing_replacement_module / "common" / "exceptions" / "error.go"
        os.chmod(sing_replacement, sing_replacement.stat().st_mode | stat.S_IWUSR)
        sing_replacement.write_text(
            sing_original.replace(ORIGINAL_IS_CLOSED, PATCHED_IS_CLOSED),
            encoding="utf-8",
        )

        mihomo_replacement_module = workaround_root / "mihomo"
        shutil.copytree(mihomo_source_module, mihomo_replacement_module)
        mihomo_replacement = (
            mihomo_replacement_module / "adapter" / "outboundgroup" / "urltest.go"
        )
        os.chmod(mihomo_replacement, mihomo_replacement.stat().st_mode | stat.S_IWUSR)
        mihomo_replacement.write_text(
            mihomo_original.replace(ORIGINAL_URL_TEST, PATCHED_URL_TEST),
            encoding="utf-8",
        )

        modfile = temp_dir / "clashfx.mod"
        modfile.write_text(
            (MODULE_ROOT / "go.mod").read_text(encoding="utf-8") +
            f"\nreplace {SING_MODULE} => ./.clashfx-core-workaround/sing\n" +
            f"replace {MIHOMO_MODULE} => ./.clashfx-core-workaround/mihomo\n",
            encoding="utf-8",
        )
        shutil.copy2(MODULE_ROOT / "go.sum", temp_dir / "clashfx.sum")
        yield str(modfile)
    finally:
        _remove_tree(temp_dir)
        _remove_tree(workaround_root)

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
MODULE_ROOT = pathlib.Path(__file__).resolve().parent
ORIGINAL_IS_CLOSED = (
    "return IsMulti(err, io.EOF, net.ErrClosed, io.ErrClosedPipe, os.ErrClosed, "
    "syscall.EPIPE, syscall.ECONNRESET, syscall.ENOTCONN)"
)
PATCHED_IS_CLOSED = (
    "return IsMulti(err, io.EOF, net.ErrClosed, io.ErrClosedPipe, os.ErrClosed, "
    "syscall.EPIPE, syscall.ECONNRESET, syscall.ENOTCONN, syscall.ENOTSOCK)"
)


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


@contextmanager
def core_modfile() -> Iterator[str]:
    # A fresh CI runner has the version in go.sum but no extracted module
    # directory yet. Download the pinned module before asking Go for its path.
    subprocess.check_call(
        ["go", "mod", "download", SING_MODULE],
        cwd=MODULE_ROOT,
    )
    module_info = subprocess.check_output(
        ["go", "list", "-m", "-f", "{{.Version}}\n{{.Dir}}", SING_MODULE],
        text=True,
        cwd=MODULE_ROOT,
    ).splitlines()
    if len(module_info) != 2:
        raise RuntimeError(f"Unable to resolve {SING_MODULE}")

    version, module_dir = module_info
    if version != EXPECTED_SING_VERSION:
        raise RuntimeError(
            f"Review the ENOTSOCK workaround before updating {SING_MODULE}: "
            f"expected {EXPECTED_SING_VERSION}, found {version}"
        )

    source_module = pathlib.Path(module_dir)
    source = source_module / "common" / "exceptions" / "error.go"
    original = source.read_text(encoding="utf-8")
    if original.count(ORIGINAL_IS_CLOSED) != 1:
        raise RuntimeError(
            f"The expected IsClosed implementation changed in {source}; "
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
        replacement_module = workaround_root / "sing"
        shutil.copytree(source_module, replacement_module)
        replacement = replacement_module / "common" / "exceptions" / "error.go"
        os.chmod(replacement, replacement.stat().st_mode | stat.S_IWUSR)
        replacement.write_text(
            original.replace(ORIGINAL_IS_CLOSED, PATCHED_IS_CLOSED),
            encoding="utf-8",
        )

        modfile = temp_dir / "clashfx.mod"
        modfile.write_text(
            (MODULE_ROOT / "go.mod").read_text(encoding="utf-8") +
            f"\nreplace {SING_MODULE} => ./.clashfx-core-workaround/sing\n",
            encoding="utf-8",
        )
        shutil.copy2(MODULE_ROOT / "go.sum", temp_dir / "clashfx.sum")
        yield str(modfile)
    finally:
        _remove_tree(temp_dir)
        _remove_tree(workaround_root)

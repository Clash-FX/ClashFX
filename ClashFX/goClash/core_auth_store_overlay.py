"""Add synchronization to the pinned Mihomo listener auth store."""

from __future__ import annotations

import hashlib
import os
import pathlib
import stat
import subprocess


SOURCE_SHA256 = "b905164191c08b3b20379ae8b8c2ce99711a4a537133f4e9e736233f3ae042df"


def patch_auth_store(mihomo_root: pathlib.Path) -> None:
    source_path = pathlib.Path(mihomo_root) / "listener" / "auth" / "auth.go"
    original = source_path.read_bytes()
    if hashlib.sha256(original).hexdigest() != SOURCE_SHA256:
        raise RuntimeError(
            "Pinned listener auth-store source changed; review the auth-store overlay"
        )

    source = original.decode("utf-8")

    def replace_once(old: str, new: str, label: str) -> None:
        nonlocal source
        if source.count(old) != 1:
            raise RuntimeError(f"Pinned auth-store source shape changed: {label}")
        source = source.replace(old, new, 1)

    replace_once(
        'import (\n\t"github.com/metacubex/mihomo/component/auth"\n)',
        'import (\n\t"sync"\n\n\t"github.com/metacubex/mihomo/component/auth"\n)',
        "imports",
    )
    replace_once(
        "type authStore struct {\n\tauthenticator auth.Authenticator\n}",
        "type authStore struct {\n\tmu            sync.RWMutex\n\tauthenticator auth.Authenticator\n}",
        "authStore fields",
    )
    replace_once(
        "func (a *authStore) Authenticator() auth.Authenticator {\n\treturn a.authenticator\n}",
        "func (a *authStore) Authenticator() auth.Authenticator {\n\ta.mu.RLock()\n\tdefer a.mu.RUnlock()\n\treturn a.authenticator\n}",
        "Authenticator getter",
    )
    replace_once(
        "func (a *authStore) SetAuthenticator(authenticator auth.Authenticator) {\n\ta.authenticator = authenticator\n}",
        "func (a *authStore) SetAuthenticator(authenticator auth.Authenticator) {\n\ta.mu.Lock()\n\tdefer a.mu.Unlock()\n\ta.authenticator = authenticator\n}",
        "SetAuthenticator setter",
    )
    replace_once(
        "return &authStore{authenticator}",
        "return &authStore{authenticator: authenticator}",
        "NewAuthStore initializer",
    )

    os.chmod(source_path, source_path.stat().st_mode | stat.S_IWUSR)
    source_path.write_text(source, encoding="utf-8")
    subprocess.check_call(["gofmt", "-w", str(source_path)])

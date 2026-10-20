#!/usr/bin/env python3
"""Exercise recovery selection ordering against a built mihomo-bin core."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self) -> None:
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, _format: str, *_args: object) -> None:
        pass


def unused_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def config_text(
    controller_port: int,
    *,
    recovery: dict[str, str] | None = None,
    nested_auto_url: str | None = None,
    dynamic_provider: bool = False,
) -> str:
    proxy_providers = ""
    proxies = """proxies:
  - name: Node
    type: socks5
    server: 127.0.0.1
    port: 1081
"""
    groups = """proxy-groups:
  - name: TAGSS
    type: select
    proxies: [DIRECT, Node, COMPATIBLE]
"""
    if dynamic_provider:
        proxy_providers = """proxy-providers:
  local:
    type: file
    path: ./providers/proxies.yaml
    health-check:
      enable: false
"""
        proxies = ""
        groups = """proxy-groups:
  - name: TAGSS
    type: select
    proxies: [DIRECT]
    use: [local]
"""
    if nested_auto_url is not None:
        if dynamic_provider:
            raise ValueError("nested automatic fixture cannot use a dynamic provider")
        groups = f'''proxy-groups:
  - name: AUTO
    type: url-test
    url: "{nested_auto_url}"
    expected-status: 200
    interval: 86400
    proxies: [DIRECT]
  - name: TAGSS
    type: select
    proxies: [DIRECT, Node, COMPATIBLE]
  - name: GLOBAL
    type: select
    proxies: [AUTO, DIRECT]
'''

    config = f'''port: 0
socks-port: 0
redir-port: 0
tproxy-port: 0
mixed-port: 0
allow-lan: false
mode: rule
external-controller: "127.0.0.1:{controller_port}"
secret: ""
tun:
  enable: false
profile:
  store-selected: true
{proxy_providers}{proxies}{groups}rules:
  - MATCH,TAGSS
'''
    if recovery is None:
        return config

    mapping = "".join(
        f"  {json.dumps(group)}: {json.dumps(target)}\n"
        for group, target in recovery.items()
    )
    return config.replace("rules:\n", "x-clashfx-recovery-selections:\n" + mapping + "rules:\n", 1)


def write_config(home: pathlib.Path, content: str) -> pathlib.Path:
    path = home / "config.yaml"
    path.write_text(content, encoding="utf-8")
    path.chmod(0o600)
    return path


def start_core(core: pathlib.Path, home: pathlib.Path, config_path: pathlib.Path):
    log_path = home / "core.log"
    log_file = log_path.open("wb")
    environment = dict(os.environ)
    environment["HOME"] = str(home)
    process = subprocess.Popen(
        [str(core), "-d", str(home), "-f", str(config_path)],
        stdin=subprocess.DEVNULL,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        env=environment,
    )
    return process, log_file, log_path


def stop_core(process: subprocess.Popen[bytes], log_file) -> None:
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
        raise RuntimeError("core did not stop after SIGTERM")
    finally:
        log_file.close()
    if process.returncode != 0:
        raise RuntimeError(f"core exited {process.returncode} during successful startup")


def read_log(log_path: pathlib.Path) -> str:
    try:
        return log_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def wait_for_proxies(
    process: subprocess.Popen[bytes], endpoint: str, log_path: pathlib.Path, timeout: float = 6
) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(
                f"core exited {process.returncode} before /proxies was available:\n{read_log(log_path)}"
            )
        try:
            with urllib.request.urlopen(endpoint, timeout=0.25) as response:
                body = json.loads(response.read().decode("utf-8"))
                if response.status == 200 and isinstance(body.get("proxies"), dict):
                    start_deadline = time.monotonic() + 2
                    while time.monotonic() < start_deadline:
                        if process.poll() is not None:
                            raise RuntimeError(
                                f"core exited {process.returncode} after /proxies became available:\n{read_log(log_path)}"
                            )
                        if "mihomo-bin started" in read_log(log_path):
                            time.sleep(0.05)
                            return body["proxies"]
                        time.sleep(0.01)
                    raise RuntimeError(
                        f"core did not finish startup after /proxies became available:\n{read_log(log_path)}"
                    )
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
            last_error = error
        time.sleep(0.02)
    raise RuntimeError(
        f"timed out waiting for {endpoint}: {last_error}\n{read_log(log_path)}"
    )


def assert_now(proxies: dict[str, object], group: str, expected: str) -> None:
    value = proxies.get(group)
    actual = value.get("now") if isinstance(value, dict) else None
    if actual != expected:
        raise RuntimeError(f"/proxies first response has {group}.now={actual!r}, expected {expected!r}")


def set_selected(endpoint: str, group: str, target: str) -> None:
    url = endpoint.rstrip("/") + "/" + urllib.parse.quote(group, safe="")
    request = urllib.request.Request(
        url,
        data=json.dumps({"name": target}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="PUT",
    )
    with urllib.request.urlopen(request, timeout=1) as response:
        if response.status not in (200, 204):
            raise RuntimeError(f"select {group}={target} returned HTTP {response.status}")


def update_provider(endpoint: str) -> None:
    request = urllib.request.Request(endpoint, data=b"", method="PUT")
    with urllib.request.urlopen(request, timeout=1) as response:
        if response.status not in (200, 204):
            raise RuntimeError(f"provider update returned HTTP {response.status}")


def write_provider_file(home: pathlib.Path, *, include_node: bool, proxy_port: int) -> None:
    proxies = ["proxies:"]
    if include_node:
        proxies.extend(
            [
                "  - name: Node",
                "    type: socks5",
                "    server: 127.0.0.1",
                f"    port: {proxy_port}",
            ]
        )
    proxies.extend(
        [
            "  - name: Other",
            "    type: socks5",
            "    server: 127.0.0.1",
            f"    port: {proxy_port}",
            "",
        ]
    )
    provider_path = home / "providers" / "proxies.yaml"
    provider_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    provider_path.write_text("\n".join(proxies), encoding="utf-8")
    provider_path.chmod(0o600)


def wait_for_now(
    process: subprocess.Popen[bytes],
    endpoint: str,
    group: str,
    expected: str,
    log_path: pathlib.Path,
    timeout: float = 4,
) -> None:
    deadline = time.monotonic() + timeout
    last_value: object = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(
                f"core exited {process.returncode} while waiting for {group}.now={expected}:\n"
                f"{read_log(log_path)}"
            )
        try:
            with urllib.request.urlopen(endpoint, timeout=0.25) as response:
                body = json.loads(response.read().decode("utf-8"))
                value = body.get("proxies", {}).get(group, {})
                last_value = value.get("now") if isinstance(value, dict) else None
                if response.status == 200 and last_value == expected:
                    return
        except (OSError, urllib.error.URLError, json.JSONDecodeError):
            pass
        time.sleep(0.02)
    raise RuntimeError(
        f"timed out waiting for {group}.now={expected}; last value was {last_value!r}\n"
        f"{read_log(log_path)}"
    )


def assert_api_closed(endpoint: str) -> None:
    try:
        urllib.request.urlopen(endpoint, timeout=0.25)
    except (OSError, urllib.error.URLError):
        return
    raise RuntimeError(f"management endpoint unexpectedly remained available: {endpoint}")


def verify_cached_selection(core: pathlib.Path, root: pathlib.Path) -> None:
    home = root / "cached"
    home.mkdir(mode=0o700)
    controller_port = unused_loopback_port()
    endpoint = f"http://127.0.0.1:{controller_port}/proxies"
    config_path = write_config(home, config_text(controller_port))

    process, log_file, log_path = start_core(core, home, config_path)
    try:
        proxies = wait_for_proxies(process, endpoint, log_path)
        set_selected(endpoint, "TAGSS", "DIRECT")
        assert_now(wait_for_proxies(process, endpoint, log_path), "TAGSS", "DIRECT")
    finally:
        stop_core(process, log_file)

    config_path = write_config(
        home,
        config_text(controller_port, recovery={"TAGSS": "Node"}),
    )
    process, log_file, log_path = start_core(core, home, config_path)
    try:
        proxies = wait_for_proxies(process, endpoint, log_path)
        assert_now(proxies, "TAGSS", "Node")
    finally:
        stop_core(process, log_file)

    config_path = write_config(
        home,
        config_text(controller_port, recovery={"TAGSS": "Unavailable"}),
    )
    process, log_file, log_path = start_core(core, home, config_path)
    try:
        try:
            process.wait(timeout=6)
        except subprocess.TimeoutExpired:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=2)
            raise RuntimeError("missing recovery target did not fail startup")
        if process.returncode != 1:
            raise RuntimeError(
                f"missing recovery target exited {process.returncode}, expected 1:\n{read_log(log_path)}"
            )
        assert_api_closed(endpoint)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        log_file.close()

    config_path = write_config(home, config_text(controller_port))
    process, log_file, log_path = start_core(core, home, config_path)
    try:
        proxies = wait_for_proxies(process, endpoint, log_path)
        assert_now(proxies, "TAGSS", "DIRECT")
    finally:
        stop_core(process, log_file)


def verify_direct_and_nested_automatic(core: pathlib.Path, root: pathlib.Path) -> None:
    home = root / "nested"
    home.mkdir(mode=0o700)
    controller_port = unused_loopback_port()
    endpoint = f"http://127.0.0.1:{controller_port}/proxies"
    with ThreadingHTTPServer(("127.0.0.1", 0), HealthHandler) as health_server:
        health_server.daemon_threads = True
        import threading

        server_thread = threading.Thread(target=health_server.serve_forever, daemon=True)
        server_thread.start()
        health_url = f"http://127.0.0.1:{health_server.server_port}/health"
        config_path = write_config(
            home,
            config_text(
                controller_port,
                recovery={"TAGSS": "DIRECT", "GLOBAL": "AUTO"},
                nested_auto_url=health_url,
            ),
        )
        process, log_file, log_path = start_core(core, home, config_path)
        try:
            proxies = wait_for_proxies(process, endpoint, log_path)
            assert_now(proxies, "TAGSS", "DIRECT")
            assert_now(proxies, "GLOBAL", "AUTO")
            assert_now(proxies, "AUTO", "DIRECT")
        finally:
            stop_core(process, log_file)
            health_server.shutdown()
            server_thread.join(timeout=2)


def verify_provider_removal(core: pathlib.Path, root: pathlib.Path) -> None:
    home = root / "provider-removal"
    home.mkdir(mode=0o700)
    controller_port = unused_loopback_port()
    proxy_port = unused_loopback_port()
    endpoint = f"http://127.0.0.1:{controller_port}/proxies"
    provider_endpoint = f"http://127.0.0.1:{controller_port}/providers/proxies/local"
    write_provider_file(home, include_node=True, proxy_port=proxy_port)
    config_path = write_config(
        home,
        config_text(
            controller_port,
            recovery={"TAGSS": "Node"},
            dynamic_provider=True,
        ),
    )

    process, log_file, log_path = start_core(core, home, config_path)
    try:
        proxies = wait_for_proxies(process, endpoint, log_path)
        assert_now(proxies, "TAGSS", "Node")

        write_provider_file(home, include_node=False, proxy_port=proxy_port)
        update_provider(provider_endpoint)
        wait_for_now(process, endpoint, "TAGSS", "REJECT", log_path)

        write_provider_file(home, include_node=True, proxy_port=proxy_port)
        update_provider(provider_endpoint)
        wait_for_now(process, endpoint, "TAGSS", "Node", log_path)

        set_selected(endpoint, "TAGSS", "DIRECT")
        wait_for_now(process, endpoint, "TAGSS", "DIRECT", log_path)
    finally:
        stop_core(process, log_file)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--core", required=True, type=pathlib.Path, help="path to built mihomo-bin core")
    args = parser.parse_args()
    core = args.core.expanduser().resolve()
    if not core.is_file() or not os.access(core, os.X_OK):
        parser.error(f"--core must name an executable file: {core}")

    try:
        with tempfile.TemporaryDirectory(prefix="clashfx-recovery-core-") as temporary_home:
            root = pathlib.Path(temporary_home)
            verify_cached_selection(core, root)
            verify_provider_removal(core, root)
            verify_direct_and_nested_automatic(core, root)
    except Exception as error:
        print(f"FAIL: {error}")
        return 1

    print("PASS: cached DIRECT restored as requested Node before first /proxies response")
    print("PASS: missing target exits 1 before publishing the management endpoint")
    print("PASS: failed recovery leaves the saved DIRECT choice intact")
    print("PASS: explicit DIRECT and nested automatic group selections start successfully")
    print("PASS: removing a recovered provider target fails closed to REJECT; reinsertion and DIRECT work")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

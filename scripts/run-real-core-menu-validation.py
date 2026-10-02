#!/usr/bin/env python3
"""Opt-in local-only Mihomo/AppKit integration. Never opens the user's config.

Builds the pinned core with the shipping overlay, runs HTTP proxy nodes and a
probe origin on 127.0.0.1, then runs the unhosted menu test. The core's config
and state use a temporary -d directory. All owned processes and listeners are
stopped in finally; artifacts are retained in a temp folder.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
from urllib.parse import parse_qs, urlsplit
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ClashFX/goClash"))
from core_overlay import core_modfile  # noqa: E402


def system_snapshot():
    def pids(name):
        result = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True)
        return result.stdout.split()
    proxy = subprocess.check_output(["scutil", "--proxy"])
    return {"appPIDs": pids("ClashFX"), "corePIDs": pids("mihomo_core"),
            "systemProxySHA256": hashlib.sha256(proxy).hexdigest()}


def main():
    if os.geteuid() == 0:
        raise RuntimeError("Do not run this fixture as root")
    directory = Path(tempfile.mkdtemp(prefix="clashfx-real-core-menu-"))
    print(f"Artifacts: {directory}", flush=True)
    before = system_snapshot()
    (directory / "before.json").write_text(json.dumps(before, indent=2))
    binary = directory / "clashfx-validation-core"
    build_env = dict(os.environ, CGO_ENABLED="0", GOMAXPROCS="2")
    fixture_env = dict(build_env)
    with core_modfile() as modfile, (directory / "build.log").open("w") as log:
        subprocess.run(["go", "build", f"-modfile={modfile}", "-trimpath", "-tags", "with_gvisor",
                        "-ldflags", "-X github.com/metacubex/mihomo/constant.Version=1.19.24",
                        "-o", str(binary), "./mihomo-bin/"],
                       cwd=ROOT / "ClashFX/goClash", env=build_env, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=300)
    print("Pinned Mihomo + production overlay built", flush=True)

    token = secrets.token_hex(24)
    state = {"Local-A": 0.04, "Local-B": 1.177}
    lock = threading.Lock()
    capture_lock = threading.Lock()
    captured_responses = []
    servers = []
    core = None
    success = False
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True
        request_queue_size = 128

    class Origin(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_HEAD(self):
            if self.path not in ("/probe-a", "/probe-b"):
                self.send_error(404)
                return
            time.sleep(0.02 if self.path == "/probe-a" else 0.10)
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_POST(self):
            if self.path != "/fixture-delays" or self.headers.get("Authorization") != "Bearer " + token:
                self.send_error(403)
                return
            values = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            if set(values) != {"Local-A", "Local-B"} or any(not 0.01 <= float(v) <= 2.6 for v in values.values()):
                self.send_error(400)
                return
            with lock:
                state.update(values)
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def start(handler):
        server = Server(("127.0.0.1", 0), handler)
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server.server_port

    class ControllerRelay(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send_payload(self, status, body, content_type="application/json"):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def authorized(self):
            return self.headers.get("Authorization") == "Bearer " + token

        def do_POST(self):
            if not self.authorized() or self.path != "/__fixture/clear-captures":
                self.send_error(403)
                return
            with capture_lock:
                captured_responses.clear()
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            if not self.authorized():
                self.send_error(403)
                return
            parsed = urlsplit(self.path)
            if parsed.path == "/__fixture/captures":
                with capture_lock:
                    payload = json.dumps({"captures": list(captured_responses)}).encode("utf-8")
                self.send_payload(200, payload)
                return

            fixed_paths = {"/version", "/configs", "/proxies", "/providers/proxies"}
            benchmark_path = (
                parsed.path.startswith("/proxies/") and parsed.path.endswith("/delay")
            ) or (
                parsed.path.startswith("/group/") and parsed.path.endswith("/delay")
            )
            if parsed.path not in fixed_paths and not benchmark_path:
                self.send_error(404)
                return

            request = urllib.request.Request(
                core_endpoint + self.path,
                headers={"Authorization": "Bearer " + token},
                method="GET",
            )
            try:
                response = opener.open(request, timeout=15)
            except urllib.error.HTTPError as error:
                response = error
            except OSError:
                self.send_error(502)
                return
            with response:
                body = response.read()
                status = response.status
                content_type = response.headers.get("Content-Type", "application/json")

            if benchmark_path:
                capture = {
                    "path": parsed.path,
                    "query": {key: values[-1] for key, values in parse_qs(parsed.query).items()},
                    "status": status,
                    "body": body.decode("utf-8", errors="replace"),
                }
                with capture_lock:
                    captured_responses.append(capture)
            self.send_payload(status, body, content_type)

    try:
        origin_port = start(Origin)
        origin = f"http://127.0.0.1:{origin_port}"

        def proxy_handler(name):
            class Proxy(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *_):
                    pass

                def do_CONNECT(self):
                    # A real HTTP tunnel, with a strict local-origin allowlist.
                    if self.path != f"127.0.0.1:{origin_port}" or name == "Local-Broken":
                        self.send_error(502)
                        return
                    with lock:
                        delay = state[name]
                    time.sleep(delay)
                    try:
                        with socket.create_connection(("127.0.0.1", origin_port), timeout=2) as upstream:
                            self.send_response(200, "Connection established")
                            self.end_headers()
                            self.wfile.flush()
                            sockets = [self.connection, upstream]
                            while True:
                                ready, _, _ = select.select(sockets, [], [], 3)
                                if not ready:
                                    return
                                for source in ready:
                                    data = source.recv(65536)
                                    if not data:
                                        return
                                    target = upstream if source is self.connection else self.connection
                                    target.sendall(data)
                    except (OSError, TimeoutError):
                        pass
            return Proxy

        ports = {name: start(proxy_handler(name)) for name in ("Local-A", "Local-B", "Local-Broken")}
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            core_controller_port = reservation.getsockname()[1]
        core_endpoint = f"http://127.0.0.1:{core_controller_port}"
        controller_port = start(ControllerRelay)
        endpoint = f"http://127.0.0.1:{controller_port}"
        config = {
            "port": 0, "socks-port": 0, "mixed-port": 0, "redir-port": 0, "tproxy-port": 0,
            "allow-lan": False, "bind-address": "127.0.0.1", "ipv6": False,
            "external-controller": f"127.0.0.1:{core_controller_port}", "secret": token,
            "tun": {"enable": False}, "dns": {"enable": False}, "ntp": {"enable": False},
            "sniffer": {"enable": False}, "find-process-mode": "off", "mode": "rule",
            "log-level": "warning", "geo-auto-update": False,
            "geox-url": {key: origin + "/disabled" for key in ("mmdb", "geoip", "geosite", "asn")},
            "profile": {"store-selected": False, "store-fake-ip": False},
            "proxies": [{"name": name, "type": "http", "server": "127.0.0.1", "port": port}
                        for name, port in ports.items()] + [
                {"name": f"Schedule-{index:02d}", "type": "http", "server": "127.0.0.1",
                 "port": ports["Local-A" if index < 32 else "Local-B"]}
                for index in range(40)
            ],
            "proxy-groups": [
                {"name": "Scheduling", "type": "select", "proxies": [f"Schedule-{index:02d}" for index in range(40)]},
                {"name": "Selector", "type": "select", "proxies": ["Local-A", "Local-B", "Local-Broken", "Automatic", "Empty-SG", "Empty-TW", "Nested-Empty", "DIRECT"]},
                {"name": "Automatic", "type": "url-test", "proxies": ["Local-A", "Local-B", "Local-Broken"], "url": origin + "/probe-a", "interval": 86400, "lazy": True, "tolerance": 0},
                {"name": "Empty-SG", "type": "url-test", "include-all": True, "filter": "^__no_sg_nodes__$", "url": origin + "/probe-a", "interval": 86400, "lazy": True},
                {"name": "Empty-TW", "type": "fallback", "include-all": True, "filter": "^__no_tw_nodes__$", "url": origin + "/probe-a", "interval": 86400, "lazy": True},
                {"name": "Nested-Empty", "type": "select", "proxies": ["Empty-SG"]},
                {"name": "URL-A", "type": "fallback", "proxies": ["Local-A"], "url": origin + "/probe-a", "interval": 86400, "lazy": True},
                {"name": "URL-B", "type": "fallback", "proxies": ["Local-A"], "url": origin + "/probe-b", "interval": 86400, "lazy": True},
            ],
            "rules": ["MATCH,REJECT"],
        }
        config_path = directory / "config.json"
        config_path.write_text(json.dumps(config, indent=2))
        core_home = directory / "core-home"
        core_home.mkdir()
        with (directory / "core.log").open("w") as log:
            core = subprocess.Popen([str(binary), "-d", str(core_home), "-f", str(config_path)],
                                    stdout=log, stderr=subprocess.STDOUT, env=fixture_env)
        deadline = time.monotonic() + 15
        while True:
            if core.poll() is not None:
                raise RuntimeError(f"Fixture core exited: {(directory / 'core.log').read_text()}")
            try:
                request = urllib.request.Request(endpoint + "/version", headers={"Authorization": "Bearer " + token})
                with opener.open(request, timeout=0.5) as response:
                    version = json.load(response)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)
        print(f"Isolated core PID {core.pid}, version {version}, loopback listeners ready", flush=True)
        manifest = directory / "manifest.json"
        manifest.write_text(json.dumps({"endpoint": endpoint, "origin": origin, "secret": token,
                                        "corePID": core.pid, "version": version}, indent=2))
        test_env = dict(os.environ, CLASHFX_REAL_CORE_MANIFEST=str(manifest),
                        TEST_RUNNER_CLASHFX_REAL_CORE_MANIFEST=str(manifest))
        command = ["xcodebuild", "-workspace", "ClashFX.xcworkspace", "-scheme", "ClashFX",
                   "-derivedDataPath", str(directory / "derived-data"),
                   "-destination", "platform=macOS,arch=arm64",
                   "-only-testing:ClashFXTests/RealCoreMenuIntegrationTests", "test",
                   "CODE_SIGNING_ALLOWED=NO", "MACOSX_DEPLOYMENT_TARGET=12.0"]
        with (directory / "tests.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, env=test_env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=180)
        output = (directory / "tests.log").read_text()
        if result.returncode != 0 or "REAL_CORE_MENU_VALIDATION_COMPLETE" not in output:
            raise RuntimeError(f"Real-core menu test did not pass; inspect {directory / 'tests.log'}")
        success = True
    finally:
        if core is not None and core.poll() is None:
            core.terminate()
            try:
                core.wait(timeout=5)
            except subprocess.TimeoutExpired:
                core.kill()
                core.wait(timeout=5)
        for server in servers:
            server.shutdown()
            server.server_close()
        after = system_snapshot()
        report = {"passed": success, "before": before, "after": after,
                  "runningAppUnchanged": before == after,
                  "fixtureCoreStopped": core is None or core.poll() is not None,
                  "fixtureListenersClosed": all(server.socket.fileno() == -1 for server in servers)}
        (directory / "result.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2), flush=True)
        if before != after:
            raise RuntimeError("Running app/core or system proxy changed during validation; investigate")
    return 0


if __name__ == "__main__":
    sys.exit(main())

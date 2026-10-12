#!/usr/bin/env python3
"""Check the production DNS-readiness policy against isolated Mihomo cores."""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
GOCLASH = ROOT / "ClashFX" / "goClash"
POLICY = ROOT / "ClashFX" / "General" / "Managers" / "StartupProxyRecoveryPolicy.swift"
LEVELS = ("info", "warning", "error", "silent")
PROCESSES = ("ClashFX", "mihomo_core", "com.clashfx.app.Helper")
QUERY = bytes.fromhex("c1a501000001000000000000076578616d706c6503636f6d0000010001")
RUNNER = r'''
let v = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
let config = v["config"] as! String
var tcp = v["tcp"] as! [Int], udpPorts = v["udp"] as! [Int]
if let n = v["omitTCPPort"] as? Int { tcp.removeAll { $0 == n } }
if let n = v["omitUDPPort"] as? Int { udpPorts.removeAll { $0 == n } }
let observed = EnhancedModeDNSReadinessPolicy.HelperListenerSnapshot(
    helperIsRunning: true, processID: v["pid"] as! Int,
    helperConfigPath: v["observedConfig"] as? String ?? config,
    tcpListenPorts: tcp, udpListenPorts: udpPorts)
let expected = EnhancedModeDNSReadinessPolicy.ExpectedListeners(
    expectedConfigPath: config, proxyPorts: [v["mixed"] as! Int],
    apiPort: v["api"] as! Int, port: v["dns"] as! Int)
let q: [UInt8] = [7,101,120,97,109,112,108,101,3,99,111,109,0,0,1,0,1]
let u = EnhancedModeDNSReadinessPolicy.parseResponse(
    Data(base64Encoded: v["udpResponse"] as! String)!, transactionID: 0xc1a5, expectedQuestion: q)
let t = EnhancedModeDNSReadinessPolicy.parseResponse(
    Data(base64Encoded: v["tcpResponse"] as! String)!, transactionID: 0xc1a5, expectedQuestion: q)
let owns = EnhancedModeDNSReadinessPolicy.currentLaunchOwnsDNSListeners(observed: observed, expected: expected)
let ready = EnhancedModeDNSReadinessPolicy.launchProtocolReady(ownsCurrentLaunchListeners: owns, udp: u, tcp: t)
let data = try JSONSerialization.data(withJSONObject: ["owns": owns, "udp": u != nil, "tcp": t != nil, "ready": ready], options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''


def snapshot():
    pids = {}
    for name in PROCESSES:
        result = subprocess.run(["pgrep", "-x", name], text=True, capture_output=True, timeout=5)
        if result.returncode not in (0, 1):
            raise RuntimeError("process snapshot failed")
        pids[name] = sorted(int(p) for p in result.stdout.splitlines() if p.strip())
    proxy = subprocess.check_output(["scutil", "--proxy"], timeout=10, stderr=subprocess.DEVNULL)
    dns = subprocess.check_output(["scutil", "--dns"], timeout=10, stderr=subprocess.DEVNULL)
    pid_hash = hashlib.sha256(json.dumps(pids, sort_keys=True).encode()).hexdigest()
    return {"pidSnapshotSHA256": pid_hash, "trackedPIDCount": sum(map(len, pids.values())),
            "systemProxySHA256": hashlib.sha256(proxy).hexdigest(),
            "systemDNSSHA256": hashlib.sha256(dns).hexdigest()}


def reserve_ports(count):
    ports, held = [], []
    while len(ports) < count:
        tcp, udp = socket.socket(), socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            tcp.bind(("127.0.0.1", 0))
            port = tcp.getsockname()[1]
            udp.bind(("127.0.0.1", port))
        except OSError:
            tcp.close(); udp.close()
            continue
        if port in ports:
            tcp.close(); udp.close()
            continue
        ports.append(port); held.extend((tcp, udp))
    return ports, held


def listen_ports(pid, transport):
    cmd = ["lsof", "-nP", "-a", "-p", str(pid), f"-i{transport.upper()}"]
    if transport == "tcp":
        cmd.append("-sTCP:LISTEN")
    cmd.extend(["-F", "n"])
    result = subprocess.run(cmd, text=True, capture_output=True, timeout=5)
    found = set()
    for line in result.stdout.splitlines():
        if line.startswith("n") and "->" not in line:
            match = re.search(r":(\d+)$", line[1:])
            if match:
                found.add(int(match.group(1)))
    return found


def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise OSError("short DNS TCP response")
        data.extend(part)
    return bytes(data)


def dns_udp(port):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(1.5)
        sock.sendto(QUERY, ("127.0.0.1", port))
        data, peer = sock.recvfrom(4096)
        if peer[0] != "127.0.0.1":
            raise OSError("DNS response was not loopback")
        return data


def dns_tcp(port):
    with socket.create_connection(("127.0.0.1", port), timeout=1.5) as sock:
        sock.settimeout(1.5)
        sock.sendall(len(QUERY).to_bytes(2, "big") + QUERY)
        size = int.from_bytes(read_exact(sock, 2), "big")
        if not 12 <= size <= 4096:
            raise OSError("invalid DNS TCP frame")
        return read_exact(sock, size)


def policy_result(runner, evidence):
    result = subprocess.run([str(runner)], input=json.dumps(evidence), text=True,
                            capture_output=True, timeout=5)
    if result.returncode:
        raise RuntimeError("production policy runner failed")
    return json.loads(result.stdout)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=5)
    return process.poll() is not None


def interrupt_on_sigterm(_signum, _frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise KeyboardInterrupt


def main():
    workspace = None
    before = after = None
    cores = []
    cases, rejections = [], {}
    failure = None
    stage = "preflight"
    version = None
    built = compiled = False
    cleaned = stopped = True
    previous_sigterm = signal.signal(signal.SIGTERM, interrupt_on_sigterm)
    try:
        if sys.platform != "darwin" or os.geteuid() == 0:
            raise RuntimeError("requires macOS and a non-root user")
        for tool in ("go", "swiftc", "lsof", "pgrep", "scutil"):
            if not shutil.which(tool):
                raise RuntimeError("required local tool is unavailable")
        before = snapshot()
        workspace = Path(tempfile.mkdtemp(prefix="clashfx-readiness-"))

        stage = "pinned_core_build"
        sys.path.insert(0, str(GOCLASH))
        import core_overlay
        source_copy = workspace / "goClash-source"
        shutil.copytree(GOCLASH, source_copy,
                        ignore=shutil.ignore_patterns(".git", ".clashfx-core-workaround"))
        # Reuse the production overlay implementation, but keep its temporary
        # replacement modules out of the shared repository checkout.
        core_overlay.MODULE_ROOT = source_copy
        version = core_overlay.EXPECTED_MIHOMO_VERSION
        binary = workspace / "isolated-mihomo-core"
        with core_overlay.core_modfile() as modfile, (workspace / "build.log").open("wb") as log:
            subprocess.run(["go", "build", f"-modfile={modfile}", "-trimpath", "-tags", "with_gvisor",
                            "-ldflags", f"-X github.com/metacubex/mihomo/constant.Version={version.lstrip('v')}",
                            "-o", str(binary), "./mihomo-bin/"], cwd=source_copy,
                           env=dict(os.environ, CGO_ENABLED="0", GOMAXPROCS="2"),
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
        built = True

        stage = "production_policy_compile"
        source = workspace / "readiness-runner.swift"
        source.write_text(POLICY.read_text(encoding="utf-8") + "\n" + RUNNER, encoding="utf-8")
        runner = workspace / "readiness-runner"
        with (workspace / "swiftc.log").open("wb") as log:
            subprocess.run(["swiftc", str(source), "-o", str(runner)], stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=60)
        compiled = True

        core_env = dict(os.environ, TMPDIR=str(workspace), GOMAXPROCS="2")
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
            core_env.pop(key, None)
        for level in LEVELS:
            stage = "real_core_" + level
            case = workspace / ("case-" + level)
            home = case / "home"
            home.mkdir(parents=True)
            config = case / "config.yaml"
            (api, mixed, dns), held = reserve_ports(3)
            secret = os.urandom(24).hex()
            try:
                config.write_text(f"""port: 0
socks-port: 0
mixed-port: {mixed}
redir-port: 0
tproxy-port: 0
allow-lan: false
bind-address: 127.0.0.1
ipv6: false
external-controller: 127.0.0.1:{api}
secret: {secret}
log-level: {level}
mode: direct
find-process-mode: off
geo-auto-update: false
geodata-mode: false
profile:
  store-selected: false
  store-fake-ip: false
tun:
  enable: false
dns:
  enable: true
  listen: 127.0.0.1:{dns}
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver: [127.0.0.1:9]
  nameserver: [127.0.0.1:9]
ntp:
  enable: false
sniffer:
  enable: false
proxies: []
proxy-groups: []
rules: ["MATCH,DIRECT"]
""", encoding="utf-8")
            finally:
                for sock in held:
                    sock.close()

            with (case / "core.log").open("wb") as log:
                core = subprocess.Popen([str(binary), "-d", str(home), "-f", str(config)],
                                        cwd=workspace, env=core_env,
                                        stdout=log, stderr=subprocess.STDOUT)
                cores.append(core)
                try:
                    deadline = time.monotonic() + 20
                    evidence = None
                    while time.monotonic() < deadline:
                        if core.poll() is not None:
                            raise RuntimeError("isolated core exited before readiness")
                        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                        request = urllib.request.Request(f"http://127.0.0.1:{api}/version",
                                                         headers={"Authorization": "Bearer " + secret})
                        try:
                            with opener.open(request, timeout=0.4) as response:
                                json.loads(response.read())
                        except (OSError, ValueError):
                            time.sleep(0.1); continue
                        tcp, udp = listen_ports(core.pid, "tcp"), listen_ports(core.pid, "udp")
                        if not ({api, mixed, dns} <= tcp and dns in udp):
                            time.sleep(0.1); continue
                        try:
                            udp_response, tcp_response = dns_udp(dns), dns_tcp(dns)
                        except OSError:
                            time.sleep(0.1); continue
                        evidence = {"pid": core.pid, "config": str(config), "api": api,
                                    "mixed": mixed, "dns": dns, "tcp": sorted(tcp), "udp": sorted(udp),
                                    "udpResponse": base64.b64encode(udp_response).decode(),
                                    "tcpResponse": base64.b64encode(tcp_response).decode()}
                        policy = policy_result(runner, evidence)
                        if all(policy.get(key) is True for key in ("owns", "udp", "tcp", "ready")):
                            break
                        evidence = None
                    if evidence is None:
                        raise TimeoutError("real TCP/UDP DNS readiness timed out")
                    cases.append({"logLevel": level, "controllerTCP": api in tcp,
                                  "proxyTCP": mixed in tcp, "dnsTCP": dns in tcp,
                                  "dnsUDP": dns in udp, "dnsUDPResponse": policy["udp"],
                                  "dnsTCPResponse": policy["tcp"], "policyAccepted": policy["ready"]})
                    if level == "warning":
                        negatives = {
                            "missingExpectedProxyPortRejected": {"omitTCPPort": mixed},
                            "singleTransportRejected": {"omitUDPPort": dns},
                            "foreignConfigRejected": {"observedConfig": str(config) + ".foreign"},
                        }
                        for label, mutation in negatives.items():
                            negative = dict(evidence); negative.update(mutation)
                            result = policy_result(runner, negative)
                            rejections[label] = result.get("owns") is False and result.get("ready") is False
                            if not rejections[label]:
                                raise RuntimeError("production policy accepted a negative case")
                finally:
                    stopped = stop(core) and stopped

        if not all(rejections.values()) or len(rejections) != 3:
            raise RuntimeError("required negative policy cases were not rejected")
    except KeyboardInterrupt:
        failure = {"stage": stage, "type": "Interrupted"}
    except Exception as exc:
        failure = {"stage": stage, "type": type(exc).__name__}
    finally:
        for core in cores:
            try:
                stopped = stop(core) and stopped
            except Exception:
                stopped = False
        if before is not None:
            try:
                after = snapshot()
            except Exception:
                after = None
        if workspace is not None:
            try:
                shutil.rmtree(workspace)
                cleaned = not workspace.exists()
            except Exception:
                cleaned = False
        signal.signal(signal.SIGTERM, previous_sigterm)

    unchanged = before is not None and after is not None and before == after
    passed = (failure is None and built and compiled and len(cases) == len(LEVELS) and all(rejections.values())
              and stopped and cleaned and unchanged)
    report = {"passed": passed,
              "core": {"source": "repository Mihomo + production core_modfile overlay", "version": version},
              "coreBinaryBuilt": built, "productionSwiftPolicyCompiled": compiled, "logLevelCases": cases,
              "policyRejections": rejections,
              "systemState": {"trackedProcessNames": PROCESSES, "before": before,
                              "after": after, "unchanged": unchanged},
              "cleanup": {"fixtureCoresStopped": stopped, "temporaryWorkspaceRemoved": cleaned}}
    if failure:
        report["failure"] = failure
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Root-only, GitHub-hosted macOS smoke for the bundled Mihomo TUN lifecycle."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
FAKE_IP_RANGE = "198.18.0.1/16"
FAKE_IP_NETWORK = ipaddress.ip_network(FAKE_IP_RANGE, strict=False)
ROUTE_STABLE_FIELDS = ("destination", "gateway", "interface", "flags")
ROUTE_TARGETS = (
    ("203.0.113.1", "preferred-reserved"),
    ("198.51.100.1", "reserved-fallback"),
    ("192.0.2.1", "reserved-fallback"),
    ("8.8.8.8", "public-fallback"),
)
START_TIMEOUT = 45
STOP_TIMEOUT = 20


class SmokeInterrupted(Exception):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"interrupted by signal {signum}")


class UsageError(Exception):
    pass


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def emit_json(value):
    print(json.dumps(value, sort_keys=True, separators=(",", ":")), flush=True)


def ci_gate():
    failures = []
    if sys.platform != "darwin":
        failures.append("sys.platform must be darwin")
    if os.environ.get("GITHUB_ACTIONS") != "true":
        failures.append("GITHUB_ACTIONS must equal true")
    if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        failures.append("RUNNER_ENVIRONMENT must equal github-hosted")
    effective_uid = os.geteuid() if hasattr(os, "geteuid") else None
    if effective_uid != 0:
        failures.append("effective uid must be 0")
    return failures, effective_uid


def validate_core(raw_path):
    path = Path(raw_path).expanduser().resolve(strict=True)
    try:
        path.relative_to(ROOT)
    except ValueError as error:
        raise ValueError("--core must resolve inside this repository") from error
    if path.name != "mihomo_core":
        raise ValueError("--core must point to the repository's mihomo_core executable")
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError("--core must be an executable regular file")
    return path


def free_port(reserved):
    for _ in range(100):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        if port not in reserved:
            reserved.add(port)
            return port
    raise RuntimeError("could not allocate distinct loopback ports")


def run_text(command, timeout=5):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=timeout).stdout


def utun_interfaces():
    names = run_text(["/sbin/ifconfig", "-l"]).split()
    return sorted(name for name in names if re.fullmatch(r"utun\d+", name))


def inspect_utun(name):
    detail = run_text(["/sbin/ifconfig", name])
    flags_match = re.search(r"flags=\d+<([^>]*)>", detail)
    flags = set(flags_match.group(1).split(",")) if flags_match else set()
    ipv4 = []
    for line in detail.splitlines():
        match = re.match(r"\s+inet\s+(\d+(?:\.\d+){3})(?:\s|$)", line)
        if match:
            address = ipaddress.ip_address(match.group(1))
            if not address.is_loopback and not address.is_unspecified:
                ipv4.append(str(address))
    return {"name": name, "up": "UP" in flags, "ipv4": sorted(ipv4)}


def route_lookup(destination, family="inet"):
    output = run_text(["/sbin/route", "-n", "get", f"-{family}", destination])
    fields = {}
    for line in output.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip().lower()
        value = value.strip()
        if key == "route to":
            fields["destination"] = value
        elif key in ROUTE_STABLE_FIELDS:
            fields[key] = value
    if "destination" not in fields:
        fields["destination"] = destination
    missing = [key for key in ROUTE_STABLE_FIELDS if not fields.get(key)]
    if missing:
        raise RuntimeError(f"route lookup for {destination} omitted stable fields: " + ", ".join(missing))
    return {key: fields[key] for key in ROUTE_STABLE_FIELDS}


def default_route():
    return route_lookup("default")


def routes_via_utun(names):
    if not names:
        return []
    output = run_text(["/usr/sbin/netstat", "-rn", "-f", "inet"])
    routes = []
    columns = None
    for line in output.splitlines():
        fields = line.split()
        lowered = [field.lower() for field in fields]
        if all(column in lowered for column in ("destination", "gateway", "flags", "netif")):
            columns = {column: lowered.index(column)
                       for column in ("destination", "gateway", "flags", "netif")}
            continue
        if columns is None or len(fields) <= max(columns.values()):
            continue
        interface = fields[columns["netif"]]
        if interface in names:
            routes.append({"destination": fields[columns["destination"]],
                           "gateway": fields[columns["gateway"]],
                           "flags": fields[columns["flags"]],
                           "interface": interface})
    return routes


def process_owns_socket(pid, protocol, port, listening=False):
    command = ["/usr/sbin/lsof", "-nP", "-t", "-a", "-p", str(pid), f"-i{protocol}:{port}"]
    if listening:
        command.extend(["-sTCP:LISTEN"])
    result = subprocess.run(command, capture_output=True, text=True, timeout=5)
    return result.returncode == 0 and str(pid) in result.stdout.split()


def api_json(endpoint, token, path, timeout=1):
    request = urllib.request.Request(endpoint + path, headers={"Authorization": "Bearer " + token})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=timeout) as response:
        return json.load(response)


def encode_dns_query(name):
    transaction_id = secrets.randbelow(65536)
    labels = name.rstrip(".").split(".")
    encoded_name = b"".join(bytes((len(label),)) + label.encode("ascii") for label in labels) + b"\0"
    packet = struct.pack("!HHHHHH", transaction_id, 0x0100, 1, 0, 0, 0)
    return transaction_id, packet + encoded_name + struct.pack("!HH", 1, 1)


def skip_dns_name(packet, offset):
    while True:
        if offset >= len(packet):
            raise RuntimeError("malformed DNS name in response")
        length = packet[offset]
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(packet):
                raise RuntimeError("truncated DNS compression pointer")
            return offset + 2
        if length == 0:
            return offset + 1
        offset += length + 1


def validate_fake_ip_response(packet, transaction_id):
    if len(packet) < 12:
        raise RuntimeError("DNS response header is truncated")
    response_id, flags, questions, answers, _, _ = struct.unpack("!HHHHHH", packet[:12])
    if response_id != transaction_id or not flags & 0x8000:
        raise RuntimeError("DNS response transaction id or response flag is invalid")
    if flags & 0x000F != 0 or answers < 1:
        raise RuntimeError(f"DNS response has rcode={flags & 0x000F}, answers={answers}")
    offset = 12
    for _ in range(questions):
        offset = skip_dns_name(packet, offset) + 4
    addresses = []
    for _ in range(answers):
        offset = skip_dns_name(packet, offset)
        if offset + 10 > len(packet):
            raise RuntimeError("DNS answer record is truncated")
        record_type, record_class, _, data_length = struct.unpack("!HHIH", packet[offset:offset + 10])
        offset += 10
        data = packet[offset:offset + data_length]
        if len(data) != data_length:
            raise RuntimeError("DNS answer data is truncated")
        if record_type == 1 and record_class == 1 and data_length == 4:
            addresses.append(str(ipaddress.ip_address(data)))
        offset += data_length
    fake_ips = [address for address in addresses if ipaddress.ip_address(address) in FAKE_IP_NETWORK]
    if not fake_ips:
        raise RuntimeError("DNS response did not contain a Clash fake IPv4 address")
    return fake_ips[0]


def tcp_read_exact(connection, length):
    chunks = bytearray()
    while len(chunks) < length:
        block = connection.recv(length - len(chunks))
        if not block:
            raise RuntimeError("DNS TCP connection closed before the response was complete")
        chunks.extend(block)
    return bytes(chunks)


def query_dns(port, transport, name):
    transaction_id, query = encode_dns_query(name)
    if transport == "udp":
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
            connection.settimeout(5)
            connection.sendto(query, ("127.0.0.1", port))
            response, _ = connection.recvfrom(4096)
    else:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
            connection.settimeout(5)
            connection.sendall(struct.pack("!H", len(query)) + query)
            response_length = struct.unpack("!H", tcp_read_exact(connection, 2))[0]
            response = tcp_read_exact(connection, response_length)
    return validate_fake_ip_response(response, transaction_id)


def make_config(controller_port, dns_port, mixed_port, token):
    return {
        "mixed-port": mixed_port,
        "allow-lan": False,
        "bind-address": "127.0.0.1",
        "mode": "rule",
        "log-level": "info",
        "ipv6": False,
        "udp": True,
        "external-controller": f"127.0.0.1:{controller_port}",
        "secret": token,
        "find-process-mode": "off",
        "geo-auto-update": False,
        "profile": {"store-selected": False, "store-fake-ip": False},
        "tun": {
            "enable": True,
            "stack": "mixed",
            "auto-route": True,
            "auto-detect-interface": True,
            "strict-route": True,
            "dns-hijack": ["any:53", "tcp://any:53"],
        },
        "dns": {
            "enable": True,
            "listen": f"127.0.0.1:{dns_port}",
            "ipv6": False,
            "enhanced-mode": "fake-ip",
            "fake-ip-range": FAKE_IP_RANGE,
            "default-nameserver": ["1.1.1.1"],
            "nameserver": ["1.1.1.1"],
        },
        "proxies": [],
        "proxy-groups": [],
        "rules": ["MATCH,DIRECT"],
    }


def wait_for_start(core, endpoint, token, before_utuns, created_sink, timeout):
    deadline = time.monotonic() + timeout
    last_error = "waiting for controller, TUN interface, and auto-route"
    while time.monotonic() < deadline:
        if core.poll() is not None:
            raise RuntimeError(f"mihomo_core exited early with status {core.returncode}")
        try:
            version = api_json(endpoint, token, "/version")
            config = api_json(endpoint, token, "/configs")
            current_utuns = utun_interfaces()
            created = sorted(set(current_utuns) - set(before_utuns))
            created_sink[:] = sorted(set(created_sink) | set(created))
            tun_details = [inspect_utun(name) for name in created]
            active = [item for item in tun_details if item["up"] and item["ipv4"]]
            routes = routes_via_utun(created)
            if active and routes:
                route_observations = []
                selected = None
                for address, category in ROUTE_TARGETS:
                    observed_route = route_lookup(address)
                    observation = {"address": address, "category": category,
                                   "route": observed_route}
                    route_observations.append(observation)
                    if observed_route["interface"] in created:
                        selected = observation
                        break
                if selected is not None:
                    if selected["category"] == "preferred-reserved":
                        selection_reason = "preferred 203.0.113.1 route uses a newly created utun"
                    else:
                        selection_reason = (
                            "preferred 203.0.113.1 did not route through a newly created utun; "
                            f"selected {selected['address']} ({selected['category']})"
                        )
                    return (version, config, created, active, routes,
                            route_observations, selected, selection_reason)
                last_error = "no route-only destination resolves through a newly created utun"
            else:
                last_error = "new utun is not yet UP with IPv4 and an auto-route"
        except (OSError, RuntimeError, urllib.error.URLError, subprocess.SubprocessError) as error:
            last_error = str(error)
        time.sleep(0.25)
    raise TimeoutError(f"timed out starting TUN lifecycle smoke: {last_error}")


def main():
    gate_failures, effective_uid = ci_gate()
    if gate_failures:
        emit_json({"status": "refused", "reason": gate_failures,
                   "sysPlatform": sys.platform, "effectiveUid": effective_uid,
                   "githubActions": os.environ.get("GITHUB_ACTIONS"),
                   "runnerEnvironment": os.environ.get("RUNNER_ENVIRONMENT")})
        return 2

    evidence = {
        "status": "running",
        "scope": "standalone Mihomo TUN lifecycle; does not validate ClashFX app/helper DNS or proxy restoration",
        "sysPlatform": sys.platform,
        "effectiveUid": effective_uid,
        "githubActions": os.environ.get("GITHUB_ACTIONS"),
        "runnerEnvironment": os.environ.get("RUNNER_ENVIRONMENT"),
        "failures": [],
    }
    parser = JsonArgumentParser(description=__doc__)
    parser.add_argument("--core", required=True, help="CI-built mihomo_core executable in this repository")
    try:
        args = parser.parse_args()
        core_path = validate_core(args.core)
    except (UsageError, OSError, ValueError) as error:
        emit_json({**evidence, "status": "failed", "failures": [str(error)]})
        return 2

    def handle_signal(signum, _frame):
        raise SmokeInterrupted(signum)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    temporary_root = None
    core = None
    core_log = None
    before_utuns = None
    before_default_route = None
    route_target_baselines = {}
    selected_route_target = None
    created_interfaces = []
    exit_code = 0
    try:
        temporary_root = Path(tempfile.mkdtemp(prefix="clashfx-ci-tun-lifecycle-"))
        core_home = temporary_root / "core-home"
        core_home.mkdir()
        before_utuns = utun_interfaces()
        before_default_route = default_route()
        for address, _category in ROUTE_TARGETS:
            route_target_baselines[address] = route_lookup(address)
        evidence["before"] = {
            "utunInterfaces": before_utuns,
            "defaultRoute": before_default_route,
            "routeTargetBaselines": route_target_baselines,
        }

        reserved_ports = set()
        controller_port = free_port(reserved_ports)
        dns_port = free_port(reserved_ports)
        mixed_port = free_port(reserved_ports)
        token = secrets.token_hex(24)
        config_path = temporary_root / "config.json"
        config_path.write_text(json.dumps(make_config(controller_port, dns_port, mixed_port, token)),
                               encoding="utf-8")
        endpoint = f"http://127.0.0.1:{controller_port}"
        core_env = os.environ.copy()
        core_log = (temporary_root / "mihomo_core.log").open("w", encoding="utf-8")
        blocked_signals = {signal.SIGTERM, signal.SIGINT}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked_signals)
        try:
            core = subprocess.Popen([str(core_path), "-d", str(core_home), "-f", str(config_path)],
                                    cwd=str(temporary_root), env=core_env,
                                    stdout=core_log, stderr=subprocess.STDOUT)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        evidence["core"] = {"path": str(core_path), "pid": core.pid}
        evidence["ports"] = {"controller": controller_port, "dns": dns_port, "mixed": mixed_port}

        (version, api_config, created_interfaces, active_tuns, tun_routes,
         route_observations, selected_route_target, selection_reason) = wait_for_start(
            core, endpoint, token, before_utuns, created_interfaces, START_TIMEOUT)
        evidence["coreVersion"] = version
        evidence["during"] = {
            "newUtunInterfaces": created_interfaces,
            "activeUtunInterfaces": active_tuns,
            "routesViaNewUtun": tun_routes,
            "routeTargetQueries": route_observations,
            "routeTargetSelection": {
                "address": selected_route_target["address"],
                "category": selected_route_target["category"],
                "reason": selection_reason,
                "route": selected_route_target["route"],
                "packetsSent": False,
            },
            "configsTun": api_config.get("tun"),
        }
        tun_config = api_config.get("tun") or {}
        if tun_config.get("enable") is not True or tun_config.get("auto-route") is not True:
            raise RuntimeError("/configs did not report TUN enable and auto-route")
        if tun_config.get("auto-detect-interface") is not True:
            raise RuntimeError("/configs did not report auto-detect-interface")

        for protocol, port, listening in (("TCP", controller_port, True),
                                          ("TCP", mixed_port, True),
                                          ("TCP", dns_port, True),
                                          ("UDP", dns_port, False)):
            if not process_owns_socket(core.pid, protocol, port, listening):
                raise RuntimeError(f"mihomo_core PID {core.pid} does not own {protocol} port {port}")
        api_json(endpoint, token, "/version")
        evidence["ownedPorts"] = [
            {"protocol": protocol, "port": port}
            for protocol, port in (("TCP", controller_port), ("TCP", mixed_port),
                                   ("TCP", dns_port), ("UDP", dns_port))
        ]

        evidence["dnsResponses"] = {}
        for transport, name in (("udp", "example.com"), ("tcp", "example.net")):
            address = query_dns(dns_port, transport, name)
            evidence["dnsResponses"][transport] = {"query": name, "fakeIp": address}

    except SmokeInterrupted as error:
        evidence["failures"].append({"type": "signal", "signal": error.signum})
        exit_code = 128 + error.signum
    except Exception as error:
        evidence["failures"].append({"type": type(error).__name__, "message": str(error)})
        exit_code = 1
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        if core is not None:
            cleanup = {"pid": core.pid, "terminateSent": False, "killed": False}
            if core.poll() is None:
                try:
                    core.terminate()
                    cleanup["terminateSent"] = True
                    core.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    try:
                        core.kill()
                        cleanup["killed"] = True
                        core.wait(timeout=5)
                    except (OSError, subprocess.SubprocessError) as error:
                        evidence["failures"].append({"type": "cleanup", "message": str(error)})
                        exit_code = exit_code or 1
                except OSError as error:
                    evidence["failures"].append({"type": "cleanup", "message": str(error)})
                    exit_code = exit_code or 1
            cleanup["returnCode"] = core.poll()
            evidence["coreCleanup"] = cleanup

        if before_utuns is not None and before_default_route is not None:
            recovery_target = (selected_route_target["address"] if selected_route_target
                               else ROUTE_TARGETS[0][0])
            recovery_baseline = (route_target_baselines.get(recovery_target)
                                 if isinstance(route_target_baselines, dict) else None)
            deadline = time.monotonic() + STOP_TIMEOUT
            last_state = None
            last_error = None
            while time.monotonic() < deadline:
                try:
                    after_utuns = utun_interfaces()
                    after_route = default_route()
                    after_target_route = route_lookup(recovery_target)
                    remaining_routes = routes_via_utun(created_interfaces)
                    last_state = {"utunInterfaces": after_utuns,
                                  "defaultRoute": after_route,
                                  "routeTarget": {"address": recovery_target,
                                                  "route": after_target_route},
                                  "routesViaCreatedUtun": remaining_routes}
                    if (after_utuns == before_utuns
                            and after_route == before_default_route
                            and (recovery_baseline is None
                                 or after_target_route == recovery_baseline)
                            and not remaining_routes):
                        break
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    last_error = str(error)
                time.sleep(0.25)
            evidence["after"] = last_state
            if last_error and last_state is None:
                evidence["failures"].append({"type": "restore-observation", "message": last_error})
                exit_code = exit_code or 1
            if recovery_baseline is None:
                evidence["failures"].append({
                    "type": "restore-observation",
                    "message": f"no pre-start route baseline was captured for {recovery_target}",
                })
                exit_code = exit_code or 1
            if (last_state is None or last_state["utunInterfaces"] != before_utuns
                    or last_state["defaultRoute"] != before_default_route
                    or (recovery_baseline is not None
                        and last_state["routeTarget"]["route"] != recovery_baseline)
                    or last_state["routesViaCreatedUtun"]):
                evidence["failures"].append({
                    "type": "restore-timeout",
                    "message": (f"TUN interfaces/routes/default route/route target "
                                f"{recovery_target} did not return to baseline within {STOP_TIMEOUT}s"),
                })
                exit_code = exit_code or 1

        if core_log is not None:
            core_log.close()
            try:
                log_path = temporary_root / "mihomo_core.log"
                evidence["coreLogTail"] = log_path.read_text(encoding="utf-8", errors="replace")[-6000:]
            except OSError as error:
                evidence["coreLogReadError"] = str(error)
        if temporary_root is not None:
            shutil.rmtree(temporary_root, ignore_errors=True)

        evidence["status"] = "passed" if exit_code == 0 and not evidence["failures"] else "failed"
        emit_json(evidence)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())

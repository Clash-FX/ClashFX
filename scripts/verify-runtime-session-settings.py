#!/usr/bin/env python3
"""Verify built-in reload session settings in a private, no-TUN/DNS cgo core.

Never contacts an installed core or changes system proxy/DNS. Each case runs in
its own process and HOME with dynamically allocated loopback-only listeners.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SWIFT = r'''
import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
func readback() -> [String: Any] {
    let pointer = clashGetConfigs()!
    defer { free(pointer) }
    return try! JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as! [String: Any]
}
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let sessionIPv6 = CommandLine.arguments[2] == "true"
let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
let api = strdup(root["external-controller"] as! String)!
initClashCore()
let response = run(0, 0, sessionIPv6 ? 1 : 0, GoUint32(root["mixed-port"] as! Int), api)!
free(api)
let startup = String(cString: response); free(response)
check(startup.hasPrefix("{"), "isolated built-in core failed to start")
defer { clashSuspendCore() }
let confirmed = readback()
var pending = root
pending["ipv6"] = !sessionIPv6 // preference changed, restart has not happened
check(RuntimeConfigReadbackPolicy.readbackError(expected: pending, actual: confirmed) != nil,
      "fixture did not expose the pending preference/readback mismatch")
let candidate = RuntimeConfigReadbackPolicy.preservingBuiltInSessionIPv6(in: pending, confirmed: confirmed)
let candidateFile = file.deletingLastPathComponent().appendingPathComponent("reload.json")
try JSONSerialization.data(withJSONObject: candidate).write(to: candidateFile)
func apply(_ configuration: [String: Any]) {
    try! JSONSerialization.data(withJSONObject: configuration).write(to: candidateFile)
    let path = strdup(candidateFile.path)!
    let applied = clashUpdateConfigWithEpoch(path, clashCurrentConfigUpdateEpoch())!
    free(path)
    let result = String(cString: applied); free(applied)
    check(result == "success", "isolated core rejected the reload")
    check(RuntimeConfigReadbackPolicy.readbackError(expected: configuration, actual: readback()) == nil,
          "reload did not apply requested session/listener settings")
}
apply(candidate)
check(readback()["ipv6"] as? Bool == sessionIPv6, "reload changed the pinned session IPv6 value")
var rebound = candidate
rebound["bind-address"] = "127.0.0.1"
apply(rebound) // same port, different address
var moved = rebound
moved["mixed-port"] = Int(CommandLine.arguments[3])!
apply(moved)
let pointer = clashGetLastSubmittedConfig()!
let submitted = String(cString: pointer); free(pointer)
let frozen = try! JSONSerialization.jsonObject(with: Data(submitted.utf8)) as! [String: Any]
check(frozen["ipv6"] as? Bool == sessionIPv6, "submitted checkpoint contradicts confirmed session settings")
print("PASS: pending IPv6 preference preserved until restart; session=\(sessionIPv6)")
'''


def free_port() -> int:
    with socket.socket() as tcp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        tcp.bind(("127.0.0.1", 0))
        port = tcp.getsockname()[1]
        udp.bind(("127.0.0.1", port))
        return port


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge-directory", type=Path, required=True)
    args = parser.parse_args()
    bridge = args.bridge_directory.resolve(strict=True)
    if os.geteuid() == 0:
        raise RuntimeError("Run this fixture unprivileged")
    stage = Path(tempfile.mkdtemp(prefix="clashfx-runtime-session-settings-"))
    print(f"Artifacts: {stage}", flush=True)
    source = stage / "main.swift"
    source.write_text(SWIFT)
    executable = stage / "session-settings"
    with (stage / "compile.log").open("w") as log:
        subprocess.run(["swiftc", "-import-objc-header", str(bridge / "goClash.h"),
                        str(ROOT / "ClashFX/General/Utils/RuntimeConfigReadbackPolicy.swift"),
                        str(source), str(bridge / "goClash.a"), "-framework", "Foundation", "-lresolv",
                        "-o", str(executable)], stdout=log, stderr=subprocess.STDOUT, check=True)
    for ipv6 in (True, False):
        home = stage / str(ipv6).lower()
        config_dir = home / ".config/clashfx"
        config_dir.mkdir(parents=True)
        proxy, api = free_port(), free_port()
        while api == proxy:
            api = free_port()
        config = config_dir / "config.yaml"
        moved_port = free_port()
        while moved_port in (api, proxy): moved_port = free_port()
        config.write_text(json.dumps({"mixed-port": proxy, "external-controller": f"127.0.0.1:{api}",
                                      "allow-lan": True, "bind-address": "[::1]", "mode": "rule", "ipv6": ipv6,
                                      "dns": {"enable": False}, "tun": {"enable": False},
                                      "rules": ["MATCH,DIRECT"]}))
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home), SAFE_PATHS=str(home))
        with (home / "core.log").open("w") as log:
            subprocess.run([str(executable), str(config), str(ipv6).lower(), str(moved_port)], env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=25)
    print("Built-in reload regression passed: both IPv6 preference directions and explicit port/address edits")


if __name__ == "__main__":
    main()

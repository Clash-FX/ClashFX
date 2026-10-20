#!/usr/bin/env python3
"""Loopback-only integration of production config transactions and isolated -t.

Starts one unprivileged, no-TUN core in its own home. Never reads user profiles,
controls installed ClashFX, changes system proxy/DNS, or installs a helper.
"""
from __future__ import annotations
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SWIFT = r'''
import Darwin
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let core = URL(fileURLWithPath: CommandLine.arguments[2])
let api = CommandLine.arguments[3]
let occupied = Int(CommandLine.arguments[4])!
let origin = CommandLine.arguments[5]
let replacementPort = Int(CommandLine.arguments[6])!
let occupiedUDP = Int(CommandLine.arguments[7])!
let initial = directory.appendingPathComponent("initial.json")
let baseline = try Data(contentsOf: initial)
let baselineRoot = try JSONSerialization.jsonObject(with: baseline) as! [String: Any]
let controller = RuntimeConfigTransactionController(directory: directory.appendingPathComponent("snapshots"), timeout: 8)
let validator = RuntimeConfigValidationRunner(binary: core, resourceDirectory: directory, timeout: 3)
var applies = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(30)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(condition(), "bounded fixture wait expired")
}
func request(_ method: String, _ path: String, _ body: [String: Any]? = nil,
             completion: @escaping (Data?, Int?, Error?) -> Void) {
    var req = URLRequest(url: URL(string: api + path)!, timeoutInterval: 3)
    req.httpMethod = method
    req.setValue("Bearer fixture-secret", forHTTPHeaderField: "Authorization")
    if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [:]
    let session = URLSession(configuration: config)
    session.dataTask(with: req) { data, response, error in
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async { completion(data, (response as? HTTPURLResponse)?.statusCode, error) }
    }.resume()
}
func proxyServes(_ port: Int, host: String = "127.0.0.1") -> Bool {
    let connectHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let family = connectHost.contains(":") ? AF_INET6 : AF_INET
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var deadline = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    let connected: Int32
    if family == AF_INET6 {
        var address = sockaddr_in6(); address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6); address.sin6_port = UInt16(port).bigEndian
        _ = connectHost.withCString { inet_pton(AF_INET6, $0, &address.sin6_addr) }
        connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    } else {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
        _ = connectHost.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    guard connected == 0 else { return false }
    let target = URL(string: origin)!
    let host = (target.host ?? "127.0.0.1") + ":" + String(target.port ?? 80)
    let payload = "GET \(origin) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
    let sent = payload.withCString { Darwin.send(fd, $0, strlen($0), 0) }
    guard sent > 0 else { return false }
    var bytes = [UInt8](repeating: 0, count: 1024)
    let count = recv(fd, &bytes, bytes.count, 0)
    guard count > 0 else { return false }
    return String(decoding: bytes.prefix(count), as: UTF8.self).contains(" 204 ")
}
let client = RuntimeConfigTransactionController.Client(
    validate: { file, done in
        let endpoint = file.path.withCString { input -> String in
            let result = clashValidateRuntimeConfig(UnsafeMutablePointer(mutating: input))!
            defer { free(result) }; return String(cString: result)
        }
        if !endpoint.isEmpty { done(endpoint); return }
        _ = validator.validate(file: file, completion: done)
    },
    apply: { file, done in
        applies += 1
        request("PUT", "/configs?force=true", ["Path": file.path]) { _, status, error in
            if error != nil { done(.uncertain("no conclusive reply")) }
            else if status == 204 { done(.accepted) }
            else { done(.rejected("core rejected fixture")) }
        }
    },
    verify: { file, done in
        let data = try! Data(contentsOf: file)
        let expected = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        request("GET", "/configs") { data, status, error in
            guard error == nil, status == 200, let data,
                  let actual = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { done(.failed("readback unavailable")); return }
            if let error = RuntimeConfigReadbackPolicy.readbackError(expected: expected, actual: actual) { done(.failed(error)); return }
            let port = RuntimeConfigReadbackPolicy.port(expected["mixed-port"])
            DispatchQueue.global().async {
                let healthy = proxyServes(port, host: expected["bind-address"] as? String ?? "127.0.0.1")
                DispatchQueue.main.async { done(healthy ? .verified(.healthy) : .failed("local proxy dataplane failed")) }
            }
        }
    })
var baselineReadback = false
request("GET", "/configs") { data, status, error in
    check(error == nil && status == 200, "baseline metadata unavailable")
    let actual = try! JSONSerialization.jsonObject(with: data!) as! [String: Any]
    check(RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(baselineRoot, actual: actual) != nil,
          "real API disabled-port defaults rejected the confirmed baseline")
    baselineReadback = true
}
wait { baselineReadback }
var verified = false
client.verify(initial) { result in
    if case .verified = result { verified = true }
}
wait { verified }
var adopted = false
controller.adoptConfirmed(data: baseline, scope: "fixture-core", isCurrent: { true }) { result in
    if case .success = result { adopted = true }
}
wait { adopted }
func submit(_ data: Data) -> RuntimeConfigTransactionController.Outcome {
    var outcome: RuntimeConfigTransactionController.Outcome?
    controller.submit(data: data, scope: "fixture-core", isCurrent: { true }, client: client) { outcome = $0 }
    wait { outcome != nil }; return outcome!
}
var changed = baselineRoot
changed["mode"] = "global"
changed.removeValue(forKey: "mixed-port")
changed = RuntimeConfigReadbackPolicy.preservingImplicitPorts(in: changed, confirmed: baselineRoot, fallback: 7890)
let changedData = try JSONSerialization.data(withJSONObject: changed)
let successful = submit(changedData)
guard case let .applied(receipt) = successful else { check(false, "valid candidate did not apply"); exit(1) }
check(receipt.dataPlane == .healthy, "real local data plane was not recorded healthy")
check(RuntimeConfigReadbackPolicy.port(changed["mixed-port"]) == RuntimeConfigReadbackPolicy.port(baselineRoot["mixed-port"]), "confirmed port was not reused")
// Binding-only and explicit-port edits must recreate listeners, not merely parse.
changed["bind-address"] = "127.0.0.1"
let rebound = submit(try JSONSerialization.data(withJSONObject: changed))
guard case let .applied(reboundReceipt) = rebound else { check(false, "binding-only edit did not apply"); exit(1) }
check(proxyServes(RuntimeConfigReadbackPolicy.port(changed["mixed-port"]), host: "127.0.0.1"), "new bind address does not serve")
check(!proxyServes(RuntimeConfigReadbackPolicy.port(changed["mixed-port"]), host: "::1"), "old broader binding remains open")
changed["mixed-port"] = replacementPort
let moved = submit(try JSONSerialization.data(withJSONObject: changed))
guard case let .applied(finalReceipt) = moved else { check(false, "explicit proxy-port edit did not apply"); exit(1) }
check(finalReceipt.digest != reboundReceipt.digest, "explicit port edit was not committed")
let beforeInvalid = applies
let rejected = submit(Data("mixed-port: [invalid\n".utf8))
if case .rejected = rejected {} else { check(false, "invalid candidate was not rejected before apply") }
check(applies == beforeInvalid, "invalid configuration reached the core")
check(controller.confirmed?.digest == finalReceipt.digest, "rejection changed confirmed receipt")
var collision = changed
collision["mixed-port"] = occupied
let failed = submit(try JSONSerialization.data(withJSONObject: collision))
if case .rolledBack = failed {} else { check(false, "real listener bind failure was not rolled back") }
check(controller.confirmed?.digest == finalReceipt.digest, "rollback did not restore confirmed snapshot")
check(!controller.isUncertain, "verified rollback left uncertain state")
check(proxyServes(RuntimeConfigReadbackPolicy.port(changed["mixed-port"]), host: "127.0.0.1"), "restored proxy is not serving")
var udpCollision = changed
udpCollision["mixed-port"] = occupiedUDP
let udpFailed = submit(try JSONSerialization.data(withJSONObject: udpCollision))
if case .rolledBack = udpFailed {} else { check(false, "UDP-only conflict falsely confirmed a closed TCP listener") }
check(controller.confirmed?.digest == finalReceipt.digest, "UDP-only conflict changed confirmed receipt")
check(proxyServes(RuntimeConfigReadbackPolicy.port(changed["mixed-port"])), "UDP-only conflict rollback did not restore proxy")
var customCollision = changed
var customListeners = customCollision["listeners"] as! [[String: Any]]
let oldCustomPort = RuntimeConfigReadbackPolicy.port(customListeners[0]["port"])
customListeners[0]["port"] = occupied
customCollision["listeners"] = customListeners
let customFailed = submit(try JSONSerialization.data(withJSONObject: customCollision))
if case .rolledBack = customFailed {} else { check(false, "named inbound bind failure was committed or left unknown") }
check(controller.confirmed?.digest == finalReceipt.digest, "named inbound failure changed confirmed receipt")
check(proxyServes(oldCustomPort), "named inbound rollback retained a closed old listener")
print("Real isolated core: confirmed-port reuse, explicit port/address edits, semantic rejection, listener readback, TCP/UDP partial-failure and named inbound rollback passed")
'''

def free_port() -> int:
    with socket.socket() as tcp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        tcp.bind(("127.0.0.1", 0)); port = tcp.getsockname()[1]
        udp.bind(("127.0.0.1", port)); return port


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge-directory", type=Path, required=True)
    parser.add_argument("--core", type=Path, required=True)
    args = parser.parse_args()
    bridge, binary = args.bridge_directory.resolve(), args.core.resolve()
    if os.geteuid() == 0:
        raise RuntimeError("Run this fixture unprivileged")
    directory = Path(tempfile.mkdtemp(prefix="clashfx-runtime-transactions-fixture-"))
    print(f"Artifacts: {directory}", flush=True)
    home = directory / "home"; home.mkdir()
    api_port, proxy_port = free_port(), free_port()
    while proxy_port == api_port: proxy_port = free_port()
    occupied = socket.socket(); occupied.bind(("127.0.0.1", 0)); occupied.listen()
    occupied_port = occupied.getsockname()[1]
    udp_blocker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp_blocker.bind(("127.0.0.1", 0))
    occupied_udp_port = udp_blocker.getsockname()[1]
    replacement_port = free_port()
    while replacement_port in (api_port, proxy_port, occupied_port): replacement_port = free_port()
    class Origin(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self): self.send_response(204); self.end_headers()
        do_HEAD = do_GET
    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    custom_port = free_port()
    while custom_port in (api_port, proxy_port, occupied_port, replacement_port): custom_port = free_port()
    config = {"mixed-port": proxy_port, "external-controller": f"127.0.0.1:{api_port}",
              "secret": "fixture-secret", "allow-lan": True, "bind-address": "[::1]", "mode": "rule", "ipv6": False,
              "tun": {"enable": False}, "dns": {"enable": False}, "rules": ["MATCH,DIRECT"],
              "listeners": [{"name": "fixture-custom", "type": "http", "listen": "127.0.0.1", "port": custom_port}]}
    initial = directory / "initial.json"; initial.write_text(json.dumps(config))
    swift = directory / "main.swift"; swift.write_text(SWIFT)
    executable = directory / "transactions"
    sources = ROOT / "ClashFX/General/Utils"
    with (directory / "compile.log").open("w") as log:
        subprocess.run(["swiftc", "-import-objc-header", str(bridge / "goClash.h"), "-I", str(bridge),
                        str(sources / "RuntimeConfigTransactionController.swift"), str(sources / "RuntimeConfigValidationRunner.swift"),
                        str(sources / "RuntimeConfigReadbackPolicy.swift"), str(swift), str(bridge / "goClash.a"),
                        "-framework", "Foundation", "-lresolv", "-o", str(executable)], stdout=log, stderr=subprocess.STDOUT, check=True)
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home), SAFE_PATHS=str(directory))
    core = None
    try:
        with (directory / "core.log").open("w") as log:
            core = subprocess.Popen([str(binary), "-d", str(home), "-f", str(initial)], stdout=log, stderr=subprocess.STDOUT, env=env)
        api = f"http://127.0.0.1:{api_port}"
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if core.poll() is not None: raise RuntimeError("isolated core exited")
            try:
                req = urllib.request.Request(api + "/version", headers={"Authorization": "Bearer fixture-secret"})
                opener.open(req, timeout=0.5).close(); break
            except OSError: time.sleep(0.05)
        else: raise RuntimeError("isolated core readiness timed out")
        subprocess.run([str(executable), str(directory), str(binary), api, str(occupied_port),
                        f"http://127.0.0.1:{origin.server_port}/probe", str(replacement_port), str(occupied_udp_port)], check=True, env=env, timeout=90)
    finally:
        if core is not None and core.poll() is None:
            core.terminate()
            try: core.wait(timeout=5)
            except subprocess.TimeoutExpired: core.kill(); core.wait(timeout=5)
        origin.shutdown(); origin.server_close(); occupied.close(); udp_blocker.close()

if __name__ == "__main__": main()

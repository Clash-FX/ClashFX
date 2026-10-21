#!/usr/bin/env python3
"""Exercise the shared reload cgo entry with generated/custom config shapes.

Only compiles a standalone Swift runner and rewrites its temporary YAML files.
Never launches ClashFX/Mihomo, binds sockets, or touches user network settings.
Pass an already-generated native Go archive/header directory; no app build runs.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import tempfile

RUNNER = r'''
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let target: Int32 = 49634
var checked = 0
func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Contract failed") {
    guard condition() else {
        FileHandle.standardError.write(Data((message() + "\n").utf8))
        exit(1)
    }
}
for mode in ["normal", "custom"] {
    let sourcePort = mode == "normal" ? 24000 : 7874
    let sourceHost = mode == "normal" ? "127.0.0.1" : "0.0.0.0"
    let allowed = ["healthy", "separate-api-tls", "ipv6-api-tls", "tuic-udp-api", "other-address-proxy", "other-address-dns", "ipv4-wildcard-ipv6-tls"]
    for scenario in allowed + ["dns-proxy", "dns-listener", "dns-api", "dns-tls", "api-proxy", "api-tls", "localhost-api-tls", "wildcard-api-tls", "tuic-udp-dns"] {
        var fields = ["mixed-port": "7890", "external-controller": "127.0.0.1:9090"]
        if scenario == "dns-proxy" { fields["mixed-port"] = "49634" }
        if scenario == "dns-api" { fields["external-controller"] = "127.0.0.1:49634" }
        if scenario == "dns-tls" { fields["external-controller-tls"] = "127.0.0.1:49634" }
        if scenario == "api-proxy" { fields["mixed-port"] = "9090" }
        if scenario == "api-tls" { fields["external-controller-tls"] = "127.0.0.1:9090" }
        if scenario == "separate-api-tls" { fields["external-controller-tls"] = "192.168.1.20:9090" }
        if scenario == "ipv6-api-tls" { fields["external-controller-tls"] = "[::1]:9090" }
        if scenario == "localhost-api-tls" { fields["external-controller-tls"] = "localhost:9090" }
        if scenario == "wildcard-api-tls" { fields["external-controller-tls"] = ":9090" }
        if scenario == "ipv4-wildcard-ipv6-tls" {
            fields["allow-lan"] = "true"
            fields["bind-address"] = "0.0.0.0"
            fields["external-controller-tls"] = "[::1]:7890"
        }
        if scenario == "other-address-proxy" {
            fields["mixed-port"] = "9090"
            fields["allow-lan"] = "true"
            fields["bind-address"] = "192.168.1.20"
        }
        var yaml = fields.keys.sorted().map { key -> String in
            let value = fields[key]!
            let quoted = ["external-controller", "external-controller-tls", "bind-address"].contains(key)
            return "\(key): \(quoted ? String(reflecting: value) : value)"
        }.joined(separator: "\n") + "\n"
        if scenario == "dns-listener" {
            yaml += "listeners:\n  - name: isolated-test\n    type: mixed\n    port: 49634\n"
        }
        if scenario == "tuic-udp-api" || scenario == "tuic-udp-dns" {
            let port = scenario == "tuic-udp-api" ? 9090 : 49634
            yaml += "listeners:\n  - name: udp-fixture\n    type: tuic\n    listen: 127.0.0.1\n    port: \(port)\n"
        }
        if scenario == "other-address-dns" {
            yaml += "listeners:\n  - name: separate-host\n    type: mixed\n    listen: 192.168.1.20\n    port: 49634\n"
        }
        yaml += """
        tun:
          enable: true
        dns:
          listen: \(sourceHost):\(sourcePort)
          nameserver: [udp://127.0.0.1:5353, https://127.0.0.1:8443/dns-query]
          proxy-server-nameserver: [udp://127.0.0.1:\(sourcePort)]

        """
        let file = directory.appendingPathComponent("\(mode)-\(scenario).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let before = try Data(contentsOf: file)
        // Custom startup uses the actual configured DNS address and never rewrites it.
        let validation: String = file.path.withCString { input in
            guard let output = clashValidateEnhancedListenerConfig(UnsafeMutablePointer(mutating: input)) else {
                fatalError("nil validation reply")
            }
            defer { free(output) }
            return String(cString: output)
        }
        let validatedBytes = try Data(contentsOf: file)
        check(validatedBytes == before, "startup validation changed config")
        if ["api-proxy", "api-tls", "localhost-api-tls", "wildcard-api-tls"].contains(scenario) {
            check(validation.hasPrefix("error:[port_conflict]"))
        } else {
            check(validation.isEmpty, "\(mode)/\(scenario) startup validation: \(validation)")
        }
        let result: String = file.path.withCString { input in
            guard let output = clashRetargetEnhancedDNSConfig(UnsafeMutablePointer(mutating: input), target) else {
                fatalError("nil cgo reply")
            }
            defer { free(output) }
            return String(cString: output)
        }
        let after = try Data(contentsOf: file)
        if allowed.contains(scenario) {
            check(result.isEmpty, "\(mode)/\(scenario): \(result)")
            let rewritten = String(data: after, encoding: .utf8)!
            check(rewritten.contains("udp://127.0.0.1:49634"))
            check(rewritten.contains("127.0.0.1:9090"))
            check(rewritten.contains("udp://127.0.0.1:5353"))
            check(rewritten.contains("https://127.0.0.1:8443/dns-query"))
        } else {
            check(result.hasPrefix("error:[port_conflict]"), "\(mode)/\(scenario): \(result)")
            check(result.contains("reason=reserved_listener"))
            check(after == before, "rejected config was changed")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        check((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        checked += 1
    }
}
let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
check(!files.contains { $0.hasPrefix(".clashfx-dns-retarget-") })
print("Swift/cgo startup validation + normal/custom reload contracts passed: \(checked) cases")
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge-directory", type=Path, required=True)
    args = parser.parse_args()
    bridge = args.bridge_directory.resolve(strict=True)
    for name in ("goClash.a", "goClash.h", "UIHelper.h"):
        if not (bridge / name).is_file():
            parser.error(f"missing generated bridge file: {bridge / name}")
    artifacts = Path(tempfile.mkdtemp(prefix="clashfx-reload-port-contracts-"))
    print(f"Artifacts: {artifacts}", flush=True)
    fixtures = artifacts / "fixtures"
    fixtures.mkdir()
    source = artifacts / "main.swift"
    source.write_text(RUNNER)
    runner = artifacts / "reload-port-contracts"
    with (artifacts / "compile.log").open("w") as log:
        subprocess.run(["swiftc", "-import-objc-header", str(bridge / "goClash.h"),
                        "-I", str(bridge), str(source), str(bridge / "goClash.a"),
                        "-framework", "Foundation", "-lresolv", "-o", str(runner)],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run([str(runner), str(fixtures)], check=True)


if __name__ == "__main__":
    main()

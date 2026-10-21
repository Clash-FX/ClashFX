#!/usr/bin/env python3
"""Verify actual cgo log delivery during a rejected first reload, without TUN.

Uses a private HOME and loopback-only sockets. No installed app, helper, user
configuration, system proxy or DNS configuration is accessed.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile

SWIFT = r'''
import Foundation
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
let lock = NSLock()
var records = [(String, String)]()
clash_setLogBlock { line, level in
    lock.lock(); records.append((line ?? "", level ?? "")); lock.unlock()
}
initClashCore()
clashSetupLogger()
let config = URL(fileURLWithPath: CommandLine.arguments[1])
let candidate = URL(fileURLWithPath: CommandLine.arguments[2])
let api = strdup(CommandLine.arguments[3])!
let response = run(0, 0, 0, GoUint32(Int(CommandLine.arguments[4])!), api)!
let start = String(cString: response); free(response); free(api)
check(start.hasPrefix("{"), "private bootstrap startup failed")
defer { clashResumeCallbacks(); clashSuspendCore() }
let baselinePointer = clashGetLastSubmittedConfig()!
let baseline = String(cString: baselinePointer); free(baselinePointer)
let rollback = config.deletingLastPathComponent().appendingPathComponent("rollback.yaml")
try baseline.write(to: rollback, atomically: true, encoding: .utf8)
clashPauseCallbacks()
lock.lock(); records = []; lock.unlock()
func apply(_ file: URL) -> String {
    let input = strdup(file.path)!
    let output = clashUpdateConfigWithEpoch(input, clashCurrentConfigUpdateEpoch())!
    let value = String(cString: output); free(output); free(input); return value
}
let rejected = apply(candidate)
check(rejected != "success" && rejected.contains("HTTP"), "occupied listener did not return the core's refusal")
let deadline = Date().addingTimeInterval(3)
var found = false
while Date() < deadline {
    lock.lock()
    found = records.contains { $0.1 == "error" && $0.0.contains("bind:") && $0.0.contains("address already in use") }
    lock.unlock()
    if found { break }
    Thread.sleep(forTimeInterval: 0.01)
}
check(found, "reload pause swallowed the original bind error")
check(apply(rollback) == "success", "verified bootstrap rollback failed")
print("PASS: actual cgo callback retains original bind error while paused; rejected first reload rolls back")
'''


def port():
    with socket.socket() as tcp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        tcp.bind(('127.0.0.1', 0))
        value = tcp.getsockname()[1]
        udp.bind(('127.0.0.1', value))
        return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bridge-directory', required=True, type=Path)
    args = parser.parse_args()
    bridge = args.bridge_directory.resolve()
    with tempfile.TemporaryDirectory(prefix='clashfx-startup-core-logging-') as temp, socket.socket() as occupied:
        root = Path(temp)
        home = root / 'home'
        config_dir = home / '.config/clashfx'
        config_dir.mkdir(parents=True)
        occupied.bind(('127.0.0.1', 0)); occupied.listen(1)
        blocked = occupied.getsockname()[1]
        mixed, api_port = port(), port()
        while len({mixed, api_port, blocked}) != 3:
            mixed, api_port = port(), port()
        baseline = {'mixed-port': mixed, 'bind-address': '127.0.0.1', 'allow-lan': False,
                    'external-controller': f'127.0.0.1:{api_port}', 'log-level': 'info',
                    'dns': {'enable': False}, 'tun': {'enable': False}, 'rules': ['MATCH,DIRECT']}
        config = config_dir / 'config.yaml'; config.write_text(json.dumps(baseline))
        candidate = dict(baseline); candidate.pop('mixed-port'); candidate['port'] = blocked
        target = config_dir / 'candidate.yaml'; target.write_text(json.dumps(candidate))
        source = root / 'main.swift'; source.write_text(SWIFT)
        executable = root / 'fixture'
        subprocess.run(['swiftc', '-swift-version', '5', '-target', platform.machine() + '-apple-macosx12.0',
                        '-import-objc-header', str(bridge / 'goClash.h'), '-I', str(bridge),
                        str(source), str(bridge / 'goClash.a'), '-framework', 'Foundation', '-lresolv', '-o', str(executable)], check=True)
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home), SAFE_PATHS=str(home))
        subprocess.run([str(executable), str(config), str(target), f'127.0.0.1:{api_port}', str(mixed)],
                       env=env, check=True, timeout=20)


if __name__ == '__main__':
    main()

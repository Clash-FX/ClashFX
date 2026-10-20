#!/usr/bin/env python3
"""Real embedded-core JSON -> confirmed YAML round trip, private HOME/no TUN.
Requires built native bridge and Yams products. Never contacts the installed core.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SWIFT = r'''import Foundation
import Yams
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
let proxy = UInt32(CommandLine.arguments[1])!
let requestedAPI = "127.0.0.1:" + CommandLine.arguments[2]
let ipv6 = CommandLine.arguments[3] == "true"
let address = strdup(requestedAPI)!
initClashCore()
let response = run(1, 0, ipv6 ? 1 : 0, GoUint32(proxy), address)!
free(address)
let startup = String(cString: response)
free(response)
check(startup.hasPrefix("{"), "Private embedded startup failed")
defer { clashSuspendCore() }
let submittedPointer = clashGetLastSubmittedConfig()!
let livePointer = clashGetConfigs()!
defer { free(submittedPointer); free(livePointer) }
let confirmed = try Yams.load(yaml: String(cString: submittedPointer)) as! [String: Any]
let actual = try JSONSerialization.jsonObject(with: Data(String(cString: livePointer).utf8)) as! [String: Any]
guard let refreshed = RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(confirmed, actual: actual) else {
    fatalError("Actual startup checkpoint failed listener/TUN comparison")
}
let yaml = try Yams.dump(object: refreshed)
let decoded = try Yams.load(yaml: yaml) as! [String: Any]
check(RuntimeConfigReadbackPolicy.readbackError(expected: decoded, actual: actual) == nil,
      "Serialized checkpoint changed confirmed runtime settings")
check((decoded["tun"] as? [String: Any])?["enable"] as? Bool == false, "Fixture enabled TUN")
check((decoded["dns"] as? [String: Any])?["enable"] as? Bool == false, "Fixture enabled DNS")
check(decoded["ipv6"] as? Bool == ipv6, "Boolean metadata was not preserved")
check(decoded["rules"] as? [String] == ["MATCH,DIRECT"], "Routing graph was changed")
let returned = try JSONSerialization.jsonObject(with: Data(startup.utf8)) as! [String: String]
if CommandLine.arguments[4] == "fallback" {
    check(returned["externalController"] != requestedAPI, "Owned API blocker did not force fallback")
}
print("PASS: embedded startup JSON scalar checkpoint encodes and round-trips YAML")
'''

def free_port():
    with socket.socket() as tcp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        tcp.bind(('127.0.0.1', 0))
        port = tcp.getsockname()[1]
        udp.bind(('127.0.0.1', port))
        return port

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge-directory', required=True, type=Path)
    parser.add_argument('--yams-build-directory', required=True, type=Path)
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError('Run unprivileged')
    bridge = args.bridge_directory.resolve(strict=True)
    yams = args.yams_build_directory.resolve(strict=True)
    stage = Path(tempfile.mkdtemp(prefix='clashfx-checkpoint-yaml-'))
    stage.chmod(0o700)
    source = stage / 'main.swift'
    source.write_text(SWIFT)
    binary = stage / 'checkpoint'
    command = ['swiftc', '-I', str(yams), '-I', str(ROOT / 'Pods/Headers/Public'),
        '-I', str(ROOT / 'Pods/Headers/Public/Yams'), '-Xcc', '-fmodule-map-file=' + str(yams / 'Yams.modulemap'),
        '-import-objc-header', str(bridge / 'goClash.h'),
        str(ROOT / 'ClashFX/General/Utils/RuntimeConfigReadbackPolicy.swift'), str(source),
        str(yams / 'libYams.a'), str(bridge / 'goClash.a'), '-framework', 'Foundation', '-lresolv', '-o', str(binary)]
    print('Artifacts:', stage, flush=True)
    with (stage / 'compile.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    for name, ipv6 in [('normal', True), ('fallback', False)]:
        home = stage / name
        folder = home / '.config/clashfx'
        folder.mkdir(parents=True)
        proxy, api = free_port(), free_port()
        with socket.socket() as blocker:
            if name == 'fallback':
                blocker.bind(('127.0.0.1', api))
                blocker.listen()
            config = {'mixed-port': 0, 'mode': 'rule', 'log-level': 'error', 'allow-lan': False,
                'bind-address': '127.0.0.1', 'external-controller': '127.0.0.1:' + str(api),
                'tun': {'enable': False}, 'dns': {'enable': False},
                'proxies': [], 'proxy-groups': [], 'rules': ['MATCH,DIRECT']}
            (folder / 'config.yaml').write_text(json.dumps(config))
            result = subprocess.run([str(binary), str(proxy), str(api), str(ipv6).lower(), name],
                env=dict(os.environ, HOME=str(home), GOMAXPROCS='2'),
                capture_output=True, text=True, timeout=15)
            (stage / (name + '.log')).write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError(name + ' checkpoint failed; inspect ' + str(stage))
            print('PASS:', name, 'native scalar YAML checkpoint', flush=True)

if __name__ == '__main__':
    main()

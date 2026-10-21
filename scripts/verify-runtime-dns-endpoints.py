#!/usr/bin/env python3
"""Probe private Mihomo DNS over IPv4/IPv6 loopback, without TUN or OS changes."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SWIFT = r'''
import Darwin
import Foundation
let listen = CommandLine.arguments[1]
guard let host = EnhancedDNSProbeTargetPolicy.host(from: listen),
      let port = Int(listen.split(separator: ":").last!) else { fatalError("invalid fixture endpoint") }
let question: [UInt8] = [0x12,0x34,1,0,0,1,0,0,0,0,0,0,7,101,120,97,109,112,108,101,3,99,111,109,0,0,1,0,1]
let deadline = ProcessInfo.processInfo.systemUptime + 10
func answers(_ kind: Int32) -> Bool {
    guard let data = BoundedDNSProbe.query(host: host, port: port, type: kind, payload: question, timeout: 0.25),
          let parsed = EnhancedModeDNSReadinessPolicy.parseResponse(data, transactionID: 0x1234,
            expectedQuestion: Array(question.dropFirst(12))) else { return false }
    return parsed.hasResponseFlag && parsed.responseCode == 0 && parsed.answerCount > 0
}
var ready = false
while ProcessInfo.processInfo.systemUptime < deadline {
    if answers(SOCK_DGRAM) && answers(SOCK_STREAM) { ready = true; break }
    Thread.sleep(forTimeInterval: 0.025)
}
guard ready else { fatalError("configured DNS address failed UDP/TCP readiness") }
print("PASS: configured DNS \(listen) UDP/TCP via \(host)")
'''


def port(family, host):
    with socket.socket(family) as tcp, socket.socket(family, socket.SOCK_DGRAM) as udp:
        tcp.bind((host, 0))
        value = tcp.getsockname()[1]
        udp.bind((host, value))
        return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError('Run unprivileged')
    stage = Path(tempfile.mkdtemp(prefix='clashfx-runtime-dns-endpoints-'))
    print(f'Artifacts: {stage}', flush=True)
    source = stage / 'main.swift'; source.write_text(SWIFT)
    executable = stage / 'dns-probe'
    with (stage / 'compile.log').open('w') as log:
        subprocess.run(['swiftc', str(ROOT/'ClashFX/General/Managers/TunDNSTransactionController.swift'),
                        str(ROOT/'ClashFX/General/Managers/StartupProxyRecoveryPolicy.swift'),
                        str(ROOT/'ClashFX/General/Utils/ManagedOperationSettlement.swift'), str(source),
                        '-o', str(executable)], stdout=log, stderr=subprocess.STDOUT, check=True)
    for family, host in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
        home = stage / ('ipv4' if family == socket.AF_INET else 'ipv6'); home.mkdir()
        dns_port = port(family, host)
        listen = f'{host}:{dns_port}' if family == socket.AF_INET else f'[{host}]:{dns_port}'
        config = home / 'config.yaml'
        config.write_text(json.dumps({'mixed-port': 0, 'external-controller': '', 'tun': {'enable': False},
          'dns': {'enable': True, 'listen': listen, 'use-hosts': True, 'nameserver': ['udp://127.0.0.1:9']},
          'hosts': {'example.com': '127.0.0.1'}, 'rules': ['MATCH,DIRECT']}))
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home), SAFE_PATHS=str(home))
        with (home/'core.log').open('w') as log:
            core = subprocess.Popen([str(args.core.resolve()), '-d', str(home), '-f', str(config)], env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
            try:
                with (home/'probe.log').open('w') as probe:
                    subprocess.run([str(executable), listen], env=env, stdout=probe, stderr=subprocess.STDOUT,
                                   timeout=15, check=True)
            finally:
                if core.poll() is None:
                    core.terminate()
                    try: core.wait(timeout=3)
                    except subprocess.TimeoutExpired: core.kill(); core.wait(timeout=3)
    print('Real isolated DNS configured-address regression passed: IPv4 and IPv6 UDP/TCP')


if __name__ == '__main__': main()

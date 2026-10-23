#!/usr/bin/env python3
"""Run production rollback publication and deferred scope checks in memory only."""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--negative-control', action='store_true')
    args = parser.parse_args()
    source = (ROOT / 'ClashFX/AppDelegate.swift').read_text()
    request = source[source.index('    private func requestConfigUpdateApplyingRuntimePatch('):]
    checks = request[request.index('        let isCurrent:'):request.index('        baselineState?(nil)')]
    binding = 'onVerifiedRollbackProfile: { selectedConfig = $0 }'
    assert binding in request
    assert 'var selectedConfig = ConfigManager.selectConfigName' in request
    rollback = source[source.index('    private func applyRuntimeConfiguration('):]
    rollback = rollback[rollback.index('                                guard current() else { completion("Configuration transaction was cancelled"); return }'):]
    rollback = rollback[:rollback.index('                            case let .rejected(reason):')]
    if args.negative_control:
        rollback = rollback.replace('onVerifiedRollbackProfile?(previousProfile)', '// old behavior omitted expected-selection update')
    gate_source = (ROOT / 'ClashFX/General/Managers/StartupProxyRecoveryPolicy.swift').read_text()
    gate = gate_source[gate_source.index('final class EnhancedModeCompletionGate {'):]
    # This class is the last declaration in its source; avoid compiling managers.
    depth = 0
    for index in range(gate.index('{'), len(gate)):
        depth += (gate[index] == '{') - (gate[index] == '}')
        if depth == 0:
            gate = gate[:index + 1]
            break
    swift = r'''
import Foundation
import Dispatch
typealias ErrorString = String
enum ConfigManager { static var selectConfigName = "B" }
struct Context: Equatable { var identity = 1 }
enum ApiRequest { static var context = Context(); static func runtimeConfigContext() -> Context { context } }
struct Remote { var uuid = UUID() }
enum RemoteControlManager { static var selectConfig: Remote? }
enum Level { case warning }
enum Logger { static func log(_ text: String, level: Level) {} }
struct Receipt { let id = UUID() }
// GATE
final class Fixture {
    var ownsRuntimeControl = true
    var isTerminating = false
    var isRestarting = false
    var proxySelectionGeneration = 1
    var runtimeConfigurationScope = "local-core"
    var isCoreConfigSnapshotVerified = false
    var published = false
    var synced = false
    func syncConfig() { synced = true }
    func isCurrentClaudeLockChange(_ change: String) -> Bool { true }
    func run(_ intervene: @escaping () -> Void, beforeRollback: () -> Void, callback: @escaping (String?) -> Void) {
        let generation = proxySelectionGeneration
        var selectedConfig = ConfigManager.selectConfigName
        let scope = runtimeConfigurationScope
        let context = ApiRequest.runtimeConfigContext()
        let remoteID = RemoteControlManager.selectConfig?.uuid
        let lockChange: String? = nil
        // CHECKS
        let current = isCurrent
        let completion = finish
        let onVerifiedRollbackProfile: ((String) -> Void)? = { selectedConfig = $0 }
        let previousProfile: String? = "A"
        let receipt = Receipt()
        let publish: (Receipt) -> Void = { _ in self.published = true }
        let baselineKind = RuntimeConfigBaselineKind.profile
        let reason = RuntimeConfigApplyDiagnostics.sanitize("bind refused; token=FAKE_CREDENTIAL")
        func deliverRollback() {
            // ROLLBACK
        }
        beforeRollback()
        deliverRollback()
        intervene()
    }
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
func run(_ intervention: @escaping (Fixture) -> Void = { _ in }, beforeRollback: Bool = false, expected: String) {
    ConfigManager.selectConfigName = "B"; ApiRequest.context = Context(); RemoteControlManager.selectConfig = nil
    let fixture = Fixture()
    var settled = false
    var result: String?
    fixture.run({ if !beforeRollback { intervention(fixture) } },
                beforeRollback: { if beforeRollback { intervention(fixture) } }) { result = $0; settled = true }
    let deadline = Date().addingTimeInterval(2)
    while !settled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    check(settled, "rollback callback did not settle")
    check(result?.contains(expected) == true, "verified rollback reason was replaced or stale scope was accepted: " + (result ?? "nil"))
    check(result?.contains("FAKE_CREDENTIAL") == false, "credential reached rollback callback")
    if beforeRollback {
        check(!fixture.published && !fixture.synced && !fixture.isCoreConfigSnapshotVerified, "stale rollback published a baseline")
        check(ConfigManager.selectConfigName == "B", "stale rollback changed the selected profile")
    } else {
        check(fixture.published && fixture.synced && fixture.isCoreConfigSnapshotVerified, "verified baseline was not published")
    }
}
run(expected: "previously verified profile configuration was restored. bind refused")
run({ _ in ConfigManager.selectConfigName = "C" }, expected: "scope changed")
run({ _ in RemoteControlManager.selectConfig = Remote() }, expected: "scope changed")
run({ _ in ApiRequest.context.identity += 1 }, expected: "scope changed")
run({ $0.proxySelectionGeneration += 1 }, expected: "scope changed")
run({ $0.runtimeConfigurationScope = "new-core" }, expected: "scope changed")
run({ $0.isTerminating = true }, expected: "scope changed")
run({ $0.runtimeConfigurationScope = "new-core" }, beforeRollback: true, expected: "scope changed")
run({ _ in RemoteControlManager.selectConfig = Remote() }, beforeRollback: true, expected: "scope changed")
print("PASS: actual verified A→B rejection/rollback preserves safe reason; deferred selection, remote, API, generation, core and termination changes remain fenced")
'''
    swift = swift.replace('// GATE', gate).replace('// CHECKS', checks).replace('// ROLLBACK', rollback)
    with tempfile.TemporaryDirectory(prefix='clashfx-rollback-completion-') as temp:
        path = Path(temp)
        (path / 'main.swift').write_text(swift)
        utils = ROOT / 'ClashFX/General/Utils'
        subprocess.run(['swiftc', '-swift-version', '5', '-target', platform.machine() + '-apple-macosx12.0',
                        str(utils / 'RuntimeConfigBaselinePolicy.swift'), str(utils / 'RuntimeConfigApplyDiagnostics.swift'),
                        str(path / 'main.swift'), '-o', str(path / 'fixture')], check=True)
        subprocess.run([str(path / 'fixture')], check=True)


if __name__ == '__main__':
    main()

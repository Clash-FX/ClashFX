#!/usr/bin/env python3
"""Compile actual AppDelegate sync/recovery methods against Foundation-only fakes.
No AppKit, production singleton, helper, preferences, config files or network I/O.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'ClashFX/AppDelegate.swift').read_text()

def block(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

rule_start = source.index('    private lazy var claudeRuleModeAutoRecovery:')
rule_end = source.index('    private func systemProxyRecoveryObservation()', rule_start)
methods = '\n'.join([
    block('    var proxySelectionGeneration:'),
    block('    func syncConfig('),
    block('    var canSwitchProxyControlScope:'),
    source[rule_start:rule_end],
])
header = r'''
import Foundation

enum ClashProxyMode { case direct, global, rule }
struct ClashConfig { var mode: ClashProxyMode; var usedHttpPort: Int }
enum OutboundModeChangeSource { case configReload }
enum Logger {
    enum Level { case debug, warning, error }
    static func log(_ message: String, level: Level = .debug) {}
}
enum Settings { static var claudeProxyLockEnabled = true }
enum ConfigManager {
    static let shared = State()
    static var selectConfigName = "isolated"
    static var apiUrl = "fixture://isolated"
    final class State {
        var isRunning = true
        var publishedPorts = [Int]()
        var currentConfig: ClashConfig? { didSet {
            if let currentConfig { publishedPorts.append(currentConfig.usedHttpPort) }
        } }
    }
}
enum RemoteControlManager {
    struct Remote { let uuid: String }
    static var selectConfig: Remote?
}
enum ApiRequest {
    static var value = ClashConfig(mode: .direct, usedHttpPort: 7890)
    static var hold = false
    static var callbacks = [(ClashConfig) -> Void]()
    static func requestConfig(completeHandler: @escaping (ClashConfig) -> Void) {
        if hold { callbacks.append(completeHandler) } else { completeHandler(value) }
    }
}
enum ProxyGroupSelectionController { static var isAnyOperationInProgress = false }
final class ProbeApp {
    var isConfigUpdateQueued = false
    var userSystemProxyChangeInProgress = false
    var enhancedModeGeneration: UInt64 = 0
    var proxyInteractionEpoch: UInt64 = 0
    var outboundModeRequestSequence = 0
    var isOutboundModeChangeInFlight = false
    var outboundModeChangeQueue = [Int]()
    var isCoreConfigSnapshotVerified = false
    var claudeLockChange: Int?
    var isConfigUpdating = false
    var isRestoringProxySelection = false
    var isEnhancedModeTransitionInProgress = false
    var isTerminating = false
    var isRestarting = false
    var ownsRuntimeControl = true
    var modeWriteCount = 0
    static func competingRuntimePID() -> Int32? { nil }
    func requestSystemProxyAutoRecovery() {}
    func verifyPendingOutboundMode(using config: ClashConfig, requestSequence: Int) {}
    func scheduleConfigSyncRetry(completeHandler: (() -> Void)?) { syncConfig(completeHandler: completeHandler) }
    func enqueueOutboundModeChange(mode: ClashProxyMode, source: OutboundModeChangeSource,
                                   closeConnections: Bool, completion: @escaping (Bool) -> Void) {
        precondition(mode == .rule && !closeConnections)
        modeWriteCount += 1
        outboundModeRequestSequence += 1
        completion(false)
        syncConfig()
    }
'''
checks = r'''
    var recoverySuspended: Bool { claudeRuleModeAutoRecovery.isSuspended }
    func stop() { claudeRuleModeAutoRecovery.cancel() }
}
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    assertions += 1
}
let app = ProbeApp()
app.syncConfig()
let deadline = Date().addingTimeInterval(7)
while !app.recoverySuspended && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
check(app.recoverySuspended, "Failed Rule-mode requests must suspend")
check(app.modeWriteCount == 3, "Recursive config sync must not create unlimited PATCH requests")
for _ in 0..<100 { app.syncConfig() }
let stormEnd = Date().addingTimeInterval(1)
while Date() < stormEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(app.modeWriteCount == 3, "Fresh mismatch notifications must not reset the budget")
app.stop()
Settings.claudeProxyLockEnabled = false
ConfigManager.shared.publishedPorts = []
let reload = ProbeApp()
ApiRequest.hold = true
reload.syncConfig()
check(ApiRequest.callbacks.count == 1, "Captured old GET")
let old = ApiRequest.callbacks.removeFirst()
reload.proxyInteractionEpoch += 1
ApiRequest.hold = false
ApiRequest.value = ClashConfig(mode: .rule, usedHttpPort: 9000)
old(ClashConfig(mode: .direct, usedHttpPort: 7088))
check(ConfigManager.shared.publishedPorts == [9000], "Same-address reload must discard the old mode and ports")
check(reload.isCoreConfigSnapshotVerified, "Only new readback verifies the config snapshot")
reload.stop()
ConfigManager.shared.publishedPorts = []
let remoteSwitch = ProbeApp()
RemoteControlManager.selectConfig = .init(uuid: "remote-a")
ApiRequest.hold = true
remoteSwitch.syncConfig()
let priorRemote = ApiRequest.callbacks.removeFirst()
RemoteControlManager.selectConfig = .init(uuid: "remote-b")
ApiRequest.hold = false
ApiRequest.value = ClashConfig(mode: .rule, usedHttpPort: 9500)
priorRemote(ClashConfig(mode: .direct, usedHttpPort: 7088))
check(ConfigManager.shared.publishedPorts == [9500], "Same-URL remote identity changes must discard old responses")
check(remoteSwitch.canSwitchProxyControlScope, "Idle controller scope can switch")
remoteSwitch.isConfigUpdating = true
check(!remoteSwitch.canSwitchProxyControlScope, "Config reload cannot switch endpoint")
remoteSwitch.isConfigUpdating = false
remoteSwitch.isConfigUpdateQueued = true
check(!remoteSwitch.canSwitchProxyControlScope, "Queued reload reserves the controller scope")
remoteSwitch.isConfigUpdateQueued = false
ProxyGroupSelectionController.isAnyOperationInProgress = true
check(!remoteSwitch.canSwitchProxyControlScope, "Selection PUT must finish before switching endpoint")
ProxyGroupSelectionController.isAnyOperationInProgress = false
remoteSwitch.stop()
print("Production interaction runtime checks passed: \(assertions)")
'''
with tempfile.TemporaryDirectory(prefix='clashfx-interaction-runtime-') as directory:
    directory = Path(directory)
    swift = directory / 'main.swift'
    swift.write_text(header + methods + checks)
    binary = directory / 'probe'
    subprocess.run(['swiftc', str(ROOT / 'ClashFX/General/Utils/ManagedOperationSettlement.swift'),
                    str(ROOT / 'ClashFX/General/Utils/SystemProxyAutoRecoveryController.swift'),
                    str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)

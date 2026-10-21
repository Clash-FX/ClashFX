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
    block('    var isRestoringProxySelection:'),
    block('    func syncConfig('),
    block('    var canSwitchProxyControlScope:'),
    block('    func beginProxyControlScopeChange()'),
    source[rule_start:rule_end],
])
header = r'''
import Foundation

enum ClashProxyMode { case direct, global, rule }
struct ClashConfig { var mode: ClashProxyMode; var usedHttpPort: Int }
struct RuntimeConfigContext {
    let apiURL: String
    let direct: Bool
    let secret: String
}
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
final class RuntimeConfigTransactionState {
    var isBusy = false
    var isUncertain = false
    var readbackGeneration: UInt64 = 0
}
enum RemoteControlManager {
    struct Remote { let uuid: String }
    static var selectConfig: Remote?
}
enum ApiRequest {
    static var value = ClashConfig(mode: .direct, usedHttpPort: 7890)
    static var hold = false
    static var callbacks = [(ClashConfig) -> Void]()
    static var directAPI = false
    static var secret = "fixture-secret"
    static var readbackEpoch: UInt64? = 1
    static func runtimeConfigContext() -> RuntimeConfigContext {
        RuntimeConfigContext(apiURL: ConfigManager.apiUrl, direct: directAPI, secret: secret)
    }
    static func currentRuntimeConfigReadbackEpoch() -> UInt64? { readbackEpoch }
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
    var automaticRecoveryNeedsRetry = false
    var automaticRecoverySelections: [String: String]?
    var automaticRecoveryConfigName: String?
    var automaticRecoveryID: UUID?
    var isConfigUpdating = false
    var selectionMemoryRestoration: Int?
    var isEnhancedModeTransitionInProgress = false
    var isTerminating = false
    var isRestarting = false
    var ownsRuntimeControl = true
    var modeWriteCount = 0
    var runtimeConfigTransactions = RuntimeConfigTransactionState()
    var configSyncReadbackIdentity: RuntimeConfigReadbackPolicy.SyncIdentity {
        let context = ApiRequest.runtimeConfigContext()
        return RuntimeConfigReadbackPolicy.SyncIdentity(
            runtimeScope: "builtin:fixture:\(context.apiURL):\(context.direct)",
            apiURL: context.apiURL,
            directAPI: context.direct,
            secret: context.secret,
            selectedConfig: ConfigManager.selectConfigName,
            coreUpdateEpoch: ApiRequest.currentRuntimeConfigReadbackEpoch(),
            configurationGeneration: runtimeConfigTransactions.readbackGeneration
        )
    }
    static func competingRuntimePID() -> Int32? { nil }
    func requestSystemProxyAutoRecovery() {}
    func invalidateProxyInteractionScope(reason: String) { proxyInteractionEpoch &+= 1 }
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
remoteSwitch.automaticRecoverySelections = ["Proxy": "Node"]
remoteSwitch.automaticRecoveryConfigName = "failed-checkpoint-profile"
remoteSwitch.automaticRecoveryID = UUID()
check(remoteSwitch.isRestoringProxySelection, "A retained recovery checkpoint remains visible as active recovery state")
check(!remoteSwitch.canSwitchProxyControlScope,
      "Unverified recovery must block controller changes before losing the checkpoint")
let priorInteractionEpoch = remoteSwitch.proxyInteractionEpoch
check(!remoteSwitch.beginProxyControlScopeChange(), "A failed recovery must not start a handoff that loses intent")
check(remoteSwitch.automaticRecoverySelections?["Proxy"] == "Node" && remoteSwitch.automaticRecoveryID != nil,
      "Rejected controller handoff must retain the original recovery checkpoint")
check(remoteSwitch.proxyInteractionEpoch == priorInteractionEpoch, "Rejected handoff must preserve recovery identity")
remoteSwitch.automaticRecoverySelections = nil
remoteSwitch.automaticRecoveryConfigName = nil
remoteSwitch.automaticRecoveryID = nil
remoteSwitch.automaticRecoveryNeedsRetry = true
check(!remoteSwitch.canSwitchProxyControlScope && !remoteSwitch.beginProxyControlScopeChange(),
      "Retry-only failures must fence controller changes even without a captured selection map")
check(remoteSwitch.automaticRecoveryNeedsRetry && remoteSwitch.proxyInteractionEpoch == priorInteractionEpoch,
      "A rejected handoff cannot erase a failed-recovery retry state")
remoteSwitch.automaticRecoveryNeedsRetry = false
check(remoteSwitch.beginProxyControlScopeChange(), "A verified healthy scope can change controller")
check(!remoteSwitch.isCoreConfigSnapshotVerified, "An accepted scope change requires fresh readback")
check(remoteSwitch.proxyInteractionEpoch == priorInteractionEpoch + 1, "Accepted scope change invalidates callbacks")
remoteSwitch.selectionMemoryRestoration = 1
check(!remoteSwitch.canSwitchProxyControlScope, "An active selection-memory restore must block controller changes")
remoteSwitch.selectionMemoryRestoration = nil
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
ConfigManager.shared.publishedPorts = []
let transactionBlocked = ProbeApp()
ApiRequest.hold = true
transactionBlocked.syncConfig()
let transactionReadback = ApiRequest.callbacks.removeFirst()
ApiRequest.hold = false
transactionBlocked.runtimeConfigTransactions.isBusy = true
transactionReadback(ClashConfig(mode: .rule, usedHttpPort: 9900))
check(ConfigManager.shared.publishedPorts.isEmpty,
      "A config readback must not publish while a runtime transaction is busy")
check(!transactionBlocked.isCoreConfigSnapshotVerified,
      "A config readback during a busy transaction must not mark the snapshot verified")
transactionBlocked.stop()
print("Production interaction runtime checks passed: \(assertions)")
'''
with tempfile.TemporaryDirectory(prefix='clashfx-interaction-runtime-') as directory:
    directory = Path(directory)
    swift = directory / 'main.swift'
    swift.write_text(header + methods + checks)
    binary = directory / 'probe'
    subprocess.run(['swiftc', str(ROOT / 'ClashFX/General/Utils/ManagedOperationSettlement.swift'),
                    str(ROOT / 'ClashFX/General/Utils/SystemProxyAutoRecoveryController.swift'),
                    str(ROOT / 'ClashFX/General/Utils/RuntimeConfigReadbackPolicy.swift'),
                    str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)

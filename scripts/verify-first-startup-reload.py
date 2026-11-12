#!/usr/bin/env python3
"""Exercise production startup/bridge callbacks with private in-memory dependencies.

No App, Helper, core, system proxy, DNS, preferences or sockets are used. macOS
12 is a harness-only compiler target; the application remains macOS 10.14.
"""
from pathlib import Path
import argparse
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def extract(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0:
                return source[start:end + 1].replace('private func ', 'func ', 1)
    raise AssertionError('unterminated ' + signature)


PRELUDE = r'''
import Foundation
import Dispatch

typealias ErrorString = String
var events = [String]()
func clashPauseCallbacks() { events.append("pause-callbacks") }
func clashResumeCallbacks() { events.append("resume-callbacks") }
enum Level { case error, warning, info }
enum Logger {
    static var messages = [String]()
    static func log(_ text: String, level: Level = .info) { messages.append(text) }
}
struct RuntimeConfigContext: Equatable { var direct: Bool; var identity: Int }
var coreEpoch: UInt64 = 1
var coreResult: String? = "success"
var coreCalls = 0
var coreHook: (() -> Void)?
struct BridgeString { let value: String; func toString() -> String { value } }
extension String { func goStringBuffer() -> String { self } }
func clashCurrentConfigUpdateEpoch() -> UInt64 { coreEpoch }
func clashUpdateConfigWithEpoch(_ path: String, _ epoch: UInt64) -> BridgeString? {
    coreCalls += 1
    coreHook?()
    return coreResult.map { BridgeString(value: $0) }
}
enum ApiRequest {
    static let clashRequestQueue = DispatchQueue(label: "private.startup.apply")
    static var current = RuntimeConfigContext(direct: true, identity: 1)
    static func runtimeConfigContext() -> RuntimeConfigContext { current }
    static var reply: (Data?, Int?, Error?) = (nil, 204, nil)
    static func runtimeConfigHTTP(path: String, method: String, body: [String: Any]?,
                                 context: RuntimeConfigContext, timeout: TimeInterval,
                                 completion: @escaping (Data?, Int?, Error?) -> Void) {
        let captured = reply
        DispatchQueue.main.async { completion(captured.0, captured.1, captured.2) }
    }
    // APPLY_METHOD
}
struct RemoteFixture { let uuid = "private-remote"; var url = "http://127.0.0.1:18080"; var secret = "fixture-secret" }
enum ClashProxy { static func cleanCache() { events.append("cache-clear") } }
enum MenuItemFactory { static func recreateProxyMenuItems() { events.append("menu") } }
typealias AppDelegate = StartupFixture
enum RemoteControlManager {
    static var selectConfig: RemoteFixture?
    static func updateDropDownMenuItems() { events.append("dropdown") }
    // CONTROL_UPDATE_METHOD
}
enum Settings { static var enhancedMode = false; static var claudeProxyLockEnabled = false }
enum ClaudeProxyLockPolicy {
    static func requiresEnhancedMode(lockEnabled: Bool, preferredEnhancedMode: Bool) -> Bool {
        lockEnabled || preferredEnhancedMode
    }
}
enum Mode { case rule, direct }
struct CurrentConfig { var usedHttpPort = 7088; var usedSocksPort = 7088; var mode = Mode.rule }
final class Flag { var value: Bool; init(_ value: Bool) { self.value = value }; func accept(_ value: Bool) { self.value = value } }
struct SystemProxyRecoveryObservation {
    let scope: String; let shouldProtect: Bool; let isPaused: Bool
    let isReady: Bool; let matches: Bool; let ownsRuntime: Bool
}
enum NetworkChangeNotifier {
    static func getPrimaryInterface() -> String? { "private-interface" }
    static func isCurrentSystemSetToClash() -> Bool { true }
}
final class PrivilegedHelperManager {
    static let shared = PrivilegedHelperManager()
    let isHelperCheckFinished = Flag(true)
}
final class ConfigManager {
    static let shared = ConfigManager()
    static var selectConfigName = "profile-A"
    var isEnhancedModeActive = false
    var isRunning = true
    var currentConfig: CurrentConfig? = CurrentConfig()
    var proxyPortAutoSet = true
    var proxyShouldPaused = Flag(false)
    var isProxySetByOtherVariable = Flag(false)
    var overrideApiURL: URL?
    var overrideSecret: String?
}
enum MenuState { case on, off, mixed }
final class MenuFixture { var isEnabled = true; var state = MenuState.off }
enum UpdateConfigAction {
    static func showError(text: String, configName: String) { events.append("alert") }
}
final class NSUserNotificationCenter {
    static let `default` = NSUserNotificationCenter()
    func post(title: String, info: String) { events.append("notification") }
    func postConfigErrorNotice(msg: String) { events.append("notification") }
}
enum ProxyGroupSelectionController { static var isAnyOperationInProgress = false }
struct BaselineReceipt { let id = UUID() }
struct FixtureTransactions { var confirmed: BaselineReceipt? = BaselineReceipt() }
final class StartupFixture {
    static var shared = StartupFixture()
    var canSwitchProxyControlScope = true
    var didCompleteStaleEnhancedCoreCleanup = true
    var startupCoreHandoffRetryAvailable = false
    func retryStartupCoreHandoff(resetRecoveryBudget: Bool) { events.append("cleanup-retry") }
    func cancelActiveSpeedTest(reason: String, refreshMenu: Bool) { events.append("cancel-probe") }
    func resetStreamApi() { events.append("streams") }
    func syncConfig() { events.append("sync") }
    var ownsRuntimeControl = true
    var isCoreConfigSnapshotVerified = true
    var wakeSystemProxyRecoveryRequested = true
    var isStartupProxyRecoveryActive = false
    var startupProxyRecoveryGeneration = 1
    var pendingStartupProxyRecoveryWork: DispatchWorkItem?
    var isStartupProxyRecoveryHealthCheckInFlight = false
    var lastStartupProxyRecoveryDecision: Int?
    var startupSystemProxyHealthVerified = true
    var isConfigUpdating = false
    var isRestoringProxySelection = false
    var userSystemProxyChangeInProgress = false
    var isEnhancedModeTransitionInProgress = false
    var claudeLockChange: String?
    static func competingRuntimePID() -> Int? { nil }
    var isTerminating = false
    var isRestarting = false
    var startupConfigurationFailure: (profile: String, reason: String)?
    var confirmedRuntimeProfileName: String?
    var enhancedModeOwnershipBlock: UUID?
    var automaticRecoverySelections: [String: String]?
    var automaticRecoveryNeedsRetry = false
    var automaticRecoveryID: UUID?
    var enhancedModeRuntimeHealthSummary = ""
    var enhancedModeMenuItem = MenuFixture()
    var loadCompletion: ((String?) -> Void)?
    var showErrors = true
    var exerciseProductionPortGate = false
    var isOutboundModeChangeInFlight = false
    var outboundModeChangeQueue = [Int]()
    var runtimeCoreSessionID = UUID()
    var runtimeConfigurationScope: String { runtimeCoreSessionID.uuidString }
    let configUpdateTransaction = ConfigUpdateTransactionCoordinator()
    var enhancedModeGeneration: UInt64 = 1
    var proxySelectionGeneration: UInt64 = 1
    var activeConfigUpdateID: UUID? { configUpdateTransaction.activeID }
    var activeConfigUpdateCompletion: ((String?) -> Void)?
    var isBuiltInCoreResumeRetryAvailable = false
    var runtimeConfigTransactions = FixtureTransactions()
    var bootstrapDeadline: TimeInterval?
    var profileDeadline: TimeInterval?
    var pendingBootstrapWait: ((String?) -> Void)?
    var pendingProfileWait: ((String?) -> Void)?
    var pendingReadback: (() -> Void)?
    var observedProfileEndpoints = [RuntimePortHandoffWaiter.Endpoint]()

    func updateConfig(configName: String? = nil, showNotification: Bool = true, showError: Bool = true,
                      completeHandler: ((String?) -> Void)? = nil) {
        if exerciseProductionPortGate {
            productionUpdateConfig(configName: configName, showNotification: showNotification, showError: showError,
                                   completeHandler: completeHandler)
            return
        }
        if let configName { events.append("profile-reload:" + configName); return }
        events.append("load")
        showErrors = showError
        loadCompletion = completeHandler
    }
    func automaticRecoveryConfigurationReloadError() -> String? { nil }
    func deferConfigUpdate(configName: String?, showNotification: Bool, showError: Bool,
                           completion: ((String?) -> Void)?) { events.append("defer") }
    func invalidateProxyInteractionScope(reason: String) { proxySelectionGeneration &+= 1 }
    func isCurrentClaudeLockChange(_ change: String) -> Bool { claudeLockChange == change }
    @discardableResult
    func startProxy() -> String? {
        guard !ConfigManager.shared.isRunning else { return nil }
        events.append("start-bootstrap")
        ConfigManager.shared.isRunning = true
        runtimeCoreSessionID = UUID()
        isBuiltInCoreResumeRetryAvailable = false
        return nil
    }
    func waitForBuiltInProxyPort(deadline: TimeInterval, useStartupOverrides: Bool, isCurrent: @escaping () -> Bool,
                                 completion: @escaping (String?) -> Void) {
        check(useStartupOverrides, "cold start did not use the effective bootstrap overrides")
        bootstrapDeadline = deadline
        pendingBootstrapWait = { error in completion(isCurrent() ? error : "Bootstrap handoff cancelled") }
    }
    func waitForRuntimeProxyPorts(_ endpoints: [RuntimePortHandoffWaiter.Endpoint], stage: String, deadline: TimeInterval,
                                  isCurrent: @escaping () -> Bool, completion: @escaping (String?) -> Void) {
        check(stage == "selected_profile", "cold start selected the wrong wait stage")
        observedProfileEndpoints = endpoints
        profileDeadline = deadline
        pendingProfileWait = { error in completion(isCurrent() ? error : "Profile handoff cancelled") }
    }
    func requestConfigUpdateApplyingRuntimePatch(configName: String, portHandoffDeadline: TimeInterval? = nil,
                                                 handoffIsCurrent: (() -> Bool)? = nil, baselineState: ((UUID?) -> Void)? = nil,
                                                 callback: @escaping (String?) -> Void) {
        let confirmedRoot: [String: Any]? = ["mixed-port": 7088]
        let candidate: [String: Any] = ["port": 7890, "socks-port": 7891]
        let baselineID = runtimeConfigTransactions.confirmed?.id
        let result: Result<(Data, [String: Any]), Error> = .success((Data(), candidate))
        let generation = proxySelectionGeneration
        let selectedConfig = ConfigManager.selectConfigName
        let scope = runtimeConfigurationScope
        let context = ApiRequest.runtimeConfigContext()
        let remoteID = RemoteControlManager.selectConfig?.uuid
        let lockChange = claudeLockChange
        // PROFILE_REQUEST_SCOPE
        let current = isCurrent
        let submit: (String?) -> Void = { error in
            if let error { callback(error); return }
            events.append("apply-selected-profile")
            self.pendingReadback = {
                self.confirmedRuntimeProfileName = configName
                self.isCoreConfigSnapshotVerified = true
                callback(nil)
            }
        }
        // PROFILE_SUBMIT_GATE
    }
    func restoreVerifiedRuntimeBaselineIfAvailable(scope: String, receiptID: UUID) {}
    func finishReloadAfterConfigReadback(transactionID: UUID, showNotification: Bool) {
        events.append("verified-profile")
        finishConfigUpdate(transactionID: transactionID, error: nil)
    }
    func completeInitialConfigLoadForProxyRecovery(error: String?) { events.append("initial-complete") }
    func updateLoggingLevel() { events.append("logging") }
    func restoreEnhancedModeIfNeeded() { events.append("restore") }
    func refreshStatusItemViewStatus() { events.append("refresh") }
    func requestSystemProxyAutoRecovery() { events.append("recovery-request") }
    func scheduleEnhancedModePostToggleRefresh() { events.append("refresh-scheduled") }
    func fenceFailedBuiltInRecovery() {
        events.append("fence")
        ConfigManager.shared.isRunning = false
        isBuiltInCoreResumeRetryAvailable = true
    }
    func restoreDNSAfterTun(completion: (Bool) -> Void) { events.append("dns-restore"); completion(true) }
    // LOCAL_ACTIVATION_METHOD
    // STARTUP_METHOD
    // UPDATE_CONFIG_METHOD
    // RUNTIME_RELOAD_METHOD
    // FINISH_CONFIG_METHOD
    // PROFILE_PORT_WAIT_METHOD
    // FAILED_METHOD
    // OBSERVATION_METHOD
    // REMOTE_SKIP_METHOD
    // FINISH_RECOVERY_METHOD
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "isolated callback did not settle")
}
func resetBridge() {
    coreEpoch = 1; coreCalls = 0; coreResult = "success"; coreHook = nil
    Logger.messages = []; ApiRequest.current = RuntimeConfigContext(direct: true, identity: 1)
    ApiRequest.reply = (nil, 204, nil)
}
func apply() -> RuntimeConfigTransactionController.ApplyResult {
    var result: RuntimeConfigTransactionController.ApplyResult?
    ApiRequest.applyRuntimeConfig(file: URL(fileURLWithPath: "/private/in-memory-only.yaml"),
                                  context: ApiRequest.current) { result = $0 }
    wait { result != nil }; return result!
}
func resetStartup(_ enhanced: Bool = false, lock: Bool = false) {
    events = []; RemoteControlManager.selectConfig = nil; Settings.enhancedMode = enhanced; Settings.claudeProxyLockEnabled = lock
    ConfigManager.selectConfigName = "profile-A"
    ConfigManager.shared.isRunning = true; ConfigManager.shared.isEnhancedModeActive = false
}
'''

TESTS = r'''
resetBridge()
if case .accepted = apply() {} else { check(false, "success was rejected") }
resetBridge(); coreResult = "listen tcp 127.0.0.1:23123: bind: address already in use; token=private-value"
if case let .rejected(reason) = apply() {
    check(reason.contains("address already in use"), "core's original bind reason was discarded")
    check(!reason.contains("private-value"), "secret reached alert")
    check(!reason.contains("requestUUID"), "implementation bookkeeping reached alert")
} else { check(false, "conclusive core rejection was not preserved") }
check(Logger.messages.contains { $0.contains("expectedEpoch=1") && $0.contains("requestUUID=") }, "apply identity not logged")
check(!Logger.messages.joined().contains("private-value"), "secret reached logger")
for value: String? in [nil, ""] {
    resetBridge(); coreResult = value
    if case .uncertain = apply() {} else { check(false, "nil/empty reply became conclusive") }
}
resetBridge()
let occupiedQueue = DispatchSemaphore(value: 0)
let queueEntered = DispatchSemaphore(value: 0)
ApiRequest.clashRequestQueue.async { queueEntered.signal(); occupiedQueue.wait() }
queueEntered.wait()
var queuedResult: RuntimeConfigTransactionController.ApplyResult?
ApiRequest.applyRuntimeConfig(file: URL(fileURLWithPath: "/private/not-opened.yaml"), context: ApiRequest.current) { queuedResult = $0 }
coreEpoch = 2; occupiedQueue.signal(); wait { queuedResult != nil }
check(coreCalls == 0, "stale queued apply reached the core")
if case .uncertain = queuedResult! {} else { check(false, "stale queued result incorrectly accepted") }
resetBridge(); coreResult = "global HTTP listener on port 23123 is not ready"
coreHook = { coreEpoch = 2 }
if case let .uncertain(reason) = apply() {
    check(reason.contains("HTTP listener"), "epoch transition discarded the raw core response")
} else { check(false, "in-flight epoch transition was not fenced") }
resetBridge(); coreHook = { ApiRequest.current.identity = 2 }
if case .uncertain = apply() {} else { check(false, "replacement context accepted an old result") }
check(Logger.messages.isEmpty, "stale scope produced a new-context diagnostic")
resetBridge(); ApiRequest.current.direct = false
ApiRequest.reply = (try! JSONSerialization.data(withJSONObject: ["message":"bind refused; secret=private-value"]), 400, nil)
if case let .rejected(reason) = apply() {
    check(reason.contains("bind refused") && !reason.contains("private-value"), "HTTP refusal detail lost or leaked")
} else { check(false, "HTTP 400 was not a conclusive refusal") }
ApiRequest.reply = (nil, 400, NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
if case .uncertain = apply() {} else { check(false, "timeout incorrectly became a deterministic refusal") }
ApiRequest.reply = (nil, 408, nil)
if case .uncertain = apply() {} else { check(false, "HTTP 408 incorrectly became deterministic") }
ApiRequest.reply = (nil, 204, nil)
if case .accepted = apply() {} else { check(false, "HTTP 204 did not succeed") }
print("PASS: production apply callback details, epoch fences, scope changes and HTTP outcomes")

resetStartup()
do {
    let app = StartupFixture()
    app.exerciseProductionPortGate = true
    app.loadInitialConfigurationAfterCoreCleanup()
    wait { app.pendingProfileWait != nil || events.contains("apply-selected-profile") }
    check(app.pendingProfileWait != nil && !events.contains("apply-selected-profile"),
          "cold start submitted the selected profile before port readiness")
    check(app.observedProfileEndpoints == [
        .init(host: "127.0.0.1", port: 7890),
        .init(host: "127.0.0.1", port: 7891),
        .init(host: "127.0.0.1", port: 7891, transport: .udp),
    ], "cold start did not wait on the finalized profile's distinct listener claims")
    check(app.profileDeadline.map { $0 > ProcessInfo.processInfo.systemUptime } == true &&
          app.pendingBootstrapWait == nil && events.contains("pause-callbacks"),
          "running bootstrap did not enter the selected-profile wait with a bounded deadline")
    app.pendingProfileWait?(nil)
    check(app.pendingReadback != nil && !events.contains("resume-callbacks") &&
          !events.contains("initial-complete") && !app.systemProxyRecoveryObservation().isReady,
          "port release published the unverified profile")
    app.pendingReadback?()
    check(events.firstIndex(of: "verified-profile")! < events.firstIndex(of: "resume-callbacks")! &&
          events.contains("initial-complete") && app.systemProxyRecoveryObservation().isReady,
          "verified cold-start profile did not settle the update and release recovery")
}

resetStartup()
do {
    let app = StartupFixture()
    app.exerciseProductionPortGate = true
    ConfigManager.shared.isRunning = false
    app.loadInitialConfigurationAfterCoreCleanup()
    check(app.pendingBootstrapWait != nil && !events.contains("start-bootstrap") && app.isConfigUpdating,
          "stopped cold start started the core before its bootstrap wait")
    let firstDeadline = app.bootstrapDeadline
    app.pendingBootstrapWait?("Bootstrap port handoff timed out")
    check(!events.contains("start-bootstrap") && !events.contains("apply-selected-profile") &&
          !app.isConfigUpdating && app.isBuiltInCoreResumeRetryAvailable,
          "bootstrap timeout did not settle a stopped, retryable startup")
    app.loadInitialConfigurationAfterCoreCleanup()
    check(app.bootstrapDeadline != firstDeadline && app.pendingBootstrapWait != nil,
          "explicit cold-start retry did not get a fresh wait budget")
    app.pendingBootstrapWait?(nil)
    wait { app.pendingProfileWait != nil }
    check(app.bootstrapDeadline == app.profileDeadline &&
          events.filter { $0 == "start-bootstrap" }.count == 1,
          "bootstrap and selected-profile waits did not share one retry deadline")
    app.pendingProfileWait?("Profile port handoff timed out")
    check(!events.contains("apply-selected-profile") && events.contains("fence") &&
          !ConfigManager.shared.isRunning && app.isBuiltInCoreResumeRetryAvailable &&
          !app.systemProxyRecoveryObservation().isReady,
          "profile timeout mutated the core or left staging published")
}

resetStartup()
do {
    let app = StartupFixture()
    app.exerciseProductionPortGate = true
    app.loadInitialConfigurationAfterCoreCleanup()
    wait { app.pendingProfileWait != nil }
    RemoteControlManager.selectConfig = RemoteFixture()
    app.pendingProfileWait?(nil)
    check(!events.contains("apply-selected-profile") && !events.contains("verified-profile") &&
          !events.contains("fence") && !events.contains("alert") && !app.isConfigUpdating,
          "stale cold-start readiness mutated the replacement controller")
}

resetStartup()
do {
    let app = StartupFixture()
    app.exerciseProductionPortGate = true
    app.confirmedRuntimeProfileName = "profile-A"
    app.updateConfig()
    wait { app.pendingProfileWait != nil || app.pendingReadback != nil }
    check(app.pendingProfileWait == nil && app.pendingBootstrapWait == nil && app.pendingReadback != nil,
          "ordinary verified Local reload entered the cold-start port wait")
    app.pendingReadback?()
}
print("PASS: cold-start bootstrap and selected-profile gates, shared retry deadline, stale scope and verified publication")

resetStartup(true)
let enhanced = StartupFixture(); enhanced.loadInitialConfigurationAfterCoreCleanup()
check(!enhanced.showErrors, "startup modal would block Enhanced continuation")
enhanced.loadCompletion?("bootstrap restored: bind refused")
check(events.contains("restore") && !events.contains("alert"), "intermediate startup error blocked mode restoration")
check(enhanced.startupConfigurationFailure != nil, "intermediate error was silently discarded")
resetStartup(false)
let normal = StartupFixture(); normal.loadInitialConfigurationAfterCoreCleanup()
normal.loadCompletion?("startup configuration restored: bind refused")
check(events.firstIndex(of: "initial-complete")! < events.firstIndex(of: "alert")!, "alert preceded startup completion")
check(events.contains("fence"), "failed bootstrap remained available as a complete profile")
resetStartup(false, lock: true)
let locked = StartupFixture(); locked.loadInitialConfigurationAfterCoreCleanup(); locked.loadCompletion?("refused")
check(events.contains("restore") && !events.contains("alert"), "Claude-required Enhanced restore blocked")
resetStartup()
let stopped = StartupFixture(); stopped.loadInitialConfigurationAfterCoreCleanup(); stopped.isTerminating = true
let before = events.count; stopped.loadCompletion?("late")
check(events.count == before, "late startup callback mutated terminating application")
resetStartup(true)
let remote = StartupFixture(); remote.isStartupProxyRecoveryActive = true
remote.isStartupProxyRecoveryHealthCheckInFlight = true
remote.pendingStartupProxyRecoveryWork = DispatchWorkItem {}
remote.wakeSystemProxyRecoveryRequested = false
RemoteControlManager.selectConfig = RemoteFixture()
remote.loadInitialConfigurationAfterCoreCleanup()
check(!events.contains("load") && remote.loadCompletion == nil, "remote startup attempted local profile load")
check(!remote.isStartupProxyRecoveryActive && !remote.isStartupProxyRecoveryHealthCheckInFlight,
      "remote startup left initial-profile recovery waiting")
check(remote.pendingStartupProxyRecoveryWork == nil, "remote startup left its recovery timer scheduled")
check(remote.wakeSystemProxyRecoveryRequested && events.contains("recovery-request"), "return-to-local recovery intent was lost")
RemoteControlManager.selectConfig = nil; Settings.enhancedMode = false
remote.confirmedRuntimeProfileName = "profile-A"
check(remote.systemProxyRecoveryObservation().isReady && remote.systemProxyRecoveryObservation().shouldProtect,
      "same-port local return remained blocked by cancelled startup recovery")
resetStartup(true)
let remoteChanged = StartupFixture(); remoteChanged.isStartupProxyRecoveryActive = true
remoteChanged.loadInitialConfigurationAfterCoreCleanup()
RemoteControlManager.selectConfig = RemoteFixture()
remoteChanged.loadCompletion?("late local error")
check(!events.contains("alert") && !events.contains("fence") && !events.contains("restore"),
      "old local startup changed the newly selected remote runtime")
check(!remoteChanged.isStartupProxyRecoveryActive, "remote switch in callback retained startup wait")
resetStartup(true)
let failed = StartupFixture(); failed.startupConfigurationFailure = ("profile-A", "first refusal")
failed.finishFailedEnhancedModeRestore(error: "second refusal")
check(Settings.enhancedMode && failed.enhancedModeMenuItem.state == .mixed, "combined failure silently disabled requested Enhanced Mode")
check(events.contains("fence") && events.contains("notification"), "combined failure did not fence and report bootstrap")
resetStartup(true)
let uncertain = StartupFixture(); uncertain.startupConfigurationFailure = ("profile-A", "first refusal")
uncertain.enhancedModeOwnershipBlock = UUID(); ConfigManager.shared.isEnhancedModeActive = true
uncertain.finishFailedEnhancedModeRestore(error: "ownership unknown")
check(!events.contains("fence") && !events.contains("dns-restore"), "uncertain external ownership was disturbed")
check(ConfigManager.shared.isEnhancedModeActive, "unconfirmed live core was reported stopped")
resetStartup(true)
let valid = StartupFixture(); valid.confirmedRuntimeProfileName = "profile-A"
valid.finishFailedEnhancedModeRestore(error: "enhanced refused")
check(!events.contains("fence"), "valid previously loaded profile was unnecessarily stopped")
resetStartup()
let observer = StartupFixture()
check(!observer.systemProxyRecoveryObservation().isReady, "bootstrap readback promoted system proxy before any confirmed profile")
observer.confirmedRuntimeProfileName = "profile-A"
check(observer.systemProxyRecoveryObservation().isReady, "normal confirmed profile incorrectly blocked system proxy recovery")
ConfigManager.shared.currentConfig?.mode = .direct
check(observer.systemProxyRecoveryObservation().isReady, "explicit DIRECT mode without Claude lock was incorrectly blocked")
Settings.claudeProxyLockEnabled = true
check(!observer.systemProxyRecoveryObservation().isReady, "Claude lock silently accepted DIRECT mode")
Settings.claudeProxyLockEnabled = false
observer.isEnhancedModeTransitionInProgress = true
check(!observer.systemProxyRecoveryObservation().isReady, "mode transition published system proxy before it settled")
resetStartup()
StartupFixture.shared = StartupFixture()
ConfigManager.shared.isRunning = false
RemoteControlManager.updateRemoteControl()
check(events.contains("load") && !events.contains("sync"), "Local after remote cold start only synchronized zero ports")
check(!StartupFixture.shared.showErrors, "local activation restored the blocking startup alert")
resetStartup()
StartupFixture.shared = StartupFixture()
StartupFixture.shared.confirmedRuntimeProfileName = "profile-A"
RemoteControlManager.updateRemoteControl()
check(!events.contains("load") && events.contains("sync"), "healthy Local profile was unnecessarily reloaded")
resetStartup()
StartupFixture.shared = StartupFixture()
RemoteControlManager.updateRemoteControl()
check(events.contains("load"), "running bootstrap without a confirmed profile was treated as a loaded Local profile")
resetStartup()
StartupFixture.shared = StartupFixture()
RemoteControlManager.selectConfig = RemoteFixture()
RemoteControlManager.updateRemoteControl()
check(!events.contains("load") && events.contains("sync"), "remote controller selection started a local profile")
check(ConfigManager.shared.overrideApiURL != nil, "remote API override was not installed")
resetStartup()
StartupFixture.shared = StartupFixture()
StartupFixture.shared.didCompleteStaleEnhancedCoreCleanup = false
StartupFixture.shared.startupCoreHandoffRetryAvailable = true
ConfigManager.shared.isRunning = false
RemoteControlManager.updateRemoteControl()
check(!events.contains("load") && !events.contains("sync") && events.contains("cleanup-retry"),
      "Local bypassed stale-core cleanup or abandoned an explicit safe retry")
resetStartup()
StartupFixture.shared = StartupFixture()
StartupFixture.shared.enhancedModeOwnershipBlock = UUID()
ConfigManager.shared.isRunning = false
RemoteControlManager.updateRemoteControl()
check(!events.contains("load") && !events.contains("sync") && !events.contains("fence"),
      "Local activation disturbed uncertain external ownership")
resetStartup()
StartupFixture.shared = StartupFixture()
StartupFixture.shared.confirmedRuntimeProfileName = "profile-A"
ConfigManager.shared.isEnhancedModeActive = true
RemoteControlManager.updateRemoteControl()
check(!events.contains("load") && events.contains("sync"), "healthy Enhanced core was reloaded on Local return")
for enhancedActive in [false, true] {
    resetStartup()
    StartupFixture.shared = StartupFixture()
    StartupFixture.shared.confirmedRuntimeProfileName = "profile-A"
    ConfigManager.shared.isEnhancedModeActive = enhancedActive
    ConfigManager.selectConfigName = "profile-B"
    RemoteControlManager.updateRemoteControl()
    check(events.contains("profile-reload:profile-B") && !events.contains("load") && !events.contains("sync") && !events.contains("restore"),
          "Local return kept the old selected profile or repeated startup for an already running core")
}
print("PASS: actual Remote→Local wiring starts only missing local profiles behind cleanup/ownership gates")
print("PASS: production startup continuation, rollback provenance, failure fencing and ownership guards")
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--negative-control', choices=['modal', 'detail', 'startup-port-wait'])
    args = parser.parse_args()
    delegate = (ROOT / 'ClashFX/AppDelegate.swift').read_text()
    api = (ROOT / 'ClashFX/General/ApiRequest.swift').read_text()
    remote_source = (ROOT / 'ClashFX/General/Managers/RemoteControlManager.swift').read_text()
    apply = extract(api, '    static func applyRuntimeConfig(')
    startup = extract(delegate, '    private func loadInitialConfigurationAfterCoreCleanup(')
    update = extract(delegate, '    func updateConfig(').replace('func updateConfig(', 'func productionUpdateConfig(', 1)
    runtime_reload = extract(delegate, '    private func requestRuntimeConfigReload(')
    finish_config = extract(delegate, '    private func finishConfigUpdate(')
    profile_wait = extract(delegate, '    private func waitForBuiltInProfilePorts(')
    profile_request = extract(delegate, '    private func requestConfigUpdateApplyingRuntimePatch(')
    profile_scope = extract(profile_request, 'let isCurrent: () -> Bool = {')
    profile_apply = extract(delegate, '    private func applyRuntimeConfiguration(')
    profile_submit = extract(profile_apply, 'DispatchQueue.main.async {\n                        guard let portHandoffDeadline')
    activation = extract(delegate, '    func loadLocalConfigurationIfNeededAfterControlScopeChange(')
    control_update = extract(remote_source, '    static func updateRemoteControl(')
    failed = extract(delegate, '    private func finishFailedEnhancedModeRestore(')
    observation = extract(delegate, '    private func systemProxyRecoveryObservation(')
    remote_skip = extract(delegate, '    private func finishLocalStartupForRemoteControl(')
    finish_recovery = extract(delegate, '    private func finishStartupProxyRecovery(')
    if args.negative_control == 'modal':
        startup = startup.replace('showError: false', 'showError: true')
    if args.negative_control == 'detail':
        apply = apply.replace('completion(.rejected(RuntimeConfigApplyDiagnostics.displayReason(detail)))',
                              'completion(.rejected("Core rejected the runtime configuration"))')
    if args.negative_control == 'startup-port-wait':
        original = 'portHandoffDeadline: portHandoffDeadline, handoffIsCurrent:'
        if runtime_reload.count(original) != 1:
            raise AssertionError('expected one runtime reload port deadline')
        runtime_reload = runtime_reload.replace(original, 'portHandoffDeadline: nil, handoffIsCurrent:')
    replacements = {
        '// LOCAL_ACTIVATION_METHOD': activation,
        '// CONTROL_UPDATE_METHOD': control_update,
        '// APPLY_METHOD': apply,
        '// STARTUP_METHOD': startup,
        '// UPDATE_CONFIG_METHOD': update,
        '// RUNTIME_RELOAD_METHOD': runtime_reload,
        '// FINISH_CONFIG_METHOD': finish_config,
        '// PROFILE_PORT_WAIT_METHOD': profile_wait,
        '// PROFILE_REQUEST_SCOPE': profile_scope,
        '// PROFILE_SUBMIT_GATE': profile_submit,
        '// FAILED_METHOD': failed,
        '// OBSERVATION_METHOD': observation,
        '// REMOTE_SKIP_METHOD': remote_skip,
        '// FINISH_RECOVERY_METHOD': finish_recovery,
    }
    swift = PRELUDE
    for marker, production_code in replacements.items():
        swift = swift.replace(marker, production_code)
    swift += TESTS
    utils = ROOT / 'ClashFX/General/Utils'
    with tempfile.TemporaryDirectory(prefix='clashfx-startup-callbacks-') as temp:
        directory = Path(temp)
        source = directory / 'main.swift'; source.write_text(swift)
        binary = directory / 'fixture'
        command = ['swiftc', '-swift-version', '5', '-target', platform.machine() + '-apple-macosx12.0',
                   str(utils / 'RuntimeConfigTransactionController.swift'),
                   str(utils / 'RuntimeConfigApplyDiagnostics.swift'),
                   str(utils / 'RuntimePortHandoffWaiter.swift'),
                   str(ROOT / 'ClashFX/General/Managers/StartupProxyRecoveryPolicy.swift'),
                   str(source), '-o', str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()

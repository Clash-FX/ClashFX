#!/usr/bin/env python3
"""Exercise built-in profile handoff and enhanced-mode close retry behavior.

The harness compiles the production handoff, close, and menu-toggle methods with
private in-memory core, API, lifecycle, and UI stand-ins. It does not start the
app, helper, embedded core, or system proxy.
"""

from pathlib import Path
import argparse
import platform
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def extract(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
            if depth == 0:
                method = source[start : end + 1]
                return method.replace("private func ", "func ", 1).replace("@IBAction ", "", 1)
    raise AssertionError("unterminated " + signature)


def replace_once(source, old, new, label):
    count = source.count(old)
    if count != 1:
        raise AssertionError(f"expected one {label} insertion point, found {count}")
    return source.replace(old, new, 1)


PRELUDE = r'''
import Foundation
import Darwin
import Dispatch

typealias ErrorString = String
var events = [String]()
var callbacksPaused = false
var callbackPauseCount = 0
var callbackResumeCount = 0

enum Level { case error, warning, info, debug }
enum Logger {
    static var messages = [String]()
    static func log(_ text: String, level: Level = .info) { messages.append(text) }
}

struct RuntimeConfigContext: Equatable {
    var identity: Int
    var apiURL: String
    var secret: String
}
enum ApiRequest {
    static var context = RuntimeConfigContext(identity: 1, apiURL: "http://127.0.0.1:19090", secret: "private")
    static func runtimeConfigContext() -> RuntimeConfigContext { context }
}
struct RemoteFixture { var uuid: String }
enum RemoteControlManager { static var selectConfig: RemoteFixture? = RemoteFixture(uuid: "remote-A") }

enum RuntimeConfigBaselineKind: String {
    case startup, profile
    init(confirmedProfile: String?) { self = confirmedProfile == nil ? .startup : .profile }
}
enum RuntimeConfigApplyDiagnostics {
    static func sanitize(_ value: String) -> String { value }
    static func displayReason(_ value: String) -> String { value.isEmpty ? "Core did not provide a failure reason" : value }
}

final class EnhancedModeCompletionGate {
    private let lock = NSLock()
    private var finished = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}
struct EnhancedModeCloseToken { let generation: UInt64; let id: UUID }
final class EnhancedModeLifecycleCoordinator {
    private(set) var generation: UInt64 = 0
    private(set) var closeID: UUID?
    func beginClose() -> EnhancedModeCloseToken {
        generation &+= 1
        let id = UUID()
        closeID = id
        events.append("begin-close")
        return EnhancedModeCloseToken(generation: generation, id: id)
    }
    func isCurrentClose(generation expected: UInt64, id: UUID, isTerminating: Bool) -> Bool {
        !isTerminating && generation == expected && closeID == id
    }
    func finishClose(id: UUID) {
        if closeID == id { closeID = nil }
        events.append("finish-close")
    }
    func invalidate() { generation &+= 1; closeID = nil }
}
enum EnhancedModeLifecyclePolicy {
    static func shouldApplyLifecycleCompletion(generation: UInt64,
                                               currentGeneration: UInt64,
                                               isTerminating: Bool) -> Bool {
        !isTerminating && generation == currentGeneration
    }
}

final class FakeRuntimeConfigTransactions {
    var isUncertain = false
    var isBusy = false
    var confirmedBaselineID: UUID?
    var confirmedBaselineProfile: String?
    var confirmedBaselineMetadata: String?
}
struct EnhancedModeOwnershipBlock { let requestID: UUID }
enum MenuState { case on, off, mixed }
final class MenuFixture { var isEnabled = true; var state = MenuState.off }
final class ConfigManager {
    static let shared = ConfigManager()
    static var selectConfigName = "profile-A"
    var isRunning = true
    var isEnhancedModeActive = true
    var currentConfigMetadata = "bootstrap metadata"
}
enum Settings {
    static var enhancedMode = true
    static var claudeProxyLockEnabled = false
}
enum ProxyGroupSelectionController { static var isAnyOperationInProgress = false }
enum MenuItemFactory {
    static func recreateProxyMenuItems(coreReloaded: Bool) { events.append("recreate-proxy-menu") }
}
struct HarnessNotificationName { static let reloadDashboard = HarnessNotificationName() }
final class NotificationCenter {
    static let `default` = NotificationCenter()
    func post(name: HarnessNotificationName, object: Any?) { events.append("dashboard-reload") }
}
final class NSMenuItem {}
final class NSUserNotificationCenter {
    static let `default` = NSUserNotificationCenter()
    func post(title: String, info: String) { events.append("notification") }
}

func clashPauseCallbacks() { callbacksPaused = true; callbackPauseCount += 1; events.append("pause-callbacks") }
func clashResumeCallbacks() { callbacksPaused = false; callbackResumeCount += 1; events.append("resume-callbacks") }
func clashSuspendCore() {
    ConfigManager.shared.isRunning = false
    ConfigManager.shared.isEnhancedModeActive = false
    events.append("suspend-core")
}

enum ProfileApplyOutcome {
    case bootstrap
    case unknown
    case fullProfile(String)
    case error(String)
}

final class AppDelegateFixture {
    var ownsRuntimeControl = true
    var isEnhancedModeTransitionInProgress = false
    var isConfigUpdating = false
    var isConfigUpdateQueued = false
    var isTerminating = false
    var isRestarting = false
    var startupCoreHandoffRetryAvailable = false
    var isBuiltInCoreResumeRetryAvailable = false
    var startupRetryCount = 0
    var enhancedModeOwnershipBlock: EnhancedModeOwnershipBlock?
    var activeEnhancedModeClientLaunchID: UUID? = UUID()
    var activeEnhancedModeConfigPath: String? = "external-config"
    var enhancedModeLifecycle = EnhancedModeLifecycleCoordinator()
    var enhancedModeGeneration: UInt64 { enhancedModeLifecycle.generation }
    var isWakeEnhancedModeRestarting = false
    var isEnhancedModeRuntimeRecoveryPending = false
    var expectedEnhancedDNSPort = 0
    var proxySelectionGeneration: UInt64 = 1
    var runtimeCoreSessionID = UUID()
    var verifiedSnapshotPromotionCount = 0
    var isCoreConfigSnapshotVerified = false {
        didSet {
            if isCoreConfigSnapshotVerified && !oldValue { verifiedSnapshotPromotionCount += 1 }
        }
    }
    var confirmedRuntimeProfileName: String?
    var runtimeConfigTransactions = FakeRuntimeConfigTransactions()
    var runtimeConfigurationScope: String {
        "builtin:\(runtimeCoreSessionID.uuidString):\(ApiRequest.context.identity):\(ApiRequest.context.apiURL)"
    }

    var enhancedModeMenuItem = MenuFixture()
    var startProxyCallCount = 0
    var startProxyResults = [String?]()
    var profileNameAfterStart: String? = "saved-profile"
    var profileApplyOutcomes = [ProfileApplyOutcome]()
    var profileApplyCallCount = 0
    var baselineIDToPublish: UUID?
    var profileApplyDeferred = false
    var pendingProfileApply: ((String?) -> Void)?
    var stopExternalError: String?
    var dnsRestoreError: String?
    var fenceCount = 0
    var baselineRestoreCount = 0
    var syncConfigRefreshPending = false
    var lastToggleError: String?
    var presentErrorCount = 0
    var protectionNoticeCount = 0
    var enableEnhancedModeCount = 0
    var cancelSpeedTestCount = 0

    func cancelActiveSpeedTest(reason: String, refreshMenu: Bool) {
        cancelSpeedTestCount += 1
        events.append("cancel-speed-test")
    }
    func completeActiveEnhancedModeLaunch(_ reason: String) { events.append("cancel-launch") }
    func cancelConfigUpdateForLifecycle(_ reason: String) { events.append("cancel-config-update") }
    func restoreDNSAfterTun(reapplyTunIfLate: Bool = false,
                            expectedGeneration: UInt64? = nil,
                            completion: ((String?) -> Void)? = nil) {
        events.append("restore-dns")
        completion?(dnsRestoreError)
    }
    func stopExternalCoreBounded(timeout: TimeInterval? = nil,
                                 isCurrent: @escaping () -> Bool,
                                 completion: @escaping (String?) -> Void) {
        events.append("stop-external")
        if isCurrent() { completion(stopExternalError) }
    }
    func reconcileUncertainEnhancedCoreOwnership(_ block: EnhancedModeOwnershipBlock,
                                                  completion: @escaping (String?) -> Void) {
        events.append("reconcile-ownership")
        enhancedModeOwnershipBlock = nil
        if isCurrentForHarness { completion(nil) }
    }
    var isCurrentForHarness = true
    func clearEnhancedModeOwnershipBlock(requestID: UUID) {
        if enhancedModeOwnershipBlock?.requestID == requestID { enhancedModeOwnershipBlock = nil }
    }
    @discardableResult
    func blockActiveEnhancedModeOwnership(generation: UInt64, reason: String) -> EnhancedModeOwnershipBlock? {
        guard activeEnhancedModeClientLaunchID != nil, activeEnhancedModeConfigPath != nil else { return nil }
        let block = EnhancedModeOwnershipBlock(requestID: UUID())
        enhancedModeOwnershipBlock = block
        ConfigManager.shared.isRunning = false
        events.append("ownership-block")
        return block
    }
    func refreshStatusItemViewStatus() { events.append("refresh-status") }

    func startProxy() -> String? {
        startProxyCallCount += 1
        events.append("start-proxy-call-\(startProxyCallCount)")
        if ConfigManager.shared.isRunning { return nil }
        let result: String? = startProxyResults.isEmpty ? nil : startProxyResults.removeFirst()
        if let result {
            ConfigManager.shared.isRunning = false
            isBuiltInCoreResumeRetryAvailable = true
            isCoreConfigSnapshotVerified = false
            confirmedRuntimeProfileName = nil
            return result
        }
        runtimeCoreSessionID = UUID()
        ConfigManager.shared.isRunning = true
        ConfigManager.shared.isEnhancedModeActive = false
        isCoreConfigSnapshotVerified = false
        confirmedRuntimeProfileName = profileNameAfterStart
        isBuiltInCoreResumeRetryAvailable = false
        return nil
    }

    func requestConfigUpdateApplyingRuntimePatch(
        configName: String,
        baselineState: ((UUID?) -> Void)? = nil,
        callback: @escaping (String?) -> Void
    ) {
        profileApplyCallCount += 1
        events.append("apply-profile:\(configName)")
        baselineState?(nil)
        if let baselineIDToPublish { baselineState?(baselineIDToPublish) }
        guard !profileApplyDeferred else {
            pendingProfileApply = callback
            return
        }
        finishProfileApply(outcome: profileApplyOutcomes.isEmpty ? .bootstrap : profileApplyOutcomes.removeFirst(),
                           callback: callback)
    }
    func finishProfileApply(outcome: ProfileApplyOutcome, callback: @escaping (String?) -> Void) {
        switch outcome {
        case .bootstrap:
            ConfigManager.shared.isRunning = true
            isCoreConfigSnapshotVerified = false
            confirmedRuntimeProfileName = nil
            runtimeConfigTransactions.isUncertain = false
            callback(nil)
        case .unknown:
            ConfigManager.shared.isRunning = true
            isCoreConfigSnapshotVerified = true
            confirmedRuntimeProfileName = ConfigManager.selectConfigName
            runtimeConfigTransactions.isUncertain = true
            callback(nil)
        case let .fullProfile(profile):
            ConfigManager.shared.isRunning = true
            isCoreConfigSnapshotVerified = true
            confirmedRuntimeProfileName = profile
            ConfigManager.shared.currentConfigMetadata = "metadata for \(profile)"
            runtimeConfigTransactions.isUncertain = false
            callback(nil)
        case let .error(error):
            ConfigManager.shared.isRunning = true
            runtimeConfigTransactions.isUncertain = false
            callback(error)
        }
    }
    func finishDeferredProfileApply(_ error: String? = nil) {
        guard let callback = pendingProfileApply else { return }
        pendingProfileApply = nil
        callback(error)
    }
    func restoreVerifiedRuntimeBaselineIfAvailable(scope: String, receiptID: UUID) {
        guard scope == runtimeConfigurationScope,
              ownsRuntimeControl, !isTerminating, !isRestarting,
              runtimeConfigTransactions.confirmedBaselineID == receiptID,
              !runtimeConfigTransactions.isBusy, !runtimeConfigTransactions.isUncertain,
              let profile = runtimeConfigTransactions.confirmedBaselineProfile,
              let metadata = runtimeConfigTransactions.confirmedBaselineMetadata else { return }
        baselineRestoreCount += 1
        isCoreConfigSnapshotVerified = true
        confirmedRuntimeProfileName = profile
        ConfigManager.shared.currentConfigMetadata = metadata
        events.append("restore-verified-baseline")
    }
    func fenceFailedBuiltInRecovery() {
        fenceCount += 1
        events.append("fence-incomplete-core")
        clashSuspendCore()
        runtimeCoreSessionID = UUID()
        isCoreConfigSnapshotVerified = false
        confirmedRuntimeProfileName = nil
        ConfigManager.shared.isRunning = false
        isBuiltInCoreResumeRetryAvailable = true
        refreshStatusItemViewStatus()
    }
    func selectProxyGroupWithMemory(completion: ((Bool) -> Void)? = nil) {
        events.append("restore-proxy-group")
        completion?(true)
    }
    func selectOutBoundModeWithMenory() { events.append("restore-outbound-mode") }
    func syncConfig() {
        events.append("sync-config")
        // Simulate a metadata refresh that remains pending. It must not own the
        // enhanced-mode close completion after the profile transaction verified.
        syncConfigRefreshPending = true
    }

    func retryAutomaticRecoveryIfNeeded() -> Bool { false }
    func retryStartupCoreHandoff(resetRecoveryBudget: Bool) {
        startupRetryCount += 1
        events.append("retry-startup-handoff")
    }
    func presentClaudeProxyLockProtectionNotice() {
        protectionNoticeCount += 1
        events.append("claude-lock-notice")
    }
    func presentEnhancedModeToggleError(_ error: String, attemptedEnable: Bool) {
        lastToggleError = error
        presentErrorCount += 1
        events.append("toggle-error")
    }
    func scheduleEnhancedModePostToggleRefresh() { events.append("post-toggle-refresh") }
    func enableEnhancedMode(completion: @escaping (UInt64, String?) -> Void) {
        enableEnhancedModeCount += 1
        events.append("enable-enhanced-mode")
    }

    // EXTRACTED_DISABLE
    // EXTRACTED_HANDOFF
    // EXTRACTED_TOGGLE
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
func wait(_ condition: () -> Bool, _ message: String) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    check(condition(), message)
}
func resetHarness() {
    events = []
    callbacksPaused = false
    callbackPauseCount = 0
    callbackResumeCount = 0
    Logger.messages = []
    ConfigManager.selectConfigName = "profile-A"
    ConfigManager.shared.isRunning = true
    ConfigManager.shared.isEnhancedModeActive = true
    ConfigManager.shared.currentConfigMetadata = "bootstrap metadata"
    Settings.enhancedMode = true
    Settings.claudeProxyLockEnabled = false
    ProxyGroupSelectionController.isAnyOperationInProgress = false
    RemoteControlManager.selectConfig = RemoteFixture(uuid: "remote-A")
    ApiRequest.context = RuntimeConfigContext(identity: 1, apiURL: "http://127.0.0.1:19090", secret: "private")
}
'''


TESTS = r'''
// An unverified startup/bootstrap response must be stopped with callbacks paused.
resetHarness()
do {
    let app = AppDelegateFixture()
    app.profileApplyOutcomes = [.bootstrap]
    app.actionToggleEnhancedMode(nil)
    wait({ app.presentErrorCount == 1 || events.contains("post-toggle-refresh") },
         "bootstrap close completion did not settle")
    check(app.startProxyCallCount == 1, "close invoked startProxy more than once")
    check(app.profileApplyCallCount == 1, "bootstrap close did not request the selected profile")
    check(app.fenceCount == 1, "bootstrap profile was not fenced")
    check(callbacksPaused && callbackResumeCount == 0, "bootstrap profile resumed core callbacks")
    check(!ConfigManager.shared.isRunning && app.isBuiltInCoreResumeRetryAvailable,
          "incomplete bootstrap core was not stopped for retry")
    check(Settings.enhancedMode == false && app.enhancedModeMenuItem.state == .mixed,
          "failed local handoff did not retain the actual local preference and retry indicator")
    let suspend = events.firstIndex(of: "suspend-core")
    let start = events.firstIndex(of: "start-proxy-call-1")
    check(suspend != nil && start != nil && suspend! < start!, "built-in staging core was not suspended before configured start")
    check(app.lastToggleError?.contains("incomplete core was stopped") == true,
          "bootstrap fencing reason did not reach the toggle completion")
}
print("PASS: bootstrap handoff is fenced and callbacks stay paused")

// An uncertain transaction is not a verified full profile even when fields look complete.
resetHarness()
do {
    let app = AppDelegateFixture()
    app.profileApplyOutcomes = [.unknown]
    ConfigManager.shared.isEnhancedModeActive = false
    clashPauseCallbacks()
    var result: String?
    var completed = false
    app.completeBuiltInProfileHandoff(isCurrent: { true }) { result = $0; completed = true }
    check(completed, "unknown profile callback did not settle")
    check(app.fenceCount == 1 && !ConfigManager.shared.isRunning,
          "uncertain runtime state was not fenced")
    check(callbacksPaused && callbackResumeCount == 0, "unknown profile resumed callbacks")
    check(result?.contains("incomplete core was stopped") == true, "unknown profile did not report a fenced failure")
    check(Logger.messages.contains {
        $0.contains("baseline_kind=profile") && $0.contains("snapshot_verified=true") &&
            $0.contains("transaction_uncertain=true")
    }, "fence log omitted the observed profile, snapshot, or uncertainty state")
}
print("PASS: uncertain profile apply is fenced")

// A rejected candidate can retain a complete prior profile only when the apply path
// published a validated baseline receipt that still matches the active scope.
resetHarness()
do {
    let app = AppDelegateFixture()
    ConfigManager.shared.isEnhancedModeActive = false
    let baselineID = UUID()
    app.confirmedRuntimeProfileName = "saved-profile"
    app.runtimeConfigTransactions.confirmedBaselineID = baselineID
    app.runtimeConfigTransactions.confirmedBaselineProfile = "saved-profile"
    app.runtimeConfigTransactions.confirmedBaselineMetadata = "verified saved-profile metadata"
    app.baselineIDToPublish = baselineID
    app.profileApplyOutcomes = [.error("candidate was rejected")]
    clashPauseCallbacks()
    var result: String?
    var completed = false
    app.completeBuiltInProfileHandoff(isCurrent: { true }) { result = $0; completed = true }
    check(completed && result == "candidate was rejected", "verified rollback did not preserve the original apply error")
    check(app.baselineRestoreCount == 1 && app.isCoreConfigSnapshotVerified,
          "validated baseline receipt did not restore verified snapshot state")
    check(app.confirmedRuntimeProfileName == "saved-profile" &&
          ConfigManager.shared.currentConfigMetadata == "verified saved-profile metadata",
          "verified rollback lost the prior profile or its metadata")
    check(app.fenceCount == 0 && !callbacksPaused && callbackResumeCount == 1,
          "verified rollback was fenced or callbacks remained paused")
    check(!events.contains("recreate-proxy-menu") && !events.contains("sync-config"),
          "failed profile apply performed success-only menu or stream work")
}
print("PASS: validated full-profile rollback resumes callbacks and retains metadata")

// A rejection without a validated ID must not promote a stale ConfigManager snapshot.
resetHarness()
do {
    let app = AppDelegateFixture()
    ConfigManager.shared.isEnhancedModeActive = false
    app.confirmedRuntimeProfileName = "saved-profile"
    app.isCoreConfigSnapshotVerified = false
    app.profileApplyOutcomes = [.error("candidate was rejected before apply")]
    clashPauseCallbacks()
    var completed = false
    app.completeBuiltInProfileHandoff(isCurrent: { true }) { _ in completed = true }
    check(completed, "unvalidated rejection callback did not settle")
    check(app.baselineRestoreCount == 0 && app.verifiedSnapshotPromotionCount == 0 &&
          !app.isCoreConfigSnapshotVerified,
          "missing validated baseline ID elevated the snapshot")
    check(app.fenceCount == 1 && callbacksPaused && callbackResumeCount == 0,
          "unvalidated rollback resumed callbacks instead of fencing")
}
print("PASS: missing validated baseline ID cannot elevate a snapshot")

// A selected DIRECT profile is still a complete profile when it was explicitly applied and verified.
resetHarness()
do {
    ConfigManager.selectConfigName = "DIRECT"
    let app = AppDelegateFixture()
    ConfigManager.shared.isEnhancedModeActive = false
    app.profileApplyOutcomes = [.fullProfile("DIRECT")]
    clashPauseCallbacks()
    var result: String? = "pending"
    app.completeBuiltInProfileHandoff(isCurrent: { true }) { result = $0 }
    check(result == nil && app.confirmedRuntimeProfileName == "DIRECT",
          "explicitly verified DIRECT profile was rejected as bootstrap state")
    check(app.fenceCount == 0 && !callbacksPaused && callbackResumeCount == 1,
          "explicit DIRECT profile did not resume callbacks")
}
print("PASS: explicitly selected DIRECT profile is accepted after verification")

// A current successful close restores selections, menus, the dashboard, and config sync.
resetHarness()
do {
    let app = AppDelegateFixture()
    app.profileApplyOutcomes = [.fullProfile("profile-A")]
    app.profileApplyDeferred = false
    app.actionToggleEnhancedMode(nil)
    wait({ events.contains("post-toggle-refresh") }, "successful close did not complete its toggle callback")
    check(app.startProxyCallCount == 1 && app.profileApplyCallCount == 1,
          "successful close did not perform one configured start and one full-profile apply")
    check(!callbacksPaused && callbackResumeCount == 1, "verified profile did not resume callbacks")
    for event in ["restore-proxy-group", "restore-outbound-mode", "recreate-proxy-menu",
                  "dashboard-reload", "sync-config"] {
        check(events.contains(event), "successful profile handoff omitted \(event)")
    }
    check(app.syncConfigRefreshPending, "success path did not launch the pending metadata refresh")
    check(app.fenceCount == 0 && Settings.enhancedMode == false &&
          app.enhancedModeMenuItem.state == .off,
          "successful close retained a failure or enhanced-mode state")
}
print("PASS: verified close restores selection menus and config sync")

// A stale completion must not fence, resume callbacks, or mutate menus for a newer scope.
for axis in ["session", "interaction", "remote", "context", "ownership", "lifecycle"] {
    resetHarness()
    let app = AppDelegateFixture()
    ConfigManager.shared.isEnhancedModeActive = false
    app.profileApplyDeferred = true
    clashPauseCallbacks()
    var result: String?
    app.completeBuiltInProfileHandoff(isCurrent: { app.isCurrentForHarness }) { result = $0 }
    check(app.profileApplyCallCount == 1 && app.pendingProfileApply != nil,
          "deferred handoff did not retain its in-flight callback")
    switch axis {
    case "session": app.runtimeCoreSessionID = UUID()
    case "interaction": app.proxySelectionGeneration &+= 1
    case "remote": RemoteControlManager.selectConfig = RemoteFixture(uuid: "remote-B")
    case "context": ApiRequest.context.identity += 1
    case "ownership": app.ownsRuntimeControl = false
    case "lifecycle": app.isCurrentForHarness = false
    default: check(false, "unknown stale-scope axis")
    }
    app.finishDeferredProfileApply(nil)
    check(result?.contains("handoff cancelled") == true, "stale \(axis) callback was not discarded")
    check(app.fenceCount == 0 && callbackResumeCount == 0 && callbacksPaused,
          "stale \(axis) callback fenced or resumed callbacks")
    check(!events.contains("restore-proxy-group") && !events.contains("recreate-proxy-menu") &&
          !events.contains("sync-config"), "stale \(axis) callback mutated selection or menu state")
}
print("PASS: stale session interaction remote context ownership and lifecycle callbacks are discarded")

// The helper's initial guard must avoid scheduling work when ownership is already stale.
resetHarness()
do {
    let app = AppDelegateFixture()
    ConfigManager.shared.isEnhancedModeActive = false
    app.ownsRuntimeControl = false
    clashPauseCallbacks()
    var result: String?
    app.completeBuiltInProfileHandoff(isCurrent: { true }) { result = $0 }
    check(app.profileApplyCallCount == 0 && result?.contains("handoff cancelled") == true,
          "stale ownership scheduled a profile mutation")
}
print("PASS: stale handoff scope is rejected before profile request")

// A failed built-in start is retryable. The next toggle repeats a complete close,
// suspends staging again, and starts the configured core once for that attempt.
resetHarness()
do {
    let app = AppDelegateFixture()
    app.startProxyResults = ["Address already in use on the configured API port", nil]
    app.profileApplyOutcomes = [.fullProfile("profile-A")]
    app.actionToggleEnhancedMode(nil)
    wait({ app.presentErrorCount == 1 }, "failed start close did not settle")
    check(app.startProxyCallCount == 1 && app.profileApplyCallCount == 0,
          "failed close did not call startProxy once or attempted profile apply after start failure")
    check(app.lastToggleError == "Address already in use on the configured API port",
          "start failure was replaced before reaching the toggle completion")
    check(callbacksPaused && callbackResumeCount == 0,
          "failed configured start resumed callbacks before profile verification")
    check(Settings.enhancedMode == false && app.enhancedModeMenuItem.state == .mixed,
          "failed configured start did not preserve local preference and retry state")
    let firstAttemptEnd = events.count
    let previousRefreshCount = events.filter { $0 == "post-toggle-refresh" }.count
    app.actionToggleEnhancedMode(nil)
    wait({ events.filter { $0 == "post-toggle-refresh" }.count == previousRefreshCount + 1 },
         "full close retry did not complete")
    check(app.startProxyCallCount == 2 && app.profileApplyCallCount == 1,
          "retry did not execute one new start and the full profile apply")
    let retryEvents = Array(events.dropFirst(firstAttemptEnd))
    check(retryEvents.filter { $0 == "suspend-core" }.count == 1 &&
          retryEvents.filter { $0 == "start-proxy-call-2" }.count == 1,
          "retry did not suspend staging and call configured start exactly once")
    let retrySuspend = retryEvents.firstIndex(of: "suspend-core")
    let retryStart = retryEvents.firstIndex(of: "start-proxy-call-2")
    check(retrySuspend != nil && retryStart != nil && retrySuspend! < retryStart!,
          "retry called configured start before suspending its staging core")
    check(!callbacksPaused && callbackResumeCount == 1 && ConfigManager.shared.isRunning,
          "retry did not complete the verified full-profile path")
    check(app.fenceCount == 0 && Settings.enhancedMode == false &&
          app.enhancedModeMenuItem.state == .off,
          "completed retry retained failure preference or mixed state")
}
print("PASS: failed close retry repeats the complete local handoff exactly once")

// If external stop is unconfirmed, the close must retain enhanced ownership and
// never attempt a built-in start or resume callbacks.
resetHarness()
do {
    let app = AppDelegateFixture()
    app.stopExternalError = "external stop was not confirmed"
    app.actionToggleEnhancedMode(nil)
    wait({ app.presentErrorCount == 1 }, "unconfirmed external stop did not settle")
    check(app.startProxyCallCount == 0 && app.profileApplyCallCount == 0,
          "unconfirmed external stop attempted built-in resume")
    check(callbackPauseCount == 0 && callbackResumeCount == 0 && !events.contains("suspend-core"),
          "unconfirmed external stop paused/resumed or suspended the wrong core")
    check(app.enhancedModeOwnershipBlock != nil && Settings.enhancedMode,
          "unconfirmed external ownership was not retained for retry")
}
print("PASS: unconfirmed external stop never resumes the built-in core")

// Claude lock or an explicit enhanced-mode preference routes a stopped-core retry
// to enhanced startup. It must not resume the built-in staging core or show lock UI.
for retryReason in ["claude-lock", "enhanced-preference"] {
    resetHarness()
    let app = AppDelegateFixture()
    ConfigManager.shared.isRunning = false
    app.isBuiltInCoreResumeRetryAvailable = true
    if retryReason == "claude-lock" {
        Settings.claudeProxyLockEnabled = true
        Settings.enhancedMode = false
    } else {
        Settings.claudeProxyLockEnabled = false
        Settings.enhancedMode = true
    }
    app.actionToggleEnhancedMode(nil)
    check(app.enableEnhancedModeCount == 1 && app.protectionNoticeCount == 0,
          "\(retryReason) stopped-core retry did not route directly to enhanced startup")
    check(app.startProxyCallCount == 0 && app.profileApplyCallCount == 0 &&
          !events.contains("suspend-core") && callbackResumeCount == 0,
          "\(retryReason) retry attempted built-in staging resume")
}
print("PASS: Claude-locked and enhanced-preference retries route directly to enhanced startup")

print("PASS: isolated built-in handoff, close, and retry scenarios used in-memory substitutes only")
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", choices=["bootstrap-resume", "duplicate-start"])
    args = parser.parse_args()

    delegate = (ROOT / "ClashFX/AppDelegate.swift").read_text()
    disable = extract(delegate, "    private func disableEnhancedMode(")
    handoff = extract(delegate, "    private func completeBuiltInProfileHandoff(")
    toggle = extract(delegate, "    @IBAction func actionToggleEnhancedMode(")

    expected_negative_failure = None
    if args.negative_control == "bootstrap-resume":
        handoff = replace_once(
            handoff,
            "guard completeProfile else {",
            "if false {",
            "complete-profile fence",
        )
        expected_negative_failure = "bootstrap profile was not fenced"
    elif args.negative_control == "duplicate-start":
        disable = replace_once(
            disable,
            "                clashSuspendCore()\n                if let resumeError = self.startProxy() {",
            "                clashSuspendCore()\n                _ = self.startProxy()\n                if let resumeError = self.startProxy() {",
            "single configured start call",
        )
        expected_negative_failure = "close invoked startProxy more than once"

    swift = (
        PRELUDE.replace("// EXTRACTED_DISABLE", disable)
        .replace("// EXTRACTED_HANDOFF", handoff)
        .replace("// EXTRACTED_TOGGLE", toggle)
        + TESTS
    )
    with tempfile.TemporaryDirectory(prefix="clashfx-builtin-handoff-") as temp:
        directory = Path(temp)
        source = directory / "main.swift"
        source.write_text(swift)
        binary = directory / "harness"
        target = f"{platform.machine()}-apple-macosx12.0"
        subprocess.run(
            ["swiftc", "-swift-version", "5", "-target", target, str(source), "-o", str(binary)],
            check=True,
        )
        result = subprocess.run(
            [str(binary)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if expected_negative_failure is None:
            if result.returncode != 0:
                print(result.stdout, end="")
                print(result.stderr, end="", file=sys.stderr)
                raise SystemExit(result.returncode)
            print(result.stdout, end="")
            return
        if result.returncode == 0 or expected_negative_failure not in result.stderr:
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            raise AssertionError(
                f"negative control {args.negative_control} did not trigger its expected assertion"
            )
        print(
            f"PASS: negative-control {args.negative_control} was caught by assertion: "
            f"{expected_negative_failure}"
        )


if __name__ == "__main__":
    main()

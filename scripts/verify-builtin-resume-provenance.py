#!/usr/bin/env python3
"""Exercise built-in resume provenance using extracted production Swift methods.

The harness compiles the real recovery/lifecycle methods plus the production
readback policy, transaction controller, and apply-diagnostic sanitizer. All
core, process, menu, and application bridges are in-memory stand-ins. The only
files created in the simulated app-private config directory are the production
method's temporary frozen-recovery snapshot; transaction-controller receipts
live in a separate private harness directory.
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
                return source[start : end + 1].replace("private func ", "func ", 1)
    raise AssertionError("unterminated " + signature)


PRELUDE = r'''
import Foundation
import Darwin
import Dispatch

typealias ErrorString = String
enum Level { case error, warning, info }
enum Logger {
    static var messages = [String]()
    static func log(_ text: String, level: Level = .info) { messages.append(text) }
}

/// The fixtures below are JSON documents, which are also valid YAML 1.2.
/// This adapter deliberately supports only that fixture subset.
enum Yams {
    static func load(yaml: String) throws -> Any? {
        guard let data = yaml.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    static func dump(object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "harness", code: 1)
        }
        return text
    }
}

struct BridgeString {
    let value: String
    func toString() -> String { value }
}
extension String { func goStringBuffer() -> String { self } }

let defaultConfigText = #"{"external-controller":"127.0.0.1:19097","secret":"new-api-secret","mixed-port":7900,"port":7902,"socks-port":7901,"mode":"rule","log-level":"info","allow-lan":false,"bind-address":"*","tun":{"enable":false},"proxies":[{"name":"default-node","type":"direct"}],"proxy-groups":[{"name":"DEFAULT","type":"select","proxies":["default-node"]}]}"#
let workConfigText = #"{"external-controller":"127.0.0.1:18097","secret":"old-work-secret","mixed-port":17890,"port":17892,"socks-port":17891,"mode":"rule","log-level":"debug","allow-lan":true,"bind-address":"0.0.0.0","tun":{"enable":false},"proxies":[{"name":"work-node","type":"socks5","server":"127.0.0.1","port":28888}],"proxy-groups":[{"name":"work-group","type":"select","proxies":["work-node"]}]}"#
let defaultRoot = (try! Yams.load(yaml: defaultConfigText)) as! [String: Any]
let workRoot = (try! Yams.load(yaml: workConfigText)) as! [String: Any]

var events = [String]()
var recoveryCheckpointEvents = [String]()
var liveRuntimeConfig: [String: Any] = defaultRoot
var bridgeMetadata: String? = defaultConfigText
var overrideMetadataAfterResume = false
var metadataAfterResume: String?
var appliedSnapshotText: String?
var appliedSnapshotRoot: [String: Any]?
var bridgeSessionIPv6: Bool?
var bridgeApplyReply: String? = "success"
var bridgeResumeReply: String? = "success"
var bridgeReadbackMutation: ((inout [String: Any]) -> Void)?
var resumeCallCount = 0
var fakeProcessRunCount = 0

func stringify(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
    return String(data: data, encoding: .utf8)
}
func clashGetLastSubmittedConfig() -> BridgeString? {
    bridgeMetadata.map { BridgeString(value: $0) }
}
func clashGetConfigs() -> BridgeString? {
    var root = liveRuntimeConfig
    bridgeReadbackMutation?(&root)
    return stringify(root).map { BridgeString(value: $0) }
}
func clashUpdateConfig(_ path: String) -> BridgeString? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let root = (try? Yams.load(yaml: text)) as? [String: Any] else {
        return BridgeString(value: "error: test bridge could not read frozen snapshot")
    }
    appliedSnapshotText = text
    appliedSnapshotRoot = root
    if bridgeApplyReply == "success" {
        liveRuntimeConfig = root
        // The production Go bridge pins this scalar to its run/resume session,
        // even when a frozen YAML checkpoint asks for the older preference.
        if let bridgeSessionIPv6 { liveRuntimeConfig["ipv6"] = bridgeSessionIPv6 }
        bridgeMetadata = text
    }
    return bridgeApplyReply.map { BridgeString(value: $0) }
}
func clashResumeCore() -> UnsafeMutablePointer<CChar>? {
    resumeCallCount += 1
    liveRuntimeConfig = defaultRoot
    bridgeMetadata = overrideMetadataAfterResume ? metadataAfterResume : defaultConfigText
    return bridgeResumeReply.flatMap { strdup($0) }
}
func clashSuspendCore() {
    events.append("suspend")
    liveRuntimeConfig = defaultRoot
    bridgeMetadata = defaultConfigText
    overrideMetadataAfterResume = false
    metadataAfterResume = nil
}
func clashPauseCallbacks() { events.append("pause-callbacks") }
func clashResumeCallbacks() { events.append("resume-callbacks") }

struct CurrentConfig {
    var usedHttpPort: Int
    var usedSocksPort: Int
    var mode: Mode = .rule
}
enum Mode { case rule, direct }
final class Flag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
    func accept(_ value: Bool) { self.value = value }
}
final class ConfigManager {
    static let shared = ConfigManager()
    static var selectConfigName = "work"
    var apiPort = "19097"
    var apiSecret = "new-api-secret"
    var isEnhancedModeActive = false
    var isRunning = true
    var currentConfig: CurrentConfig? = CurrentConfig(usedHttpPort: 7900, usedSocksPort: 7901)
    var proxyPortAutoSet = true
    var proxyShouldPaused = Flag(false)
    var isProxySetByOtherVariable = Flag(false)
}
enum Settings {
    static var enhancedMode = false
    static var claudeProxyLockEnabled = false
}
struct RemoteFixture { let uuid: String }
enum RemoteControlManager { static var selectConfig: RemoteFixture? }
struct SystemProxyRecoveryObservation {
    let scope: String
    let shouldProtect: Bool
    let isPaused: Bool
    let isReady: Bool
    let matches: Bool
    let ownsRuntime: Bool
}
enum NetworkChangeNotifier {
    static func getPrimaryInterface() -> String? { "harness-interface" }
    static func isCurrentSystemSetToClash() -> Bool { true }
}
final class PrivilegedHelperManager {
    static let shared = PrivilegedHelperManager()
    let isHelperCheckFinished = Flag(true)
}

/// These names intentionally shadow the imported process/UI entry points.
/// No Foundation.Process or AppKit operation is invoked by this harness.
struct InjectedLaunchFailure: LocalizedError {
    var errorDescription: String? { "injected launch-helper failure token=launch-canary" }
}
final class Process {
    var executableURL: URL?
    var arguments: [String] = []
    func run() throws {
        fakeProcessRunCount += 1
        events.append("launch-helper-attempt")
        throw InjectedLaunchFailure()
    }
}
final class NSMenuItem {
    var isEnabled = true
    let title: String
    init(title: String, action: Any?, keyEquivalent: String) { self.title = title }
}
final class NSMenu {
    var items = [NSMenuItem]()
    func addItem(_ item: NSMenuItem) { items.append(item) }
}
final class StatusItemFixture { var menu: NSMenu? }
final class HarnessApplication {
    var terminationRequested = false
    func terminate(_ sender: Any?) { terminationRequested = true; events.append("terminate") }
}
let NSApp = HarnessApplication()
enum NSAlert {
    static var messages = [String]()
    static func alert(with message: String) { messages.append(message); events.append("alert") }
}
final class NSUserNotificationCenter {
    static let `default` = NSUserNotificationCenter()
    static var notices = [String]()
    func postConfigErrorNotice(msg: String) {
        Self.notices.append(msg)
        events.append("config-error-notice")
    }
}

final class ApiRequest {
    static var cancellationCount = 0
    static func cancelRuntimeConfigOperations() { cancellationCount += 1 }
}

// RESUME_GATE_TYPE

var kConfigFolderPath = ""
final class AppDelegateFixture {
    static func competingRuntimePID() -> Int? { nil }
    var runtimeConfigurationScope = "built-in-session"
    var runtimeConfigTransactions: RuntimeConfigTransactionController!
    var confirmedRuntimeProfileName: String?
    var builtInRecoveryCheckpoint: Data?
    var builtInRecoveryProfileName: String?
    var runtimeCoreSessionID = UUID()
    var isCoreConfigSnapshotVerified = true
    var isBuiltInCoreResumeRetryAvailable = false
    var automaticRecoverySelections: [String: String]?
    var automaticRecoveryNeedsRetry = false
    var enhancedModeOwnershipBlock: UUID?
    var ownsRuntimeControl = true
    var isRestarting = false
    var isTerminating = false
    var wakeSystemProxyRecoveryRequested = true
    var isStartupProxyRecoveryActive = false
    var startupSystemProxyHealthVerified = true
    var isConfigUpdating = false
    var isConfigUpdateQueued = false
    var isRestoringProxySelection = false
    var userSystemProxyChangeInProgress = false
    var isEnhancedModeTransitionInProgress = false
    var claudeLockChange: String?
    var statusItem: StatusItemFixture! = StatusItemFixture()
    var statusMenu = NSMenu()

    init(transactionDirectory: URL) {
        runtimeConfigTransactions = RuntimeConfigTransactionController(directory: transactionDirectory)
        statusItem?.menu = NSMenu()
    }
    func listenPort(from address: String) -> Int {
        Int(address.split(separator: ":").last ?? "") ?? 0
    }
    func cancelDeferredConfigUpdate(reason: String) { events.append("cancel-deferred") }
    func invalidateProxyInteractionScope(reason: String) { events.append("invalidate-proxy-scope") }
    func refreshStatusItemViewStatus() { events.append("refresh-status") }
    func cleanupEnhancedModeForTermination(completion: @escaping (String?) -> Void) { completion(nil) }
    func restoreEnhancedModeIfNeeded() { events.append("restore-enhanced") }

    // CAPTURE_METHOD
    // RECOVERY_METHOD
    // FENCE_METHOD
    // RESUME_METHOD
    // RESUME_CALLBACK_METHOD
    // RESTART_METHOD
    // OBSERVATION_METHOD
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
func waitUntil(_ condition: () -> Bool, _ message: String) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    check(condition(), message)
}
func assertBusyRestartBlocked(_ app: AppDelegateFixture, label: String) {
    let checkpoint = app.builtInRecoveryCheckpoint
    let profile = app.builtInRecoveryProfileName
    let confirmedProfile = app.confirmedRuntimeProfileName
    let session = app.runtimeCoreSessionID
    events = []
    recoveryCheckpointEvents = []
    Logger.messages = []
    NSAlert.messages = []
    NSUserNotificationCenter.notices = []
    fakeProcessRunCount = 0
    resumeCallCount = 0
    app.restartApp()
    check(app.builtInRecoveryCheckpoint == checkpoint && checkpoint != nil,
          "\(label) restart cleared the existing recovery checkpoint")
    check(app.builtInRecoveryProfileName == profile && app.confirmedRuntimeProfileName == confirmedProfile,
          "\(label) restart cleared existing profile provenance")
    check(recoveryCheckpointEvents.isEmpty && !events.contains("capture"),
          "\(label) restart captured a checkpoint while configuration was busy")
    check(!events.contains("suspend") && !events.contains("pause-callbacks") &&
          !events.contains("launch-helper-attempt") && !events.contains("terminate"),
          "\(label) restart suspended or launched while configuration was busy")
    check(fakeProcessRunCount == 0 && resumeCallCount == 0 && !NSApp.terminationRequested,
          "\(label) restart entered helper/core lifecycle while configuration was busy")
    check(!app.isRestarting && ConfigManager.shared.isRunning && app.runtimeCoreSessionID == session,
          "\(label) restart changed runtime lifecycle state")
    check(NSUserNotificationCenter.notices.count == 1 && events == ["config-error-notice"],
          "\(label) restart did not issue exactly one non-modal error notice")
    check(NSAlert.messages.isEmpty,
          "\(label) restart displayed a modal alert instead of a notification")
    check(Logger.messages.contains { $0.contains("stage=restart outcome=blocked") },
          "\(label) restart did not log the busy guard")
}
func resetBridges() {
    events = []
    recoveryCheckpointEvents = []
    liveRuntimeConfig = defaultRoot
    bridgeMetadata = defaultConfigText
    appliedSnapshotText = nil
    appliedSnapshotRoot = nil
    bridgeApplyReply = "success"
    bridgeSessionIPv6 = nil
    bridgeResumeReply = "success"
    overrideMetadataAfterResume = false
    metadataAfterResume = nil
    bridgeReadbackMutation = nil
    resumeCallCount = 0
    fakeProcessRunCount = 0
    ApiRequest.cancellationCount = 0
    Logger.messages = []
    NSAlert.messages = []
    NSUserNotificationCenter.notices = []
    NSApp.terminationRequested = false
    ConfigManager.selectConfigName = "work"
    ConfigManager.shared.apiPort = "19097"
    ConfigManager.shared.apiSecret = "new-api-secret"
    ConfigManager.shared.isEnhancedModeActive = false
    ConfigManager.shared.isRunning = true
    ConfigManager.shared.currentConfig = CurrentConfig(usedHttpPort: 7900, usedSocksPort: 7901)
    ConfigManager.shared.proxyPortAutoSet = true
    ConfigManager.shared.proxyShouldPaused = Flag(false)
    Settings.enhancedMode = false
    Settings.claudeProxyLockEnabled = false
    RemoteControlManager.selectConfig = nil
    kConfigFolderPath = CommandLine.arguments[1] + "/app-private"
    try! FileManager.default.createDirectory(atPath: kConfigFolderPath,
                                              withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
}
func newApp() -> AppDelegateFixture {
    let txDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        .appendingPathComponent("transactions-\(UUID().uuidString)", isDirectory: true)
    return AppDelegateFixture(transactionDirectory: txDirectory)
}
func seedVerifiedWork(_ app: AppDelegateFixture) throws {
    liveRuntimeConfig = workRoot
    ConfigManager.shared.currentConfig = CurrentConfig(usedHttpPort: 17890, usedSocksPort: 17891)
    _ = try app.runtimeConfigTransactions.adoptConfirmed(
        data: Data(workConfigText.utf8), scope: app.runtimeConfigurationScope
    )
    app.confirmedRuntimeProfileName = "work"
    app.isCoreConfigSnapshotVerified = true
}
func appPrivateFiles() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: kConfigFolderPath)) ?? []
}
func root(_ data: Data?) -> [String: Any]? {
    guard let data, let value = try? JSONSerialization.jsonObject(with: data),
          let dictionary = value as? [String: Any] else { return nil }
    return dictionary
}
func assertWorkSnapshot(_ value: [String: Any]?, endpoint: String, label: String) {
    guard let value else { check(false, "\(label) snapshot was not recorded"); return }
    check(RuntimeConfigReadbackPolicy.port(value["mixed-port"]) == 17890,
          "\(label) snapshot lost work mixed-port")
    check(RuntimeConfigReadbackPolicy.port(value["socks-port"]) == 17891,
          "\(label) snapshot lost work socks-port")
    check(value["external-controller"] as? String == endpoint,
          "\(label) snapshot did not use the expected API endpoint")
    let proxies = value["proxies"] as? [[String: Any]] ?? []
    let groups = value["proxy-groups"] as? [[String: Any]] ?? []
    check(proxies.contains { $0["name"] as? String == "work-node" },
          "\(label) snapshot lost the work proxy")
    check(groups.contains { $0["name"] as? String == "work-group" },
          "\(label) snapshot lost the work policy group")
}
'''


TESTS = r'''
resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = nil
    app.confirmedRuntimeProfileName = "stale-work"
    let error = app.checkedResumeBuiltInCore()
    check(app.confirmedRuntimeProfileName == nil,
          "resume with no checkpoint retained the prior confirmed profile identity")
    check(error?.contains("no verified profile") == true && !ConfigManager.shared.isRunning &&
          app.isBuiltInCoreResumeRetryAvailable && !app.isCoreConfigSnapshotVerified && events.contains("suspend"),
          "no-checkpoint fallback was not fenced and left retryable")
    // Even a later stale metadata callback cannot supply profile provenance.
    app.isCoreConfigSnapshotVerified = true
    let observation = app.systemProxyRecoveryObservation()
    check(!observation.isReady, "startup baseline passed the automatic system-proxy profile gate")
    check(ConfigManager.shared.apiPort == "19097" && ConfigManager.shared.apiSecret == "new-api-secret",
          "baseline resume did not retain fresh metadata API details")
    check(RuntimeConfigBaselineKind(confirmedProfile: app.confirmedRuntimeProfileName) == .startup,
          "checkpoint-free resume was not classified as startup baseline")
    print("PASS: no-checkpoint fallback is stopped and retryable, with no stale profile or automatic proxy recovery")
}

for unavailableCore in ["stopped", "enhanced"] {
    resetBridges()
    let app = newApp()
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    ConfigManager.shared.isRunning = unavailableCore != "stopped"
    ConfigManager.shared.isEnhancedModeActive = unavailableCore == "enhanced"
    bridgeMetadata = defaultConfigText
    liveRuntimeConfig = defaultRoot
    let checkpoint = app.builtInRecoveryCheckpoint
    app.captureBuiltInRecoveryCheckpoint()
    check(app.builtInRecoveryCheckpoint == checkpoint && app.builtInRecoveryProfileName == "work",
          "unavailable built-in capture replaced the frozen verified profile")
    check(!events.contains("capture"), "unavailable built-in capture read a live replacement snapshot")
}
print("PASS: stopped-core and enhanced-core retries preserve the frozen built-in graph and profile identity")

for busyKind in ["updating", "queued"] {
    resetBridges()
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    app.confirmedRuntimeProfileName = "work"
    if busyKind == "updating" { app.isConfigUpdating = true }
    else { app.isConfigUpdateQueued = true }
    assertBusyRestartBlocked(app, label: "config-\(busyKind)")
}
print("PASS: updating and queued configuration block restart without disturbing the checkpoint")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    app.confirmedRuntimeProfileName = "work"
    var heldValidation: ((String?) -> Void)?
    let client = RuntimeConfigTransactionController.Client(
        validate: { _, completion in heldValidation = completion },
        apply: { _, completion in completion(.accepted) },
        verify: { _, completion in completion(.verified(.notChecked)) }
    )
    app.runtimeConfigTransactions.submit(
        data: Data(workConfigText.utf8), scope: app.runtimeConfigurationScope,
        isCurrent: { true }, client: client
    ) { _ in }
    waitUntil({ heldValidation != nil }, "production transaction controller did not enter active validation")
    check(app.runtimeConfigTransactions.isBusy,
          "production transaction controller did not expose an active operation")
    assertBusyRestartBlocked(app, label: "active-runtime-transaction")
    app.runtimeConfigTransactions.invalidate()
    heldValidation = nil
    check(!app.runtimeConfigTransactions.isBusy,
          "harness failed to release the active transaction after the guard assertion")
}
print("PASS: active production runtime transaction blocks restart without capture or suspension")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    app.confirmedRuntimeProfileName = "stale-before-resume"
    check(app.checkedResumeBuiltInCore() == nil, "valid checkpoint resume failed")
    assertWorkSnapshot(root(appliedSnapshotText?.data(using: .utf8)), endpoint: "127.0.0.1:19097", label: "applied")
    check(ConfigManager.shared.apiPort == "19097" && ConfigManager.shared.apiSecret == "new-api-secret",
          "valid restore replaced the fresh core API endpoint or secret")
    check(app.confirmedRuntimeProfileName == "work", "verified restore did not restore the profile identity")
    // checkedResume intentionally leaves the metadata snapshot unverified until sync completes.
    app.isCoreConfigSnapshotVerified = true
    check(app.systemProxyRecoveryObservation().isReady,
          "a fully verified work profile was incorrectly blocked by the automatic proxy gate")
    check(Logger.messages.contains { $0.contains("baseline_kind=profile") },
          "verified profile restore did not record profile baseline kind")
    check(appPrivateFiles().isEmpty, "recovery temp directory retained a temporary file")
    print("RECORDED_APPLIED mixed-port=17890 socks-port=17891 endpoint=127.0.0.1:19097 proxy=work-node group=work-group")
    print("PASS: checkpoint restore reapplies full work config, adopts fresh API endpoint, and passes proxy gate")
}

// A fresh run may use a different IPv6 preference from the frozen routing graph.
for enabled in [false, true] {
    resetBridges()
    let app = newApp()
    var checkpoint = workRoot
    checkpoint["ipv6"] = !enabled
    app.builtInRecoveryCheckpoint = Data(stringify(checkpoint)!.utf8)
    app.builtInRecoveryProfileName = "work"
    var metadata = defaultRoot
    metadata["ipv6"] = enabled
    bridgeSessionIPv6 = enabled
    overrideMetadataAfterResume = true
    metadataAfterResume = stringify(metadata)
    let error = app.checkedResumeBuiltInCore()
    check(error == nil && ConfigManager.shared.isRunning && app.confirmedRuntimeProfileName == "work",
          "session IPv6 mismatch falsely rejected a valid frozen profile")
    check(appliedSnapshotRoot?["ipv6"] as? Bool == enabled,
          "recovery YAML did not preserve the fresh built-in session IPv6 setting")
    assertWorkSnapshot(root(appliedSnapshotText?.data(using: .utf8)), endpoint: "127.0.0.1:19097", label: "IPv6-adjusted")
    check(!events.contains("suspend"), "valid IPv6-adjusted restore fenced the core")
}
print("PASS: frozen profiles adopt current built-in session IPv6 in both directions without losing the routing graph")

for metadataCase in ["missing", "invalid"] {
    resetBridges()
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    overrideMetadataAfterResume = true
    if metadataCase == "missing" { metadataAfterResume = nil }
    else { metadataAfterResume = #"{"secret":"new-api-secret","mode":"rule"}"# }
    let error = app.checkedResumeBuiltInCore()
    check(error != nil, "\(metadataCase) metadata with checkpoint did not fail")
    check(app.confirmedRuntimeProfileName == nil && !ConfigManager.shared.isRunning && !app.isCoreConfigSnapshotVerified,
          "\(metadataCase) metadata failure retained profile identity or skipped the recovery fence")
    check(events.contains("suspend"), "\(metadataCase) metadata failure did not suspend the core")
    check(appPrivateFiles().isEmpty, "\(metadataCase) metadata failure left a recovery temp file")
}
print("PASS: missing and invalid resume metadata fence the core without stale identity")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    app.confirmedRuntimeProfileName = "stale-before-resume"
    // GoRawConfig serializes this field without omitempty; an empty string is valid.
    overrideMetadataAfterResume = true
    metadataAfterResume = #"{"external-controller":"","secret":""}"#
    check(app.checkedResumeBuiltInCore() == nil,
          "empty external-controller metadata incorrectly rejected the full checkpoint")
    assertWorkSnapshot(appliedSnapshotRoot, endpoint: "", label: "direct-only restore")
    check(app.confirmedRuntimeProfileName == "work",
          "empty external-controller metadata did not restore the verified work identity")
    check(ConfigManager.shared.isRunning && !events.contains("suspend"),
          "empty external-controller metadata incorrectly fenced the resumed core")
    check(Logger.messages.contains { $0.contains("baseline_kind=profile") },
          "empty external-controller metadata did not record a verified profile baseline")
}
print("PASS: empty external-controller metadata accepts and verifies a full direct-only checkpoint")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data("not-json".utf8)
    app.builtInRecoveryProfileName = "work"
    let error = app.checkedResumeBuiltInCore()
    check(error != nil && app.confirmedRuntimeProfileName == nil && !ConfigManager.shared.isRunning,
          "invalid checkpoint did not clear provenance and fence the core")
    check(events.contains("suspend"), "invalid checkpoint did not suspend the core")
}
print("PASS: invalid frozen checkpoint fences the resumed core")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    bridgeApplyReply = "error: token=apply-canary"
    let error = app.checkedResumeBuiltInCore() ?? ""
    check(error.contains("[redacted]") && !error.contains("apply-canary"),
          "checkpoint apply rejection did not return a sanitized original reason")
    check(Logger.messages.contains { $0.contains("stage=resume_apply") },
          "checkpoint apply rejection did not log the dedicated resume_apply stage")
    check(!Logger.messages.joined().contains("apply-canary"), "checkpoint apply token reached logs")
    check(app.confirmedRuntimeProfileName == nil && !ConfigManager.shared.isRunning && events.contains("suspend"),
          "checkpoint apply rejection retained old profile identity or skipped fencing")
    check(appPrivateFiles().isEmpty, "rejected apply retained its temporary frozen snapshot")
}
print("PASS: rejected checkpoint apply preserves a safe reason and fences without leaking token canary")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    bridgeReadbackMutation = { $0["mixed-port"] = 19999 }
    let error = app.checkedResumeBuiltInCore()
    check(error?.contains("could not be restored and verified") == true,
          "readback mismatch did not take the independent verification failure path")
    check(!Logger.messages.contains { $0.contains("stage=resume_apply") },
          "readback mismatch was mislabeled as an apply rejection")
    check(app.confirmedRuntimeProfileName == nil && !ConfigManager.shared.isRunning && events.contains("suspend"),
          "readback mismatch retained stale identity or skipped fencing")
}
print("PASS: successful apply with mismatched readback takes the separate fence path")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.confirmedRuntimeProfileName = "work"
    app.automaticRecoverySelections = ["group": "node"]
    let before = (app.confirmedRuntimeProfileName, ConfigManager.shared.isRunning,
                  app.isCoreConfigSnapshotVerified, app.runtimeCoreSessionID)
    check(app.checkedResumeBuiltInCore() != nil, "automatic-recovery guard did not reject built-in resume")
    check(resumeCallCount == 0 && app.confirmedRuntimeProfileName == before.0 &&
          ConfigManager.shared.isRunning == before.1 && app.isCoreConfigSnapshotVerified == before.2 &&
          app.runtimeCoreSessionID == before.3,
          "automatic-recovery guard touched resume or existing runtime state")
}
resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.confirmedRuntimeProfileName = "work"
    app.enhancedModeOwnershipBlock = UUID()
    let beforeSession = app.runtimeCoreSessionID
    check(app.checkedResumeBuiltInCore() != nil, "ownership guard did not reject built-in resume")
    check(resumeCallCount == 0 && app.confirmedRuntimeProfileName == "work" &&
          ConfigManager.shared.isRunning && app.isCoreConfigSnapshotVerified && app.runtimeCoreSessionID == beforeSession,
          "ownership guard touched resume or cleared existing profile state")
}
print("PASS: automatic-recovery and ownership guards leave existing state untouched")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.confirmedRuntimeProfileName = "work"
    bridgeResumeReply = "error: token=resume-canary"
    let error = app.checkedResumeBuiltInCore() ?? ""
    check(error.contains("[redacted]") && !error.contains("resume-canary"),
          "failed core resume returned an unsanitized original response")
    check(!Logger.messages.joined().contains("resume-canary"), "failed core resume token reached logs")
    check(app.confirmedRuntimeProfileName == nil && !ConfigManager.shared.isRunning,
          "failed core resume retained stale profile identity")
}
print("PASS: failed core resume sanitizes its response before returning or logging")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    bridgeResumeReply = "error: token=resume-canary"
    let error = app.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: true)
    check(error?.contains("[redacted]") == true,
          "failed built-in resume did not preserve the sanitized bridge error")
    check(resumeCallCount == 1 && !ConfigManager.shared.isRunning &&
          app.isBuiltInCoreResumeRetryAvailable,
          "failed built-in resume did not leave the stopped core retryable")
    check(!events.contains("resume-callbacks"),
          "failed built-in resume resumed callbacks after the bridge error")
}
print("PASS: callback recovery leaves callbacks paused after a built-in bridge resume error")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = nil
    let error = app.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: true)
    check(error?.contains("no verified profile") == true,
          "missing checkpoint did not return the verified-profile fence error")
    check(resumeCallCount == 1 && events.contains("suspend") &&
          !ConfigManager.shared.isRunning && app.isBuiltInCoreResumeRetryAvailable,
          "missing checkpoint did not fence the resumed core and leave it retryable")
    check(!events.contains("resume-callbacks"),
          "missing checkpoint resumed callbacks before a full profile was verified")
}
print("PASS: missing-checkpoint recovery fences the core without resuming callbacks")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    let gate = EnhancedModeCoreResumeGate()
    let firstError = app.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: true, resumeGate: gate)
    let secondError = app.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: true, resumeGate: gate)
    check(firstError == nil && secondError == nil,
          "repeated gated recovery did not return the successful resume result")
    check(resumeCallCount == 1,
          "repeated gated recovery resumed the built-in core more than once")
    check(events.filter { $0 == "resume-callbacks" }.count == 1,
          "repeated gated recovery did not resume callbacks exactly once")
    check(ConfigManager.shared.isRunning && app.confirmedRuntimeProfileName == "work" &&
          !events.contains("suspend"),
          "gated callback resume did not retain the verified full profile")
}
print("PASS: a repeated resume gate restores a full checkpoint and resumes callbacks once")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.builtInRecoveryCheckpoint = Data(workConfigText.utf8)
    app.builtInRecoveryProfileName = "work"
    bridgeResumeReply = "error: token=first-resume-canary"
    let failedGate = EnhancedModeCoreResumeGate()
    let firstError = app.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: true, resumeGate: failedGate)
    let repeatedError = app.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: true, resumeGate: failedGate)
    check(firstError != nil && repeatedError == firstError,
          "same-gate retry did not return the memoized bridge failure")
    check(resumeCallCount == 1 && !events.contains("resume-callbacks"),
          "same-gate retry retried the bridge or resumed callbacks after failure")

    bridgeResumeReply = "success"
    let stillFailed = app.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: true, resumeGate: failedGate)
    check(stillFailed == firstError && resumeCallCount == 1 && !events.contains("resume-callbacks"),
          "changing the bridge reply allowed a failed gate to retry implicitly")

    let freshGate = EnhancedModeCoreResumeGate()
    let retryError = app.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: true, resumeGate: freshGate)
    check(retryError == nil && resumeCallCount == 2,
          "a fresh explicit retry gate did not perform one new bridge resume")
    check(events.filter { $0 == "resume-callbacks" }.count == 1 &&
          ConfigManager.shared.isRunning && app.confirmedRuntimeProfileName == "work",
          "fresh-gate recovery did not restore the full profile and resume callbacks once")
}
print("PASS: failed resume gate is one-shot; a fresh explicit retry gate can recover once")

resetBridges()
do {
    let app = newApp()
    app.automaticRecoveryNeedsRetry = true
    let error = app.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: true)
    check(error?.contains("Automatic recovery") == true,
          "automatic recovery retry fence did not reject built-in callback recovery")
    check(resumeCallCount == 0 && !events.contains("resume-callbacks"),
          "automatic recovery retry fence touched the bridge or resumed callbacks")
}
print("PASS: automatic-recovery retry guard blocks bridge resume and callback delivery")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.confirmedRuntimeProfileName = "work"
    ConfigManager.shared.isRunning = true
    app.isEnhancedModeTransitionInProgress = false
    RemoteControlManager.selectConfig = nil
    app.restartApp()
    check(fakeProcessRunCount == 1 && events.contains("launch-helper-attempt"),
          "restart did not exercise the injected launch-helper failure")
    check(!NSApp.terminationRequested, "injected helper failure attempted to terminate the harness")
    let captureIndex = events.firstIndex(of: "capture")
    let suspendIndex = events.firstIndex(of: "suspend")
    check(captureIndex != nil && suspendIndex != nil,
          "restart did not record both checkpoint capture and suspension")
    check(captureIndex! < suspendIndex!,
          "restart suspended the core before capturing its frozen profile")
    check(recoveryCheckpointEvents == ["capture:false"],
          "restart captured the checkpoint after isRestarting was set")
    let captured = root(app.builtInRecoveryCheckpoint)
    assertWorkSnapshot(captured, endpoint: "127.0.0.1:18097", label: "captured")
    check(app.builtInRecoveryProfileName == "work", "restart snapshot lost the confirmed work profile name")
    assertWorkSnapshot(appliedSnapshotRoot, endpoint: "127.0.0.1:19097", label: "restart recovery")
    check(app.confirmedRuntimeProfileName == "work" && ConfigManager.shared.isRunning,
          "helper failure did not restore verified work profile state")
    app.isCoreConfigSnapshotVerified = true
    check(app.systemProxyRecoveryObservation().isReady,
          "helper failure recovery left a verified profile blocked from the proxy gate")
    check(appPrivateFiles().isEmpty, "restart recovery left a temporary frozen snapshot")
    print("RECORDED_CAPTURE mixed-port=17890 socks-port=17891 endpoint=127.0.0.1:18097 profile=work proxy=work-node group=work-group")
    print("RECORDED_RESTART_RECOVERY mixed-port=17890 socks-port=17891 endpoint=127.0.0.1:19097 profile=work proxy=work-node group=work-group")
    print("PASS: restart captures work before suspension and restores it after injected helper failure")
}

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    app.confirmedRuntimeProfileName = "work"
    app.restartApp()
    check(app.confirmedRuntimeProfileName == "work" && ConfigManager.shared.isRunning,
          "first helper failure did not restore work")
    if case nil = app.runtimeConfigTransactions.confirmed {} else {
        check(false, "first resume unexpectedly adopted a new transaction receipt")
    }

    // Keep the same app/core state. Clear only observations between retries.
    events = []
    recoveryCheckpointEvents = []
    Logger.messages = []
    NSAlert.messages = []
    appliedSnapshotText = nil
    appliedSnapshotRoot = nil
    fakeProcessRunCount = 0
    app.restartApp()

    let captureIndex = events.firstIndex(of: "capture")
    let suspendIndex = events.firstIndex(of: "suspend")
    check(captureIndex != nil && suspendIndex != nil && captureIndex! < suspendIndex!,
          "second restart did not capture before suspending")
    check(recoveryCheckpointEvents == ["capture:false"],
          "second restart did not capture the live work fallback")
    assertWorkSnapshot(root(app.builtInRecoveryCheckpoint),
                       endpoint: "127.0.0.1:18097", label: "second captured")
    assertWorkSnapshot(appliedSnapshotRoot,
                       endpoint: "127.0.0.1:19097", label: "second restart recovery")
    check(app.builtInRecoveryProfileName == "work" && app.confirmedRuntimeProfileName == "work",
          "second helper failure lost the previously confirmed work profile name")
    check(ConfigManager.shared.isRunning,
          "second helper failure fenced the successfully restored work runtime")
    if case nil = app.runtimeConfigTransactions.confirmed {} else {
        check(false, "second resume unexpectedly adopted a transaction receipt")
    }
}
print("PASS: repeated helper failures preserve the work graph and profile provenance")

resetBridges()
do {
    let app = newApp()
    try seedVerifiedWork(app)
    var preserved = workRoot
    preserved["test-frozen-marker"] = "preserve-during-transition"
    app.builtInRecoveryCheckpoint = Data(try Yams.dump(object: preserved).utf8)
    app.builtInRecoveryProfileName = "work"
    app.confirmedRuntimeProfileName = "work"
    app.isEnhancedModeTransitionInProgress = true
    app.restartApp()
    check(recoveryCheckpointEvents.isEmpty,
          "restart recaptured a checkpoint while Enhanced Mode transition was in progress")
    check(appliedSnapshotRoot?["test-frozen-marker"] as? String == "preserve-during-transition",
          "transition-time restart replaced the previously frozen checkpoint")
    check(app.confirmedRuntimeProfileName == "work" && ConfigManager.shared.isRunning,
          "transition-time restart did not recover the preserved work checkpoint")
}
print("PASS: transition-time restart preserves the previously frozen checkpoint without recapturing")

print("PASS: isolated built-in resume provenance scenarios; only in-memory core/process/UI substitutes were used")
'''


def replace_once(source, old, new, label):
    count = source.count(old)
    if count != 1:
        raise AssertionError(f"expected one {label} insertion point, found {count}")
    return source.replace(old, new, 1)


def assert_readiness_failure_uses_canonical_resume(delegate):
    start_marker = "External core failed readiness checks; stopping the current launch before rollback"
    end_marker = "self.noteEnhancedModeOwnershipBlocked(block, error: stopError)"
    if delegate.count(start_marker) != 1:
        raise AssertionError("expected one enhanced-mode listener-readiness failure branch")
    start = delegate.index(start_marker)
    if delegate.count(end_marker, start) != 1:
        raise AssertionError("expected one listener-readiness failure completion boundary")
    end = delegate.index(end_marker, start)
    if end <= start:
        raise AssertionError("could not bound the enhanced-mode listener-readiness failure branch")
    branch = delegate[start:end]
    required = (
        "resumeEnhancedModeCallbacksIfNeeded(",
        "alreadySuspended: true",
        "resumeGate: resumeGate",
        "combiningFailure(coreError, resumeError: resumeError)",
    )
    for fragment in required:
        if fragment not in branch:
            raise AssertionError(
                "listener-readiness failure bypasses canonical resume recovery: " + fragment
            )
    forbidden = ("clashResumeCallbacks()", ".startProxy()", "clashReopenCacheDB()")
    for fragment in forbidden:
        if fragment in branch:
            raise AssertionError(
                "listener-readiness failure contains an unsafe direct fallback: " + fragment
            )
    print(
        "PASS: static listener-readiness callsite uses canonical checked resume "
        "(source assertion only; full launch method is not executed)"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--negative-control",
        choices=[
            "missing-clear",
            "missing-capture",
            "missing-live-guard",
            "missing-profile-fence",
            "missing-session-ipv6",
            "premature-callback-resume",
        ],
    )
    args = parser.parse_args()

    delegate = (ROOT / "ClashFX/AppDelegate.swift").read_text()
    capture = extract(delegate, "    private func captureBuiltInRecoveryCheckpoint()")
    recovery = extract(delegate, "    private func restoreBuiltInRecoveryCheckpoint()")
    fence = extract(delegate, "    private func fenceFailedBuiltInRecovery()")
    resume = extract(delegate, "    private func checkedResumeBuiltInCore()")
    resume_gate = extract(delegate, "    private final class EnhancedModeCoreResumeGate").replace(
        "    private final class ", "final class ", 1
    )
    resume_callback_helper = extract(delegate, "    private func resumeEnhancedModeCallbacksIfNeeded(")
    restart = extract(delegate, "    private func restartApp()")
    observation = extract(delegate, "    private func systemProxyRecoveryObservation()")

    assert_readiness_failure_uses_canonical_resume(delegate)

    # This observer is test instrumentation around the extracted production
    # assignment; all decisions and mutations remain in the production method.
    capture = replace_once(
        capture,
        "builtInRecoveryCheckpoint = Data(frozen.utf8)",
        "builtInRecoveryCheckpoint = Data(frozen.utf8)\n        recoveryCheckpointEvents.append(\"capture:\\(isRestarting)\")\n        events.append(\"capture\")",
        "capture event",
    )

    expected_negative_failure = None
    if args.negative_control == "missing-clear":
        recovery = recovery.replace("        confirmedRuntimeProfileName = nil\n", "", 1)
        resume = resume.replace("        confirmedRuntimeProfileName = nil\n", "", 1)
        expected_negative_failure = "resume with no checkpoint retained the prior confirmed profile identity"
    elif args.negative_control == "missing-capture":
        restart = restart.replace("            captureBuiltInRecoveryCheckpoint()\n", "", 1)
        expected_negative_failure = "restart did not record both checkpoint capture and suspension"

    if args.negative_control == "missing-live-guard":
        capture = replace_once(capture,
            "guard ConfigManager.shared.isRunning, !ConfigManager.shared.isEnhancedModeActive else {",
            "guard true else {", "live capture guard")
        expected_negative_failure = "unavailable built-in capture replaced the frozen verified profile"
    elif args.negative_control == "missing-profile-fence":
        resume = replace_once(resume,
            "guard confirmedRuntimeProfileName != nil else {",
            "guard true else {", "resume profile fence")
        expected_negative_failure = "no-checkpoint fallback was not fenced and left retryable"

    if args.negative_control == "missing-session-ipv6":
        recovery = replace_once(recovery,
            '        restored = RuntimeConfigReadbackPolicy.preservingBuiltInSessionIPv6(in: restored, confirmed: root)\n',
            '', "session IPv6 preservation")
        expected_negative_failure = "session IPv6 mismatch falsely rejected a valid frozen profile"
    elif args.negative_control == "premature-callback-resume":
        resume_callback_helper = replace_once(
            resume_callback_helper,
            """            guard let error = checkedResumeBuiltInCore() else {
                clashResumeCallbacks()
                return nil
            }
            return error""",
            """            clashResumeCallbacks()
            return checkedResumeBuiltInCore()""",
            "premature callback resume",
        )
        expected_negative_failure = "failed built-in resume resumed callbacks after the bridge error"

    swift = (
        PRELUDE.replace("// RESUME_GATE_TYPE", resume_gate)
        .replace("// CAPTURE_METHOD", capture)
        .replace("// RECOVERY_METHOD", recovery)
        .replace("// FENCE_METHOD", fence)
        .replace("// RESUME_METHOD", resume)
        .replace("// RESUME_CALLBACK_METHOD", resume_callback_helper)
        .replace("// RESTART_METHOD", restart)
        .replace("// OBSERVATION_METHOD", observation)
        + TESTS
    )

    utils = ROOT / "ClashFX/General/Utils"
    with tempfile.TemporaryDirectory(prefix="clashfx-builtin-resume-") as temp:
        directory = Path(temp)
        source = directory / "main.swift"
        source.write_text(swift)
        binary = directory / "harness"
        architecture = platform.machine()
        target = f"{architecture}-apple-macosx12.0"
        command = [
            "swiftc",
            "-swift-version",
            "5",
            "-target",
            target,
            str(utils / "RuntimeConfigReadbackPolicy.swift"),
            str(utils / "RuntimeConfigBaselinePolicy.swift"),
            str(utils / "RuntimeConfigApplyDiagnostics.swift"),
            str(utils / "RuntimeConfigTransactionController.swift"),
            str(source),
            "-o",
            str(binary),
        ]
        subprocess.run(command, check=True)
        result = subprocess.run(
            [str(binary), str(directory)],
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

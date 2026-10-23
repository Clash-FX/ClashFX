#!/usr/bin/env python3
"""Exercise the production startup result without AppKit, a core, or user state."""
from pathlib import Path
import platform
import subprocess
import tempfile
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('startup_harness', ROOT / 'scripts/verify-first-startup-reload.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
method = module.extract((ROOT / 'ClashFX/AppDelegate.swift').read_text(), '    func startProxy()')
swift = r'''
import Foundation
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
enum Level { case info, warning, error }
enum Logger {
    static var messages = [String]()
    static func log(_ text: String, level: Level = .info) { messages.append(text) }
}
enum Settings {
    static var isApiSecretSet = true
    static var apiSecret = "fixture-secret"
    static var overrideConfigSecret = true
    static var builtInApiMode = true
    static var enableIPV6 = true
    static var proxyPort = 7088
    static var apiPort = 19090
    static var apiPortAllowLan = false
}
final class ConfigManager {
    static let shared = ConfigManager()
    static var allowConnectFromLan = true
    var isRunning = false
    var allowExternalControl = false
    var apiPort = "0"
    var apiSecret = ""
}
enum ApiRequest { static var cancellations = 0; static func cancelRuntimeConfigOperations() { cancellations += 1 } }
final class Transactions { var invalidations = 0; func invalidate() { invalidations += 1 } }
final class Menu { var isEnabled = false }
final class NSUserNotificationCenter {
    static let `default` = NSUserNotificationCenter()
    var messages = [String]()
    func postConfigErrorNotice(msg: String) { messages.append(msg) }
}
// All potential process/file-system resource paths are shadowed. Startup's
// dashboard branch must not run in this in-memory bridge contract fixture.
enum Bundle { struct Main { var resourceURL: URL? { nil } }; static let main = Main() }
final class Process {
    var executableURL: URL?; var arguments: [String]?
    func run() throws { fatalError("No process allowed") }
    func waitUntilExit() { fatalError("No process allowed") }
}
let SecCreateSharedWebCredentialPassword: () -> Any? = { "generated-fixture-secret" }
struct Bridge { let value: String; func toString() -> String { value } }
typealias GoUint32 = UInt32
extension Bool { func goObject() -> Bool { self } }
extension String { func goStringBuffer() -> String { self } }
var calls = [(Bool, Bool, Bool, UInt32, String)]()
var reply: String? = #"{"externalController":"127.0.0.1:19090","secret":"fixture-secret"}"#
func run(_ direct: Bool, _ lan: Bool, _ ipv6: Bool, _ port: UInt32, _ api: String) -> Bridge? {
    calls.append((direct, lan, ipv6, port, api))
    return reply.map { Bridge(value: $0) }
}
func clash_checkSecret() -> Bridge { Bridge(value: "") }
func clash_setSecret(_ value: String) {}
func setUIPath(_ value: String) { fatalError("No dashboard allowed") }
final class Probe {
    var automaticRecoverySelections: [String: String]?
    var automaticRecoveryNeedsRetry = false
    var runtimeConfigTransactions = Transactions()
    var runtimeCoreSessionID = UUID()
    var isCoreConfigSnapshotVerified = true
    var confirmedRuntimeProfileName: String? = "old-profile"
    var isBuiltInCoreResumeRetryAvailable = false
    var proxyModeMenuItem = Menu()
    var dashboardMenuItem = Menu()
    var restoreError: String?
    func restoreBuiltInRecoveryCheckpoint() -> String? { restoreError }
    // METHOD
}
let app = Probe()
check(app.startProxy() == nil, "Configured startup must succeed")
check(calls.count == 1 && calls[0].0 && calls[0].1 && calls[0].2 && calls[0].3 == 7088 && calls[0].4 == "127.0.0.1:19090", "Custom startup settings were lost")
check(ConfigManager.shared.isRunning && !app.isBuiltInCoreResumeRetryAvailable, "Startup success not published")
check(app.startProxy() == nil && calls.count == 1, "Running core must not start twice")
let badResponses: [String?] = [nil, "", "[port_conflict] service=proxy_listener port=7088 reason=configured_port_unavailable", "open cache database: timeout token=credential-canary"]
for bad in badResponses {
    ConfigManager.shared.isRunning = false
    reply = bad
    Logger.messages = []
    NSUserNotificationCenter.default.messages = []
    let reason = app.startProxy()
    check(reason != nil && !reason!.isEmpty, "Startup failure must return a nonempty reason")
    check(!ConfigManager.shared.isRunning && app.isBuiltInCoreResumeRetryAvailable, "Failure must remain stopped/retryable")
    check(!Logger.messages.contains("Start proxy done"), "Failure logged startup success")
    check(!reason!.contains("credential-canary") && !Logger.messages.joined().contains("credential-canary") && !NSUserNotificationCenter.default.messages.joined().contains("credential-canary"), "Sensitive core detail leaked")
    if bad?.contains("port_conflict") == true { check(reason!.contains("port=7088"), "Original port diagnostic lost") }
}
ConfigManager.shared.isRunning = false
reply = #"{"externalController":"127.0.0.1:19090","secret":"fixture-secret"}"#
app.restoreError = "The previous built-in configuration could not be restored: fixture rejection"
check(app.startProxy() == app.restoreError && !ConfigManager.shared.isRunning && app.isBuiltInCoreResumeRetryAvailable, "Checkpoint restore error was replaced")
let count = calls.count
app.automaticRecoverySelections = ["TAGSS": "Node"]
check(app.startProxy() != nil && calls.count == count, "Protected automatic recovery invoked bootstrap fallback")
print("PASS: actual startup custom options, idempotent running guard, nil/invalid replies, port/cache error propagation, redaction and checkpoint/recovery guards")
'''.replace('// METHOD', '@discardableResult\n' + method)
with tempfile.TemporaryDirectory(prefix='clashfx-builtin-start-result-') as temp:
    directory = Path(temp)
    source = directory / 'main.swift'
    source.write_text(swift)
    binary = directory / 'harness'
    subprocess.run(['swiftc', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macosx12.0', str(ROOT / 'ClashFX/General/Utils/RuntimeConfigApplyDiagnostics.swift'), str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

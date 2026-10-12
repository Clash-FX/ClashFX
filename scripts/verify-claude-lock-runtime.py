#!/usr/bin/env python3
"""Exercise production AppDelegate Lock runtime methods with in-memory adapters.

No app, Helper, preferences, sockets or proxy processes are loaded. Source method
bodies are extracted so the test does not substitute a second implementation.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'ClashFX/AppDelegate.swift').read_text()


def declaration(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


methods = '\n'.join(declaration('    private func ' + name) for name in (
    'isCurrentClaudeLockChange(', 'applyClaudeLockRuntime(',
    'reloadClaudeLockRuntime(', 'restoreClaudeLockRuntime('
))
states = '\n'.join(declaration(marker) for marker in (
    '    private struct ClaudeLockRuntimeSettings', '    private final class ClaudeLockChange'
))
stubs = r'''
import Foundation

enum ClashProxyMode { case rule, global, direct }
enum OutboundModeChangeSource { case configReload }
enum Settings {
    static var claudeProxyLockEnabled = false
    static var claudeProxyLockTarget = "Old"
    static var enhancedMode = false
}
struct Config { var mode: ClashProxyMode = .global }
struct Value { var value = false }
final class ConfigManager {
    static let shared = ConfigManager()
    static var selectOutBoundMode: ClashProxyMode = .global
    static var selectConfigName = "Fixture"
    var currentConfig: Config? = Config()
    var isEnhancedModeActive = false
    var isRunning = true
    var proxyPortAutoSet = false
    var isProxySetByOtherVariable = Value()
}
struct SystemProxyCheckpoint {}
func clashPauseCallbacks() {}
func clashSuspendCore() {}

enum RemoteControlManager { static var selectConfig: Int? }
final class Harness {
    var ownsRuntimeControl = true
    var enhancedModeGeneration: UInt64 = 1
    var isTerminating = false
    var isRestarting = false
    var events: [String] = []
    var reloadErrors: [String?] = []
    var enableError: String?
    var disableError: String?
    var stopUnconfirmed = false
    var enhancedModeOwnershipBlock: Int?
    var isEnhancedModeCleanupRequired: Bool {
        ConfigManager.shared.isEnhancedModeActive || enhancedModeOwnershipBlock != nil
    }
    private var claudeLockChange: ClaudeLockChange?
    func enableEnhancedMode(completion: @escaping (UInt64, String?) -> Void) {
        events.append("enable")
        enhancedModeGeneration += 1
        DispatchQueue.main.async {
            if self.enableError == nil { ConfigManager.shared.isEnhancedModeActive = true }
            completion(self.enhancedModeGeneration, self.enableError)
        }
    }
    func disableEnhancedMode(completion: @escaping (UInt64, String?) -> Void) {
        events.append("disable")
        enhancedModeGeneration += 1
        DispatchQueue.main.async {
            if !self.stopUnconfirmed {
                ConfigManager.shared.isEnhancedModeActive = false
                self.enhancedModeOwnershipBlock = nil
            }
            completion(self.enhancedModeGeneration, self.disableError)
        }
    }
    func reconcileUncertainEnhancedCoreOwnership(_ block: Int, completion: @escaping (String?) -> Void) {
        events.append("reconcile")
        if !stopUnconfirmed { enhancedModeOwnershipBlock = nil }
        completion(stopUnconfirmed ? "ownership unknown" : nil)
    }
    func startProxy() { events.append("start builtin"); ConfigManager.shared.isRunning = true }
    func refreshStatusItemViewStatus() {}
    func requestConfigUpdateApplyingRuntimePatch(configName: String, callback: @escaping (String?) -> Void) {
        events.append(claudeLockChange!.restoring ? "reload old" : "reload new")
        callback(reloadErrors.isEmpty ? nil : reloadErrors.removeFirst())
    }
    func enqueueOutboundModeChange(mode: ClashProxyMode, source: OutboundModeChangeSource,
                                  closeConnections: Bool, completion: @escaping (Bool) -> Void) {
        events.append(mode == .rule ? "rule" : "old mode")
        completion(true)
    }
    func begin(enabled: Bool = true) {
        claudeLockChange = ClaudeLockChange(enabled: enabled, target: "New", generation: enhancedModeGeneration)
    }
    func apply() -> String? {
        awaitReply { reply in self.applyClaudeLockRuntime(self.claudeLockChange!, completion: reply) }
    }
    func restore() -> String? {
        claudeLockChange!.restoring = true
        claudeLockChange!.runtimeTouched = true
        return awaitReply { reply in self.restoreClaudeLockRuntime(self.claudeLockChange!, completion: reply) }
    }
    func staleReload() -> String? {
        enhancedModeGeneration += 1
        return awaitReply { reply in self.reloadClaudeLockRuntime(self.claudeLockChange!, completion: reply) }
    }
    private func awaitReply(_ action: (@escaping (String?) -> Void) -> Void) -> String? {
        var done = false
        var result: String?
        action { result = $0; done = true }
        let deadline = Date().addingTimeInterval(2)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        precondition(done, "runtime callback did not settle")
        return result
    }
'''
checks = r'''
}
func reset(_ enhanced: Bool) {
    ConfigManager.shared.isEnhancedModeActive = enhanced
    ConfigManager.shared.isRunning = true
    Settings.enhancedMode = enhanced
    Settings.claudeProxyLockEnabled = false
}
var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    passed += 1
}
reset(true)
let live = Harness(); live.begin()
check(live.apply() == nil, "live lock failed")
check(live.events == ["reload new", "rule"], "live Enhanced lock must avoid port handoffs")
check(!Settings.claudeProxyLockEnabled, "runtime stage must not commit preferences")
reset(false)
let builtin = Harness(); builtin.begin()
check(builtin.apply() == nil, "builtin to Enhanced failed")
check(builtin.events == ["enable", "reload new", "rule"], "wrong enabling sequence")
check(builtin.restore() == nil, "builtin rollback failed")
check(builtin.events.suffix(3) == ["disable", "reload old", "old mode"], "wrong builtin rollback sequence")
reset(true)
let healthy = Harness(); healthy.begin()
check(healthy.restore() == nil, "healthy Enhanced restoration failed")
check(healthy.events == ["reload old", "old mode"], "healthy rollback should keep the existing listener")
reset(true)
let crashed = Harness(); crashed.begin(); crashed.reloadErrors = ["core unavailable", nil]
check(crashed.restore() == nil, "crashed Enhanced restoration failed")
check(crashed.events == ["reload old", "disable", "enable", "reload old", "old mode"], "old Enhanced core was not rebuilt")
reset(true)
let blocked = Harness(); blocked.begin(); blocked.reloadErrors = ["core unavailable"]
blocked.disableError = "stop unknown"; blocked.stopUnconfirmed = true; blocked.enhancedModeOwnershipBlock = 1
check(blocked.restore() == "stop unknown", "uncertain stop must report failure")
check(blocked.events == ["disable"], "uncertain owner must never authorize another core")
reset(true)
let late = Harness(); late.begin()
check(late.staleReload() != nil, "late callback must be refused")
check(late.events.isEmpty, "stale change touched the new runtime")
reset(false)
ConfigManager.shared.isRunning = false
let stopped = Harness(); stopped.begin(enabled: false)
check(stopped.apply() == nil, "a stale lock must remain disableable when the core is stopped")
check(stopped.events == ["start builtin", "reload new", "old mode"], "disable did not recover the stopped builtin core")
check(stopped.restore() == nil, "stopped runtime rollback failed")
check(!ConfigManager.shared.isRunning, "rollback must preserve a previously stopped core")
print("Production Lock runtime checks passed: \(passed)")
'''
with tempfile.TemporaryDirectory(prefix='clashfx-lock-runtime-') as temporary:
    path = Path(temporary) / 'main.swift'
    path.write_text('\n'.join((stubs, states, methods, checks)))
    binary = Path(temporary) / 'runtime-tests'
    subprocess.run(['swiftc', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

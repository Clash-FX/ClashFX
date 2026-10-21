#!/usr/bin/env python3
"""Isolated regression for the enhanced readiness helper queue boundary."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
APP_DELEGATE = ROOT / "ClashFX" / "AppDelegate.swift"


def extract_function(source: str, name: str) -> str:
    marker = f"private func {name}("
    start = source.find(marker)
    if start < 0:
        raise AssertionError(f"could not find {name} in AppDelegate.swift")

    opening = source.find("{", start)
    if opening < 0:
        raise AssertionError(f"could not find body for {name}")

    depth = 0
    for offset in range(opening, len(source)):
        if source[offset] == "{":
            depth += 1
        elif source[offset] == "}":
            depth -= 1
            if depth == 0:
                return source[start : offset + 1]
    raise AssertionError(f"unterminated body for {name}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    source = APP_DELEGATE.read_text(encoding="utf-8")
    capture = extract_function(source, "captureCoreReadinessHelper")
    probe = extract_function(source, "currentCoreOwnsExpectedListeners")

    require(
        "dispatchPrecondition(condition: .onQueue(.main))" in capture
        and "PrivilegedHelperManager.shared.helper()" in capture,
        "helper capture must be asserted on main",
    )
    require(
        "using helper: ProxyConfigRemoteProcessProtocol?" in probe,
        "ownership probe must accept a captured optional helper",
    )
    require(
        "PrivilegedHelperManager.shared" not in probe
        and "AppDelegate.shared" not in probe
        and "helper()" not in probe
        and "DispatchQueue.main.sync" not in probe,
        "ownership probe must not reach AppKit or capture a helper",
    )
    require(
        "semaphore.wait(timeout: .now() + 0.35)" in probe,
        "ownership probe must keep its bounded XPC wait",
    )

    call_sites = (
        "verifyRuntimeCandidate",
        "completeExternalCoreReadinessProbe",
        "waitForExternalCoreFinalCheck",
    )
    for name in call_sites:
        caller = extract_function(source, name)
        capture_at = caller.find("captureCoreReadinessHelper()")
        dispatch_at = caller.find("DispatchQueue.global")
        require(
            capture_at >= 0 and dispatch_at > capture_at,
            f"{name} must capture the helper before dispatching probe work",
        )
        require(
            "currentCoreOwnsExpectedListeners(" in caller
            and "using: readinessHelper" in caller,
            f"{name} must pass the captured helper to the ownership probe",
        )

    startup_probe = extract_function(source, "completeExternalCoreReadinessProbe")
    final_probe = extract_function(source, "waitForExternalCoreFinalCheck")
    wait_probe = extract_function(source, "waitForExternalCore")
    require(
        "guard self.isCurrentEnhancedModeLaunch(context) else { ready(false); return }"
        in startup_probe,
        "stale readiness callbacks must settle false",
    )
    require(
        "guard self.isCurrentEnhancedModeLaunch(context) else { ready(false); return }"
        in final_probe,
        "stale final-check callbacks must settle false",
    )
    require(
        "guard isCurrentEnhancedModeLaunch(context) else { ready(false); return }"
        in wait_probe,
        "cancelled or stale polling must settle false",
    )

    probe = probe.replace(
        'Bundle.main.path(forResource: "mihomo_core", ofType: nil)',
        'TestBundle.main.path(forResource: "mihomo_core", ofType: nil)',
    )
    probe = probe.replace("private func currentCoreOwnsExpectedListeners(", "func currentCoreOwnsExpectedListeners(", 1)
    harness = r'''import Foundation

struct TestBundle {
    static let main = TestBundle()
    func path(forResource: String, ofType: String?) -> String? { "/bundle/mihomo_core" }
}

protocol ProxyConfigRemoteProcessProtocol {
    var getMihomoCoreStatus: ((@escaping (Any?) -> Void) -> Void)? { get }
}

enum EnhancedModeListenerOwnership: Equatable {
    case unknown
    case notCurrentLaunch
    case missingProxyPorts([Int])
    case ready
}

struct EnhancedModeLaunchContext {
    let launchID: String
    let apiPort: String
    let dnsPort: Int
    let proxyPorts: [Int]
    let configPath: String
    let deadline: Date
}

enum EnhancedModeDNSReadinessPolicy {
    enum HelperListenerPortsState: String { case unknown, known, notRunning }

    struct HelperListenerSnapshot {
        let helperIsRunning: Bool
        let processID: Int
        let helperConfigPath: String?
        let tcpListenPorts: [Int]
        let udpListenPorts: [Int]
        let tcpListenPortsState: HelperListenerPortsState
        let udpListenPortsState: HelperListenerPortsState
    }

    struct ExpectedListeners {
        let expectedConfigPath: String
        let proxyPorts: [Int]
        let apiPort: Int
        let port: Int
    }

    static func matchesExpectedCoreBinary(
        _ actual: String?, bundlePath: String, approvedPath: String
    ) -> Bool {
        actual == bundlePath || actual == approvedPath
    }

    static func currentLaunchOwnsDNSListeners(
        observed: HelperListenerSnapshot, expected: ExpectedListeners
    ) -> Bool {
        guard observed.helperIsRunning,
              observed.processID > 0,
              observed.helperConfigPath == expected.expectedConfigPath,
              observed.tcpListenPortsState == .known,
              observed.udpListenPortsState == .known else { return false }
        let expectedTCP = expected.proxyPorts + [expected.apiPort, expected.port]
        return expectedTCP.allSatisfy(observed.tcpListenPorts.contains)
            && observed.udpListenPorts.contains(expected.port)
    }
}

enum PrivilegedHelperManager {
    static let approvedCorePath = "/approved/mihomo_core"
}

enum Logger {
    enum Level { case debug, warning }
    static func log(_ message: String, level: Level = .debug) {}
}

final class StubHelper: ProxyConfigRemoteProcessProtocol {
    var getMihomoCoreStatus: ((@escaping (Any?) -> Void) -> Void)?
    private let lock = NSLock()
    private var invocationOnMainStorage: Bool?

    var invocationOnMain: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return invocationOnMainStorage
    }

    func recordInvocationThread() {
        lock.lock()
        invocationOnMainStorage = Thread.isMainThread
        lock.unlock()
    }
}

final class ReadinessProbeHarness {
    let enhancedModeReadinessLock = NSLock()
    var enhancedModeLastMissingProxyPorts = [Int]()

    __ACTUAL_PROBE__
}

func makeContext() -> EnhancedModeLaunchContext {
    EnhancedModeLaunchContext(
        launchID: "launch-17",
        apiPort: "9090",
        dnsPort: 53,
        proxyPorts: [7890],
        configPath: "/tmp/enhanced.yaml",
        deadline: Date().addingTimeInterval(5)
    )
}

func makeStatus(configPath: String = "/tmp/enhanced.yaml") -> [String: Any] {
    [
        "running": NSNumber(value: true),
        "launchID": "helper-launch-17",
        "configPath": configPath,
        "binaryPath": "/bundle/mihomo_core",
        "pid": NSNumber(value: 123),
        "tcpListenPortsState": "known",
        "udpListenPortsState": "known",
        "tcpListenPorts": [53, 7890, 9090].map(NSNumber.init(value:)),
        "udpListenPorts": [53].map(NSNumber.init(value:))
    ]
}

let harness = ReadinessProbeHarness()
let helper = StubHelper()
helper.getMihomoCoreStatus = { reply in
    helper.recordInvocationThread()
    reply(makeStatus())
}
dispatchPrecondition(condition: .onQueue(.main))
let capturedHelper: ProxyConfigRemoteProcessProtocol? = helper
let completion = DispatchSemaphore(value: 0)
var ownership: EnhancedModeListenerOwnership?
DispatchQueue.global(qos: .utility).async {
    ownership = harness.currentCoreOwnsExpectedListeners(makeContext(), using: capturedHelper)
    completion.signal()
}
guard completion.wait(timeout: .now() + 1) == .success else {
    fatalError("valid status probe did not settle")
}
precondition(ownership == .ready, "valid captured-helper status should prove ownership")
precondition(helper.invocationOnMain == false, "the XPC status request must run off main")
precondition(
    harness.currentCoreOwnsExpectedListeners(makeContext(), using: nil) == .unknown,
    "missing helper must remain unknown without a helper lookup"
)

let wrongConfig = StubHelper()
wrongConfig.getMihomoCoreStatus = { reply in reply(makeStatus(configPath: "/tmp/other.yaml")) }
precondition(
    harness.currentCoreOwnsExpectedListeners(makeContext(), using: wrongConfig) == .notCurrentLaunch,
    "a status for another config must not pass ownership"
)

let unanswered = StubHelper()
unanswered.getMihomoCoreStatus = { _ in }
let timedOut = DispatchSemaphore(value: 0)
var timeoutOwnership: EnhancedModeListenerOwnership?
let timeoutStarted = Date()
DispatchQueue.global(qos: .utility).async {
    timeoutOwnership = harness.currentCoreOwnsExpectedListeners(makeContext(), using: unanswered)
    timedOut.signal()
}
guard timedOut.wait(timeout: .now() + 1) == .success else {
    fatalError("unanswered status request exceeded its bound")
}
precondition(timeoutOwnership == .unknown, "an unanswered request must remain unknown")
precondition(Date().timeIntervalSince(timeoutStarted) < 0.9, "status wait exceeded its bound")
print("enhanced readiness helper queue regression passed")
'''.replace("__ACTUAL_PROBE__", probe)

    with tempfile.TemporaryDirectory(prefix="clashfx-readiness-queue-") as temporary:
        swift_file = Path(temporary) / "ReadinessProbeRegression.swift"
        executable = Path(temporary) / "ReadinessProbeRegression"
        swift_file.write_text(harness, encoding="utf-8")
        subprocess.run(
            ["swiftc", str(swift_file), "-o", str(executable)],
            check=True,
        )
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()

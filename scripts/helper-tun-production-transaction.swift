import Darwin
import Foundation
import SystemConfiguration

private let helperMachService = "com.clashfx.app.Helper"
private let expectedClientBundleIdentifier = "com.clashfx.app"
private let expectedHelperProtocolVersion = 4
private let helperReplyTimeout: TimeInterval = 30
private let controllerReadinessTimeout: TimeInterval = 45
private let invalidRuntimeDeadline: TimeInterval = 15
private let lateProxyReplyDeadline: TimeInterval = 35
private let pollInterval: TimeInterval = 0.25

enum AcceptanceLogLevel: String {
    case debug
    case info
    case warning
    case error
}

/// The production manager's only non-Foundation dependency in this standalone
/// acceptance build. It records manager diagnostics in the evidence document.
enum Logger {
    static var observer: ((String, AcceptanceLogLevel) -> Void)?
    static func log(_ message: String, level: AcceptanceLogLevel) {
        observer?(message, level)
    }
}

private struct Fixtures: Decodable {
    let controllerURL: String
    let secret: String
    let coreBinary: String
    let homeDir: String
    let goodConfig: String
    let alternateConfig: String?
    let invalidConfig: String
    let outputJSON: String
}

private struct ControllerAddress {
    let baseURL: URL
    let port: Int
}

private struct ConfigFixture {
    let path: String
    let controller: String
    let secret: String
    let httpPort: Int
    let socksPort: Int

    static func load(path: String, expectedController: ControllerAddress, secret: String) throws -> ConfigFixture {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let value = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = value as? [String: Any] else {
            throw AcceptanceFailure("Config fixture is not a JSON object: \(path)")
        }
        guard let rawController = object["external-controller"] as? String,
              let configuredSecret = object["secret"] as? String else {
            throw AcceptanceFailure("Config fixture must contain external-controller and secret: \(path)")
        }
        guard configuredSecret == secret else {
            throw AcceptanceFailure("Config fixture secret does not match the manifest: \(path)")
        }
        let controllerText = rawController.contains("://") ? rawController : "http://\(rawController)"
        guard let components = URLComponents(string: controllerText),
              let host = components.host?.lowercased(),
              Self.isLoopback(host), components.port == expectedController.port else {
            throw AcceptanceFailure("Config fixture controller does not match controllerURL: \(path)")
        }
        guard let tun = object["tun"] as? [String: Any],
              Self.bool(tun["enable"]), Self.bool(tun["auto-route"]),
              Self.bool(tun["auto-detect-interface"]) else {
            throw AcceptanceFailure("Config fixture must enable TUN, auto-route, and auto-detect-interface: \(path)")
        }

        let mixedPort = Self.integer(object["mixed-port"])
        let httpPort = mixedPort > 0 ? mixedPort : Self.integer(object["port"])
        let socksPort = mixedPort > 0 ? mixedPort : Self.integer(object["socks-port"])
        guard (1 ... 65_535).contains(httpPort), (1 ... 65_535).contains(socksPort) else {
            throw AcceptanceFailure("Config fixture does not provide valid HTTP and SOCKS ports: \(path)")
        }
        return ConfigFixture(path: path, controller: rawController, secret: configuredSecret,
                             httpPort: httpPort, socksPort: socksPort)
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host)
    }
}

private struct ValidatedManifest {
    let fixtures: Fixtures
    let controller: ControllerAddress
    let targetConfig: ConfigFixture
    let goodConfig: ConfigFixture
    let alternateConfig: ConfigFixture?
    let workspaceURL: URL
    let runnerTempURL: URL
    let outputURL: URL
}

private struct AcceptanceFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum HelperClientFailure: Error, LocalizedError {
    case xpc(String)
    case timedOut(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case let .xpc(message): return "XPC error: \(message)"
        case let .timedOut(operation): return "Timed out waiting for Helper \(operation) reply"
        case let .malformed(message): return message
        }
    }
}

private final class Evidence {
    private let lock = NSLock()
    private var document: [String: Any]
    private var activeProxyAttempt: String?
    private var inactive = false

    init(environment: [String: Any]) {
        document = [
            "schemaVersion": 1,
            "status": "running",
            "scope": "Production Helper NSXPC + production SystemProxyManager + production ClaudeProxyLockTransaction; minimal CLI, no full AppDelegate",
            "manifestSchema": [
                "controllerURL": "loopback HTTP controller base URL",
                "secret": "Mihomo controller bearer token; never emitted in evidence",
                "coreBinary": "runner-staged executable mihomo core",
                "homeDir": "runner-staged core data directory",
                "goodConfig": "valid TUN-enabled Mihomo JSON config for runtime restoration",
                "alternateConfig": "optional valid TUN-enabled config using the same controller and proxy ports",
                "invalidConfig": "runner-staged config path intended to fail runtime readiness",
                "outputJSON": "runner-owned evidence output path"
            ],
            "environment": environment,
            "coverage": [
                "productionHelperXPC": false,
                "realInitialProxyCheckpoint": false,
                "productionClaudeTransactionSuccess": false,
                "productionSystemProxyEnable": false,
                "productionClaudeRuntimeFailureRollback": false,
                "actualInvalidConfigNotReady": false,
                "runtimeRestoredWithProductionHelper": false,
                "newPIDRuntimeRecovery": false,
                "productionSystemProxyCheckpointRestore": false,
                "realSCPreferencesLockFailure": false,
                "realSCPreferencesLockFailureRollback": false,
                "failedTransactionPreferenceCommitDeltaZero": false
            ],
            "assertions": [],
            "events": [],
            "helperCalls": [],
            "proxyAttempts": [],
            "transactions": [],
            "failures": [],
            "scopeNotes": [
                "The production AppDelegate is not launched; the compiled client uses the production transaction and SystemProxyManager types with an isolated UserDefaults suite and in-memory application preference metadata.",
                "Mihomo readiness is tied to the Helper-reported launch ID/PID/config path and loopback controller /version and /configs responses, including TUN auto-route flags.",
                "UDP/TCP DNS, utun ownership, and route checks remain runner-owned evidence and are not claimed by this client.",
                "The System Proxy failure case uses a real SCPreferencesLock held by this client across the production manager call; no fake helper result or invalid-port shortcut is used."
            ]
        ]
    }

    func record(_ name: String, _ fields: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        var event: [String: Any] = ["atUTC": Self.timestamp(), "name": name]
        fields.forEach { event[$0.key] = $0.value }
        var events = document["events"] as? [[String: Any]] ?? []
        events.append(event)
        document["events"] = events
    }

    func helperCall(_ operation: String, phase: String, result: String? = nil, error: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var item: [String: Any] = ["operation": operation, "phase": phase, "atUTC": Self.timestamp()]
        if let result { item["result"] = result }
        if let error { item["error"] = error }
        var calls = document["helperCalls"] as? [[String: Any]] ?? []
        calls.append(item)
        document["helperCalls"] = calls
    }

    func assertion(_ name: String, passed: Bool, evidence: Any? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var item: [String: Any] = ["name": name, "passed": passed]
        if let evidence { item["evidence"] = evidence }
        var assertions = document["assertions"] as? [[String: Any]] ?? []
        assertions.append(item)
        document["assertions"] = assertions
        if !passed {
            var failures = document["failures"] as? [[String: Any]] ?? []
            failures.append(["phase": name, "message": "assertion failed"])
            document["failures"] = failures
        }
    }

    func fail(_ phase: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        var failures = document["failures"] as? [[String: Any]] ?? []
        failures.append(["phase": phase, "message": message])
        document["failures"] = failures
    }

    func setCoverage(_ key: String, _ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var coverage = document["coverage"] as? [String: Bool] ?? [:]
        coverage[key] = value
        document["coverage"] = coverage
    }

    func set(_ key: String, _ value: Any) {
        lock.lock()
        defer { lock.unlock() }
        document[key] = value
    }

    func setActiveProxyAttempt(_ name: String?) {
        lock.lock()
        activeProxyAttempt = name
        lock.unlock()
    }

    func currentProxyAttempt() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeProxyAttempt
    }

    func addProxyAttempt(_ item: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        var attempts = document["proxyAttempts"] as? [[String: Any]] ?? []
        attempts.append(item)
        document["proxyAttempts"] = attempts
    }

    func updateProxyAttempt(name: String, fields: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        var attempts = document["proxyAttempts"] as? [[String: Any]] ?? []
        guard let index = attempts.lastIndex(where: { $0["name"] as? String == name }) else { return }
        fields.forEach { attempts[index][$0.key] = $0.value }
        document["proxyAttempts"] = attempts
    }

    func proxyAttempt(name: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        let attempts = document["proxyAttempts"] as? [[String: Any]] ?? []
        return attempts.last(where: { $0["name"] as? String == name })
    }

    func allCoverageIsTrue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let coverage = document["coverage"] as? [String: Bool] ?? [:]
        let required = coverage.filter { $0.key != "controlPassed" }
        return !required.isEmpty && required.values.allSatisfy { $0 }
    }

    func addTransaction(_ transaction: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        var transactions = document["transactions"] as? [[String: Any]] ?? []
        transactions.append(transaction)
        document["transactions"] = transactions
    }

    func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !inactive
    }

    func deactivate() {
        lock.lock()
        inactive = true
        activeProxyAttempt = nil
        lock.unlock()
    }

    func finish(status: String, outputURL: URL?) -> [String: Any] {
        lock.lock()
        document["status"] = status
        document["finishedAtUTC"] = Self.timestamp()
        let result = document
        lock.unlock()
        if let outputURL {
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: outputURL, options: .atomic)
            } catch {
                fputs("Could not write transaction evidence JSON: \(error.localizedDescription)\n", stderr)
            }
        }
        return result
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private enum LoggerBridge {
    static var evidence: Evidence?
}

private final class ProxySnapshotCache {
    private let lock = NSLock()
    private var snapshot: [String: Any] = [:]

    func store(_ value: [String: Any]) {
        lock.lock()
        snapshot = value
        lock.unlock()
    }

    func current() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

private final class SystemProxyPreferencesLocker {
    private let lock = NSLock()
    private var preferences: SCPreferences?

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return preferences != nil
    }

    func acquire() -> (Bool, String?) {
        let created = SCPreferencesCreate(nil, "ClashFX helper TUN acceptance lock" as CFString, nil)
        guard let created else { return (false, "SCPreferencesCreate returned nil") }
        guard SCPreferencesLock(created, false) else {
            return (false, "SCPreferencesLock could not acquire the system preferences lock")
        }
        lock.lock()
        preferences = created
        lock.unlock()
        return (true, nil)
    }

    @discardableResult
    func release() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = preferences else { return true }
        let unlocked = SCPreferencesUnlock(current)
        if unlocked { preferences = nil }
        return unlocked
    }
}

private final class ProductionHelperClient {
    private let connection: NSXPCConnection
    private let evidence: Evidence

    init(evidence: Evidence) {
        self.evidence = evidence
        connection = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ProxyConfigRemoteProcessProtocol.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    private func request<Value>(
        _ operation: String,
        timeout: TimeInterval? = helperReplyTimeout,
        invoke: @escaping (ProxyConfigRemoteProcessProtocol,
                           @escaping (Result<Value, HelperClientFailure>) -> Void) -> Void,
        completion: @escaping (Result<Value, HelperClientFailure>) -> Void
    ) {
        evidence.helperCall(operation, phase: "request")
        let settlement = ManagedOperationSettlement<Result<Value, HelperClientFailure>> { result in
            switch result {
            case .success:
                self.evidence.helperCall(operation, phase: "settled", result: "success")
            case let .failure(error):
                self.evidence.helperCall(operation, phase: "settled", error: error.localizedDescription)
            }
            completion(result)
        }
        if let timeout {
            settlement.scheduleTimeout(after: timeout, queue: .main, outcome: {
                .failure(.timedOut(operation))
            })
        }

        let settle: (Result<Value, HelperClientFailure>) -> Void = { result in
            DispatchQueue.main.async {
                if !settlement.finish(result) {
                    self.evidence.record("lateXPCReplyDiscarded", ["operation": operation])
                }
            }
        }
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
            settle(.failure(.xpc(error.localizedDescription)))
        }) as? ProxyConfigRemoteProcessProtocol else {
            settle(.failure(.malformed("Could not create the production Helper remote object proxy")))
            return
        }
        invoke(remote, settle)
    }

    func helperProtocolVersion(completion: @escaping (Result<Int, HelperClientFailure>) -> Void) {
        request("getHelperProtocolVersion", invoke: { remote, finish in
            guard let method = remote.getHelperProtocolVersion else {
                finish(.failure(.malformed("Production Helper protocol version selector is missing")))
                return
            }
            method { version in finish(.success(Int(version))) }
        }, completion: completion)
    }

    func coreStatus(completion: @escaping (Result<[String: Any], HelperClientFailure>) -> Void) {
        request("getMihomoCoreStatus", invoke: { remote, finish in
            guard let method = remote.getMihomoCoreStatus else {
                finish(.failure(.malformed("Production Helper core status selector is missing")))
                return
            }
            method { value in
                guard let status = value as? [String: Any] else {
                    finish(.failure(.malformed("Production Helper returned malformed core status")))
                    return
                }
                finish(.success(status))
            }
        }, completion: completion)
    }

    func proxySnapshot(completion: @escaping (Result<[String: Any], HelperClientFailure>) -> Void) {
        request("getCurrentProxySetting", invoke: { remote, finish in
            remote.getCurrentProxySetting { value in
                guard let snapshot = value as? [String: Any] else {
                    finish(.failure(.malformed("Production Helper returned malformed System Proxy settings")))
                    return
                }
                finish(.success(snapshot))
            }
        }, completion: completion)
    }

    func startCore(binary: String, config: String, home: String,
                   completion: @escaping (Result<String?, HelperClientFailure>) -> Void) {
        request("startMihomoCore", invoke: { remote, finish in
            remote.startMihomoCore(withBinaryPath: binary, configPath: config, homeDir: home) { error in
                finish(.success(error as String?))
            }
        }, completion: completion)
    }

    func enableProxy(port: Int, socksPort: Int, filterInterface: Bool, ignoreList: [String],
                     completion: @escaping (Result<String?, HelperClientFailure>) -> Void) {
        request("enableProxy", timeout: nil, invoke: { remote, finish in
            remote.enableProxy(withPort: Int32(port), socksPort: Int32(socksPort), pac: nil,
                               filterInterface: filterInterface, ignoreList: ignoreList) { error in
                finish(.success(error as String?))
            }
        }, completion: completion)
    }

    func restoreProxy(port: Int, socksPort: Int, snapshot: [String: Any], filterInterface: Bool,
                      completion: @escaping (Result<String?, HelperClientFailure>) -> Void) {
        request("restoreProxy", timeout: nil, invoke: { remote, finish in
            remote.restoreProxy(withCurrentPort: Int32(port), socksPort: Int32(socksPort), info: snapshot,
                                filterInterface: filterInterface) { error in
                finish(.success(error as String?))
            }
        }, completion: completion)
    }

    func systemProxyClient(
        evidence: Evidence,
        snapshotCache: ProxySnapshotCache,
        preferencesLocker: SystemProxyPreferencesLocker,
        failure: @escaping () -> Void
    ) -> SystemProxyHelperClient {
        SystemProxyHelperClient(
            getCurrentProxySetting: { [weak self] reply in
                guard let self else { failure(); reply(nil); return }
                self.proxySnapshot { result in
                    switch result {
                    case let .success(snapshot):
                        snapshotCache.store(snapshot)
                        reply(snapshot)
                    case let .failure(error):
                        failure()
                        reply(nil)
                        evidence.record("proxySnapshotXPCFailure", ["error": error.localizedDescription])
                    }
                }
            },
            enable: { [weak self] port, socksPort, filter, ignoreList, reply in
                guard let self else { failure(); reply("Helper client was released"); return }
                let attempt = evidence.currentProxyAttempt() ?? "unattributed"
                let held = preferencesLocker.isHeld
                evidence.updateProxyAttempt(name: attempt, fields: [
                    "helperEnableInvoked": true,
                    "helperEnableInvokedWhileSCPreferencesLocked": held,
                    "httpPort": Int(port), "socksPort": Int(socksPort)
                ])
                self.enableProxy(port: Int(port), socksPort: Int(socksPort), filterInterface: filter,
                                 ignoreList: ignoreList) { result in
                    switch result {
                    case let .success(helperError):
                        let managerAlreadyCompleted = evidence.proxyAttempt(name: attempt)?["managerCompleted"] as? Bool == true
                        evidence.updateProxyAttempt(name: attempt, fields: [
                            "helperReplyObserved": true,
                            "helperOperationSettled": true,
                            "helperReplyArrivedAfterManagerCompletion": managerAlreadyCompleted,
                            "helperReplyError": helperError as Any? ?? NSNull()
                        ])
                        reply(helperError)
                    case let .failure(error):
                        let managerAlreadyCompleted = evidence.proxyAttempt(name: attempt)?["managerCompleted"] as? Bool == true
                        evidence.updateProxyAttempt(name: attempt, fields: [
                            "helperReplyArrivedAfterManagerCompletion": managerAlreadyCompleted,
                            "helperTransportError": error.localizedDescription
                        ])
                        failure()
                    }
                }
            },
            disable: { [weak self] filter, reply in
                guard let self else { failure(); reply("Helper client was released"); return }
                self.request("disableProxy", timeout: nil, invoke: { remote, finish in
                    remote.disableProxy(withFilterInterface: filter) { error in
                        finish(.success(error as String?))
                    }
                }, completion: { result in
                    switch result {
                    case let .success(error): reply(error)
                    case .failure: failure()
                    }
                })
            },
            restore: { [weak self] port, socksPort, snapshot, filter, reply in
                guard let self else { failure(); reply("Helper client was released"); return }
                self.restoreProxy(port: Int(port), socksPort: Int(socksPort), snapshot: snapshot,
                                  filterInterface: filter) { result in
                    switch result {
                    case let .success(error): reply(error)
                    case .failure: failure()
                    }
                }
            }
        )
    }
}

private final class LoopbackController {
    private let baseURL: URL
    private let secret: String
    private let session: URLSession
    private let evidence: Evidence

    init(address: ControllerAddress, secret: String, evidence: Evidence) {
        baseURL = address.baseURL
        self.secret = secret
        self.evidence = evidence
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [
            "HTTPEnable": NSNumber(value: 0),
            "HTTPSEnable": NSNumber(value: 0),
            "SOCKSEnable": NSNumber(value: 0),
            "ProxyAutoConfigEnable": NSNumber(value: 0),
            "ProxyAutoDiscoveryEnable": NSNumber(value: 0)
        ]
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func getJSON(_ path: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        evidence.record("controllerRequest", ["path": "/\(path)", "host": url.host ?? "", "proxyDisabled": true])
        session.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
                  let data, let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let object = json as? [String: Any] else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(AcceptanceFailure("Loopback controller /\(path) returned non-JSON HTTP status \(code)")))
                return
            }
            completion(.success(object))
        }.resume()
    }
}

private struct ApplicationPreferenceMetadata: Equatable {
    var target = "baseline"
    var enabled = false
    var enhanced = false
    var mode = "rule"
}

private final class AcceptanceRun {
    private let manifest: ValidatedManifest
    private let evidence: Evidence
    private let suiteName = "com.clashfx.helper-tun-acceptance.\(UUID().uuidString)"
    private let snapshotCache = ProxySnapshotCache()
    private let preferencesLocker = SystemProxyPreferencesLocker()
    private let helper: ProductionHelperClient
    private let controller: LoopbackController
    private let defaults: UserDefaults
    private var proxyManager: SystemProxyManager!
    private var preferences = ApplicationPreferenceMetadata()
    private var preferenceCommitCount = 0
    private var activeTransactionID: UUID?
    private var active = true
    private var coreLaunchID: String?
    private var corePID: Int?
    private var latestRuntimeFailureEvidence: [String: Any]?
    private var latestGoodRuntimeRestorePassed = false
    private var latestGoodRuntimeRestorePID: Int?
    private var latestProxyRestorePassed = false
    private var didFinish = false
    private var exitCode: Int32 = 1

    init(manifest: ValidatedManifest, evidence: Evidence) throws {
        self.manifest = manifest
        self.evidence = evidence
        helper = ProductionHelperClient(evidence: evidence)
        controller = LoopbackController(address: manifest.controller, secret: manifest.fixtures.secret,
                                        evidence: evidence)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw AcceptanceFailure("Could not create isolated acceptance UserDefaults suite")
        }
        self.defaults = defaults
        proxyManager = SystemProxyManager(dependencies: SystemProxyDependencies(
            defaults: defaults,
            helper: { [weak self] failure in
                guard let self else { failure(); return nil }
                return self.helper.systemProxyClient(evidence: self.evidence,
                                                     snapshotCache: self.snapshotCache,
                                                     preferencesLocker: self.preferencesLocker,
                                                     failure: failure)
            },
            currentPorts: { (manifest.targetConfig.httpPort, manifest.targetConfig.socksPort) },
            shouldSuspend: { false },
            disableRestoreProxy: { false },
            filterInterface: { false },
            proxyIgnoreList: { ["localhost", "127.0.0.1", "::1"] },
            liveSystemPointsToClashFX: { [weak self] in
                guard let self else { return false }
                return SystemProxyOperationPolicy.isClashFXOwnedSnapshot(
                    ["active": self.snapshotCache.current()],
                    httpPort: manifest.targetConfig.httpPort,
                    socksPort: manifest.targetConfig.socksPort
                )
            },
            stageTimeout: 8,
            canControlRuntime: { [weak self] in self?.isCurrentClient() == true }
        ))
        Logger.observer = { [weak evidence] message, level in
            evidence?.record("systemProxyManagerLog", ["level": level.rawValue, "message": message])
        }
    }

    func begin() {
        evidence.record("clientStarted", [
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "effectiveUID": Int(geteuid()), "realUID": Int(getuid()),
            "controllerHost": manifest.controller.baseURL.host ?? "",
            "httpPort": manifest.targetConfig.httpPort,
            "socksPort": manifest.targetConfig.socksPort
        ])
        helper.helperProtocolVersion { result in
            switch result {
            case let .success(version):
                let pass = version == expectedHelperProtocolVersion
                self.evidence.assertion("Production Helper protocol version matches", passed: pass,
                                        evidence: ["actual": version, "expected": expectedHelperProtocolVersion])
                guard pass else { self.finish("failed"); return }
                    self.setCoverage("productionHelperXPC", true)
                self.inspectStartingCore()
            case let .failure(error):
                self.failAndFinish("helperProtocol", error.localizedDescription)
            }
        }
    }

    private func inspectStartingCore() {
        helper.coreStatus { result in
            switch result {
            case let .success(status):
                self.evidence.set("initialHelperCoreStatus", Self.redactedCoreStatus(status))
                let isRunning = (status["running"] as? NSNumber)?.boolValue ?? false
                self.evidence.assertion("Guest Helper has no pre-existing core", passed: !isRunning,
                                        evidence: Self.redactedCoreStatus(status))
                guard !isRunning else {
                    self.finish("refused")
                    return
                }
                self.captureCheckpoint(name: "initialProxyCheckpoint") { checkpoint in
                    self.setCoverage("realInitialProxyCheckpoint", true)
                    self.runSuccessfulTransaction(checkpoint)
                }
            case let .failure(error):
                self.failAndFinish("initialCoreStatus", error.localizedDescription)
            }
        }
    }

    private func captureCheckpoint(name: String, completion: @escaping (SystemProxyCheckpoint) -> Void) {
        proxyManager.captureCheckpoint { result in
            switch result {
            case let .success(checkpoint):
                self.snapshotCache.store(checkpoint.liveSnapshot)
                self.evidence.record("systemProxyCheckpointCaptured", [
                    "name": name,
                    "capturedServiceIDs": checkpoint.liveSnapshot[SystemProxyOperationPolicy.capturedServiceIDsKey] as? [String] ?? [],
                    "savedSnapshotValid": checkpoint.savedSnapshotValid,
                    "httpPort": checkpoint.httpPort,
                    "socksPort": checkpoint.socksPort
                ])
                self.evidence.set(name, [
                    "capturedServiceIDs": checkpoint.liveSnapshot[SystemProxyOperationPolicy.capturedServiceIDsKey] as? [String] ?? [],
                    "serviceCount": (checkpoint.liveSnapshot[SystemProxyOperationPolicy.capturedServiceIDsKey] as? [String] ?? []).count,
                    "savedSnapshotValid": checkpoint.savedSnapshotValid,
                    "httpPort": checkpoint.httpPort,
                    "socksPort": checkpoint.socksPort
                ])
                let serviceIDs = checkpoint.liveSnapshot[SystemProxyOperationPolicy.capturedServiceIDsKey] as? [String] ?? []
                self.evidence.assertion("Helper captured at least one System Proxy service", passed: !serviceIDs.isEmpty,
                                        evidence: ["serviceCount": serviceIDs.count])
                guard !serviceIDs.isEmpty else { self.finish("failed"); return }
                completion(checkpoint)
            case let .failure(error):
                self.failAndFinish(name, error.localizedDescription)
            }
        }
    }

    private func runSuccessfulTransaction(_ checkpoint: SystemProxyCheckpoint) {
        runTransaction(name: "success", runtimeConfig: manifest.targetConfig.path,
                       checkpoint: checkpoint, systemProxyMode: .normal) { failure in
            self.evidence.assertion("Production Claude transaction commits only after runtime and System Proxy succeed",
                                    passed: failure == nil && self.preferenceCommitCount == 1,
                                    evidence: ["failure": failure as Any? ?? NSNull(), "commitCount": self.preferenceCommitCount,
                                               "preferences": self.preferenceRecord()])
            guard failure == nil, self.preferenceCommitCount == 1 else { self.finish("failed"); return }
            self.setCoverage("productionClaudeTransactionSuccess", true)
            self.setCoverage("productionSystemProxyEnable", true)
            self.captureCheckpoint(name: "runtimeFailureCheckpoint") { nextCheckpoint in
                self.runInvalidRuntimeFailure(nextCheckpoint)
            }
        }
    }

    private func runInvalidRuntimeFailure(_ checkpoint: SystemProxyCheckpoint) {
        let oldPreferences = preferences
        let oldCommitCount = preferenceCommitCount
        latestRuntimeFailureEvidence = nil
        latestGoodRuntimeRestorePassed = false
        latestGoodRuntimeRestorePID = nil
        latestProxyRestorePassed = false
        runTransaction(name: "invalidRuntime", runtimeConfig: manifest.fixtures.invalidConfig,
                       checkpoint: checkpoint, systemProxyMode: .notReached) { failure in
            let commitDelta = self.preferenceCommitCount - oldCommitCount
            let noPreferenceMutation = self.preferences == oldPreferences && commitDelta == 0
            let observation = self.latestRuntimeFailureEvidence?["observation"] as? String
            let actualNotReady = observation != nil && observation != "unexpectedlyReady"
            let invalidPID = (self.latestRuntimeFailureEvidence?["pid"] as? NSNumber)?.intValue
            let recoveryPIDChanged = invalidPID != nil && self.latestGoodRuntimeRestorePID != nil &&
                invalidPID != self.latestGoodRuntimeRestorePID
            let passed = failure != nil && actualNotReady &&
                self.latestGoodRuntimeRestorePassed && recoveryPIDChanged && self.latestProxyRestorePassed && noPreferenceMutation
            self.evidence.assertion("Invalid config causes actual runtime rollback and exact proxy checkpoint restoration",
                                    passed: passed,
                                    evidence: [
                                        "transactionFailure": failure as Any? ?? NSNull(),
                                        "invalidRuntimeEvidence": self.latestRuntimeFailureEvidence as Any? ?? NSNull(),
                                        "actualNotReady": actualNotReady,
                                        "goodRuntimeRestored": self.latestGoodRuntimeRestorePassed,
                                        "invalidCorePID": invalidPID as Any? ?? NSNull(),
                                        "recoveryCorePID": self.latestGoodRuntimeRestorePID as Any? ?? NSNull(),
                                        "recoveryPIDChanged": recoveryPIDChanged,
                                        "proxyCheckpointRestored": self.latestProxyRestorePassed,
                                        "preferenceCommitDelta": commitDelta,
                                        "preferencesUnchanged": noPreferenceMutation
                                    ])
            self.setCoverage("productionClaudeRuntimeFailureRollback", failure != nil && actualNotReady)
            self.setCoverage("actualInvalidConfigNotReady", actualNotReady)
            self.setCoverage("runtimeRestoredWithProductionHelper", self.latestGoodRuntimeRestorePassed)
            self.setCoverage("newPIDRuntimeRecovery", recoveryPIDChanged)
            self.setCoverage("productionSystemProxyCheckpointRestore", self.latestProxyRestorePassed)
            self.setCoverage("failedTransactionPreferenceCommitDeltaZero", noPreferenceMutation)
            guard passed else { self.finish("failed"); return }
            self.captureCheckpoint(name: "lockedProxyFailureCheckpoint") { lockedCheckpoint in
                self.runLockedSystemProxyFailure(lockedCheckpoint)
            }
        }
    }

    private func runLockedSystemProxyFailure(_ checkpoint: SystemProxyCheckpoint) {
        let oldPreferences = preferences
        let oldCommitCount = preferenceCommitCount
        latestGoodRuntimeRestorePassed = false
        latestGoodRuntimeRestorePID = nil
        latestProxyRestorePassed = false
        let attemptName = "scPreferencesLock"
        evidence.addProxyAttempt(["name": attemptName, "managerCompleted": false,
                                  "helperEnableInvoked": false, "helperReplyObserved": false])

        runTransaction(name: "lockedSystemProxy", runtimeConfig: manifest.targetConfig.path,
                       checkpoint: checkpoint, systemProxyMode: .locked(attemptName)) { failure in
            let attempt = self.proxyAttempt(named: attemptName)
            let commitDelta = self.preferenceCommitCount - oldCommitCount
            let proxyFailureOccurred = (attempt?["managerReportedFailure"] as? Bool) == true
            let realHelperPathReached = (attempt?["helperEnableInvoked"] as? Bool) == true &&
                (attempt?["helperEnableInvokedWhileSCPreferencesLocked"] as? Bool) == true
            let helperReplyObserved = (attempt?["helperReplyObserved"] as? Bool) == true
            let lockReleased = (attempt?["scPreferencesUnlockSucceeded"] as? Bool) == true
            let noPreferenceMutation = self.preferences == oldPreferences && commitDelta == 0
            let passed = failure != nil && proxyFailureOccurred && realHelperPathReached && helperReplyObserved &&
                lockReleased && self.latestGoodRuntimeRestorePassed && self.latestProxyRestorePassed && noPreferenceMutation
            self.evidence.assertion("Real SCPreferences contention fails the production manager and restores runtime and proxy state",
                                    passed: passed,
                                    evidence: ["transactionFailure": failure as Any? ?? NSNull(),
                                               "proxyAttempt": attempt as Any? ?? NSNull(),
                                               "goodRuntimeRestored": self.latestGoodRuntimeRestorePassed,
                                               "proxyCheckpointRestored": self.latestProxyRestorePassed,
                                               "scPreferencesLockReleased": lockReleased,
                                               "preferenceCommitDelta": commitDelta,
                                               "preferencesUnchanged": noPreferenceMutation])
            self.setCoverage("realSCPreferencesLockFailure", proxyFailureOccurred && realHelperPathReached && helperReplyObserved)
            self.setCoverage("realSCPreferencesLockFailureRollback",
                             proxyFailureOccurred && realHelperPathReached && helperReplyObserved && lockReleased &&
                                self.latestGoodRuntimeRestorePassed && self.latestProxyRestorePassed && noPreferenceMutation)
            self.setCoverage("failedTransactionPreferenceCommitDeltaZero",
                             (self.coverage("failedTransactionPreferenceCommitDeltaZero") && noPreferenceMutation))
            self.setCoverage("productionSystemProxyCheckpointRestore",
                             (self.coverage("productionSystemProxyCheckpointRestore") && self.latestProxyRestorePassed))
            self.finish(passed ? "passed" : "failed")
        }
    }

    private enum SystemProxyMode {
        case normal
        case notReached
        case locked(String)
    }

    private func runTransaction(name: String, runtimeConfig: String,
                                checkpoint: SystemProxyCheckpoint,
                                systemProxyMode: SystemProxyMode,
                                completion: @escaping (String?) -> Void) {
        let transactionID = UUID()
        activeTransactionID = transactionID
        evidence.record("transactionStarted", ["name": name, "transactionID": transactionID.uuidString,
                                                "runtimeConfig": runtimeConfig])
        var runtimeRestoreSucceeded = false
        var proxyRestoreSucceeded = false
        let transaction = ClaudeProxyLockTransaction(dependencies: ClaudeProxyLockTransaction.Dependencies(
            isCurrent: { [weak self] in self?.isCurrent(transactionID) == true },
            applyRuntime: { [weak self] done in
                guard let self else { done("Acceptance client is unavailable"); return }
                if name == "invalidRuntime" {
                    self.startInvalidRuntime(configPath: runtimeConfig, completion: done)
                } else {
                    self.startAndWaitForRuntime(configPath: runtimeConfig, completion: done)
                }
            },
            applySystemProxy: { [weak self] done in
                guard let self else { done("Acceptance client is unavailable"); return }
                if case .notReached = systemProxyMode {
                    done("System Proxy stage should not be reached after invalid runtime")
                    return
                }
                let proxyAttemptName: String
                if case let .locked(attempt) = systemProxyMode {
                    proxyAttemptName = attempt
                    let lockResult = self.preferencesLocker.acquire()
                    self.evidence.updateProxyAttempt(name: attempt, fields: [
                        "scPreferencesLockAcquired": lockResult.0,
                        "scPreferencesLockError": lockResult.1 as Any? ?? NSNull(),
                        "scPreferencesLockHeldBeforeManagerEnable": lockResult.0
                    ])
                    guard lockResult.0 else {
                        done("Could not acquire the real SystemConfiguration preferences lock")
                        return
                    }
                } else {
                    proxyAttemptName = name
                    self.evidence.addProxyAttempt(["name": proxyAttemptName, "managerCompleted": false,
                                                   "helperEnableInvoked": false, "helperReplyObserved": false])
                }
                self.evidence.setActiveProxyAttempt(proxyAttemptName)
                self.proxyManager.enableProxy(
                    port: self.manifest.targetConfig.httpPort,
                    socksPort: self.manifest.targetConfig.socksPort,
                    isCurrent: { [weak self] in self?.isCurrent(transactionID) == true }
                ) { success in
                    self.evidence.setActiveProxyAttempt(nil)
                    if case .locked = systemProxyMode {
                        let unlocked = self.preferencesLocker.release()
                        self.evidence.updateProxyAttempt(name: proxyAttemptName, fields: [
                            "managerCompleted": true,
                            "managerReportedFailure": !success,
                            "scPreferencesUnlockSucceeded": unlocked,
                            "scPreferencesLockReleasedInManagerCompletion": true
                        ])
                    } else {
                        self.evidence.updateProxyAttempt(name: proxyAttemptName, fields: [
                            "managerCompleted": true,
                            "managerReportedSuccess": success
                        ])
                    }
                    guard success else {
                        done("Production SystemProxyManager reported a failed enable operation")
                        return
                    }
                    if case .locked = systemProxyMode {
                        done("SCPreferencesLock did not block or fail the production manager operation")
                        return
                    }
                    self.helper.proxySnapshot { result in
                        switch result {
                        case let .success(snapshot):
                            self.snapshotCache.store(snapshot)
                            let serviceIDs = checkpoint.liveSnapshot[SystemProxyOperationPolicy.capturedServiceIDsKey] as? [String] ?? []
                            let matchesAll = !serviceIDs.isEmpty && serviceIDs.allSatisfy { serviceID in
                                guard let settings = snapshot[serviceID] as? [String: Any] else { return false }
                                return SystemProxyOperationPolicy.isClashFXOwnedSnapshot(
                                    [serviceID: settings], httpPort: self.manifest.targetConfig.httpPort,
                                    socksPort: self.manifest.targetConfig.socksPort
                                )
                            }
                            self.evidence.updateProxyAttempt(name: proxyAttemptName, fields: [
                                "actualHelperReadbackMatchedEveryCapturedService": matchesAll,
                                "capturedServiceCount": serviceIDs.count
                            ])
                            done(matchesAll ? nil : "Actual Helper System Proxy readback did not match every captured service")
                        case let .failure(error):
                            done("Could not read actual System Proxy state after manager enable: \(error.localizedDescription)")
                        }
                    }
                }
            },
            prepareRollback: {
                self.evidence.record("transactionRollbackStarted", ["name": name, "transactionID": transactionID.uuidString])
            },
            restoreRuntime: { [weak self] done in
                guard let self else { done("Acceptance client is unavailable"); return }
                self.startAndWaitForRuntime(configPath: self.manifest.fixtures.goodConfig, completion: { error in
                    runtimeRestoreSucceeded = error == nil
                    if name == "invalidRuntime" || name == "lockedSystemProxy" {
                        self.latestGoodRuntimeRestorePassed = runtimeRestoreSucceeded
                        self.latestGoodRuntimeRestorePID = self.corePID
                    }
                    done(error)
                })
            },
            restoreSystemProxy: { [weak self] done in
                guard let self else { done("Acceptance client is unavailable"); return }
                let restoreWhenSafe = {
                    self.proxyManager.restoreCheckpoint(checkpoint, isCurrent: { self.isCurrent(transactionID) }) { success in
                        guard success else {
                            proxyRestoreSucceeded = false
                            self.latestProxyRestorePassed = false
                            done("Production SystemProxyManager could not restore its actual checkpoint")
                            return
                        }
                        self.helper.proxySnapshot { result in
                            switch result {
                            case let .success(actual):
                                self.snapshotCache.store(actual)
                                let exact = SystemProxyOperationPolicy.restoredSnapshotMatches(
                                    expected: checkpoint.liveSnapshot, actual: actual
                                )
                                proxyRestoreSucceeded = exact
                                self.latestProxyRestorePassed = exact
                                self.evidence.record("systemProxyCheckpointRestored", [
                                    "transaction": name, "exactMatch": exact,
                                    "capturedServiceCount": (checkpoint.liveSnapshot[SystemProxyOperationPolicy.capturedServiceIDsKey] as? [String] ?? []).count
                                ])
                                done(exact ? nil : "Actual Helper System Proxy snapshot did not exactly match the checkpoint")
                            case let .failure(error):
                                proxyRestoreSucceeded = false
                                self.latestProxyRestorePassed = false
                                done("Could not verify actual System Proxy checkpoint restore: \(error.localizedDescription)")
                            }
                        }
                    }
                }
                if case let .locked(attemptName) = systemProxyMode {
                    self.waitForHelperEnableReply(attemptName, deadline: Date().addingTimeInterval(lateProxyReplyDeadline)) { observed in
                        self.evidence.updateProxyAttempt(name: attemptName, fields: [
                            "lateHelperReplyObservedBeforeCheckpointRestore": observed
                        ])
                        guard observed else {
                            done("Timed out waiting for the real Helper enable reply to clear SystemProxyManager quarantine")
                            return
                        }
                        restoreWhenSafe()
                    }
                } else {
                    restoreWhenSafe()
                }
            },
            commit: {
                self.preferences.target = name == "success" ? self.manifest.targetConfig.path : runtimeConfig
                self.preferences.enabled = true
                self.preferences.enhanced = true
                self.preferences.mode = "rule"
                self.preferenceCommitCount += 1
                self.evidence.record("transactionPreferencesCommitted", [
                    "name": name, "commitCount": self.preferenceCommitCount,
                    "preferences": self.preferenceRecord()
                ])
            },
            finished: { [weak self] failure in
                guard let self else { completion("Acceptance client is unavailable"); return }
                self.evidence.record("transactionFinished", [
                    "name": name, "transactionID": transactionID.uuidString,
                    "failure": failure.map { ["primary": $0.primary,
                                              "restorationErrors": $0.restorationErrors,
                                              "cancelled": $0.cancelled] as [String: Any] } as Any? ?? NSNull(),
                    "runtimeRestoreSucceeded": runtimeRestoreSucceeded,
                    "proxyRestoreSucceeded": proxyRestoreSucceeded,
                    "preferenceCommitCount": self.preferenceCommitCount
                ])
                self.activeTransactionID = nil
                if case let .locked(attempt) = systemProxyMode {
                    self.evidence.setActiveProxyAttempt(nil)
                    if self.preferencesLocker.isHeld {
                        let unlocked = self.preferencesLocker.release()
                        self.evidence.updateProxyAttempt(name: attempt, fields: ["releasedDuringFinalization": true,
                                                                               "finalUnlockSucceeded": unlocked])
                    }
                }
                let failureText = failure.map { $0.primary }
                completion(failureText)
            }
        ))
        transaction.start()
    }

    private func startAndWaitForRuntime(configPath: String, completion: @escaping (String?) -> Void) {
        helper.coreStatus { result in
            guard case let .success(before) = result else {
                completion("Could not read Helper status before core start")
                return
            }
            let previousLaunch = before["launchID"] as? String
            let previousPIDValue = (before["pid"] as? NSNumber)?.intValue ?? 0
            let previousPID = previousPIDValue > 0 ? previousPIDValue : nil
            self.evidence.record("runtimeStartRequested", ["configPath": configPath,
                                                            "previousLaunchID": previousLaunch as Any? ?? NSNull(),
                                                            "previousPID": previousPID as Any? ?? NSNull()])
            self.helper.startCore(binary: self.manifest.fixtures.coreBinary,
                                  config: configPath, home: self.manifest.fixtures.homeDir) { result in
                switch result {
                case let .success(helperError):
                    self.evidence.record("runtimeStartReply", ["configPath": configPath,
                                                                "helperError": helperError as Any? ?? NSNull()])
                    if let helperError {
                        completion("Production Helper rejected core start: \(helperError)")
                        return
                    }
                    self.waitUntilReady(configPath: configPath, previousLaunchID: previousLaunch,
                                        previousPID: previousPID,
                                        deadline: Date().addingTimeInterval(controllerReadinessTimeout),
                                        completion: completion)
                case let .failure(error):
                    completion("Production Helper start request failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startInvalidRuntime(configPath: String, completion: @escaping (String?) -> Void) {
        helper.coreStatus { result in
            guard case let .success(before) = result else {
                completion("Could not read Helper status before invalid-config launch")
                return
            }
            let previousLaunch = before["launchID"] as? String
            self.evidence.record("invalidRuntimeStartRequested", ["configPath": configPath,
                                                                    "configExists": FileManager.default.fileExists(atPath: configPath),
                                                                    "previousLaunchID": previousLaunch as Any? ?? NSNull()])
            self.helper.startCore(binary: self.manifest.fixtures.coreBinary,
                                  config: configPath, home: self.manifest.fixtures.homeDir) { result in
                let replyError: String?
                switch result {
                case let .success(error):
                    replyError = error
                case let .failure(error):
                    replyError = error.localizedDescription
                }
                self.evidence.record("invalidRuntimeStartReply", ["helperReply": replyError as Any? ?? NSNull()])
                self.waitUntilInvalid(configPath: configPath, previousLaunchID: previousLaunch,
                                      deadline: Date().addingTimeInterval(invalidRuntimeDeadline),
                                      replyError: replyError, completion: completion)
            }
        }
    }

    private func waitUntilReady(configPath: String, previousLaunchID: String?, previousPID: Int?, deadline: Date,
                                completion: @escaping (String?) -> Void) {
        guard Date() < deadline else {
            completion("Mihomo did not become API/TUN ready before the \(Int(controllerReadinessTimeout)) second deadline")
            return
        }
        helper.coreStatus { result in
            guard case let .success(status) = result else {
                self.schedulePoll { self.waitUntilReady(configPath: configPath, previousLaunchID: previousLaunchID,
                                                        previousPID: previousPID,
                                                        deadline: deadline, completion: completion) }
                return
            }
            let running = (status["running"] as? NSNumber)?.boolValue ?? false
            let launchID = status["launchID"] as? String
            let pid = (status["pid"] as? NSNumber)?.intValue ?? 0
            let observedConfig = status["configPath"] as? String
            let pidChanged = previousPID == nil || pid != previousPID
            guard running, pid > 0, let launchID, !launchID.isEmpty,
                  launchID != previousLaunchID, pidChanged, observedConfig == configPath else {
                if !running, launchID != previousLaunchID,
                   let summary = status["lastTermination"] as? String {
                    completion("Helper-managed core exited before readiness: \(summary)")
                    return
                }
                self.schedulePoll { self.waitUntilReady(configPath: configPath, previousLaunchID: previousLaunchID,
                                                        previousPID: previousPID,
                                                        deadline: deadline, completion: completion) }
                return
            }
            self.controller.getJSON("version") { versionResult in
                guard case let .success(version) = versionResult else {
                    self.schedulePoll { self.waitUntilReady(configPath: configPath, previousLaunchID: previousLaunchID,
                                                            previousPID: previousPID,
                                                            deadline: deadline, completion: completion) }
                    return
                }
                self.controller.getJSON("configs") { configResult in
                    guard case let .success(config) = configResult else {
                        self.schedulePoll { self.waitUntilReady(configPath: configPath, previousLaunchID: previousLaunchID,
                                                                previousPID: previousPID,
                                                                deadline: deadline, completion: completion) }
                        return
                    }
                    let tun = config["tun"] as? [String: Any] ?? [:]
                    let tunReady = Self.bool(tun["enable"]) && Self.bool(tun["auto-route"]) &&
                        Self.bool(tun["auto-detect-interface"])
                    let mixedPort = Self.integer(config["mixed-port"])
                    let actualHTTPPort = mixedPort > 0 ? mixedPort : Self.integer(config["port"])
                    let actualSOCKSPort = mixedPort > 0 ? mixedPort : Self.integer(config["socks-port"])
                    let portsMatch = actualHTTPPort == self.manifest.targetConfig.httpPort &&
                        actualSOCKSPort == self.manifest.targetConfig.socksPort
                    let apiVersion = version["version"] as? String
                    guard tunReady, portsMatch, let apiVersion, !apiVersion.isEmpty else {
                        self.schedulePoll { self.waitUntilReady(configPath: configPath, previousLaunchID: previousLaunchID,
                                                                previousPID: previousPID,
                                                                deadline: deadline, completion: completion) }
                        return
                    }
                    self.helper.coreStatus { finalStatusResult in
                        guard case let .success(finalStatus) = finalStatusResult,
                              (finalStatus["running"] as? NSNumber)?.boolValue == true,
                              (finalStatus["launchID"] as? String) == launchID,
                              (finalStatus["pid"] as? NSNumber)?.intValue == pid,
                              (finalStatus["configPath"] as? String) == configPath else {
                            self.schedulePoll { self.waitUntilReady(configPath: configPath,
                                                                    previousLaunchID: previousLaunchID,
                                                                    previousPID: previousPID,
                                                                    deadline: deadline, completion: completion) }
                            return
                        }
                        self.coreLaunchID = launchID
                        self.corePID = pid
                        self.evidence.record("runtimeReady", ["configPath": configPath,
                                                              "launchID": launchID, "pid": pid,
                                                              "apiVersion": apiVersion, "tun": tun,
                                                              "httpPort": actualHTTPPort,
                                                              "socksPort": actualSOCKSPort])
                        completion(nil)
                    }
                }
            }
        }
    }

    private func waitUntilInvalid(configPath: String, previousLaunchID: String?, deadline: Date,
                                  replyError: String?, completion: @escaping (String?) -> Void) {
        helper.coreStatus { statusResult in
            guard case let .success(status) = statusResult else {
                if Date() >= deadline {
                    completion("Could not establish a new Helper launch identity for the invalid config")
                } else {
                    self.schedulePoll { self.waitUntilInvalid(configPath: configPath, previousLaunchID: previousLaunchID,
                                                             deadline: deadline, replyError: replyError,
                                                             completion: completion) }
                }
                return
            }
            let launchID = status["launchID"] as? String
            let observedConfig = status["configPath"] as? String
            let running = (status["running"] as? NSNumber)?.boolValue ?? false
            guard let launchID, launchID != previousLaunchID, observedConfig == configPath else {
                if Date() >= deadline {
                    completion("Helper did not report a new launch identity for the invalid config")
                } else {
                    self.schedulePoll { self.waitUntilInvalid(configPath: configPath, previousLaunchID: previousLaunchID,
                                                             deadline: deadline, replyError: replyError,
                                                             completion: completion) }
                }
                return
            }
            if !running, let summary = status["lastTermination"] as? String {
                self.invalidRuntimeEvidence(configPath: configPath, kind: "processExited",
                                            details: ["launchID": launchID,
                                                      "pid": (status["pid"] as? NSNumber)?.intValue ?? 0,
                                                      "lastTermination": summary,
                                                      "helperReply": replyError as Any? ?? NSNull()], completion: completion)
                return
            }
            if !running {
                if Date() >= deadline {
                    self.invalidRuntimeEvidence(configPath: configPath, kind: "processExitedWithoutSummary",
                                                details: ["launchID": launchID,
                                                          "pid": (status["pid"] as? NSNumber)?.intValue ?? 0,
                                                          "helperReply": replyError as Any? ?? NSNull()],
                                                completion: completion)
                } else {
                    self.schedulePoll { self.waitUntilInvalid(configPath: configPath,
                                                             previousLaunchID: previousLaunchID,
                                                             deadline: deadline, replyError: replyError,
                                                             completion: completion) }
                }
                return
            }
            self.controller.getJSON("version") { versionResult in
                switch versionResult {
                case .success:
                    self.controller.getJSON("configs") { configResult in
                        if case let .success(config) = configResult,
                           let tun = config["tun"] as? [String: Any],
                           Self.bool(tun["enable"]), Self.bool(tun["auto-route"]),
                           Self.bool(tun["auto-detect-interface"]) {
                            self.invalidRuntimeEvidence(configPath: configPath, kind: "unexpectedlyReady",
                                                        details: ["launchID": launchID, "running": running,
                                                                  "tun": tun, "helperReply": replyError as Any? ?? NSNull()],
                                                        completion: completion)
                            return
                        }
                        self.waitForInvalidDeadline(configPath: configPath, previousLaunchID: previousLaunchID,
                                                    deadline: deadline, replyError: replyError,
                                                    lastStatus: status, completion: completion)
                    }
                case let .failure(error):
                    self.waitForInvalidDeadline(configPath: configPath, previousLaunchID: previousLaunchID,
                                                deadline: deadline, replyError: replyError,
                                                lastStatus: status.merging(["controllerError": error.localizedDescription]) { _, new in new },
                                                completion: completion)
                }
            }
        }
    }

    private func waitForInvalidDeadline(configPath: String, previousLaunchID: String?, deadline: Date,
                                        replyError: String?, lastStatus: [String: Any],
                                        completion: @escaping (String?) -> Void) {
        guard Date() >= deadline else {
            self.schedulePoll { self.waitUntilInvalid(configPath: configPath, previousLaunchID: previousLaunchID,
                                                      deadline: deadline, replyError: replyError,
                                                      completion: completion) }
            return
        }
        invalidRuntimeEvidence(configPath: configPath, kind: "notReadyAtDeadline",
                               details: ["launchID": lastStatus["launchID"] as Any? ?? NSNull(),
                                         "pid": lastStatus["pid"] as Any? ?? NSNull(),
                                         "running": lastStatus["running"] as Any? ?? NSNull(),
                                         "controllerError": lastStatus["controllerError"] as Any? ?? NSNull(),
                                         "helperReply": replyError as Any? ?? NSNull()], completion: completion)
    }

    private func invalidRuntimeEvidence(configPath: String, kind: String, details: [String: Any],
                                        completion: @escaping (String?) -> Void) {
        var item: [String: Any] = ["configPath": configPath, "observation": kind]
        details.forEach { item[$0.key] = $0.value }
        latestRuntimeFailureEvidence = item
        evidence.record("invalidRuntimeFailureObserved", item)
        let message = kind == "unexpectedlyReady"
            ? "The manifest invalidConfig became API/TUN ready"
            : "Invalid config did not reach API/TUN readiness (\(kind))"
        completion(message)
    }

    private func waitForHelperEnableReply(_ attemptName: String, deadline: Date,
                                          completion: @escaping (Bool) -> Void) {
        if (proxyAttempt(named: attemptName)?["helperOperationSettled"] as? Bool) == true {
            completion(true)
            return
        }
        guard Date() < deadline else { completion(false); return }
        schedulePoll { self.waitForHelperEnableReply(attemptName, deadline: deadline, completion: completion) }
    }

    private func proxyAttempt(named name: String) -> [String: Any]? {
        evidence.proxyAttempt(name: name)
    }

    private func preferenceRecord() -> [String: Any] {
        ["target": preferences.target, "enabled": preferences.enabled,
         "enhanced": preferences.enhanced, "mode": preferences.mode]
    }

    private func coverage(_ key: String) -> Bool {
        coverageState[key] ?? false
    }

    private var coverageState: [String: Bool] = [:]

    private func setCoverage(_ key: String, _ value: Bool) {
        coverageState[key] = value
        evidence.setCoverage(key, value)
    }

    private func schedulePoll(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: action)
    }

    private func isCurrentClient() -> Bool {
        active && evidence.isActive()
    }

    private func isCurrent(_ transactionID: UUID) -> Bool {
        active && activeTransactionID == transactionID && evidence.isActive()
    }

    private func failAndFinish(_ phase: String, _ message: String) {
        evidence.fail(phase, message)
        finish("failed")
    }

    private func finish(_ status: String) {
        guard !didFinish else { return }
        didFinish = true
        active = false
        activeTransactionID = nil
        evidence.deactivate()
        if preferencesLocker.isHeld {
            let unlocked = preferencesLocker.release()
            evidence.record("SCPreferencesLockReleasedAtClientFinish", ["success": unlocked])
        }
        evidence.set("finalCoreLaunchID", coreLaunchID as Any? ?? NSNull())
        evidence.set("applicationPreferenceMetadata", preferenceRecord())
        evidence.set("applicationPreferenceCommitCount", preferenceCommitCount)
        let allCoverage = evidence.allCoverageIsTrue()
        let controlPassed = status == "passed" && allCoverage
        let resolvedStatus = status == "passed" && !allCoverage ? "failed" : status
        exitCode = controlPassed ? 0 : (resolvedStatus == "refused" ? 2 : 1)
        evidence.set("controlPassed", controlPassed)
        evidence.setCoverage("controlPassed", controlPassed)
        let result = evidence.finish(status: resolvedStatus, outputURL: manifest.outputURL)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        defaults.removePersistentDomain(forName: suiteName)
        Logger.observer = nil
        CFRunLoopStop(CFRunLoopGetMain())
    }

    var processExitCode: Int32 { exitCode }
    var isFinished: Bool { didFinish }

    private static func redactedCoreStatus(_ status: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        ["running", "pid", "launchID", "configPath", "binaryPath", "lastTermination"].forEach { key in
            if let value = status[key] { result[key] = value }
        }
        return result
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}

private enum ClientEntry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "--manifest", arguments[1].hasPrefix("/") else {
            emitAndExit(["status": "refused", "reason": "Expected exactly --manifest <runner-created-absolute-json-path>"], code: 64)
        }
        let gate = hostedGuestGate()
        guard gate.failures.isEmpty else {
            emitAndExit(["status": "refused", "reason": gate.failures,
                         "platform": gate.platform, "realUID": gate.realUID,
                         "effectiveUID": gate.effectiveUID,
                         "githubActions": gate.environment["GITHUB_ACTIONS"] ?? "",
                         "runnerEnvironment": gate.environment["RUNNER_ENVIRONMENT"] ?? ""], code: 2)
        }

        var confinedManifestURL: URL?
        do {
            guard let workspace = gate.environment["GITHUB_WORKSPACE"],
                  let runnerTemp = gate.environment["RUNNER_TEMP"] else {
                throw AcceptanceFailure("GITHUB_WORKSPACE and RUNNER_TEMP are required on the hosted guest")
            }
            let confinedFixtureURL = try confinedURL(arguments[1],
                                                      workspace: URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL,
                                                      runnerTemp: URL(fileURLWithPath: runnerTemp, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL,
                                                      mustExist: true)
            confinedManifestURL = confinedFixtureURL
            let data = try Data(contentsOf: confinedFixtureURL)
            let fixtures = try JSONDecoder().decode(Fixtures.self, from: data)
            let validated = try validate(fixtures: fixtures, environment: gate.environment)
            guard Bundle.main.bundleIdentifier == expectedClientBundleIdentifier,
                  Bundle.main.bundleURL.pathExtension == "app" else {
                throw AcceptanceFailure("Client must run from an ad-hoc-signed ClashFX.app bundle")
            }
            let evidence = Evidence(environment: [
                "platform": gate.platform,
                "githubActions": gate.environment["GITHUB_ACTIONS"] ?? "",
                "runnerEnvironment": gate.environment["RUNNER_ENVIRONMENT"] ?? "",
                "realUID": gate.realUID,
                "effectiveUID": gate.effectiveUID,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "clientExecutable": Bundle.main.executableURL?.path ?? "",
                "fixtureManifest": confinedFixtureURL.path
            ])
            let run = try AcceptanceRun(manifest: validated, evidence: evidence)
            run.begin()
            while !run.isFinished {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            exit(run.processExitCode)
        } catch {
            var output: [String: Any] = ["status": "failed", "reason": error.localizedDescription]
            if let confinedManifestURL,
               let outputPath = try? extractOutputPath(from: confinedManifestURL),
               let outputURL = validatedOutputURL(outputPath, environment: gate.environment) {
                output["outputJSON"] = outputURL.path
                if let encoded = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
                    try? encoded.write(to: outputURL, options: .atomic)
                }
            }
            emitAndExit(output, code: 1)
        }
    }

    private static func hostedGuestGate() -> (failures: [String], environment: [String: String], platform: String,
                                              realUID: Int, effectiveUID: Int) {
        let environment = ProcessInfo.processInfo.environment
        var failures: [String] = []
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "non-macOS"
        failures.append("Darwin/macOS is required")
        #endif
        if environment["GITHUB_ACTIONS"] != "true" { failures.append("GITHUB_ACTIONS must equal true") }
        if environment["RUNNER_ENVIRONMENT"] != "github-hosted" {
            failures.append("RUNNER_ENVIRONMENT must equal github-hosted")
        }
        if environment["RUNNER_OS"] != "macOS" { failures.append("RUNNER_OS must equal macOS") }
        let realUID = Int(getuid())
        let effectiveUID = Int(geteuid())
        let validGuestIdentity = (realUID == 501 && (effectiveUID == 501 || effectiveUID == 0)) ||
            (realUID == 0 && effectiveUID == 0)
        if !validGuestIdentity { failures.append("real/effective UID must identify the hosted guest user 501 or root") }
        return (failures, environment, platform, realUID, effectiveUID)
    }

    private static func validate(fixtures: Fixtures, environment: [String: String]) throws -> ValidatedManifest {
        guard !fixtures.secret.isEmpty else { throw AcceptanceFailure("Manifest secret must not be empty") }
        guard let controllerComponents = URLComponents(string: fixtures.controllerURL),
              controllerComponents.scheme?.lowercased() == "http",
              let host = controllerComponents.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              let port = controllerComponents.port, (1 ... 65_535).contains(port),
              controllerComponents.user == nil, controllerComponents.password == nil,
              controllerComponents.query == nil, controllerComponents.fragment == nil,
              controllerComponents.path.isEmpty || controllerComponents.path == "/" else {
            throw AcceptanceFailure("controllerURL must be an HTTP loopback base URL with an explicit port")
        }
        guard let baseURL = controllerComponents.url else { throw AcceptanceFailure("controllerURL is malformed") }
        guard let workspace = environment["GITHUB_WORKSPACE"],
              let runnerTemp = environment["RUNNER_TEMP"] else {
            throw AcceptanceFailure("GITHUB_WORKSPACE and RUNNER_TEMP are required on the hosted guest")
        }
        let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let runnerTempURL = URL(fileURLWithPath: runnerTemp, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: workspaceURL.path),
              FileManager.default.fileExists(atPath: runnerTempURL.path) else {
            throw AcceptanceFailure("Hosted workspace and runner temp directories must already exist")
        }
        for path in [fixtures.coreBinary, fixtures.homeDir, fixtures.goodConfig, fixtures.invalidConfig,
                     fixtures.outputJSON] + (fixtures.alternateConfig.map { [$0] } ?? []) {
            guard URL(fileURLWithPath: path).isFileURL, path.hasPrefix("/") else {
                throw AcceptanceFailure("Manifest file paths must be absolute: \(path)")
            }
        }
        let coreURL = try confinedURL(fixtures.coreBinary, workspace: workspaceURL, runnerTemp: runnerTempURL,
                                      mustExist: true)
        guard FileManager.default.isExecutableFile(atPath: coreURL.path) else {
            throw AcceptanceFailure("coreBinary is not executable")
        }
        let homeURL = try confinedURL(fixtures.homeDir, workspace: workspaceURL, runnerTemp: runnerTempURL,
                                      mustExist: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: homeURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AcceptanceFailure("homeDir must be a runner-created directory")
        }
        let goodURL = try confinedURL(fixtures.goodConfig, workspace: workspaceURL, runnerTemp: runnerTempURL,
                                      mustExist: true)
        let invalidURL = try confinedURL(fixtures.invalidConfig, workspace: workspaceURL, runnerTemp: runnerTempURL,
                                         mustExist: false)
        let controller = ControllerAddress(baseURL: baseURL, port: port)
        let goodConfig = try ConfigFixture.load(path: goodURL.path, expectedController: controller, secret: fixtures.secret)
        var alternateConfig: ConfigFixture?
        if let alternate = fixtures.alternateConfig {
            let alternateURL = try confinedURL(alternate, workspace: workspaceURL, runnerTemp: runnerTempURL,
                                               mustExist: true)
            let loaded = try ConfigFixture.load(path: alternateURL.path, expectedController: controller,
                                                secret: fixtures.secret)
            guard loaded.httpPort == goodConfig.httpPort, loaded.socksPort == goodConfig.socksPort else {
                throw AcceptanceFailure("alternateConfig must preserve goodConfig HTTP and SOCKS ports")
            }
            alternateConfig = loaded
        }
        guard invalidURL.path != goodURL.path,
              invalidURL.path != alternateConfig?.path else {
            throw AcceptanceFailure("invalidConfig must be separate from the valid runtime configs")
        }
        let outputURL = try validatedOutputURL(fixtures.outputJSON, workspace: workspaceURL,
                                               runnerTemp: runnerTempURL)
        return ValidatedManifest(fixtures: Fixtures(controllerURL: baseURL.absoluteString,
                                                     secret: fixtures.secret, coreBinary: coreURL.path,
                                                     homeDir: homeURL.path, goodConfig: goodURL.path,
                                                     alternateConfig: alternateConfig?.path,
                                                     invalidConfig: invalidURL.path,
                                                     outputJSON: outputURL.path),
                                 controller: controller,
                                 targetConfig: alternateConfig ?? goodConfig,
                                 goodConfig: goodConfig, alternateConfig: alternateConfig,
                                 workspaceURL: workspaceURL, runnerTempURL: runnerTempURL,
                                 outputURL: outputURL)
    }

    private static func confinedURL(_ path: String, workspace: URL, runnerTemp: URL,
                                    mustExist: Bool) throws -> URL {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        if mustExist && !FileManager.default.fileExists(atPath: candidate.path) {
            throw AcceptanceFailure("Runner fixture does not exist: \(path)")
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved, root: workspace) || isInside(resolved, root: runnerTemp) else {
            throw AcceptanceFailure("Runner fixture must remain inside GITHUB_WORKSPACE or RUNNER_TEMP: \(path)")
        }
        return resolved
    }

    private static func validatedOutputURL(_ path: String, workspace: URL, runnerTemp: URL) throws -> URL {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              isInside(parent, root: workspace) || isInside(parent, root: runnerTemp) else {
            throw AcceptanceFailure("outputJSON parent must be a runner-created directory inside the workspace or runner temp")
        }
        return parent.appendingPathComponent(candidate.lastPathComponent, isDirectory: false)
    }

    private static func validatedOutputURL(_ path: String, environment: [String: String]) -> URL? {
        guard let workspace = environment["GITHUB_WORKSPACE"], let runnerTemp = environment["RUNNER_TEMP"] else { return nil }
        do {
            return try validatedOutputURL(path,
                                         workspace: URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL,
                                         runnerTemp: URL(fileURLWithPath: runnerTemp, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL)
        } catch { return nil }
    }

    private static func extractOutputPath(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: data)
        return fixtures.outputJSON
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private static func emitAndExit(_ object: [String: Any], code: Int32) -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        exit(code)
    }

}

@main
private struct HelperTUNProductionTransactionMain {
    static func main() {
        ClientEntry.main()
    }
}


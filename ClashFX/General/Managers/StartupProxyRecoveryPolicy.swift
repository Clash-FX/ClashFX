//
//  StartupProxyRecoveryPolicy.swift
//  ClashFX
//

import Foundation

struct StartupProxyRecoveryObservation {
    let wantsSystemProxy: Bool
    let proxyPaused: Bool
    let enhancedModeActive: Bool
    let initialConfigLoaded: Bool
    let coreRunning: Bool
    let httpPort: Int
    let socksPort: Int
    let helperReady: Bool
    let primaryInterfaceReady: Bool
}

enum StartupProxyRecoveryDecision: Equatable {
    case stop
    case waitForConfig
    case waitForCore
    case waitForHelper
    case waitForNetwork
    case verifyAndApply
}

enum StartupProxyRecoveryPolicy {
    static func decide(_ observation: StartupProxyRecoveryObservation) -> StartupProxyRecoveryDecision {
        guard observation.wantsSystemProxy,
              !observation.proxyPaused,
              !observation.enhancedModeActive else {
            return .stop
        }
        guard observation.initialConfigLoaded,
              observation.httpPort > 0,
              observation.socksPort > 0 else {
            return .waitForConfig
        }
        guard observation.coreRunning else { return .waitForCore }
        guard observation.helperReady else { return .waitForHelper }
        guard observation.primaryInterfaceReady else { return .waitForNetwork }
        return .verifyAndApply
    }
}

enum RuntimeDataPlaneProbeOutcome {
    case healthy
    case confirmedCoreFailure
    case baselineUnavailable
}

enum EnhancedModeRuntimeFailureKind {
    case apiUnavailable
    case tunDisabled
    case tunInterfaceUnavailable
    case physicalNetworkUnavailable
}

struct EnhancedModeLifecycleIdentity: Equatable {
    let generation: UInt64
    let launchID: UUID
}

final class EnhancedModeLifecycleCoordinator {
    private(set) var generation: UInt64 = 0
    private(set) var launchID: UUID?
    private(set) var closeID: UUID?

    @discardableResult
    func beginLaunch() -> UInt64 {
        generation &+= 1
        launchID = UUID()
        closeID = nil
        return generation
    }

    @discardableResult
    func beginLaunchAttempt() -> UUID {
        let id = UUID()
        launchID = id
        return id
    }

    func beginClose() -> (generation: UInt64, id: UUID) {
        generation &+= 1
        launchID = nil
        let id = UUID()
        closeID = id
        return (generation, id)
    }

    @discardableResult
    func invalidate() -> UInt64 {
        generation &+= 1
        launchID = nil
        closeID = nil
        return generation
    }

    func finishClose(id: UUID) {
        guard closeID == id else { return }
        closeID = nil
    }

    func isCurrentLaunch(_ identity: EnhancedModeLifecycleIdentity, isTerminating: Bool) -> Bool {
        EnhancedModeLifecyclePolicy.isCurrent(
            identity: identity,
            generation: generation,
            launchID: launchID,
            isTerminating: isTerminating
        )
    }

    func isCurrentClose(generation expectedGeneration: UInt64, id: UUID, isTerminating: Bool) -> Bool {
        !isTerminating && generation == expectedGeneration && closeID == id
    }
}

final class EnhancedModeCompletionGate {
    private let lock = NSLock()
    private var isFinished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        isFinished = true
        return true
    }
}

final class ConfigUpdateTransactionCoordinator {
    private(set) var activeID: UUID?

    @discardableResult
    func begin() -> UUID {
        let id = UUID()
        activeID = id
        return id
    }

    @discardableResult
    func finish(id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}

enum EnhancedModeLifecyclePolicy {
    static func isCurrent(
        identity: EnhancedModeLifecycleIdentity,
        generation: UInt64,
        launchID: UUID?,
        isTerminating: Bool
    ) -> Bool {
        !isTerminating && identity.generation == generation && identity.launchID == launchID
    }

    static func shouldContinueWaiting(deadline: Date, now: Date) -> Bool {
        now < deadline
    }

    static func finishCloseShouldRestoreCore(
        generation: UInt64,
        currentGeneration: UInt64,
        isTerminating: Bool
    ) -> Bool {
        !isTerminating && generation == currentGeneration
    }

    static func finishConfigUpdateShouldApply(
        transactionID: UUID,
        activeTransactionID: UUID?,
        isTerminating: Bool
    ) -> Bool {
        !isTerminating && transactionID == activeTransactionID
    }
}

enum DNSReadiness: Equatable {
    case protocolResponding
    case upstreamHealthy
    case invalidResponse
}

enum EnhancedModeDNSReadinessPolicy {
    struct Response {
        let responseCode: UInt8
        let answerCount: Int
        let hasResponseFlag: Bool
    }

    static func parseResponse(
        _ data: Data,
        transactionID: UInt16,
        expectedQuestion: [UInt8]
    ) -> Response? {
        let bytes = Array(data)
        // DNS header: ID, flags, QDCOUNT, ANCOUNT, NSCOUNT, ARCOUNT.
        // Additional records (for example EDNS) are optional; QDCOUNT owns
        // the echoed question. RCODE is in the low byte of the flags word.
        guard bytes.count >= 12,
              bytes[0] == UInt8(transactionID >> 8),
              bytes[1] == UInt8(transactionID & 0xff),
              bytes[4] == 0, bytes[5] == 1,
              bytes.count >= 12 + expectedQuestion.count,
              Array(bytes[12 ..< (12 + expectedQuestion.count)]) == expectedQuestion else { return nil }
        let flags = bytes[2]
        let answerCount = (Int(bytes[6]) << 8) | Int(bytes[7])
        return Response(
            responseCode: bytes[3] & 0x0f,
            answerCount: answerCount,
            hasResponseFlag: flags & 0x80 != 0 && flags & 0x02 == 0
        )
    }

    static func readTCPMessage(readChunk: (Int) -> Data?) -> Data? {
        guard let prefix = readExactly(2, readChunk: readChunk),
              let length = framedMessageLength(prefix: Array(prefix)),
              length >= 12,
              let message = readExactly(length, readChunk: readChunk) else { return nil }
        return message
    }

    private static func readExactly(_ length: Int, readChunk: (Int) -> Data?) -> Data? {
        var result = Data()
        while result.count < length {
            guard let chunk = readChunk(length - result.count), !chunk.isEmpty else { return nil }
            result.append(chunk.prefix(length - result.count))
        }
        return result
    }

    struct HelperListenerSnapshot {
        let helperIsRunning: Bool
        let processID: Int
        let helperConfigPath: String?
        let launchLog: String
        let tcpListenPorts: [Int]
        let udpListenPorts: [Int]
    }

    struct ExpectedListeners {
        let expectedConfigPath: String
        let proxyPorts: [Int]
        let apiPort: Int
        let port: Int
    }

    static func currentLaunchOwnsDNSListeners(
        observed: HelperListenerSnapshot,
        expected: ExpectedListeners
    ) -> Bool {
        guard observed.helperIsRunning, observed.processID > 0,
              observed.helperConfigPath == expected.expectedConfigPath,
              expected.apiPort > 0, expected.port > 0 else { return false }
        let suffix = ":\(expected.port)"
        let hasUDPBind = observed.launchLog.contains("DNS server(UDP) listening at: 127.0.0.1\(suffix)") ||
            observed.launchLog.contains("DNS server(UDP) listening at: 0.0.0.0\(suffix)")
        let hasTCPBind = observed.launchLog.contains("DNS server(TCP) listening at: 127.0.0.1\(suffix)") ||
            observed.launchLog.contains("DNS server(TCP) listening at: 0.0.0.0\(suffix)")
        return hasUDPBind && hasTCPBind &&
            observed.tcpListenPorts.contains(expected.port) && observed.udpListenPorts.contains(expected.port) &&
            observed.tcpListenPorts.contains(expected.apiPort) &&
            expected.proxyPorts.allSatisfy(observed.tcpListenPorts.contains)
    }

    static func classify(responseCode: UInt8, answerCount: Int, hasResponseFlag: Bool) -> DNSReadiness {
        guard hasResponseFlag else { return .invalidResponse }
        // A DNS daemon can be correctly bound and answer SERVFAIL while its
        // upstream is transiently unavailable. That is protocol readiness,
        // but not proof of a healthy upstream.
        guard responseCode == 0, answerCount > 0 else { return .protocolResponding }
        return .upstreamHealthy
    }

    static func launchProtocolReady(
        ownsCurrentLaunchListeners: Bool,
        udp: Response?,
        tcp: Response?
    ) -> Bool {
        guard ownsCurrentLaunchListeners,
              let udp,
              let tcp else { return false }
        return classify(
            responseCode: udp.responseCode,
            answerCount: udp.answerCount,
            hasResponseFlag: udp.hasResponseFlag
        ) != .invalidResponse &&
            classify(
                responseCode: tcp.responseCode,
                answerCount: tcp.answerCount,
                hasResponseFlag: tcp.hasResponseFlag
            ) != .invalidResponse
    }

    static func framedMessageLength(prefix: [UInt8]) -> Int? {
        guard prefix.count >= 2 else { return nil }
        return (Int(prefix[0]) << 8) | Int(prefix[1])
    }

    static func retargetLoopbackServers(_ value: Any, to port: Int) -> Any {
        let replacement = { (server: String) -> String in
            guard let expression = try? NSRegularExpression(
                pattern: #"(127\.0\.0\.1:|localhost:|\[::1\]:)\d+"#
            ) else { return server }
            let range = NSRange(server.startIndex ..< server.endIndex, in: server)
            return expression.stringByReplacingMatches(
                in: server,
                range: range,
                withTemplate: "$1\(port)"
            )
        }
        if let server = value as? String {
            return replacement(server)
        }
        if let servers = value as? [String] {
            return servers.map(replacement)
        }
        if let servers = value as? [Any] {
            return servers.map { retargetLoopbackServers($0, to: port) }
        }
        if let policy = value as? [String: Any] {
            return policy.mapValues { retargetLoopbackServers($0, to: port) }
        }
        return value
    }

    static func preserveDNSListenPort(in config: inout [String: Any], port: Int) -> Bool {
        guard port > 0, var dns = config["dns"] as? [String: Any] else { return false }
        dns["listen"] = "127.0.0.1:\(port)"
        for key in ["nameserver", "default-nameserver", "fallback", "proxy-server-nameserver", "nameserver-policy"] {
            if let value = dns[key] {
                dns[key] = retargetLoopbackServers(value, to: port)
            }
        }
        config["dns"] = dns
        return true
    }
}

enum EnhancedModeRuntimeRecoveryPolicy {
    static func shouldRecover(
        from failure: EnhancedModeRuntimeFailureKind,
        trafficIsFlowing: Bool
    ) -> Bool {
        switch failure {
        case .tunDisabled, .tunInterfaceUnavailable:
            return true
        case .apiUnavailable:
            return !trafficIsFlowing
        case .physicalNetworkUnavailable:
            return false
        }
    }
}

enum RuntimeDataPlaneFailurePolicy {
    static func nextFailureCount(
        current: Int,
        outcome: RuntimeDataPlaneProbeOutcome
    ) -> Int {
        switch outcome {
        case .healthy:
            return 0
        case .confirmedCoreFailure:
            return current + 1
        case .baselineUnavailable:
            // An unavailable independent baseline is inconclusive. Preserve the
            // prior evidence but neither forgive it nor count a new failure.
            return current
        }
    }
}

struct CoreCPUWatchdogSample: Equatable {
    let launchID: String
    let processIdentifier: Int
    let cpuTime: TimeInterval
    let sampleUptime: TimeInterval
}

enum CoreCPUWatchdogDecision: Equatable {
    case invalid
    case baseline
    case normal(utilization: Double)
    case elevated(utilization: Double, consecutiveSamples: Int)
    case captureDiagnostic(utilization: Double, consecutiveSamples: Int)
    case recover(utilization: Double, consecutiveSamples: Int)
}

/// Detects a process consuming approximately one complete CPU core over a
/// sustained period. Samples are tied to the helper launch identity and PID so
/// delayed replies from an older core cannot accumulate toward recovery.
struct CoreCPUWatchdogPolicy {
    let utilizationThreshold: Double
    let diagnosticSampleCount: Int
    let recoverySampleCount: Int
    let maximumSampleInterval: TimeInterval

    private var previousSample: CoreCPUWatchdogSample?
    private var consecutiveElevatedSamples = 0
    private var didRequestDiagnostic = false

    init(utilizationThreshold: Double = 0.90,
         diagnosticSampleCount: Int = 8,
         recoverySampleCount: Int = 12,
         maximumSampleInterval: TimeInterval = 45) {
        let validatedDiagnosticSampleCount = max(1, diagnosticSampleCount)
        self.utilizationThreshold = utilizationThreshold
        self.diagnosticSampleCount = validatedDiagnosticSampleCount
        self.recoverySampleCount = max(
            validatedDiagnosticSampleCount + 1,
            recoverySampleCount
        )
        self.maximumSampleInterval = maximumSampleInterval
    }

    mutating func reset() {
        previousSample = nil
        consecutiveElevatedSamples = 0
        didRequestDiagnostic = false
    }

    mutating func observe(_ sample: CoreCPUWatchdogSample) -> CoreCPUWatchdogDecision {
        guard sample.processIdentifier > 0,
              !sample.launchID.isEmpty,
              sample.cpuTime.isFinite,
              sample.sampleUptime.isFinite,
              sample.cpuTime >= 0,
              sample.sampleUptime >= 0 else {
            reset()
            return .invalid
        }

        guard let previousSample,
              previousSample.launchID == sample.launchID,
              previousSample.processIdentifier == sample.processIdentifier else {
            reset()
            previousSample = sample
            return .baseline
        }

        let elapsed = sample.sampleUptime - previousSample.sampleUptime
        let consumedCPU = sample.cpuTime - previousSample.cpuTime
        self.previousSample = sample
        guard elapsed > 0,
              elapsed <= maximumSampleInterval,
              consumedCPU >= 0,
              consumedCPU.isFinite else {
            consecutiveElevatedSamples = 0
            didRequestDiagnostic = false
            return .baseline
        }

        let utilization = consumedCPU / elapsed
        guard utilization.isFinite, utilization >= 0 else {
            reset()
            return .invalid
        }
        guard utilization >= utilizationThreshold else {
            consecutiveElevatedSamples = 0
            didRequestDiagnostic = false
            return .normal(utilization: utilization)
        }

        consecutiveElevatedSamples += 1
        if consecutiveElevatedSamples >= recoverySampleCount {
            let count = consecutiveElevatedSamples
            consecutiveElevatedSamples = 0
            didRequestDiagnostic = false
            return .recover(utilization: utilization, consecutiveSamples: count)
        }
        if consecutiveElevatedSamples >= diagnosticSampleCount,
           !didRequestDiagnostic {
            didRequestDiagnostic = true
            return .captureDiagnostic(
                utilization: utilization,
                consecutiveSamples: consecutiveElevatedSamples
            )
        }
        return .elevated(
            utilization: utilization,
            consecutiveSamples: consecutiveElevatedSamples
        )
    }
}

enum WakeRecoveryRetryPolicy {
    static func delay(
        baseDelay: TimeInterval,
        maximumAttempts: Int,
        attemptsLeft: Int
    ) -> TimeInterval {
        let completedAttempts = max(0, maximumAttempts - attemptsLeft)
        return min(baseDelay * pow(2, Double(completedAttempts)), 8)
    }
}

enum PortPreferencePolicy {
    static func editableText(configuredPort: Int) -> String {
        configuredPort > 0 ? String(configuredPort) : ""
    }

    static func configuredPort(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard let port = Int(trimmed), (1 ... 65_535).contains(port) else {
            return nil
        }
        return port
    }

    static func runtimeFallback(
        configuredPort: Int,
        runtimePort: Int
    ) -> (configured: Int, runtime: Int)? {
        guard configuredPort > 0,
              runtimePort > 0,
              configuredPort != runtimePort else { return nil }
        return (configuredPort, runtimePort)
    }
}

import CoreFoundation
import Foundation

/// Transport failures are not evidence that a proxy is dead.
enum ProxyDelayOutcome: Equatable {
    case measured(Int)
    case failed
    case timedOut
    case unavailable
    case cancelled

    var delay: Int? {
        switch self {
        case let .measured(value): return value
        case .failed: return 0
        case .timedOut, .unavailable, .cancelled: return nil
        }
    }

    func rowState(name: String) -> ProxyBenchmarkRowState {
        switch self {
        case let .measured(value): return .measured(displayName: name, delay: value)
        case .failed: return .failed(displayName: name)
        case .timedOut: return .timedOut(displayName: name)
        case .unavailable, .cancelled: return .unavailable(displayName: name)
        }
    }

    static func decode(statusCode: Int?, data: Data?, transportFailed: Bool,
                       cancelled: Bool = false) -> ProxyDelayOutcome {
        if cancelled { return .cancelled }
        guard !transportFailed, let statusCode, let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable
        }
        if (200 ..< 300).contains(statusCode) {
            // JSON booleans bridge to NSNumber too; reject them, fractions and
            // malformed payloads instead of manufacturing a failed probe.
            guard let number = object["delay"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  (0.0 ... 65535.0).contains(number.doubleValue) else { return .unavailable }
            return number.intValue > 0 ? .measured(number.intValue) : .failed
        }
        // Newer cores include a typed failure code. Require its HTTP status to
        // agree with the probe result before trusting it.
        let message = object["message"] as? String
        let typedCode = (object["clashfx_probe_error"] as? [String: Any])?["code"] as? String
        if statusCode == 503 {
            if typedCode == "probe_timeout" { return .unavailable }
            if let typedCode, Self.knownCoreFailureCodes.contains(typedCode) {
                return .failed
            }
            // Older cores have no typed envelope; retain their stable message.
            if message == "An error occurred in the delay test" { return .failed }
        }
        if statusCode == 504 {
            if typedCode == "probe_timeout" { return .timedOut }
            if let typedCode, Self.knownCoreFailureCodes.contains(typedCode) {
                return .unavailable
            }
            // Older cores have no typed envelope; retain their stable message.
            if message == "Timeout" { return .timedOut }
        }
        return .unavailable
    }

    private static let knownCoreFailureCodes: Set<String> = [
        "authentication_failed",
        "dial_failed",
        "dns_resolution_failed",
        "dns_timeout",
        "http_request_failed",
        "probe_failed",
        "probe_timeout",
        "quic_handshake_failed",
        "tls_expired",
        "tls_failure",
        "tls_name_mismatch",
        "tls_unknown_authority",
        "zero_delay",
    ]
}

struct BenchmarkConditions: Hashable {
    let url: String
    let expectedStatus: String?

    init(url: String, expectedStatus: String? = nil) {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = expectedStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expectedStatus = status?.isEmpty == false ? status : nil
    }
}

enum ProxyGroupDelayOutcome {
    case success([ClashProxyName: Int])
    case empty
    case allFailed
    case httpFailure(statusCode: Int, description: String)
    case cancelled

    var candidateDelays: [ClashProxyName: Int] {
        if case let .success(values) = self { return values }
        return [:]
    }

    var hasProbeEvidence: Bool {
        switch self {
        case .success, .allFailed: return true
        default: return false
        }
    }

    var diagnostic: String {
        switch self {
        case let .success(values): return "success: \(values.count) candidate(s)"
        case .empty: return "empty candidate response"
        case .allFailed: return "all candidates failed"
        case let .httpFailure(code, description): return "HTTP \(code): \(description)"
        case .cancelled: return "cancelled"
        }
    }

    static func decode(statusCode: Int, data: Data?, transportFailed: Bool) -> Self {
        guard !transportFailed, let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .httpFailure(statusCode: statusCode, description: "unavailable response")
        }
        if statusCode == 504, object["message"] as? String == "get delay: all proxies timeout" {
            return .allFailed
        }
        guard (200 ..< 300).contains(statusCode) else {
            return .httpFailure(statusCode: statusCode, description: "group API unavailable")
        }
        var values = [String: Int]()
        for (name, raw) in object {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  (0.0 ... 65535.0).contains(number.doubleValue) else {
                return .httpFailure(statusCode: statusCode, description: "invalid candidate response")
            }
            values[name] = number.intValue
        }
        return values.isEmpty ? .empty : .success(values)
    }
}

/// One measurement namespace per concrete node and test semantics.
struct BenchmarkEvidenceCache {
    struct Key: Hashable {
        let identity: LeafProxyBenchmarkIdentity
        let conditions: BenchmarkConditions
    }

    private var measurements = [Key: GlobalLeafBenchmarkPresentation]()
    private var attempts = [Key: GlobalLeafBenchmarkPresentation]()

    mutating func publish(_ presentation: GlobalLeafBenchmarkPresentation) {
        let key = Key(identity: presentation.identity, conditions: presentation.conditions)
        guard attempts[key].map({ $0.publishedAt <= presentation.publishedAt }) ?? true else { return }
        attempts[key] = presentation
        if case let .measured(_, delay) = presentation.rowState, delay > 0 {
            measurements[key] = presentation
        }
    }

    func measurement(for proxy: ClashProxy, conditions: BenchmarkConditions) -> GlobalLeafBenchmarkPresentation? {
        guard !ClashProxyType.isCompatibilityFallback(proxy) else { return nil }
        return measurements[Key(identity: LeafProxyBenchmarkIdentity(proxy: proxy), conditions: conditions)]
    }

    func attempt(for proxy: ClashProxy, conditions: BenchmarkConditions) -> GlobalLeafBenchmarkPresentation? {
        guard !ClashProxyType.isCompatibilityFallback(proxy) else { return nil }
        return attempts[Key(identity: LeafProxyBenchmarkIdentity(proxy: proxy), conditions: conditions)]
    }

    mutating func prune(using snapshot: ClashProxyResp) {
        let identities = Set(snapshot.proxiesMap.values.filter {
            $0.all == nil && !ClashProxyType.isCompatibilityFallback($0)
        }.map(LeafProxyBenchmarkIdentity.init))
        measurements = measurements.filter { identities.contains($0.key.identity) }
        attempts = attempts.filter { identities.contains($0.key.identity) }
    }

    mutating func clear() {
        measurements.removeAll()
        attempts.removeAll()
    }
}

/// The same resolver is used for live notifications and snapshot refreshes.
/// Selection is deliberately absent: it always belongs to the core's `now`.
enum BenchmarkRowResolver {
    struct Evidence {
        let state: ProxyBenchmarkRowState
        let measuredAt: Date
    }

    struct Presentation {
        let state: ProxyBenchmarkRowState
        let measuredAt: Date?
        let isHistorical: Bool
        let lastAttemptUnavailable: Bool
        let previousSuccess: Evidence?
    }

    static func resolve(name: String, core: ClashProxyTestState?,
                        cached: Evidence?, contextual: Evidence?,
                        activity: Evidence?, now: Date = Date()) -> Presentation {
        let valid: (Evidence?) -> Evidence? = { evidence in
            guard let evidence,
                  BenchmarkMeasurementEpoch.acceptsMeasurement(at: evidence.measuredAt) else { return nil }
            return evidence
        }
        let cached = valid(cached)
        let contextual = valid(contextual)
        let activity = valid(activity)

        var successes = [Evidence]()
        var attempts = [(evidence: Evidence, priority: Int)]()
        func collect(_ evidence: Evidence?, priority: Int) {
            guard let evidence else { return }
            switch evidence.state {
            case let .measured(_, delay) where delay > 0:
                successes.append(evidence)
            case .testing:
                break
            case .measured, .failed, .timedOut, .unavailable:
                attempts.append((evidence, priority))
            }
        }
        collect(cached, priority: 0)
        collect(contextual, priority: 1)
        collect(activity, priority: 3)

        var explicitSignals = [(evidence: Evidence, priority: Int)]()
        if let contextual { explicitSignals.append((contextual, 1)) }
        if let activity { explicitSignals.append((activity, 3)) }
        let latestExplicitSignal = explicitSignals.max {
            if $0.evidence.measuredAt != $1.evidence.measuredAt {
                return $0.evidence.measuredAt < $1.evidence.measuredAt
            }
            return $0.priority < $1.priority
        }?.evidence

        if let core {
            let validHistory = core.history.filter {
                BenchmarkMeasurementEpoch.acceptsMeasurement(at: $0.time)
            }
            for (index, history) in validHistory.enumerated() where history.delay > 0 {
                // A positive entry is success evidence even when a later entry
                // reports failure; retain all such entries for history display.
                if index != validHistory.count - 1 || core.alive {
                    let delay = history.meanDelay.flatMap { $0 > 0 ? $0 : nil } ?? history.delay
                    successes.append(Evidence(
                        state: .measured(displayName: name, delay: delay), measuredAt: history.time
                    ))
                }
            }
            if let history = validHistory.last {
                let state: ProxyBenchmarkRowState = core.alive && history.delay > 0
                    ? .measured(displayName: name, delay: history.meanDelay.flatMap { $0 > 0 ? $0 : nil } ?? history.delay)
                    : .failed(displayName: name)
                collect(Evidence(state: state, measuredAt: history.time), priority: 2)
            }
        }

        // Only the newest explicit row signal can remain in-flight. A newer
        // global result must supersede stale contextual testing state; core
        // refresh timestamps do not participate in this decision.
        if let latestExplicitSignal, case .testing = latestExplicitSignal.state {
            return Presentation(state: .testing(displayName: name), measuredAt: nil,
                                isHistorical: false, lastAttemptUnavailable: false,
                                previousSuccess: newestSuccess(in: successes))
        }

        let newestSuccess = newestSuccess(in: successes)
        let latestAttempt = attempts.max {
            if $0.evidence.measuredAt != $1.evidence.measuredAt {
                return $0.evidence.measuredAt < $1.evidence.measuredAt
            }
            return $0.priority < $1.priority
        }?.evidence

        // If a success and a failure share a timestamp, keep the positive
        // measurement. The timestamp alone cannot prove that failure came later.
        if let latestAttempt, let newestSuccess,
           latestAttempt.measuredAt > newestSuccess.measuredAt {
            let unavailable: Bool
            if case .unavailable = latestAttempt.state { unavailable = true } else { unavailable = false }
            return Presentation(state: latestAttempt.state, measuredAt: latestAttempt.measuredAt,
                                isHistorical: false, lastAttemptUnavailable: unavailable,
                                previousSuccess: newestSuccess)
        }

        if let newestSuccess {
            return Presentation(state: newestSuccess.state, measuredAt: newestSuccess.measuredAt,
                                isHistorical: now.timeIntervalSince(newestSuccess.measuredAt) > 30 * 60,
                                lastAttemptUnavailable: false, previousSuccess: nil)
        }

        if let latestAttempt {
            let unavailable: Bool
            if case .unavailable = latestAttempt.state { unavailable = true } else { unavailable = false }
            return Presentation(state: latestAttempt.state, measuredAt: latestAttempt.measuredAt,
                                isHistorical: false, lastAttemptUnavailable: unavailable,
                                previousSuccess: nil)
        }

        return Presentation(state: .unavailable(displayName: name), measuredAt: nil,
                            isHistorical: false, lastAttemptUnavailable: false, previousSuccess: nil)
    }

    private static func newestSuccess(in successes: [Evidence]) -> Evidence? {
        successes.max { $0.measuredAt < $1.measuredAt }
    }
}

enum BenchmarkRowDelayPresentation {
    static func applyingHistoryMarker(
        to delay: String?,
        isHistorical: Bool,
        localizedFormat: String
    ) -> String? {
        guard isHistorical, let delay else { return delay }
        return String(format: localizedFormat, delay)
    }
}

enum GlobalLeafBenchmarkPresentationStore {
    private static var cache = BenchmarkEvidenceCache()

    static func publish(_ presentation: GlobalLeafBenchmarkPresentation) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache.publish(presentation)
        NotificationCenter.default.post(name: .speedTestFinishForProxy, object: presentation)
    }

    static func presentation(for proxy: ClashProxy, conditions: BenchmarkConditions) -> GlobalLeafBenchmarkPresentation? {
        dispatchPrecondition(condition: .onQueue(.main))
        return cache.measurement(for: proxy, conditions: conditions)
    }

    static func attempt(for proxy: ClashProxy, conditions: BenchmarkConditions) -> GlobalLeafBenchmarkPresentation? {
        dispatchPrecondition(condition: .onQueue(.main))
        return cache.attempt(for: proxy, conditions: conditions)
    }

    static func prune(using snapshot: ClashProxyResp) {
        dispatchPrecondition(condition: .onQueue(.main))
        BenchmarkProbeDiagnosticsStore.prune(using: snapshot)
        cache.prune(using: snapshot)
    }

    static func clearAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        BenchmarkProbeDiagnosticsStore.clearAll()
        cache.clear()
    }
}

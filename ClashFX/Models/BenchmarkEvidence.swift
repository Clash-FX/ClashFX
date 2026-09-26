import CoreFoundation
import Foundation

/// Transport failures are not evidence that a proxy is dead.
enum ProxyDelayOutcome: Equatable {
    case measured(Int)
    case failed
    case unavailable
    case cancelled

    var delay: Int? {
        switch self {
        case let .measured(value): return value
        case .failed: return 0
        case .unavailable, .cancelled: return nil
        }
    }

    func rowState(name: String) -> ProxyBenchmarkRowState {
        switch self {
        case let .measured(value): return .measured(displayName: name, delay: value)
        case .failed: return .failed(displayName: name)
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
        // These are Mihomo's node-delay failure responses, not generic 5xx.
        let message = object["message"] as? String
        if (statusCode == 503 && message == "An error occurred in the delay test")
            || (statusCode == 504 && message == "Timeout") {
            return .failed
        }
        return .unavailable
    }
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
        if presentation.rowState.rawDelay != nil {
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
    }

    static func resolve(name: String, core: ClashProxyTestState?,
                        cached: Evidence?, contextual: Evidence?,
                        activity: Evidence?, now: Date = Date()) -> Presentation {
        var candidates = [cached, contextual].compactMap { $0 }.filter { $0.state.rawDelay != nil }
        if let core, let history = core.history.last {
            candidates.append(Evidence(
                state: core.alive && history.delay > 0
                    ? .measured(displayName: name, delay: history.meanDelay.flatMap { $0 > 0 ? $0 : nil } ?? history.delay)
                    : .failed(displayName: name),
                measuredAt: history.time
            ))
        }
        let newest = candidates.max { $0.measuredAt < $1.measuredAt }
        if let activity, case .testing = activity.state {
            return Presentation(state: .testing(displayName: name), measuredAt: nil,
                                isHistorical: false, lastAttemptUnavailable: false)
        }
        let unavailable: Bool = {
            guard let activity, case .unavailable = activity.state else { return false }
            return newest.map { activity.measuredAt >= $0.measuredAt } ?? true
        }()
        guard let newest else {
            return Presentation(state: .unavailable(displayName: name), measuredAt: nil,
                                isHistorical: false, lastAttemptUnavailable: unavailable)
        }
        let state: ProxyBenchmarkRowState = newest.state.rawDelay == 0
            ? .failed(displayName: name)
            : .measured(displayName: name, delay: newest.state.rawDelay!)
        return Presentation(state: state, measuredAt: newest.measuredAt,
                            isHistorical: unavailable || now.timeIntervalSince(newest.measuredAt) > 30 * 60,
                            lastAttemptUnavailable: unavailable)
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
        cache.prune(using: snapshot)
    }

    static func clearAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        cache.clear()
    }
}

import Foundation

/// The Enhanced Mode data-plane monitor only exercises the DIRECT path and the
/// DNS listener, so it stays green while every proxy node fails. These types
/// decide, from samples of the nodes the user actually selected, whether the
/// proxy path is broken and how far automatic recovery should go.

struct ProxyPathNode: Equatable {
    let type: String
    let now: String?
}

/// Follows each Selector's `now` chain down to the node that carries traffic.
enum SelectedLeafResolver {
    private static let groupTypes: Set<String> = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]
    private static let inertTypes: Set<String> = ["Direct", "Reject", "RejectDrop", "Pass", "Compatible"]

    /// Most commonly selected leaves first, ties broken by name.
    static func leaves(in nodes: [String: ProxyPathNode], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for name in nodes.keys.sorted() {
            guard nodes[name]?.type == "Selector", let leaf = resolve(name, in: nodes) else { continue }
            counts[leaf, default: 0] += 1
        }
        let ranked = counts.keys.sorted { lhs, rhs in
            let left = counts[lhs] ?? 0
            let right = counts[rhs] ?? 0
            return left != right ? left > right : lhs < rhs
        }
        return Array(ranked.prefix(max(0, limit)))
    }

    private static func resolve(_ start: String, in nodes: [String: ProxyPathNode]) -> String? {
        var current = start
        var visited = Set<String>()
        while let node = nodes[current] {
            guard visited.insert(current).inserted, !inertTypes.contains(node.type) else { return nil }
            if groupTypes.contains(node.type) {
                guard let next = node.now, !next.isEmpty else { return nil }
                current = next
                continue
            }
            return current
        }
        return nil
    }
}

enum ProxyPathFailureKind: Equatable {
    /// The node's hostname does not resolve through the core's DNS.
    case nodeResolution
    /// The hostname resolves (or is a literal IP) but the node cannot be dialed.
    case unreachable
    /// The profile does not reveal the node's server, so the cause is unknown.
    case unknown
}

struct ProxyPathSample: Equatable {
    let leaf: String
    /// nil when the node answered a delay probe.
    let failure: ProxyPathFailureKind?
}

enum ProxyPathVerdict: Equatable {
    case healthy
    case noSample
    case failing(ProxyPathFailureKind)
}

enum ProxyPathEvaluator {
    /// One answering node is enough to call the path healthy; the verdict is
    /// failing only when every sampled node fails.
    static func verdict(for samples: [ProxyPathSample]) -> ProxyPathVerdict {
        guard !samples.isEmpty else { return .noSample }
        if samples.contains(where: { $0.failure == nil }) { return .healthy }
        let kinds = Set(samples.compactMap { $0.failure })
        return .failing(kinds.count == 1 ? kinds.first ?? .unknown : .unknown)
    }
}

/// Escalation for a failing proxy path. Cheap and reversible steps come first,
/// each followed by a re-probe, and the ladder always ends in telling the user:
/// when the subscription itself is stale, nothing automatic can repair it.
struct ProxyPathRecoveryLadder {
    enum Step: Equatable {
        case finish
        case flushDNSCache
        case reloadConfig
        /// Network may still be settling; probe again before concluding.
        case retryLater
        case notify(ProxyPathFailureKind)
        case abandon
    }

    let generation: Int
    private var stage = 0

    init(generation: Int) {
        self.generation = generation
    }

    mutating func nextStep(currentGeneration: Int, verdict: ProxyPathVerdict) -> Step {
        guard currentGeneration == generation else { return .abandon }
        guard case let .failing(kind) = verdict else { return .finish }
        defer { stage += 1 }
        switch (kind, stage) {
        case (.unreachable, 0): return .retryLater
        case (.unreachable, 1): return .notify(kind)
        case (.nodeResolution, 0), (.unknown, 0): return .flushDNSCache
        case (.nodeResolution, 1), (.unknown, 1): return .reloadConfig
        case (.nodeResolution, 2), (.unknown, 2): return .notify(kind)
        default: return .finish
        }
    }
}

enum ProxyPathRecoveryDriver {
    struct Hooks {
        let generation: () -> Int
        let probe: (@escaping (ProxyPathVerdict) -> Void) -> Void
        let flushDNSCache: (@escaping () -> Void) -> Void
        let reloadConfig: (@escaping (String?) -> Void) -> Void
        /// Runs the block after the delay; injectable so tests need no clock.
        let after: (TimeInterval, @escaping () -> Void) -> Void
        let notify: (ProxyPathFailureKind) -> Void
        let log: (String) -> Void
    }

    static let settleAfterFlush: TimeInterval = 2
    static let settleAfterReload: TimeInterval = 4
    static let settleBeforeRetry: TimeInterval = 10

    static func run(_ ladder: ProxyPathRecoveryLadder, hooks: Hooks) {
        var ladder = ladder
        // A superseded wake (or a sleep) must not even probe: the probe is
        // network traffic and its verdict would be discarded anyway.
        guard ladder.generation == hooks.generation() else {
            hooks.log("superseded by a newer wake or sleep; abandoning before the next probe")
            return
        }
        hooks.probe { verdict in
            let step = ladder.nextStep(currentGeneration: hooks.generation(), verdict: verdict)
            if verdict != .healthy, verdict != .noSample {
                hooks.log("proxy path \(verdict) -> \(step)")
            }
            switch step {
            case .finish, .abandon:
                break
            case .flushDNSCache:
                hooks.flushDNSCache {
                    hooks.after(settleAfterFlush) { run(ladder, hooks: hooks) }
                }
            case .reloadConfig:
                hooks.reloadConfig { error in
                    if let error = error { hooks.log("in-place reload did not complete (\(error))") }
                    hooks.after(settleAfterReload) { run(ladder, hooks: hooks) }
                }
            case .retryLater:
                hooks.after(settleBeforeRetry) { run(ladder, hooks: hooks) }
            case let .notify(kind):
                hooks.notify(kind)
            }
        }
    }
}

/// Keeps a persistent fault from raising a notification on every wake.
struct ProxyPathNotificationThrottle {
    private let interval: TimeInterval
    private var lastNotified: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func shouldNotify(now: Date) -> Bool {
        if let last = lastNotified, now.timeIntervalSince(last) < interval { return false }
        lastNotified = now
        return true
    }
}

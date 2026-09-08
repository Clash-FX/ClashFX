//
//  ClashProxy.swift
//  ClashX
//
//  Created by CYC on 2019/3/17.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa
import SwiftyJSON

enum ClashProxyType: String, Codable, Hashable {
    case urltest = "URLTest"
    case fallback = "Fallback"
    case loadBalance = "LoadBalance"
    case select = "Selector"
    case direct = "Direct"
    case reject = "Reject"
    case shadowsocks = "Shadowsocks"
    case shadowsocksR = "ShadowsocksR"
    case socks5 = "Socks5"
    case http = "Http"
    case vmess = "Vmess"
    case snell = "Snell"
    case trojan = "Trojan"
    case relay = "Relay"
    case unknown = "Unknown"
    case wireguard = "Wireguard"
    case vless = "Vless"
    case hysteria = "Hysteria"
    case hysteria2 = "Hysteria2"
    case tuic = "Tuic"
    case ssh = "Ssh"
    case anytls = "Anytls"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ClashProxyType(rawValue: rawValue) ?? .unknown
    }

    static let proxyGroups: [ClashProxyType] = [.select, .urltest, .fallback, .loadBalance]

    var isAutoGroup: Bool {
        switch self {
        case .urltest, .fallback, .loadBalance:
            return true
        default:
            return false
        }
    }

    static func isProxyGroup(_ proxy: ClashProxy) -> Bool {
        switch proxy.type {
        case .select, .urltest, .fallback, .loadBalance, .relay: return true
        default: return false
        }
    }

    static func isBuiltInProxy(_ proxy: ClashProxy) -> Bool {
        switch proxy.name {
        case "DIRECT", "REJECT": return true
        default: return false
        }
    }
}

typealias ClashProxyName = String
typealias ClashProviderName = String

struct ProxyMenuPreparationState {
    private(set) var isPrepared = false

    mutating func begin() -> Bool {
        guard !isPrepared else { return false }
        isPrepared = true
        return true
    }
}

struct ProxyMenuRefreshCoordinator {
    enum Mode: Equatable {
        case incremental
        case rebuild
    }

    struct Ticket: Equatable {
        let generation: Int
        let mode: Mode
    }

    struct Completion {
        let shouldApply: Bool
        let nextTicket: Ticket?
    }

    private let minimumIncrementalInterval: TimeInterval
    private var generation = 0
    private var activeTicket: Ticket?
    private var rebuildPending = false
    private var lastAppliedCompletionDate: Date?

    init(minimumIncrementalInterval: TimeInterval = 0.75) {
        self.minimumIncrementalInterval = minimumIncrementalInterval
    }

    mutating func request(_ mode: Mode, now: Date = Date()) -> Ticket? {
        if mode == .rebuild {
            generation += 1
            if activeTicket != nil {
                rebuildPending = true
                return nil
            }
            let ticket = Ticket(generation: generation, mode: .rebuild)
            activeTicket = ticket
            return ticket
        }

        guard activeTicket == nil else { return nil }
        if let lastAppliedCompletionDate,
           now.timeIntervalSince(lastAppliedCompletionDate) < minimumIncrementalInterval {
            return nil
        }
        let ticket = Ticket(generation: generation, mode: .incremental)
        activeTicket = ticket
        return ticket
    }

    mutating func complete(_ ticket: Ticket, now: Date = Date()) -> Completion {
        guard activeTicket == ticket else {
            return Completion(shouldApply: false, nextTicket: nil)
        }

        activeTicket = nil
        let shouldApply = ticket.generation == generation
        if shouldApply {
            lastAppliedCompletionDate = now
        }

        guard rebuildPending else {
            return Completion(shouldApply: shouldApply, nextTicket: nil)
        }
        rebuildPending = false
        let nextTicket = Ticket(generation: generation, mode: .rebuild)
        activeTicket = nextTicket
        return Completion(shouldApply: shouldApply, nextTicket: nextTicket)
    }
}

struct ProxyMenuStructureSignature: Equatable {
    struct Group: Equatable {
        let name: ClashProxyName
        let type: ClashProxyType
        let members: [ClashProxyName]
        let hidden: Bool
        let testURL: String?
        let expectedStatus: String?
    }

    struct ProviderAssignment: Equatable {
        let proxyName: ClashProxyName
        let providerName: ClashProviderName
    }

    let groups: [Group]
    let providerAssignments: [ProviderAssignment]

    init(snapshot: ClashProxyResp) {
        groups = snapshot.proxyGroups.map {
            Group(
                name: $0.name,
                type: $0.type,
                members: $0.all ?? [],
                hidden: $0.hidden ?? false,
                testURL: $0.testUrl,
                expectedStatus: $0.expectedStatus
            )
        }
        providerAssignments = snapshot.proxiesMap.values.compactMap { proxy in
            proxy.enclosingProvider.map {
                ProviderAssignment(proxyName: proxy.name, providerName: $0.name)
            }
        }.sorted {
            if $0.proxyName == $1.proxyName {
                return $0.providerName < $1.providerName
            }
            return $0.proxyName < $1.proxyName
        }
    }
}

enum ProxyMenuSnapshotDelta {
    private struct History: Equatable {
        let time: Date
        let delay: Int
        let meanDelay: Int?
    }

    private struct ExtraState: Equatable {
        let url: String
        let alive: Bool
        let history: History?
    }

    private struct Presentation: Equatable {
        let now: ClashProxyName?
        let alive: Bool?
        let history: History?
        let extra: [ExtraState]
    }

    static func affectedNames(previous: ClashProxyResp, current: ClashProxyResp) -> Set<ClashProxyName> {
        var affected = Set(current.proxiesMap.compactMap { name, proxy -> ClashProxyName? in
            guard let old = previous.proxiesMap[name] else { return name }
            return presentation(for: old) == presentation(for: proxy) ? nil : name
        })

        var changed = true
        while changed {
            changed = false
            for group in current.proxyGroups where !affected.contains(group.name) {
                guard (group.all ?? []).contains(where: affected.contains) else { continue }
                affected.insert(group.name)
                changed = true
            }
        }
        return affected
    }

    private static func presentation(for proxy: ClashProxy) -> Presentation {
        let history = proxy.history.last.map {
            History(time: $0.time, delay: $0.delay, meanDelay: $0.meanDelay)
        }
        let extra = (proxy.extra ?? [:]).map { url, state in
            ExtraState(
                url: url,
                alive: state.alive,
                history: state.history.last.map {
                    History(time: $0.time, delay: $0.delay, meanDelay: $0.meanDelay)
                }
            )
        }.sorted { $0.url < $1.url }
        return Presentation(now: proxy.now, alive: proxy.alive, history: history, extra: extra)
    }
}

enum ProxyBenchmarkRowState {
    case testing(displayName: String)
    case measured(displayName: String, delay: Int)
    case failed(displayName: String)
    case unavailable(displayName: String)

    var presentationName: String {
        switch self {
        case let .testing(displayName),
             let .measured(displayName, _),
             let .failed(displayName),
             let .unavailable(displayName):
            return displayName
        }
    }

    var delayDisplay: String? {
        switch self {
        case .testing:
            return NSLocalizedString("Testing", comment: "")
        case let .measured(_, delay):
            return "\(delay) ms"
        case .failed:
            return NSLocalizedString("fail", comment: "")
        case .unavailable:
            return NSLocalizedString("Benchmark unavailable", comment: "")
        }
    }

    var rawDelay: Int? {
        switch self {
        case let .measured(_, delay):
            return delay
        case .failed:
            return 0
        case .testing, .unavailable:
            return nil
        }
    }
}

struct LeafProxyBenchmarkIdentity: Hashable {
    let endpoint: SelectorBenchmarkEndpoint
    let providerName: ClashProviderName?
    let proxyName: ClashProxyName

    init(endpoint: SelectorBenchmarkEndpoint,
         providerName: ClashProviderName?,
         proxyName: ClashProxyName) {
        self.endpoint = endpoint
        self.providerName = providerName
        self.proxyName = proxyName
    }

    init(proxy: ClashProxy) {
        endpoint = proxy.enclosingProvider == nil ? .inline : .provider
        providerName = proxy.enclosingProvider?.name
        proxyName = proxy.name
    }
}

struct GlobalLeafBenchmarkPresentation {
    private static let freshCacheAge: TimeInterval = 30 * 60
    private static let maximumCacheAge: TimeInterval = 24 * 60 * 60

    let identity: LeafProxyBenchmarkIdentity
    let benchmarkURL: String
    let sessionIdentifier: UUID
    let rowState: ProxyBenchmarkRowState
    let publishedAt: Date

    var isStale: Bool {
        Date().timeIntervalSince(publishedAt) > Self.freshCacheAge
    }

    init(identity: LeafProxyBenchmarkIdentity,
         benchmarkURL: String,
         sessionIdentifier: UUID,
         rowState: ProxyBenchmarkRowState,
         publishedAt: Date = .init()) {
        self.identity = identity
        self.benchmarkURL = benchmarkURL
        self.sessionIdentifier = sessionIdentifier
        self.rowState = rowState
        self.publishedAt = publishedAt
    }

    func reconciled(with proxy: ClashProxy,
                    now: Date = .init()) -> GlobalLeafBenchmarkPresentation? {
        guard now.timeIntervalSince(publishedAt) <= Self.maximumCacheAge,
              proxy.all == nil,
              identity == LeafProxyBenchmarkIdentity(proxy: proxy) else {
            return nil
        }
        return self
    }

    func isNewer(than state: ClashProxyTestState?) -> Bool {
        guard let latestHistory = state?.history.last else { return true }
        return publishedAt >= latestHistory.time
    }
}

enum ProxyBenchmarkPresentationPolicy {
    static func allowsGlobalLeafFallback(in groupType: ClashProxyType) -> Bool {
        return groupType == .select || groupType.isAutoGroup
    }

    static func prefersGlobal(
        publishedAt globalDate: Date,
        over contextualDate: Date?
    ) -> Bool {
        guard let contextualDate else { return true }
        return globalDate > contextualDate
    }
}

struct SelectorBenchmarkPresentation {
    private static let freshCacheAge: TimeInterval = 30 * 60
    private static let maximumCacheAge: TimeInterval = 24 * 60 * 60
    let selectorName: ClashProxyName
    let rowName: ClashProxyName
    let resolvedLeafName: ClashProxyName?
    let benchmarkURL: String
    let sessionIdentifier: UUID
    let rowState: ProxyBenchmarkRowState
    let publishedAt: Date

    var isStale: Bool {
        Date().timeIntervalSince(publishedAt) > Self.freshCacheAge
    }

    init(
        selectorName: ClashProxyName,
        rowName: ClashProxyName,
        resolvedLeafName: ClashProxyName?,
        benchmarkURL: String,
        sessionIdentifier: UUID,
        rowState: ProxyBenchmarkRowState,
        publishedAt: Date = .init()
    ) {
        self.selectorName = selectorName
        self.rowName = rowName
        self.resolvedLeafName = resolvedLeafName
        self.benchmarkURL = benchmarkURL
        self.sessionIdentifier = sessionIdentifier
        self.rowState = rowState
        self.publishedAt = publishedAt
    }

    func reconciled(
        with snapshot: ClashProxyResp,
        currentBenchmarkURL: String
    ) -> SelectorBenchmarkPresentation {
        guard Date().timeIntervalSince(publishedAt) <= Self.maximumCacheAge else {
            return unavailable()
        }
        let currentAutomaticBenchmarkURL = snapshot.proxiesMap[rowName]
            .flatMap { $0.type.isAutoGroup ? $0.effectiveBenchmarkURL(fallback: currentBenchmarkURL) : nil }
        guard benchmarkURL == currentBenchmarkURL
            || benchmarkURL == currentAutomaticBenchmarkURL else {
            return unavailable()
        }
        guard let resolvedLeafName else {
            return self
        }
        guard case let .resolved(_, leaf) = snapshot.resolveSelectedPath(from: rowName),
              leaf.name == resolvedLeafName else {
            return unavailable()
        }
        return self
    }

    private func unavailable() -> SelectorBenchmarkPresentation {
        switch rowState {
        case .unavailable:
            return self
        case .testing, .measured, .failed:
            return SelectorBenchmarkPresentation(
                selectorName: selectorName,
                rowName: rowName,
                resolvedLeafName: resolvedLeafName,
                benchmarkURL: benchmarkURL,
                sessionIdentifier: sessionIdentifier,
                rowState: .unavailable(displayName: rowName),
                publishedAt: publishedAt
            )
        }
    }
}

struct AutomaticGroupBenchmarkIdentity: Equatable {
    let groupName: ClashProxyName
    let members: [ClashProxyName]
    let benchmarkURL: String
    let expectedStatus: String?

    init(group: ClashProxy, fallbackBenchmarkURL: String) {
        groupName = group.name
        members = group.all ?? []
        benchmarkURL = group.effectiveBenchmarkURL(fallback: fallbackBenchmarkURL)
        expectedStatus = group.expectedStatus.flatMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}

struct AutomaticGroupChildBenchmarkPresentation {
    private static let freshCacheAge: TimeInterval = 30 * 60
    private static let maximumCacheAge: TimeInterval = 24 * 60 * 60

    let identity: AutomaticGroupBenchmarkIdentity
    let rowName: ClashProxyName
    let sessionIdentifier: UUID
    let rowState: ProxyBenchmarkRowState
    let publishedAt: Date

    var isStale: Bool {
        return Date().timeIntervalSince(publishedAt) > Self.freshCacheAge
    }

    init(identity: AutomaticGroupBenchmarkIdentity,
         rowName: ClashProxyName,
         sessionIdentifier: UUID,
         rowState: ProxyBenchmarkRowState,
         publishedAt: Date = .init()) {
        self.identity = identity
        self.rowName = rowName
        self.sessionIdentifier = sessionIdentifier
        self.rowState = rowState
        self.publishedAt = publishedAt
    }

    func reconciled(group: ClashProxy,
                    fallbackBenchmarkURL: String,
                    now: Date = .init()) -> AutomaticGroupChildBenchmarkPresentation? {
        guard now.timeIntervalSince(publishedAt) <= Self.maximumCacheAge,
              identity == AutomaticGroupBenchmarkIdentity(
                  group: group,
                  fallbackBenchmarkURL: fallbackBenchmarkURL
              ),
              identity.members.contains(rowName) else { return nil }
        return self
    }
}

enum SelectorBenchmarkEndpoint: Hashable {
    case inline
    case provider
}

struct SelectorBenchmarkMeasurementKey: Hashable {
    let endpoint: SelectorBenchmarkEndpoint
    let providerName: ClashProviderName?
    let proxyName: ClashProxyName
    let benchmarkURL: String
    let timeout: Int
}

struct SelectorBenchmarkSchedulingBucket: Hashable {
    let endpoint: SelectorBenchmarkEndpoint
    let providerName: ClashProviderName?
    let proxyType: ClashProxyType
}

enum SelectorBenchmarkUnavailableReason: Hashable {
    case cycle(ClashProxyName)
    case missingNode(ClashProxyName)
    case missingSelection(ClashProxyName)
    case unknownTarget(ClashProxyName)
    case nonLeafTerminal(ClashProxyName)
}

enum SelectedProxyPathResolution {
    case resolved(path: [ClashProxyName], leaf: ClashProxy)
    case unavailable(path: [ClashProxyName], reason: SelectorBenchmarkUnavailableReason)
}

struct AutomaticGroupRetestSnapshot {
    enum Evidence {
        case measured(delay: Int)
        case zeroDelay(node: ClashProxyName)
        case unavailable(SelectorBenchmarkUnavailableReason)
        case noMatchingCandidate
    }

    let groupName: ClashProxyName
    let selectedPath: [ClashProxyName]
    let finalLeaf: ClashProxyName?
    let evidence: Evidence

    static func make(groupName: ClashProxyName,
                     candidateDelays: [ClashProxyName: Int],
                     snapshot: ClashProxyResp) -> AutomaticGroupRetestSnapshot {
        switch snapshot.resolveSelectedPath(from: groupName) {
        case let .unavailable(path, reason):
            return AutomaticGroupRetestSnapshot(
                groupName: groupName,
                selectedPath: path,
                finalLeaf: path.last,
                evidence: .unavailable(reason)
            )
        case let .resolved(path, leaf):
            // Mihomo's fresh path is the only authority. Candidate values are display
            // evidence, never a policy input; the final leaf wins over its ancestors.
            let candidatePath = Array(path.dropFirst().reversed())
            for node in candidatePath {
                guard let delay = candidateDelays[node] else { continue }
                if delay > 0 {
                    return AutomaticGroupRetestSnapshot(
                        groupName: groupName,
                        selectedPath: path,
                        finalLeaf: leaf.name,
                        evidence: .measured(delay: delay)
                    )
                }
                return AutomaticGroupRetestSnapshot(
                    groupName: groupName,
                    selectedPath: path,
                    finalLeaf: leaf.name,
                    evidence: .zeroDelay(node: node)
                )
            }
            return AutomaticGroupRetestSnapshot(
                groupName: groupName,
                selectedPath: path,
                finalLeaf: leaf.name,
                evidence: .noMatchingCandidate
            )
        }
    }
}

struct SelectorBenchmarkRow {
    let rowName: ClashProxyName
    let displayName: String
    let measurementKey: SelectorBenchmarkMeasurementKey?
    let schedulingBucket: SelectorBenchmarkSchedulingBucket?
    let isDeferredAutomaticRetest: Bool
    let unavailableReason: SelectorBenchmarkUnavailableReason?
}

struct SelectorBenchmarkConcurrencyPolicy {
    // Failed nodes are not proof of local congestion. Keep the normal starting
    // capacity instead of halving throughput for the remaining timeout tail.
    private static let minimumConcurrency = 8
    private static let initialConcurrency = 8
    private static let maximumConcurrency = 12
    private static let adjustmentStep = 4

    private let targetCount: Int
    private(set) var currentLimit: Int

    var minimumLimit: Int {
        return max(1, min(targetCount, Self.minimumConcurrency))
    }

    var maximumLimit: Int {
        return max(1, min(targetCount, Self.maximumConcurrency))
    }

    init(targetCount: Int) {
        let normalizedTargetCount = max(0, targetCount)
        self.targetCount = normalizedTargetCount
        currentLimit = max(1, min(normalizedTargetCount, Self.initialConcurrency))
    }

    mutating func recordCohort(_ outcomes: [Bool]) {
        guard targetCount > 0, !outcomes.isEmpty else { return }
        let failureCount = outcomes.filter { !$0 }.count
        let healthyMaximumFailures = outcomes.count / 4
        let clusteredFailureMinimum = max(2, outcomes.count / 2)

        if failureCount <= healthyMaximumFailures {
            currentLimit = min(maximumLimit, currentLimit + Self.adjustmentStep)
        } else if failureCount >= clusteredFailureMinimum {
            currentLimit = max(minimumLimit, currentLimit - Self.adjustmentStep)
        }
    }
}

final class AdaptiveAsyncTaskRunner {
    typealias Task = (@escaping (Bool) -> Void) -> Void

    private let tasks: [Task]
    private let stateQueue: DispatchQueue
    private let limitChanged: ((Int, Int) -> Void)?
    private var policy: SelectorBenchmarkConcurrencyPolicy
    private var nextTaskIndex = 0
    private var activeTaskCount = 0
    private struct LaunchCohort {
        var expectedCount = 0
        var outcomes = [Bool]()
        var isClosed = false
    }

    private var cohorts = [Int: LaunchCohort]()
    private var launchCohortIdentifier = 0
    private var nextDecisionCohortIdentifier = 0
    private var remainingLaunchesInCohort: Int
    private var completion: (() -> Void)?

    init(tasks: [Task],
         policy: SelectorBenchmarkConcurrencyPolicy,
         stateQueue: DispatchQueue = DispatchQueue(label: "com.clashfx.adaptiveProxyDelayTaskRunner"),
         limitChanged: ((Int, Int) -> Void)? = nil) {
        self.tasks = tasks
        self.policy = policy
        self.stateQueue = stateQueue
        self.limitChanged = limitChanged
        remainingLaunchesInCohort = policy.currentLimit
    }

    func start(completion: @escaping () -> Void) {
        stateQueue.async {
            self.completion = completion
            self.scheduleAvailableTasks()
        }
    }

    private func scheduleAvailableTasks() {
        if nextTaskIndex == tasks.count, activeTaskCount == 0 {
            let completion = completion
            self.completion = nil
            DispatchQueue.main.async {
                completion?()
            }
            return
        }

        // Replenish the pool whenever a request settles. Concurrency decisions
        // still use complete observation windows, but slow requests no longer
        // hold every later target behind a cohort barrier.
        while nextTaskIndex < tasks.count, activeTaskCount < policy.currentLimit {
            let task = tasks[nextTaskIndex]
            nextTaskIndex += 1
            activeTaskCount += 1

            let cohortIdentifier = launchCohortIdentifier
            var cohort = cohorts[cohortIdentifier] ?? LaunchCohort()
            cohort.expectedCount += 1
            remainingLaunchesInCohort -= 1
            if remainingLaunchesInCohort == 0 {
                cohort.isClosed = true
                launchCohortIdentifier += 1
                remainingLaunchesInCohort = policy.currentLimit
            }
            cohorts[cohortIdentifier] = cohort

            if nextTaskIndex == tasks.count,
               remainingLaunchesInCohort != policy.currentLimit {
                var finalCohort = cohorts[launchCohortIdentifier] ?? LaunchCohort()
                finalCohort.isClosed = true
                cohorts[launchCohortIdentifier] = finalCohort
            }

            task { succeeded in
                self.stateQueue.async {
                    self.activeTaskCount -= 1
                    self.cohorts[cohortIdentifier]?.outcomes.append(succeeded)
                    self.evaluateSettledLaunchCohorts()
                    self.scheduleAvailableTasks()
                }
            }
        }
    }

    private func evaluateSettledLaunchCohorts() {
        while let cohort = cohorts[nextDecisionCohortIdentifier],
              cohort.isClosed,
              cohort.outcomes.count == cohort.expectedCount,
              cohort.expectedCount > 0 {
            let previousLimit = policy.currentLimit
            policy.recordCohort(cohort.outcomes)
            cohorts[nextDecisionCohortIdentifier] = nil
            nextDecisionCohortIdentifier += 1
            if policy.currentLimit != previousLimit {
                limitChanged?(previousLimit, policy.currentLimit)
            }
        }
    }
}

struct SelectorBenchmarkAutomaticRetestTarget {
    let groupName: ClashProxyName
    let benchmarkURL: String
    let expectedStatus: String?
}

/// Shared production executor; transport and scheduling can be isolated in tests.
enum SelectorBenchmarkExecutor {
    static func run(
        plan: SelectorBenchmarkPlan,
        reusing measurements: [SelectorBenchmarkMeasurementKey: Int] = [:],
        isCancelled: @escaping () -> Bool,
        schedulingQueue: DispatchQueue = DispatchQueue(label: "com.clashfx.selectorBenchmarkExecutor"),
        request: @escaping (SelectorBenchmarkPlan.Target, @escaping (Int) -> Void) -> Void,
        result: @escaping (SelectorBenchmarkPlan.Target, Int) -> Void,
        limitChanged: ((Int, Int) -> Void)? = nil,
        completion: @escaping () -> Void
    ) {
        let pending = plan.interleavedTargets.filter { target in
            guard !isCancelled() else { return false }
            guard let delay = measurements[target.key], delay > 0 else { return true }
            result(target, delay)
            return false
        }
        let tasks: [AdaptiveAsyncTaskRunner.Task] = pending.map { target in
            return { done in
                guard !isCancelled() else { done(false); return }
                let settlement = ManagedOperationSettlement<Int> { delay in
                    if !isCancelled() { result(target, delay) }
                    done(delay > 0)
                }
                request(target) { settlement.finish($0) }
            }
        }
        Logger.log("[Proxy Delay] Selector requests: \(tasks.count), reused: \(plan.targets.count - pending.count)")
        AdaptiveAsyncTaskRunner(
            tasks: tasks,
            policy: SelectorBenchmarkConcurrencyPolicy(targetCount: tasks.count),
            stateQueue: schedulingQueue,
            limitChanged: limitChanged
        ).start(completion: completion)
    }
}

struct SelectorBenchmarkPlan {
    struct Target {
        let key: SelectorBenchmarkMeasurementKey
        let schedulingBucket: SelectorBenchmarkSchedulingBucket
        let aliases: [SelectorBenchmarkRow]
    }

    let orderedRows: [SelectorBenchmarkRow]
    let targets: [Target]
    let selectedAutomaticRetest: SelectorBenchmarkAutomaticRetestTarget?

    /// Reuse only successful direct-leaf measurements made during this same
    /// action, with exactly the Selector's URL, timeout and status semantics.
    /// Nested groups measure a selected path, not an independently named leaf.
    func reusableMeasurements(group: ClashProxy,
                              candidateDelays: [ClashProxyName: Int],
                              timeout: Int) -> [SelectorBenchmarkMeasurementKey: Int] {
        guard let retest = selectedAutomaticRetest,
              retest.groupName == group.name,
              group.type.isAutoGroup,
              retest.benchmarkURL == group.effectiveBenchmarkURL(fallback: retest.benchmarkURL),
              retest.expectedStatus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              group.expectedStatus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              let snapshot = group.enclosingResp else { return [:] }
        let members = Set(group.all ?? [])
        var measurements = [SelectorBenchmarkMeasurementKey: Int]()
        for target in targets {
            let key = target.key
            guard key.benchmarkURL == retest.benchmarkURL,
                  key.timeout == timeout,
                  members.contains(key.proxyName),
                  let leaf = snapshot.proxiesMap[key.proxyName],
                  leaf.all == nil,
                  !ClashProxyType.isProxyGroup(leaf),
                  leaf.enclosingProvider?.name == key.providerName,
                  (leaf.enclosingProvider == nil ? SelectorBenchmarkEndpoint.inline : .provider) == key.endpoint,
                  let delay = candidateDelays[key.proxyName], delay > 0 else { continue }
            measurements[key] = delay
        }
        return measurements
    }

    var interleavedTargets: [Target] {
        var bucketOrder = [SelectorBenchmarkSchedulingBucket]()
        var bucketTargets = [SelectorBenchmarkSchedulingBucket: [Target]]()
        for target in targets {
            if bucketTargets[target.schedulingBucket] == nil {
                bucketOrder.append(target.schedulingBucket)
            }
            bucketTargets[target.schedulingBucket, default: []].append(target)
        }

        var nextIndex = [SelectorBenchmarkSchedulingBucket: Int]()
        var ordered = [Target]()
        while ordered.count < targets.count {
            for bucket in bucketOrder {
                let index = nextIndex[bucket, default: 0]
                guard let candidates = bucketTargets[bucket], index < candidates.count else {
                    continue
                }
                ordered.append(candidates[index])
                nextIndex[bucket] = index + 1
            }
        }
        return ordered
    }

    var concurrencyPolicy: SelectorBenchmarkConcurrencyPolicy {
        return SelectorBenchmarkConcurrencyPolicy(targetCount: targets.count)
    }

    /// The initial limit remains available to diagnostics and regression tests;
    /// Selector execution can raise or lower it using current-session results.
    var maxConcurrentRequests: Int {
        return concurrencyPolicy.currentLimit
    }

    static func make(selector: ClashProxy,
                     snapshot: ClashProxyResp,
                     benchmarkURL: String,
                     timeout: Int) -> SelectorBenchmarkPlan {
        let visibleNames = selector.all ?? []
        let selectedAutomaticGroup: ClashProxy? = {
            guard let selectedName = selector.now,
                  let selected = snapshot.proxiesMap[selectedName],
                  selected.type.isAutoGroup,
                  visibleNames.contains(selectedName) else { return nil }
            return selected
        }()
        var orderedRows = [SelectorBenchmarkRow]()
        var aliases = [SelectorBenchmarkMeasurementKey: [SelectorBenchmarkRow]]()
        var schedulingBuckets = [SelectorBenchmarkMeasurementKey: SelectorBenchmarkSchedulingBucket]()
        var targetOrder = [SelectorBenchmarkMeasurementKey]()

        for visibleName in visibleNames {
            let row = makeRow(
                visibleName: visibleName,
                snapshot: snapshot,
                benchmarkURL: benchmarkURL,
                timeout: timeout,
                deferAutomaticRetest: visibleName == selectedAutomaticGroup?.name
            )
            orderedRows.append(row)
            guard let key = row.measurementKey else { continue }
            if aliases[key] == nil {
                aliases[key] = []
                targetOrder.append(key)
            }
            aliases[key]?.append(row)
            if let schedulingBucket = row.schedulingBucket {
                schedulingBuckets[key] = schedulingBucket
            }
        }

        let targets = targetOrder.compactMap { key -> Target? in
            guard let rows = aliases[key], !rows.isEmpty,
                  let schedulingBucket = schedulingBuckets[key] else { return nil }
            return Target(key: key, schedulingBucket: schedulingBucket, aliases: rows)
        }
        let selectedAutomaticRetest = selectedAutomaticGroup.map {
            SelectorBenchmarkAutomaticRetestTarget(
                groupName: $0.name,
                benchmarkURL: $0.effectiveBenchmarkURL(fallback: benchmarkURL),
                expectedStatus: $0.expectedStatus
            )
        }
        return SelectorBenchmarkPlan(
            orderedRows: orderedRows,
            targets: targets,
            selectedAutomaticRetest: selectedAutomaticRetest
        )
    }

    private static func makeRow(visibleName: ClashProxyName,
                                snapshot: ClashProxyResp,
                                benchmarkURL: String,
                                timeout: Int,
                                deferAutomaticRetest: Bool) -> SelectorBenchmarkRow {
        if deferAutomaticRetest {
            return SelectorBenchmarkRow(
                rowName: visibleName,
                displayName: visibleName,
                measurementKey: nil,
                schedulingBucket: nil,
                isDeferredAutomaticRetest: true,
                unavailableReason: nil
            )
        }
        switch snapshot.resolveSelectedPath(from: visibleName) {
        case let .resolved(_, proxy):
            let endpoint: SelectorBenchmarkEndpoint
            let providerName: ClashProviderName?
            if let provider = proxy.enclosingProvider {
                endpoint = .provider
                providerName = provider.name
            } else {
                endpoint = .inline
                providerName = nil
            }
            return SelectorBenchmarkRow(
                rowName: visibleName,
                // Keep the visible Selector row stable. Expanding a nested
                // policy path here makes AppKit resize the open menu and can
                // overlap the delay badge on long node names.
                displayName: visibleName,
                measurementKey: SelectorBenchmarkMeasurementKey(
                    endpoint: endpoint,
                    providerName: providerName,
                    proxyName: proxy.name,
                    benchmarkURL: benchmarkURL,
                    timeout: timeout
                ),
                schedulingBucket: SelectorBenchmarkSchedulingBucket(
                    endpoint: endpoint,
                    providerName: providerName,
                    proxyType: proxy.type
                ),
                isDeferredAutomaticRetest: false,
                unavailableReason: nil
            )
        case let .unavailable(_, reason):
            Logger.log(
                "[Proxy Delay] Selector row '\(visibleName)' is unavailable: \(reason)",
                level: .warning
            )
            return SelectorBenchmarkRow(
                rowName: visibleName,
                displayName: visibleName,
                measurementKey: nil,
                schedulingBucket: nil,
                isDeferredAutomaticRetest: false,
                unavailableReason: reason
            )
        }
    }
}

class ClashProxySpeedHistory: Codable {
    let time: Date
    let delay: Int
    let meanDelay: Int?

    class HisDateFormaterInstance {
        static let shared = HisDateFormaterInstance()
        lazy var formater: DateFormatter = {
            var f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
    }

    lazy var delayDisplay: String = {
        if let meanDelay, meanDelay > 0 {
            switch meanDelay {
            case 0: return NSLocalizedString("fail", comment: "")
            default: return "\(meanDelay) ms"
            }
        } else {
            switch delay {
            case 0: return NSLocalizedString("fail", comment: "")
            default: return "\(delay) ms"
            }
        }
    }()

    lazy var dateDisplay: String = HisDateFormaterInstance.shared.formater.string(from: time)

    lazy var displayString: String = "\(dateDisplay) \(delayDisplay)"
}

struct ClashProxyTestState: Codable {
    let alive: Bool
    let history: [ClashProxySpeedHistory]
}

class ClashProxy: Codable {
    let name: ClashProxyName
    let type: ClashProxyType
    let all: [ClashProxyName]?
    let history: [ClashProxySpeedHistory]
    let now: ClashProxyName?
    let alive: Bool?
    let extra: [String: ClashProxyTestState]?
    let hidden: Bool?
    let testUrl: String?
    let expectedStatus: String?
    weak var enclosingResp: ClashProxyResp?
    weak var enclosingProvider: ClashProvider?

    enum SpeedtestAbleItem {
        case proxy(name: ClashProxyName)
        case provider(name: ClashProxyName, provider: ClashProviderName)
    }

    private static var nameLengthCachedMap = [ClashProxyName: CGFloat]()
    static func cleanCache() {
        nameLengthCachedMap.removeAll()
    }

    lazy var speedtestAble: [SpeedtestAbleItem] = {
        guard let resp = enclosingResp, let allProxys = all else { return [] }
        var proxys = [SpeedtestAbleItem]()
        for proxy in allProxys {
            if let p = resp.proxiesMap[proxy] {
                if let provider = p.enclosingProvider {
                    proxys.append(.provider(name: p.name, provider: provider.name))
                } else {
                    proxys.append(.proxy(name: p.name))
                }
            }
        }
        return proxys
    }()

    lazy var isSpeedTestable: Bool = !speedtestAble.isEmpty

    private enum CodingKeys: String, CodingKey {
        case type, all, history, now, name, alive, extra, hidden, testUrl, expectedStatus
    }

    func testState(for benchmarkURL: String) -> ClashProxyTestState? {
        let normalizedURL = benchmarkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return nil }
        return extra?[normalizedURL]
    }

    func effectiveBenchmarkURL(fallback: String) -> String {
        testUrl
            .flatMap {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            ?? fallback
    }

    lazy var maxProxyNameLength: CGFloat = {
        let rect = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)

        let lengths = all?.compactMap { name -> CGFloat in
            if let length = ClashProxy.nameLengthCachedMap[name] {
                return length
            }

            let rects = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)
            let attr = [NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 14)]
            let length = (name as NSString)
                .boundingRect(with: rect,
                              options: .usesLineFragmentOrigin,
                              attributes: attr).width
            ClashProxy.nameLengthCachedMap[name] = length
            return length
        }
        return lengths?.max() ?? 0
    }()
}

class ClashProxyResp {
    var proxies: [ClashProxy]

    var proxiesMap: [ClashProxyName: ClashProxy]

    var enclosingProviderResp: ClashProviderResp?

    init(_ data: Data?) {
        guard let data
        else {
            self.proxiesMap = [:]
            self.proxies = []
            return
        }
        let proxies = JSON(data)["proxies"]
        var proxiesModel = [ClashProxy]()

        var proxiesMap = [ClashProxyName: ClashProxy]()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(DateFormatter.js)
        for value in proxies.dictionaryValue.values {
            guard let data = try? value.rawData() else {
                continue
            }
            guard let proxy = try? decoder.decode(ClashProxy.self, from: data) else {
                continue
            }
            proxiesModel.append(proxy)
            proxiesMap[proxy.name] = proxy
        }
        self.proxiesMap = proxiesMap
        self.proxies = proxiesModel

        for proxy in self.proxies {
            proxy.enclosingResp = self
        }
    }

    func resolveSelectedPath(from name: ClashProxyName) -> SelectedProxyPathResolution {
        var path = [ClashProxyName]()
        var visited = Set<ClashProxyName>()
        var currentName = name

        while true {
            guard let proxy = proxiesMap[currentName] else {
                let reason: SelectorBenchmarkUnavailableReason = path.isEmpty
                    ? .missingNode(currentName)
                    : .unknownTarget(currentName)
                return .unavailable(path: path, reason: reason)
            }
            guard !visited.contains(proxy.name) else {
                return .unavailable(path: path, reason: .cycle(proxy.name))
            }

            visited.insert(proxy.name)
            path.append(proxy.name)
            guard ClashProxyType.isProxyGroup(proxy) else {
                guard proxy.all == nil else {
                    return .unavailable(path: path, reason: .nonLeafTerminal(proxy.name))
                }
                return .resolved(path: path, leaf: proxy)
            }

            guard let selectedName = proxy.now, !selectedName.isEmpty else {
                return .unavailable(path: path, reason: .missingSelection(proxy.name))
            }
            currentName = selectedName
        }
    }

    func updateProvider(_ providerResp: ClashProviderResp) {
        enclosingProviderResp = providerResp
        for provider in providerResp.providers.values {
            for proxy in provider.proxies {
                proxy.enclosingProvider = provider
                proxy.enclosingResp = self
                proxiesMap[proxy.name] = proxy
                proxies.append(proxy)
            }
        }
    }

    lazy var proxiesSortMap: [ClashProxyName: Int] = {
        var map = [ClashProxyName: Int]()
        for (idx, proxy) in (self.proxiesMap["GLOBAL"]?.all ?? []).enumerated() {
            map[proxy] = idx
        }
        return map
    }()

    lazy var proxyGroups: [ClashProxy] = proxies.filter {
        ClashProxyType.isProxyGroup($0)
    }.sorted(by: { proxiesSortMap[$0.name] ?? -1 < proxiesSortMap[$1.name] ?? -1 })

    lazy var longestProxyGroupName = proxyGroups.max { $1.name.count > $0.name.count }?.name ?? ""

    lazy var maxProxyNameLength: CGFloat = {
        let rect = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)
        let attr = [NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 0)]
        return (self.longestProxyGroupName as NSString)
            .boundingRect(with: rect,
                          options: .usesLineFragmentOrigin,
                          attributes: attr).width
    }()
}

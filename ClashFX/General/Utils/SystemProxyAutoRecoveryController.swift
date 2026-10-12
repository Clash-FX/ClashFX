import Foundation

struct SystemProxyRecoveryObservation {
    var scope: String
    var shouldProtect: Bool
    var isPaused: Bool
    var isReady: Bool
    var matches: Bool
    var ownsRuntime: Bool
}

/// The injected scheduler keeps the controller deterministic in tests. Its
/// scheduled actions must run on the main queue, like the production scheduler.
struct SystemProxyAutoRecoveryScheduler {
    let now: () -> TimeInterval
    let schedule: (_ delay: TimeInterval, _ action: @escaping () -> Void) -> (() -> Void)

    static let main = SystemProxyAutoRecoveryScheduler(
        now: { ProcessInfo.processInfo.systemUptime },
        schedule: { delay, action in
            let workItem = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
            return { workItem.cancel() }
        }
    )
}

/// Shares the retry budget and write lease between controllers. Automatic
/// proxy notifications can arrive through more than one owner, but they still
/// describe the same system-wide proxy state.
final class SystemProxyAutoRecoveryCoordination {
    static let shared = SystemProxyAutoRecoveryCoordination()

    fileprivate var attemptsByScope = [String: Int]()
    fileprivate var suspendedScopes = Set<String>()
    fileprivate var lastAttemptAtByScope = [String: TimeInterval]()
    fileprivate var activeLease: UUID?
    private var leaseWaiters = [UUID: () -> Void]()

    func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        attemptsByScope.removeAll()
        suspendedScopes.removeAll()
        lastAttemptAtByScope.removeAll()
    }

    fileprivate func acquire(_ lease: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeLease == nil else { return false }
        activeLease = lease
        return true
    }

    fileprivate func addWaiter(owner: UUID, wake: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        leaseWaiters[owner] = wake
    }

    fileprivate func removeWaiter(owner: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        leaseWaiters.removeValue(forKey: owner)
    }

    fileprivate func release(_ lease: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeLease == lease else { return }
        activeLease = nil
        let waiters = Array(leaseWaiters.values)
        leaseWaiters.removeAll()
        waiters.forEach { $0() }
    }
}

/// Serializes automatic recovery attempts and verifies the resulting system
/// state from a fresh observation after each helper callback.
final class SystemProxyAutoRecoveryController {
    static let requestCoalescingDelay: TimeInterval = 0.75
    static let settleDelay: TimeInterval = 0.25
    static let retryCooldown: TimeInterval = 2
    static let matchingResetInterval: TimeInterval = 15
    static let applyTimeout: TimeInterval = 30
    static let maximumAttempts = 3

    private struct Operation {
        let id: UUID
        let generation: UInt64
        let scope: String
        var callbackReceived: Bool
        var timedOut: Bool
    }

    private let observe: () -> SystemProxyRecoveryObservation
    private let apply: (@escaping (Bool) -> Void) -> Void
    private let didObserve: (SystemProxyRecoveryObservation) -> Void
    private let didSuspend: () -> Void
    private let scheduler: SystemProxyAutoRecoveryScheduler
    private let coordination: SystemProxyAutoRecoveryCoordination
    private let identity = UUID()

    private var generation: UInt64 = 0
    private var isArmed = false
    private var currentScope: String?
    private var operation: Operation?
    private var requestCancellation: (() -> Void)?
    private var retryCancellation: (() -> Void)?
    private var stableCancellation: (() -> Void)?
    private var settleCancellation: (() -> Void)?
    private var timeoutCancellation: (() -> Void)?
    private var retryScope: String?
    private var stableScope: String?
    private var requestPendingDuringOperation = false

    var isSuspended: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let scope = currentScope else { return false }
        return coordination.suspendedScopes.contains(scope)
    }

    init(
        observe: @escaping () -> SystemProxyRecoveryObservation,
        apply: @escaping (@escaping (Bool) -> Void) -> Void,
        didObserve: @escaping (SystemProxyRecoveryObservation) -> Void,
        didSuspend: @escaping () -> Void,
        scheduler: SystemProxyAutoRecoveryScheduler = .main,
        coordination: SystemProxyAutoRecoveryCoordination = .shared
    ) {
        self.observe = observe
        self.apply = apply
        self.didObserve = didObserve
        self.didSuspend = didSuspend
        self.scheduler = scheduler
        self.coordination = coordination
    }

    deinit {
        let coordination = self.coordination
        let identity = self.identity
        if Thread.isMainThread {
            coordination.removeWaiter(owner: identity)
        } else {
            DispatchQueue.main.async {
                coordination.removeWaiter(owner: identity)
            }
        }
    }

    /// Coalesces watch and callback notifications into one trailing snapshot.
    func request() {
        dispatchPrecondition(condition: .onQueue(.main))
        if !isArmed {
            isArmed = true
            advanceGeneration()
        }
        scheduleRequest(after: Self.requestCoalescingDelay)
    }

    /// Explicit user, configuration, or lock-scope changes grant a new budget.
    /// An apply whose callback has not arrived keeps its lease until callback or
    /// timeout, so resetting can never overlap the underlying helper operation.
    func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        coordination.reset()
        advanceGeneration()
        cancelRequestTask()
        cancelRetryTask()
        cancelStableTask()
        coordination.removeWaiter(owner: identity)
        requestPendingDuringOperation = false

        if let operation = operation, operation.callbackReceived {
            clearOperation(operation.id)
        } else {
            settleCancellation?()
            settleCancellation = nil
        }

        if isArmed {
            scheduleRequest(after: Self.requestCoalescingDelay)
        }
    }

    /// Invalidates callbacks and scheduled retries. A write already handed to
    /// the helper retains its lease until its callback or bounded timeout.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        advanceGeneration()
        isArmed = false
        requestPendingDuringOperation = false
        cancelRequestTask()
        cancelRetryTask()
        cancelStableTask()
        coordination.removeWaiter(owner: identity)

        if let operation = operation, operation.callbackReceived {
            clearOperation(operation.id)
        } else {
            settleCancellation?()
            settleCancellation = nil
        }
    }

    private func advanceGeneration() {
        generation &+= 1
        if generation == 0 { generation = 1 }
    }

    private func scheduleRequest(after delay: TimeInterval) {
        cancelRequestTask()
        let expectedGeneration = generation
        requestCancellation = scheduler.schedule(max(0, delay)) { [weak self] in
            guard let self = self else { return }
            self.requestCancellation = nil
            guard self.isArmed, self.generation == expectedGeneration else { return }
            self.reconcileFreshSnapshot(generation: expectedGeneration)
        }
    }

    private func reconcileFreshSnapshot(generation expectedGeneration: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isArmed, generation == expectedGeneration else { return }
        if operation != nil {
            requestPendingDuringOperation = true
            return
        }

        let observation = observe()
        updateCurrentScope(observation.scope)
        didObserve(observation)
        process(observation, generation: expectedGeneration, mayStartApply: true)
    }

    private func process(
        _ observation: SystemProxyRecoveryObservation,
        generation expectedGeneration: UInt64,
        mayStartApply: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isArmed, generation == expectedGeneration else { return }

        guard isReadyForStableMatch(observation) else {
            cancelRetryTask()
            cancelStableTask()
            coordination.removeWaiter(owner: identity)
            return
        }

        if observation.matches {
            cancelRetryTask()
            scheduleStableResetIfNeeded(scope: observation.scope, generation: expectedGeneration)
            return
        }

        cancelStableTask()
        guard observation.shouldProtect else {
            cancelRetryTask()
            return
        }
        guard !coordination.suspendedScopes.contains(observation.scope) else {
            if retryScope == observation.scope { cancelRetryTask() }
            return
        }

        let attempts = coordination.attemptsByScope[observation.scope, default: 0]
        guard attempts < Self.maximumAttempts else {
            suspend(scope: observation.scope)
            return
        }

        guard mayStartApply else {
            scheduleRetry(scope: observation.scope, generation: expectedGeneration)
            return
        }

        let now = scheduler.now()
        if let lastAttempt = coordination.lastAttemptAtByScope[observation.scope] {
            let remaining = Self.retryCooldown - (now - lastAttempt)
            if remaining > 0 {
                scheduleRetry(scope: observation.scope, generation: expectedGeneration, after: remaining)
                return
            }
        }

        cancelRetryTask()
        beginApply(scope: observation.scope, generation: expectedGeneration, now: now)
    }

    private func beginApply(scope: String, generation expectedGeneration: UInt64, now: TimeInterval) {
        let operationID = UUID()
        guard coordination.acquire(operationID) else {
            coordination.addWaiter(owner: identity) { [weak self] in
                guard let self = self else { return }
                guard self.isArmed else { return }
                self.scheduleRequest(after: 0)
            }
            return
        }

        coordination.removeWaiter(owner: identity)
        coordination.attemptsByScope[scope, default: 0] += 1
        coordination.lastAttemptAtByScope[scope] = now
        operation = Operation(
            id: operationID,
            generation: expectedGeneration,
            scope: scope,
            callbackReceived: false,
            timedOut: false
        )

        timeoutCancellation = scheduler.schedule(Self.applyTimeout) { [self] in
            timeoutCancellation = nil
            handleApplyTimeout(operationID, generation: expectedGeneration)
        }

        apply { [weak self] result in
            guard let self = self else { return }
            self.runOnMain { [weak self] in
                self?.handleApplyCallback(
                    operationID,
                    generation: expectedGeneration,
                    reportedSuccess: result
                )
            }
        }
    }

    private func handleApplyCallback(
        _ operationID: UUID,
        generation expectedGeneration: UInt64,
        reportedSuccess: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var active = operation,
              active.id == operationID,
              !active.callbackReceived else { return }

        active.callbackReceived = true
        operation = active
        timeoutCancellation?()
        timeoutCancellation = nil

        if active.timedOut {
            clearOperation(operationID)
            schedulePendingRequestIfNeeded(generation: generation)
            return
        }

        guard isArmed, generation == expectedGeneration, active.generation == expectedGeneration else {
            clearOperation(operationID)
            schedulePendingRequestIfNeeded(generation: generation)
            return
        }

        // The callback reports operation completion; only observe() determines
        // whether the system proxy actually reached the requested state.
        _ = reportedSuccess
        settleCancellation = scheduler.schedule(Self.settleDelay) { [self] in
            settleCancellation = nil
            finishSettledOperation(operationID, generation: expectedGeneration)
        }
    }

    private func finishSettledOperation(_ operationID: UUID, generation expectedGeneration: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let active = operation, active.id == operationID else { return }
        settleCancellation = nil

        guard isArmed, generation == expectedGeneration, active.generation == expectedGeneration else {
            clearOperation(operationID)
            schedulePendingRequestIfNeeded(generation: generation)
            return
        }

        let observation = observe()
        updateCurrentScope(observation.scope)
        didObserve(observation)
        process(observation, generation: expectedGeneration, mayStartApply: false)
        let scopeChanged = observation.scope != active.scope
        clearOperation(operationID)
        schedulePendingRequestIfNeeded(generation: expectedGeneration, force: scopeChanged)
    }

    private func handleApplyTimeout(_ operationID: UUID, generation expectedGeneration: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var active = operation,
              active.id == operationID,
              !active.callbackReceived,
              !active.timedOut else { return }
        timeoutCancellation = nil
        active.timedOut = true
        operation = active
        let shouldNotify = isArmed && generation == expectedGeneration && active.generation == expectedGeneration
        suspend(scope: active.scope, notify: shouldNotify)
    }

    private func clearOperation(_ operationID: UUID) {
        guard operation?.id == operationID else { return }
        operation = nil
        settleCancellation?()
        settleCancellation = nil
        timeoutCancellation?()
        timeoutCancellation = nil
        coordination.release(operationID)
    }

    private func scheduleRetry(
        scope: String,
        generation expectedGeneration: UInt64,
        after requestedDelay: TimeInterval? = nil
    ) {
        guard isArmed, generation == expectedGeneration,
              !coordination.suspendedScopes.contains(scope) else { return }
        if retryScope == scope, retryCancellation != nil { return }

        cancelRetryTask()
        retryScope = scope
        let now = scheduler.now()
        let cooldownRemaining: TimeInterval
        if let lastAttempt = coordination.lastAttemptAtByScope[scope] {
            cooldownRemaining = max(0, Self.retryCooldown - (now - lastAttempt))
        } else {
            cooldownRemaining = Self.retryCooldown
        }
        let delay = max(cooldownRemaining, requestedDelay ?? 0)
        retryCancellation = scheduler.schedule(delay) { [weak self] in
            guard let self = self else { return }
            self.retryCancellation = nil
            self.retryScope = nil
            guard self.isArmed, self.generation == expectedGeneration else { return }
            self.reconcileFreshSnapshot(generation: expectedGeneration)
        }
    }

    private func scheduleStableResetIfNeeded(scope: String, generation expectedGeneration: UInt64) {
        let attempts = coordination.attemptsByScope[scope, default: 0]
        guard attempts > 0 || coordination.suspendedScopes.contains(scope) else { return }
        if stableScope == scope, stableCancellation != nil { return }

        cancelStableTask()
        stableScope = scope
        stableCancellation = scheduler.schedule(Self.matchingResetInterval) { [weak self] in
            guard let self = self else { return }
            self.stableCancellation = nil
            self.stableScope = nil
            guard self.isArmed, self.generation == expectedGeneration else { return }

            let observation = self.observe()
            self.updateCurrentScope(observation.scope)
            guard observation.scope == scope,
                  self.isReadyForStableMatch(observation),
                  observation.matches else {
                self.didObserve(observation)
                self.process(observation, generation: expectedGeneration, mayStartApply: true)
                return
            }

            self.coordination.attemptsByScope.removeValue(forKey: scope)
            self.coordination.suspendedScopes.remove(scope)
            self.coordination.lastAttemptAtByScope.removeValue(forKey: scope)
            self.didObserve(observation)
        }
    }

    private func suspend(scope: String, notify: Bool = true) {
        guard coordination.suspendedScopes.insert(scope).inserted else { return }
        if retryScope == scope { cancelRetryTask() }
        coordination.removeWaiter(owner: identity)
        if notify { didSuspend() }
    }

    private func updateCurrentScope(_ scope: String) {
        guard currentScope != scope else { return }
        currentScope = scope
        if retryScope != nil, retryScope != scope { cancelRetryTask() }
        if stableScope != nil, stableScope != scope { cancelStableTask() }
    }

    private func schedulePendingRequestIfNeeded(generation expectedGeneration: UInt64, force: Bool = false) {
        let shouldRun = requestPendingDuringOperation || force
        requestPendingDuringOperation = false
        guard shouldRun, isArmed, generation == expectedGeneration else { return }
        scheduleRequest(after: 0)
    }

    private func isReadyForStableMatch(_ observation: SystemProxyRecoveryObservation) -> Bool {
        !observation.isPaused && observation.isReady && observation.ownsRuntime
    }

    private func cancelRequestTask() {
        requestCancellation?()
        requestCancellation = nil
    }

    private func cancelRetryTask() {
        retryCancellation?()
        retryCancellation = nil
        retryScope = nil
    }

    private func cancelStableTask() {
        stableCancellation?()
        stableCancellation = nil
        stableScope = nil
    }

    private func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}

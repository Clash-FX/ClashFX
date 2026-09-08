//
//  ManagedOperationSettlement.swift
//  ClashFX
//

import Foundation

/// Serializes entire asynchronous operations, including their callbacks.
/// Merely dispatching their start onto a serial queue allows XPC writes to overlap.
final class SerializedAsyncOperationQueue {
    typealias Operation = (@escaping () -> Void) -> Void
    private let queue: DispatchQueue
    private var pending = [Operation]()
    private var running = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func enqueue(_ operation: @escaping Operation) {
        queue.async {
            self.pending.append(operation)
            self.startNext()
        }
    }

    private func startNext() {
        guard !running, !pending.isEmpty else { return }
        running = true
        let operation = pending.removeFirst()
        let settlement = ManagedOperationSettlement<Void> { _ in
            self.queue.async {
                self.running = false
                self.startNext()
            }
        }
        operation { _ = settlement.finish(()) }
    }
}

/// Resolves an asynchronous operation once, regardless of whether the first
/// terminal event is a result, an error, or a timeout.
final class ManagedOperationSettlement<Outcome> {
    private let lock = NSLock()
    private let completion: (Outcome) -> Void
    private var settled = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(completion: @escaping (Outcome) -> Void) {
        self.completion = completion
    }

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    @discardableResult
    func finish(_ outcome: Outcome) -> Bool {
        let completion: ((Outcome) -> Void)?
        lock.lock()
        if settled {
            completion = nil
        } else {
            settled = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            completion = self.completion
        }
        lock.unlock()

        completion?(outcome)
        return completion != nil
    }

    func scheduleTimeout(after delay: TimeInterval,
                         queue: DispatchQueue = .main,
                         outcome: @escaping () -> Outcome) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            _ = self.finish(outcome())
        }

        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = workItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelTimeout() {
        lock.lock()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        lock.unlock()
    }
}

struct TerminationCleanupObservation {
    let enhancedModeActive: Bool
    let proxyPortAutoSet: Bool
    let isProxySetByOther: Bool
    let currentSystemSetToClash: Bool
    let hasInterfaceProxySetToClash: Bool
}

struct TerminationCleanupPolicy: Equatable {
    let cleanEnhancedMode: Bool
    let cleanSystemProxy: Bool
    let forceDisableProxy: Bool

    var shouldWait: Bool {
        cleanEnhancedMode || cleanSystemProxy
    }

    static func make(observation: TerminationCleanupObservation) -> TerminationCleanupPolicy {
        let cleanSystemProxy =
            (observation.proxyPortAutoSet && !observation.isProxySetByOther) ||
            observation.currentSystemSetToClash ||
            observation.hasInterfaceProxySetToClash
        return TerminationCleanupPolicy(
            cleanEnhancedMode: observation.enhancedModeActive,
            cleanSystemProxy: cleanSystemProxy,
            // Restoring the captured settings remains the user's requested
            // behavior even when a transient network change marked them external.
            forceDisableProxy: false
        )
    }
}

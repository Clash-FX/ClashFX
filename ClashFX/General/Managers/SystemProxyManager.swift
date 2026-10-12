//
//  SystemProxyManager.swift
//  ClashX
//

import Foundation

/// Only proxy operations are exposed; tests cannot install a Helper or touch DNS.
struct SystemProxyHelperClient {
    var getCurrentProxySetting: (@escaping (Any?) -> Void) -> Void
    var enable: (Int32, Int32, Bool, [String], @escaping (String?) -> Void) -> Void
    var disable: (Bool, @escaping (String?) -> Void) -> Void
    var restore: (Int32, Int32, [String: Any], Bool, @escaping (String?) -> Void) -> Void
}

struct SystemProxyDependencies {
    let defaults: UserDefaults
    let helper: (@escaping () -> Void) -> SystemProxyHelperClient?
    let currentPorts: () -> (http: Int, socks: Int)
    let shouldSuspend: () -> Bool
    let disableRestoreProxy: () -> Bool
    let filterInterface: () -> Bool
    let proxyIgnoreList: () -> [String]
    let liveSystemPointsToClashFX: () -> Bool
    var stageTimeout: TimeInterval = 8
    var canControlRuntime: () -> Bool = { true }
}

struct SystemProxyCheckpoint {
    let liveSnapshot: [String: Any]
    let savedSnapshot: [String: Any]
    let savedSnapshotValid: Bool
    let httpPort: Int
    let socksPort: Int
}

/// Owns the complete system-proxy transition. Enabling never reaches the
/// privileged helper until the previous settings have been captured or a
/// known-valid snapshot already exists.
final class SystemProxyManager: NSObject {
    private enum OperationError: LocalizedError {
        case runtimeNotOwned
        case helperUnavailable
        case captureFailed(String)
        case enableFailed(String)
        case disableFailed(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .runtimeNotOwned: return "This process does not own ClashFX runtime control."
            case .helperUnavailable: return "System Proxy Helper is unavailable."
            case let .captureFailed(reason): return "Could not capture System Proxy: \(reason)"
            case let .enableFailed(reason): return "Could not enable System Proxy: \(reason)"
            case let .disableFailed(reason): return "Could not restore System Proxy: \(reason)"
            case let .timedOut(stage): return "System Proxy request timed out while \(stage)."
            }
        }
    }

    private let transitionQueue = DispatchQueue(label: "com.clashfx.system-proxy-transition")
    private let operations: SerializedAsyncOperationQueue
    private var isTerminating = false
    private let mutationLock = NSLock()
    private var pendingHelperMutation: UUID?

    private var hasPendingHelperMutation: Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return pendingHelperMutation != nil
    }

    /// A timeout or XPC error ends the caller's wait, not the privileged write.
    /// Keep mutations quarantined until the actual helper reply confirms exit.
    private func trackHelperMutation(
        _ invocation: (@escaping (String?) -> Void) -> Void,
        completion: @escaping (String?) -> Void
    ) {
        let id = UUID()
        mutationLock.lock()
        pendingHelperMutation = id
        mutationLock.unlock()
        invocation { [self] error in
            mutationLock.lock()
            if pendingHelperMutation == id { pendingHelperMutation = nil }
            mutationLock.unlock()
            completion(error)
        }
    }

    private var policy = SystemProxyOperationPolicy()
    private let dependencies: SystemProxyDependencies

    init(dependencies: SystemProxyDependencies) {
        self.dependencies = dependencies
        operations = SerializedAsyncOperationQueue(queue: transitionQueue)
        super.init()
    }

    func prepareForTermination() {
        transitionQueue.async { self.isTerminating = true }
    }

    func resumeAfterCancelledTermination() {
        transitionQueue.async { self.isTerminating = false }
    }

    func restoreForTermination(result: @escaping (Bool) -> Void) {
        disableProxy(
            port: dependencies.currentPorts().http,
            socksPort: dependencies.currentPorts().socks,
            forTermination: true,
            result: result
        )
    }

    private var savedProxyInfo: [String: Any] {
        return dependencies.defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey) ?? [:]
    }

    private var hasValidSavedProxySnapshot: Bool {
        return dependencies.defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)
    }

    private func saveSnapshot(_ snapshot: [String: Any]) {
        dependencies.defaults.set(snapshot, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        dependencies.defaults.set(true, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)
    }

    private func clearSnapshot() {
        dependencies.defaults.removeObject(forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        dependencies.defaults.set(false, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)
    }

    private func migrateLegacySnapshotIfSafe(port: Int, socksPort: Int) -> Bool {
        guard !hasValidSavedProxySnapshot else { return true }
        let snapshot = savedProxyInfo
        let mayMigrate = SystemProxyOperationPolicy.shouldMigrateLegacySnapshot(
            snapshot,
            validityMarker: false,
            liveSystemPointsToClashFX: dependencies.liveSystemPointsToClashFX(),
            httpPort: port,
            socksPort: socksPort
        )
        guard mayMigrate else { return false }
        dependencies.defaults.set(true, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)
        Logger.log("migrated legacy system proxy snapshot", level: .info)
        return true
    }

    /// Kept for old callers. Capture is deliberately an internal stage of the
    /// enable transition so it cannot race the privileged mutation.
    func saveProxy() {
        Logger.log("saveProxy is handled by the enable transition", level: .debug)
    }

    func captureCheckpoint(completion: @escaping (Result<SystemProxyCheckpoint, Error>) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.captureCheckpoint(completion: completion) }
            return
        }
        guard dependencies.canControlRuntime() else {
            completion(.failure(OperationError.runtimeNotOwned))
            return
        }
        let ports = dependencies.currentPorts()
        operations.enqueue { [weak self] done in
            guard let self = self else {
                done()
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "com.clashfx.system-proxy", code: 1)))
                }
                return
            }

            let savedSnapshot = self.savedProxyInfo
            let savedSnapshotValid = self.hasValidSavedProxySnapshot
            let settlement = ManagedOperationSettlement<Result<SystemProxyCheckpoint, Error>> { [weak self] result in
                guard let self = self else {
                    done()
                    DispatchQueue.main.async { completion(result) }
                    return
                }
                self.transitionQueue.async {
                    done()
                    DispatchQueue.main.async { completion(result) }
                }
            }
            settlement.scheduleTimeout(after: self.dependencies.stageTimeout, queue: self.transitionQueue, outcome: {
                .failure(OperationError.timedOut("capturing checkpoint system proxy settings"))
            })

            guard let helper = self.ownedHelper({
                _ = settlement.finish(.failure(OperationError.helperUnavailable))
            }) else {
                _ = settlement.finish(.failure(OperationError.helperUnavailable))
                return
            }
            helper.getCurrentProxySetting { info in
                guard let liveSnapshot = info as? [String: Any] else {
                    _ = settlement.finish(.failure(OperationError.captureFailed("helper returned malformed proxy settings")))
                    return
                }
                if let error = SystemProxyOperationPolicy.captureError(in: liveSnapshot) {
                    _ = settlement.finish(.failure(OperationError.captureFailed(error)))
                    return
                }
                guard SystemProxyOperationPolicy.isValidPropertyListSnapshot(liveSnapshot) else {
                    _ = settlement.finish(.failure(OperationError.captureFailed("helper returned an invalid proxy snapshot")))
                    return
                }
                _ = settlement.finish(.success(SystemProxyCheckpoint(
                    liveSnapshot: liveSnapshot,
                    savedSnapshot: savedSnapshot,
                    savedSnapshotValid: savedSnapshotValid,
                    httpPort: ports.http,
                    socksPort: ports.socks
                )))
            }
        }
    }

    func restoreCheckpoint(
        _ checkpoint: SystemProxyCheckpoint,
        isCurrent: @escaping () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        operations.enqueue { [weak self] done in
            guard let self = self else {
                done()
                DispatchQueue.main.async { completion(false) }
                return
            }
            let settlement = ManagedOperationSettlement<Bool> { [self] success in
                self.transitionQueue.async {
                    done()
                    self.finishOnMain(success, completion)
                }
            }
            self.checkCheckpointIsCurrent(isCurrent) { current in
                guard current else {
                    _ = settlement.finish(false)
                    return
                }
                self.invokeCheckpointRestore(checkpoint, isCurrent: isCurrent, settlement: settlement)
            }
        }
    }

    private func invokeCheckpointRestore(
        _ checkpoint: SystemProxyCheckpoint,
        isCurrent: @escaping () -> Bool,
        settlement: ManagedOperationSettlement<Bool>
    ) {
        guard let httpPort = Int32(exactly: checkpoint.httpPort),
              let socksPort = Int32(exactly: checkpoint.socksPort) else {
            _ = settlement.finish(false)
            return
        }

        let stage = checkpointStageSettlement(
            "restoring checkpoint system proxy settings",
            operation: settlement
        ) {
            self.checkCheckpointIsCurrent(isCurrent) { current in
                guard current else {
                    _ = settlement.finish(false)
                    return
                }
                self.verifyCheckpointRestore(checkpoint, isCurrent: isCurrent, settlement: settlement)
            }
        }
        guard let helper = ownedHelper({
            _ = stage.finish(.helperUnavailable)
        }) else {
            _ = stage.finish(.helperUnavailable)
            return
        }
        // Checkpoint restoration always covers every service and is independent
        // of the user's preference for ordinary proxy shutdown.
        guard !stage.isSettled else { return }
        trackHelperMutation({ done in
            helper.restore(httpPort, socksPort, checkpoint.liveSnapshot, false, done)
        }, completion: { error in
            _ = stage.finish(error.map(OperationError.disableFailed))
        })
    }

    private func verifyCheckpointRestore(
        _ checkpoint: SystemProxyCheckpoint,
        isCurrent: @escaping () -> Bool,
        settlement: ManagedOperationSettlement<Bool>
    ) {
        let stage = checkpointStageSettlement(
            "verifying checkpoint system proxy settings",
            operation: settlement
        ) {
            self.checkCheckpointIsCurrent(isCurrent) { current in
                guard current else {
                    _ = settlement.finish(false)
                    return
                }
                self.dependencies.defaults.set(
                    checkpoint.savedSnapshot,
                    forKey: SystemProxyOperationPolicy.savedSnapshotKey
                )
                self.dependencies.defaults.set(
                    checkpoint.savedSnapshotValid,
                    forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey
                )
                _ = settlement.finish(true)
            }
        }
        guard let helper = ownedHelper({
            _ = stage.finish(.helperUnavailable)
        }) else {
            _ = stage.finish(.helperUnavailable)
            return
        }
        helper.getCurrentProxySetting { info in
            guard let actual = info as? [String: Any],
                  SystemProxyOperationPolicy.restoredSnapshotMatches(
                    expected: checkpoint.liveSnapshot,
                    actual: actual
                  ) else {
                _ = stage.finish(.disableFailed("restored proxy settings did not match the checkpoint"))
                return
            }
            _ = stage.finish(nil)
        }
    }

    private func checkpointStageSettlement(
        _ name: String,
        operation: ManagedOperationSettlement<Bool>,
        onSuccess: @escaping () -> Void
    ) -> ManagedOperationSettlement<OperationError?> {
        let stage = ManagedOperationSettlement<OperationError?> { [self] error in
            self.transitionQueue.async {
                guard !operation.isSettled else { return }
                if let error = error {
                    Logger.log("system proxy checkpoint operation failed: \(error)", level: .error)
                    _ = operation.finish(false)
                } else {
                    onSuccess()
                }
            }
        }
        stage.scheduleTimeout(after: dependencies.stageTimeout, queue: transitionQueue, outcome: {
            .timedOut(name)
        })
        return stage
    }

    /// The caller's predicate may read parent transaction state, so evaluate it
    /// on main and only return its value to the serialized proxy queue.
    private func checkCheckpointIsCurrent(
        _ isCurrent: @escaping () -> Bool,
        continuation: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            let current = isCurrent()
            self.transitionQueue.async {
                continuation(current)
            }
        }
    }

    func enableProxy(complete: ((Bool) -> Void)? = nil) {
        let port = dependencies.currentPorts().http
        let socketPort = dependencies.currentPorts().socks
        enableProxy(port: port, socksPort: socketPort, complete: complete)
    }

    /// `isCurrent` lets automatic callers veto a request that went stale while
    /// queued behind another system-proxy operation. It is always evaluated on
    /// main, including immediately before helper writes; existing callers keep
    /// their behavior through the default predicate.
    func enableProxy(
        port: Int,
        socksPort: Int,
        replacingExternalProxy: Bool = false,
        isCurrent: @escaping () -> Bool = { true },
        complete: ((Bool) -> Void)? = nil
    ) {
        guard dependencies.canControlRuntime() else {
            fail(.runtimeNotOwned, complete: complete)
            return
        }
        guard port > 0 && socksPort > 0 else {
            Logger.log("enableProxy fail: \(port) \(socksPort)", level: .error)
            finishOnMain(false, complete)
            return
        }
        if dependencies.shouldSuspend() {
            Logger.log("not enableProxy due to ssid in disabled list", level: .info)
            finishOnMain(false, complete)
            return
        }

        operations.enqueue { [weak self] done in
            guard let self = self else { done(); return }
            self.checkEnableIsCurrent(isCurrent) { current in
                guard current, !self.isTerminating else {
                    done()
                    self.finishOnMain(false, complete)
                    return
                }
                let complete: (Bool) -> Void = { success in
                    done()
                    complete?(success)
                }
                let generation = self.policy.beginTransition()
                Logger.log("enableProxy transition \(generation)", level: .debug)
                let enable: () -> Void = { [weak self] in
                    self?.enableAfterPreparation(
                        generation: generation,
                        port: port,
                        socksPort: socksPort,
                        replacingExternalProxy: replacingExternalProxy,
                        isCurrent: isCurrent,
                        complete: complete
                    )
                }

                let canReuseSnapshot = self.hasValidSavedProxySnapshot ||
                    self.migrateLegacySnapshotIfSafe(port: port, socksPort: socksPort)
                guard !self.dependencies.disableRestoreProxy(), !canReuseSnapshot else {
                    enable()
                    return
                }
                self.captureSnapshot(
                    generation: generation,
                    port: port,
                    socksPort: socksPort,
                    isCurrent: isCurrent,
                    onSuccess: enable,
                    complete: complete
                )
            }
        }
    }

    func disableProxy(
        forceDisable: Bool = false,
        complete: (() -> Void)? = nil,
        result: ((Bool) -> Void)? = nil
    ) {
        let port = dependencies.currentPorts().http
        let socketPort = dependencies.currentPorts().socks
        disableProxy(
            port: port,
            socksPort: socketPort,
            forceDisable: forceDisable,
            complete: complete,
            result: result
        )
    }

    func disableProxy(
        port: Int,
        socksPort: Int,
        forceDisable: Bool = false,
        forTermination: Bool = false,
        complete: (() -> Void)? = nil,
        result: ((Bool) -> Void)? = nil
    ) {
        guard dependencies.canControlRuntime() else {
            finishOnMain(false, result)
            DispatchQueue.main.async { complete?() }
            return
        }
        operations.enqueue { [weak self] done in
            guard let self = self else { done(); return }
            guard self.dependencies.canControlRuntime(), !self.isTerminating || forTermination else {
                done()
                self.finishOnMain(false, result)
                DispatchQueue.main.async { complete?() }
                return
            }
            let generation = self.policy.beginTransition()
            Logger.log("disableProxy transition \(generation)", level: .debug)
            self.disableOrRestore(
                generation: generation,
                port: port,
                socksPort: socksPort,
                forceDisable: forceDisable,
                complete: {
                    done()
                    complete?()
                },
                result: result
            )
        }
    }

    private func captureSnapshot(
        generation: UInt64,
        port: Int,
        socksPort: Int,
        isCurrent: @escaping () -> Bool,
        onSuccess: @escaping () -> Void,
        complete: ((Bool) -> Void)?
    ) {
        let settlement = ManagedOperationSettlement<Result<[String: Any], OperationError>> { [weak self] outcome in
            self?.transitionQueue.async {
                guard let self = self, self.policy.acceptsCallback(for: generation) else { return }
                switch outcome {
                case let .success(snapshot):
                    guard SystemProxyOperationPolicy.captureError(in: snapshot) == nil,
                          SystemProxyOperationPolicy.isValidPropertyListSnapshot(snapshot) else {
                        self.fail(.captureFailed("helper returned an invalid proxy snapshot"), complete: complete)
                        return
                    }
                    self.checkEnableIsCurrent(isCurrent) { current in
                        guard current else {
                            self.finishOnMain(false, complete)
                            return
                        }
                        // Capture includes disconnected services too. Their old
                        // loopback settings must not block enabling the current
                        // network; preserve them exactly for later restoration.
                        let alreadyOwnsLiveProxy = self.dependencies.liveSystemPointsToClashFX() &&
                            SystemProxyOperationPolicy.isClashFXOwnedSnapshot(snapshot, httpPort: port, socksPort: socksPort)
                        guard !alreadyOwnsLiveProxy else {
                            self.fail(.captureFailed("current proxy settings already belong to ClashFX; no original snapshot is available"), complete: complete)
                            return
                        }
                        self.saveSnapshot(snapshot)
                        Logger.log("saved system proxy snapshot before enable", level: .debug)
                        onSuccess()
                    }
                case let .failure(error):
                    self.fail(error, complete: complete)
                }
            }
        }
        settlement.scheduleTimeout(after: dependencies.stageTimeout, queue: transitionQueue, outcome: {
            return .failure(.timedOut("capturing current system proxy settings"))
        })

        guard let proxy = ownedHelper({
            _ = settlement.finish(.failure(.helperUnavailable))
        }, checkRuntimeOwnership: false) else {
            _ = settlement.finish(.failure(.helperUnavailable))
            return
        }
        proxy.getCurrentProxySetting { info in
            guard let snapshot = info as? [String: Any] else {
                _ = settlement.finish(.failure(.captureFailed("helper returned malformed proxy settings")))
                return
            }
            if let error = SystemProxyOperationPolicy.captureError(in: snapshot) {
                _ = settlement.finish(.failure(.captureFailed(error)))
            } else {
                _ = settlement.finish(.success(snapshot))
            }
        }
    }

    private func enableAfterPreparation(
        generation: UInt64,
        port: Int,
        socksPort: Int,
        replacingExternalProxy: Bool,
        isCurrent: @escaping () -> Bool,
        complete: ((Bool) -> Void)?
    ) {
        guard policy.acceptsCallback(for: generation) else { return }
        guard !isTerminating else {
            finishOnMain(false, complete)
            return
        }
        if replacingExternalProxy {
            forceDisableBeforeEnable(
                generation: generation,
                port: port,
                socksPort: socksPort,
                isCurrent: isCurrent,
                complete: complete
            )
            return
        }
        invokeEnable(generation: generation, port: port, socksPort: socksPort, isCurrent: isCurrent, complete: complete)
    }

    private func forceDisableBeforeEnable(
        generation: UInt64,
        port: Int,
        socksPort: Int,
        isCurrent: @escaping () -> Bool,
        complete: ((Bool) -> Void)?
    ) {
        checkEnableIsCurrent(isCurrent) { [weak self] current in
            guard let self = self else { return }
            guard current, self.policy.acceptsCallback(for: generation), !self.isTerminating else {
                self.finishOnMain(false, complete)
                return
            }
            let settlement = self.helperSettlement(generation: generation, stage: "force-disabling system proxy") { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.fail(error, complete: complete)
                } else {
                    self.invokeEnable(
                        generation: generation,
                        port: port,
                        socksPort: socksPort,
                        isCurrent: isCurrent,
                        complete: complete
                    )
                }
            }
            guard let proxy = self.ownedHelper({
                _ = settlement.finish(.helperUnavailable)
            }, checkRuntimeOwnership: false) else {
                _ = settlement.finish(.helperUnavailable)
                return
            }
            guard !settlement.isSettled else { return }
            self.trackHelperMutation({ done in
                proxy.disable(self.dependencies.filterInterface(), done)
            }, completion: { error in
                _ = settlement.finish(error.map(OperationError.disableFailed))
            })
        }
    }

    private func invokeEnable(
        generation: UInt64,
        port: Int,
        socksPort: Int,
        isCurrent: @escaping () -> Bool,
        complete: ((Bool) -> Void)?
    ) {
        checkEnableIsCurrent(isCurrent) { [weak self] current in
            guard let self = self else { return }
            guard current, !self.isTerminating, self.policy.acceptsCallback(for: generation) else {
                self.finishOnMain(false, complete)
                return
            }
            let settlement = self.helperSettlement(generation: generation, stage: "enabling system proxy") { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.fail(error, complete: complete)
                } else {
                    self.finishOnMain(true, complete)
                }
            }
            guard let proxy = self.ownedHelper({
                _ = settlement.finish(.helperUnavailable)
            }, checkRuntimeOwnership: false) else {
                _ = settlement.finish(.helperUnavailable)
                return
            }
            guard !settlement.isSettled else { return }
            self.trackHelperMutation({ done in
                proxy.enable(Int32(port), Int32(socksPort), self.dependencies.filterInterface(),
                             self.dependencies.proxyIgnoreList(), done)
            }, completion: { error in
                _ = settlement.finish(error.map(OperationError.enableFailed))
            })
        }
    }

    /// Automatic callers supply a predicate tied to their request generation.
    /// Evaluate it on main, then return to the transition queue before changing
    /// proxy state. The timeout also releases a queued operation if main is no
    /// longer servicing eligibility checks.
    private func checkEnableIsCurrent(
        _ isCurrent: @escaping () -> Bool,
        continuation: @escaping (Bool) -> Void
    ) {
        let settlement = ManagedOperationSettlement<Bool> { [self] current in
            transitionQueue.async { continuation(current) }
        }
        settlement.scheduleTimeout(after: dependencies.stageTimeout, queue: transitionQueue, outcome: { false })
        DispatchQueue.main.async {
            let current = self.dependencies.canControlRuntime() &&
                !self.dependencies.shouldSuspend() && isCurrent()
            _ = settlement.finish(current)
        }
    }

    private func disableOrRestore(
        generation: UInt64,
        port: Int,
        socksPort: Int,
        forceDisable: Bool,
        complete: (() -> Void)?,
        result: ((Bool) -> Void)?
    ) {
        let shouldRestore = !dependencies.disableRestoreProxy() && !forceDisable && hasValidSavedProxySnapshot
        let settlement = helperSettlement(generation: generation, stage: shouldRestore ? "restoring system proxy" : "disabling system proxy") { [weak self] error in
            guard let self = self else { return }
            let success = error == nil
            if success, shouldRestore {
                self.verifyRestoredSnapshot(generation: generation, complete: complete, result: result)
                return
            }
            if let error = error {
                self.fail(error, complete: nil)
            }
            self.finishOnMain(success, result)
            DispatchQueue.main.async { complete?() }
        }
        guard let proxy = ownedHelper({
            _ = settlement.finish(.helperUnavailable)
        }) else {
            _ = settlement.finish(.helperUnavailable)
            return
        }
        guard !settlement.isSettled else { return }
        trackHelperMutation({ done in
            if shouldRestore {
                proxy.restore(Int32(port), Int32(socksPort), savedProxyInfo, dependencies.filterInterface(), done)
            } else {
                proxy.disable(dependencies.filterInterface(), done)
            }
        }, completion: { error in
            _ = settlement.finish(error.map(OperationError.disableFailed))
        })
    }

    private func verifyRestoredSnapshot(generation: UInt64,
                                        complete: (() -> Void)?,
                                        result: ((Bool) -> Void)?) {
        let expected = savedProxyInfo
        let settlement = helperSettlement(generation: generation, stage: "verifying restored system proxy") { [weak self] error in
            guard let self else { return }
            if let error {
                self.fail(error, complete: nil)
            } else {
                self.clearSnapshot()
            }
            self.finishOnMain(error == nil, result)
            DispatchQueue.main.async { complete?() }
        }
        guard let helper = ownedHelper({
            _ = settlement.finish(.helperUnavailable)
        }) else {
            _ = settlement.finish(.helperUnavailable)
            return
        }
        helper.getCurrentProxySetting { info in
            guard let actual = info as? [String: Any],
                  SystemProxyOperationPolicy.restoredSnapshotMatches(expected: expected, actual: actual) else {
                _ = settlement.finish(.disableFailed("restored proxy settings did not match the saved snapshot"))
                return
            }
            _ = settlement.finish(nil)
        }
    }

    private func helperSettlement(
        generation: UInt64,
        stage: String,
        finish: @escaping (OperationError?) -> Void
    ) -> ManagedOperationSettlement<OperationError?> {
        let settlement = ManagedOperationSettlement<OperationError?> { [weak self] error in
            self?.transitionQueue.async {
                guard let self = self, self.policy.acceptsCallback(for: generation) else { return }
                finish(error)
            }
        }
        settlement.scheduleTimeout(after: dependencies.stageTimeout, queue: transitionQueue, outcome: {
            return .timedOut(stage)
        })
        return settlement
    }

    private func ownedHelper(
        _ failure: @escaping () -> Void,
        checkRuntimeOwnership: Bool = true
    ) -> SystemProxyHelperClient? {
        guard !hasPendingHelperMutation else {
            Logger.log("System Proxy request blocked: a previous helper write has not confirmed completion", level: .warning)
            failure()
            return nil
        }
        guard !checkRuntimeOwnership || dependencies.canControlRuntime() else {
            failure()
            return nil
        }
        return dependencies.helper(failure)
    }

    private func fail(_ error: OperationError, complete: ((Bool) -> Void)?) {
        Logger.log("system proxy transition failed: \(error)", level: .error)
        finishOnMain(false, complete)
    }

    private func finishOnMain(_ success: Bool, _ complete: ((Bool) -> Void)?) {
        DispatchQueue.main.async {
            complete?(success)
        }
    }
}

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
}

/// Owns the complete system-proxy transition. Enabling never reaches the
/// privileged helper until the previous settings have been captured or a
/// known-valid snapshot already exists.
final class SystemProxyManager: NSObject {
    private enum OperationError: Error {
        case helperUnavailable
        case captureFailed(String)
        case enableFailed(String)
        case disableFailed(String)
        case timedOut(String)
    }

    private let transitionQueue = DispatchQueue(label: "com.clashfx.system-proxy-transition")
    private let operations: SerializedAsyncOperationQueue
    private var isTerminating = false
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

    func enableProxy(complete: ((Bool) -> Void)? = nil) {
        let port = dependencies.currentPorts().http
        let socketPort = dependencies.currentPorts().socks
        enableProxy(port: port, socksPort: socketPort, complete: complete)
    }

    func enableProxy(
        port: Int,
        socksPort: Int,
        replacingExternalProxy: Bool = false,
        complete: ((Bool) -> Void)? = nil
    ) {
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
            guard !self.isTerminating else {
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
                onSuccess: enable,
                complete: complete
            )
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
        operations.enqueue { [weak self] done in
            guard let self = self else { done(); return }
            guard !self.isTerminating || forTermination else {
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
                    guard !SystemProxyOperationPolicy.isClashFXOwnedSnapshot(snapshot, httpPort: port, socksPort: socksPort) else {
                        self.fail(.captureFailed("current proxy settings already belong to ClashFX; no original snapshot is available"), complete: complete)
                        return
                    }
                    self.saveSnapshot(snapshot)
                    Logger.log("saved system proxy snapshot before enable", level: .debug)
                    onSuccess()
                case let .failure(error):
                    self.fail(error, complete: complete)
                }
            }
        }
        settlement.scheduleTimeout(after: dependencies.stageTimeout, queue: transitionQueue, outcome: {
            return .failure(.timedOut("capturing current system proxy settings"))
        })

        guard let proxy = dependencies.helper({
            _ = settlement.finish(.failure(.helperUnavailable))
        }) else {
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
        complete: ((Bool) -> Void)?
    ) {
        guard policy.acceptsCallback(for: generation) else { return }
        guard !isTerminating else {
            finishOnMain(false, complete)
            return
        }
        if replacingExternalProxy {
            forceDisableBeforeEnable(generation: generation, port: port, socksPort: socksPort, complete: complete)
            return
        }
        invokeEnable(generation: generation, port: port, socksPort: socksPort, complete: complete)
    }

    private func forceDisableBeforeEnable(
        generation: UInt64,
        port: Int,
        socksPort: Int,
        complete: ((Bool) -> Void)?
    ) {
        let settlement = helperSettlement(generation: generation, stage: "force-disabling system proxy") { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.fail(error, complete: complete)
            } else {
                self.invokeEnable(generation: generation, port: port, socksPort: socksPort, complete: complete)
            }
        }
        guard let proxy = dependencies.helper({
            _ = settlement.finish(.helperUnavailable)
        }) else {
            _ = settlement.finish(.helperUnavailable)
            return
        }
        proxy.disable(dependencies.filterInterface()) { error in
            _ = settlement.finish(error.map(OperationError.disableFailed))
        }
    }

    private func invokeEnable(generation: UInt64, port: Int, socksPort: Int, complete: ((Bool) -> Void)?) {
        guard !isTerminating else {
            finishOnMain(false, complete)
            return
        }
        let settlement = helperSettlement(generation: generation, stage: "enabling system proxy") { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.fail(error, complete: complete)
            } else {
                self.finishOnMain(true, complete)
            }
        }
        guard let proxy = dependencies.helper({
            _ = settlement.finish(.helperUnavailable)
        }) else {
            _ = settlement.finish(.helperUnavailable)
            return
        }
        proxy.enable(
            Int32(port),
            Int32(socksPort),
            dependencies.filterInterface(),
            dependencies.proxyIgnoreList()
        ) { error in
            _ = settlement.finish(error.map(OperationError.enableFailed))
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
        guard let proxy = dependencies.helper({
            _ = settlement.finish(.helperUnavailable)
        }) else {
            _ = settlement.finish(.helperUnavailable)
            return
        }
        if shouldRestore {
            proxy.restore(
                Int32(port),
                Int32(socksPort),
                savedProxyInfo,
                dependencies.filterInterface()
            ) { error in
                _ = settlement.finish(error.map(OperationError.disableFailed))
            }
        } else {
            proxy.disable(dependencies.filterInterface()) { error in
                _ = settlement.finish(error.map(OperationError.disableFailed))
            }
        }
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
        guard let helper = dependencies.helper({
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

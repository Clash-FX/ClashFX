import Foundation

/// Main-queue transaction shared by the app and isolated failure-injection tests.
/// Settings are committed only after the runtime and System Proxy accept the change.
final class ClaudeProxyLockTransaction {
    struct Failure {
        let primary: String
        let restorationErrors: [String]
        let cancelled: Bool
    }

    struct Dependencies {
        var isCurrent: () -> Bool
        var applyRuntime: (@escaping (String?) -> Void) -> Void
        var applySystemProxy: (@escaping (String?) -> Void) -> Void
        var prepareRollback: () -> Void
        var restoreRuntime: (@escaping (String?) -> Void) -> Void
        var restoreSystemProxy: (@escaping (String?) -> Void) -> Void
        var commit: () -> Void
        var finished: (Failure?) -> Void
    }

    private let dependencies: Dependencies
    private var sequence = 0
    private var finished = false
    private var started = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        run(dependencies.applyRuntime) { error in
            if let error { self.rollback(error); return }
            self.run(self.dependencies.applySystemProxy) { error in
                if let error { self.rollback(error); return }
                self.dependencies.commit()
                self.finish(nil)
            }
        }
    }

    private func rollback(_ primary: String) {
        dependencies.prepareRollback()
        run(dependencies.restoreRuntime) { runtimeError in
            // Restore the proxy snapshot even if runtime recovery failed. Leaving
            // a new loopback proxy behind can otherwise keep the machine offline.
            self.run(self.dependencies.restoreSystemProxy) { proxyError in
                self.finish(Failure(
                    primary: primary,
                    restorationErrors: [runtimeError, proxyError].compactMap { $0 },
                    cancelled: false
                ))
            }
        }
    }

    private func run(
        _ stage: (@escaping (String?) -> Void) -> Void,
        completion: @escaping (String?) -> Void
    ) {
        guard !finished else { return }
        guard dependencies.isCurrent() else { cancel(); return }
        sequence += 1
        let capturedSequence = sequence
        var settled = false
        stage { error in
            DispatchQueue.main.async {
                guard !self.finished, !settled,
                      self.sequence == capturedSequence else { return }
                settled = true
                guard self.dependencies.isCurrent() else { self.cancel(); return }
                completion(error)
            }
        }
    }

    private func cancel() {
        finish(Failure(primary: "Claude Proxy Lock change was superseded.",
                       restorationErrors: [], cancelled: true))
    }

    private func finish(_ failure: Failure?) {
        guard !finished else { return }
        finished = true
        sequence += 1
        dependencies.finished(failure)
    }
}

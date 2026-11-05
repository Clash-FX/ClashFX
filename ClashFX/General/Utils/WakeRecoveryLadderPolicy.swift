import Foundation

/// Escalation ladder for a wake in which the core API answers but Enhanced
/// Mode's DNS listener may have stopped responding. A config reload reapplies
/// DNS and TUN state without exiting the core, so it is tried once before a
/// full stop/start, which is the step that can race for the DNS port.
struct WakeRecoveryLadder {
    enum Step: Equatable {
        /// The listener answers, or there is nothing to probe.
        case finish
        /// Reapply the confirmed configuration in place (owned port plan).
        case reloadConfig
        /// The listener is still silent after an in-place reload.
        case restartEnhancedMode
        /// A newer wake superseded this one; take no action.
        case abandon
    }

    private let generation: Int
    private var reloadAttempted = false

    init(generation: Int) {
        self.generation = generation
    }

    /// - Parameters:
    ///   - currentGeneration: the app's live wake generation.
    ///   - dnsListenerResponding: nil when no listener port is known.
    mutating func nextStep(currentGeneration: Int, dnsListenerResponding: Bool?) -> Step {
        guard currentGeneration == generation else { return .abandon }
        guard dnsListenerResponding == false else { return .finish }
        if reloadAttempted { return .restartEnhancedMode }
        reloadAttempted = true
        return .reloadConfig
    }
}

/// Runs a `WakeRecoveryLadder` against injected effects so the escalation
/// wiring can be exercised without a core, a socket or a sleeping machine.
enum WakeRecoveryLadderDriver {
    struct Hooks {
        let port: Int
        let generation: () -> Int
        /// Reports whether the DNS listener answers; nil when unknown.
        let probe: (@escaping (Bool?) -> Void) -> Void
        /// Reapplies the confirmed configuration; the argument is the error, if any.
        let reload: (@escaping (String?) -> Void) -> Void
        let restart: (String) -> Void
        let log: (String) -> Void
    }

    static func run(_ ladder: WakeRecoveryLadder, hooks: Hooks) {
        var ladder = ladder
        hooks.probe { responding in
            switch ladder.nextStep(currentGeneration: hooks.generation(), dnsListenerResponding: responding) {
            case .finish, .abandon:
                break
            case .reloadConfig:
                hooks.log("DNS listener on port \(hooks.port) is silent; reloading the confirmed configuration in place")
                hooks.reload { error in
                    if let error = error {
                        hooks.log("in-place reload failed (\(error)); rebuilding Enhanced Mode")
                        hooks.restart("wake DNS listener reload failed")
                        return
                    }
                    run(ladder, hooks: hooks)
                }
            case .restartEnhancedMode:
                hooks.log("DNS listener still silent after reload; rebuilding Enhanced Mode")
                hooks.restart("wake DNS listener unresponsive after reload")
            }
        }
    }
}

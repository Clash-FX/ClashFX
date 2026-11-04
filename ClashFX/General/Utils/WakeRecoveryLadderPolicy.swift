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

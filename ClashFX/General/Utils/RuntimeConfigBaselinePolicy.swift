import Foundation

/// A listener-verified startup snapshot is not evidence that a profile loaded.
enum RuntimeConfigBaselineKind: String {
    case startup
    case profile

    init(confirmedProfile: String?) {
        self = confirmedProfile == nil ? .startup : .profile
    }

    func rollbackMessage(reason: String, localize: (String) -> String = { NSLocalizedString($0, comment: "") }) -> String {
        let key: String
        switch self {
        case .startup:
            key = "Configuration switch failed; the startup configuration was restored. The selected profile has not loaded successfully. %@"
        case .profile:
            key = "Configuration switch failed; the previously verified profile configuration was restored. %@"
        }
        return String(format: localize(key), reason)
    }
}

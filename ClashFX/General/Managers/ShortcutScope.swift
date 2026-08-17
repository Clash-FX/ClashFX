//
//  ShortcutScope.swift
//  ClashFX
//

enum ShortcutScope: Int {
    case menuOnly
    case global
}

enum ShortcutCommandKind {
    case action
    case openMenu
}

enum ShortcutRegistrationPolicy {
    static let defaultActionScope = ShortcutScope.menuOnly

    static func actionScope(from rawValue: Int) -> ShortcutScope {
        ShortcutScope(rawValue: rawValue) ?? defaultActionScope
    }

    static func shouldRegisterGlobally(
        _ commandKind: ShortcutCommandKind,
        scope: ShortcutScope
    ) -> Bool {
        switch commandKind {
        case .openMenu:
            return true
        case .action:
            return scope == .global
        }
    }

    static func shouldRegisterActionShortcutsGlobally(
        scope: ShortcutScope,
        isMenuTracking: Bool
    ) -> Bool {
        shouldRegisterGlobally(.action, scope: scope) && !isMenuTracking
    }
}

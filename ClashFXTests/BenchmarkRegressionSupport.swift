import Foundation

// The unhosted unit-test bundle compiles the pure proxy-model sources directly.
// These test-only shims satisfy their logging/date-format dependencies without
// loading ClashFX's AppDelegate, controller, helper, or live configuration.
enum ClashLogLevel {
    case info
    case warning
}

enum Logger {
    static func log(_ message: String, level: ClashLogLevel = .info) {}
}

extension DateFormatter {
    static let js: DateFormatter = DateFormatter()
}

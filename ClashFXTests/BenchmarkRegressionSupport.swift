import Foundation

/// The unhosted unit-test bundle compiles the pure proxy-model sources directly.
/// These test-only shims satisfy their logging/date-format dependencies without
/// loading ClashFX's AppDelegate, controller, helper, or live configuration.
enum ClashLogLevel {
    case info
    case warning
}

enum Logger {
    static func log(_ message: String, level: ClashLogLevel = .info) {}
}

extension DateFormatter {
    static let js: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: NSCalendar.Identifier.ISO8601.rawValue)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SZ"
        return formatter
    }()
}

final class IsolatedBenchmarkSession {
    private var terminated = false
    private var observers = [() -> Void]()

    var isCancelled = false

    func onTermination(_ observer: @escaping () -> Void) {
        if terminated {
            observer()
        } else {
            observers.append(observer)
        }
    }

    func cancel() {
        isCancelled = true
        terminate()
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        let callbacks = observers
        observers.removeAll()
        callbacks.forEach { $0() }
    }
}

struct IsolatedBenchmarkOwnership {
    private(set) var activeGeneration: Int?

    mutating func begin() -> Int {
        let generation = (activeGeneration ?? 0) + 1
        activeGeneration = generation
        return generation
    }

    mutating func finish(_ generation: Int) -> Bool {
        guard activeGeneration == generation else { return false }
        activeGeneration = nil
        return true
    }
}

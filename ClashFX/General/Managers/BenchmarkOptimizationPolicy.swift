import Foundation

enum BenchmarkRequestPolicy {
    private static let timeoutMargin: TimeInterval = 2

    static func timeoutInterval(coreTimeoutMilliseconds: Int) -> TimeInterval {
        max(1, Double(coreTimeoutMilliseconds) / 1000 + timeoutMargin)
    }
}

/// Measurements made before a runtime measurement-method change are not
/// comparable with the new method, even if node IDs and URLs are unchanged.
enum BenchmarkMeasurementEpoch {
    private static let lock = NSLock()
    private static var minimumTime = Date.distantPast

    @discardableResult
    static func invalidate(at time: Date = Date()) -> Date {
        lock.lock()
        let previous = minimumTime
        minimumTime = time
        lock.unlock()
        return previous
    }

    static func acceptsMeasurement(at time: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return time >= minimumTime
    }
}

enum BenchmarkMode: String, CaseIterable {
    case quick
    case complete

    var timeoutMilliseconds: Int {
        switch self {
        case .quick: return 2500
        case .complete: return 5000
        }
    }
}

enum BenchmarkSortOrder: String, CaseIterable {
    case configuration
    case latency
}

enum BenchmarkMeasurementMethod: String, CaseIterable {
    case followConfiguration
    case unified
    case connection
}

struct BenchmarkProgressSnapshot: Equatable {
    let total: Int
    let completed: Int
    let succeeded: Int
    let timedOut: Int
    let failed: Int
    let unavailable: Int
    let reused: Int

    init(
        total: Int = 0,
        completed: Int = 0,
        succeeded: Int = 0,
        timedOut: Int = 0,
        failed: Int = 0,
        unavailable: Int = 0,
        reused: Int = 0
    ) {
        self.total = total
        self.completed = completed
        self.succeeded = succeeded
        self.timedOut = timedOut
        self.failed = failed
        self.unavailable = unavailable
        self.reused = reused
    }
}

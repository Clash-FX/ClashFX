import Foundation

/// Compose the current result and historical reference without treating an old
/// positive delay as the outcome of a new failed request.
enum BenchmarkFailurePresentation {
    static func details(
        for presentation: BenchmarkRowResolver.Presentation,
        conditions: BenchmarkConditions,
        proxy: ClashProxy?,
        currentScope: BenchmarkProbeCoreScope? = nil
    ) -> String {
        var lines = [BenchmarkProbeDiagnostic.sanitizedURL(conditions.url)]
        if let date = presentation.measuredAt {
            let key: String
            if case .measured = presentation.state { key = "Measured at: %@" }
            else { key = "Attempted at: %@" }
            lines.append(String(format: NSLocalizedString(key, comment: ""), timestamp(date)))
        }
        if presentation.isHistorical {
            lines.append(NSLocalizedString("Historical benchmark result", comment: ""))
        }
        if let previous = presentation.previousSuccess,
           case let .measured(_, delay) = previous.state, delay > 0 {
            lines.append(String(
                format: NSLocalizedString("Previous successful measurement: %@ (%@)", comment: ""),
                "\(delay) ms", timestamp(previous.measuredAt)
            ))
        }
        let diagnostic = proxy.flatMap { proxy in
            if let currentScope {
                return BenchmarkProbeDiagnosticsStore.latest(
                    for: proxy,
                    conditions: conditions,
                    currentScope: currentScope
                )
            }
            return ApiRequest.latestBenchmarkProbeDiagnostic(for: proxy, conditions: conditions)
        }
        if let diagnostic,
           let date = presentation.measuredAt,
           abs(diagnostic.completedAt.timeIntervalSince(date)) <= 2,
           matches(diagnostic.outcome, presentation.state) {
            lines.append(String(format: NSLocalizedString("Latest recorded probe: %@", comment: ""),
                                timestamp(diagnostic.completedAt)))
            lines.append(String(format: NSLocalizedString("Probe timeout: %d ms; elapsed: %d ms", comment: ""),
                                diagnostic.timeoutMilliseconds, diagnostic.elapsedMilliseconds))
            if let status = diagnostic.statusCode {
                lines.append(String(format: NSLocalizedString("Core API response: %d", comment: ""), status))
            }
            if let reason = diagnostic.localizedFailureDescription { lines.append(reason) }
        }
        return lines.joined(separator: "\n")
    }

    static func matches(_ outcome: ProxyDelayOutcome, _ state: ProxyBenchmarkRowState) -> Bool {
        switch (outcome, state) {
        case (.failed, .failed), (.timedOut, .timedOut), (.unavailable, .unavailable):
            return true
        case let (.measured(probeDelay), .measured(_, rowDelay)):
            return probeDelay == rowDelay
        default: return false
        }
    }

    private static func timestamp(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
    }
}

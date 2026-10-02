import XCTest

final class BenchmarkHistoryPresentationTests: XCTestCase {
    private let historyFormat = "%@ (previous)"

    func testUnavailableLatestAttemptKeepsOldMeasurementMarkedUntilSuccess() {
        let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let measurement = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 1177),
            measuredAt: measuredAt
        )
        let unavailableAttempt = BenchmarkRowResolver.Evidence(
            state: .unavailable(displayName: "Leaf"),
            measuredAt: measuredAt.addingTimeInterval(1)
        )

        let historical = BenchmarkRowResolver.resolve(
            name: "Leaf", core: nil, cached: measurement, contextual: nil,
            activity: unavailableAttempt, now: measuredAt.addingTimeInterval(2)
        )

        XCTAssertEqual(historical.state.rawDelay, 1177)
        XCTAssertTrue(historical.isHistorical)
        XCTAssertTrue(historical.lastAttemptUnavailable)
        XCTAssertEqual(displayDelay(for: historical), "1177 ms (previous)")

        let newMeasurement = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 93),
            measuredAt: measuredAt.addingTimeInterval(3)
        )
        let current = BenchmarkRowResolver.resolve(
            name: "Leaf", core: nil, cached: newMeasurement, contextual: nil,
            activity: newMeasurement, now: measuredAt.addingTimeInterval(4)
        )

        XCTAssertEqual(current.state.rawDelay, 93)
        XCTAssertFalse(current.isHistorical)
        XCTAssertFalse(current.lastAttemptUnavailable)
        XCTAssertEqual(displayDelay(for: current), "93 ms")
    }

    func testMeasurementOlderThanThirtyMinutesGetsHistoryMarker() {
        let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let measurement = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 1177),
            measuredAt: measuredAt
        )
        let result = BenchmarkRowResolver.resolve(
            name: "Leaf", core: nil, cached: measurement, contextual: nil,
            activity: nil, now: measuredAt.addingTimeInterval(30 * 60 + 1)
        )

        XCTAssertTrue(result.isHistorical)
        XCTAssertFalse(result.lastAttemptUnavailable)
        XCTAssertEqual(result.state.rawDelay, 1177)
        XCTAssertEqual(displayDelay(for: result), "1177 ms (previous)")
    }

    func testMethodChangeRejectsPreviousMeasurementsAndPendingActivity() {
        let boundary = Date(timeIntervalSince1970: 1_800_000_100)
        let previous = BenchmarkMeasurementEpoch.invalidate(at: boundary)
        defer { BenchmarkMeasurementEpoch.invalidate(at: previous) }
        let stale = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 1177),
            measuredAt: boundary.addingTimeInterval(-1)
        )
        let pending = BenchmarkRowResolver.Evidence(
            state: .testing(displayName: "Leaf"),
            measuredAt: boundary.addingTimeInterval(-1)
        )
        let invalidated = BenchmarkRowResolver.resolve(
            name: "Leaf", core: nil, cached: stale, contextual: nil,
            activity: pending, now: boundary
        )
        XCTAssertNil(invalidated.state.rawDelay)
        guard case .unavailable = invalidated.state else {
            return XCTFail("Old testing activity must be invalidated")
        }
        let fresh = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 80), measuredAt: boundary
        )
        let current = BenchmarkRowResolver.resolve(
            name: "Leaf", core: nil, cached: fresh, contextual: stale,
            activity: pending, now: boundary
        )
        XCTAssertEqual(current.state.rawDelay, 80)
        XCTAssertFalse(current.isHistorical)
    }

    private func displayDelay(for presentation: BenchmarkRowResolver.Presentation) -> String? {
        BenchmarkRowDelayPresentation.applyingHistoryMarker(
            to: presentation.state.delayDisplay,
            isHistorical: presentation.isHistorical,
            localizedFormat: historyFormat
        )
    }
}

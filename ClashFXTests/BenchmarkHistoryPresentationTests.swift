import XCTest

final class BenchmarkHistoryPresentationTests: XCTestCase {
    private let historyFormat = "%@ · old"

    func testUnavailableLatestAttemptRemainsPrimaryAndKeepsPreviousSuccess() {
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

        XCTAssertNil(historical.state.rawDelay)
        guard case .unavailable = historical.state else {
            return XCTFail("The latest unavailable attempt must remain the primary state")
        }
        XCTAssertEqual(historical.measuredAt, unavailableAttempt.measuredAt)
        XCTAssertFalse(historical.isHistorical)
        XCTAssertTrue(historical.lastAttemptUnavailable)
        XCTAssertEqual(historical.previousSuccess?.state.rawDelay, 1177)
        XCTAssertEqual(historical.previousSuccess?.measuredAt, measurement.measuredAt)
        XCTAssertEqual(displayDelay(for: historical), NSLocalizedString("Benchmark unavailable", comment: ""))

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
        XCTAssertNil(current.previousSuccess)
        XCTAssertEqual(displayDelay(for: current), "93 ms")
    }

    func testLatestFailureAndTimeoutUseAttemptDateAndKeepPriorSuccess() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let success = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 120), measuredAt: base
        )

        for (state, expectedDelay) in [
            (ProxyBenchmarkRowState.failed(displayName: "Leaf"), 0),
            (ProxyBenchmarkRowState.timedOut(displayName: "Leaf"), nil)
        ] {
            let attempt = BenchmarkRowResolver.Evidence(
                state: state, measuredAt: base.addingTimeInterval(1)
            )
            let result = BenchmarkRowResolver.resolve(
                name: "Leaf", core: nil, cached: success, contextual: nil,
                activity: attempt, now: base.addingTimeInterval(2)
            )

            XCTAssertEqual(result.state.rawDelay, expectedDelay)
            XCTAssertEqual(result.measuredAt, attempt.measuredAt)
            XCTAssertFalse(result.isHistorical)
            XCTAssertFalse(result.lastAttemptUnavailable)
            XCTAssertEqual(result.previousSuccess?.state.rawDelay, 120)
            XCTAssertEqual(result.previousSuccess?.measuredAt, success.measuredAt)
        }
    }

    func testLatestTestingRemainsVisibleWithOlderSuccess() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let success = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 120), measuredAt: base
        )
        let testing = BenchmarkRowResolver.Evidence(
            state: .testing(displayName: "Leaf"), measuredAt: base.addingTimeInterval(1)
        )
        let result = BenchmarkRowResolver.resolve(
            name: "Leaf", core: nil, cached: success, contextual: nil,
            activity: testing, now: base.addingTimeInterval(2)
        )

        guard case .testing = result.state else {
            return XCTFail("A current benchmark must stay visible over an older success")
        }
        XCTAssertNil(result.measuredAt)
        XCTAssertFalse(result.isHistorical)
        XCTAssertEqual(result.previousSuccess?.state.rawDelay, 120)
    }

    func testNewerActivitySupersedesOlderContextualTesting() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let previousSuccess = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 120), measuredAt: base.addingTimeInterval(-1)
        )
        let staleTesting = BenchmarkRowResolver.Evidence(
            state: .testing(displayName: "Leaf"), measuredAt: base
        )

        for (state, expectedDelay, offset) in [
            (ProxyBenchmarkRowState.failed(displayName: "Leaf"), 0, 1.0),
            (ProxyBenchmarkRowState.timedOut(displayName: "Leaf"), nil, 1.0),
            // Activity has priority when both explicit signals share a timestamp.
            (ProxyBenchmarkRowState.failed(displayName: "Leaf"), 0, 0.0)
        ] {
            let latestActivity = BenchmarkRowResolver.Evidence(
                state: state, measuredAt: base.addingTimeInterval(offset)
            )
            let result = BenchmarkRowResolver.resolve(
                name: "Leaf", core: nil, cached: previousSuccess,
                contextual: staleTesting, activity: latestActivity,
                now: base.addingTimeInterval(2)
            )

            XCTAssertEqual(result.state.rawDelay, expectedDelay)
            XCTAssertEqual(result.measuredAt, latestActivity.measuredAt)
            XCTAssertFalse(result.isHistorical)
            XCTAssertEqual(result.previousSuccess?.state.rawDelay, 120)
        }
    }

    func testFreshCoreFailureAndUnavailableAttemptCannotFallBackToOldSuccess() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter.js
        let history = "\"history\":[{\"time\":\"\(formatter.string(from: base.addingTimeInterval(-1)))\",\"delay\":120},{\"time\":\"\(formatter.string(from: base))\",\"delay\":0}]"
        let data = Data("{\"alive\":false,\(history)}".utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        let core = try decoder.decode(ClashProxyTestState.self, from: data)
        let result = BenchmarkRowResolver.resolve(
            name: "Leaf", core: core, cached: nil, contextual: nil, activity: nil,
            now: base.addingTimeInterval(1)
        )

        XCTAssertEqual(result.state.rawDelay, 0)
        XCTAssertEqual(result.measuredAt, base)
        XCTAssertFalse(result.isHistorical)
        XCTAssertEqual(result.previousSuccess?.state.rawDelay, 120)

        let unavailable = BenchmarkRowResolver.Evidence(
            state: .unavailable(displayName: "Leaf"), measuredAt: base.addingTimeInterval(1)
        )
        let afterUnavailable = BenchmarkRowResolver.resolve(
            name: "Leaf", core: core, cached: nil, contextual: nil,
            activity: unavailable, now: base.addingTimeInterval(2)
        )
        guard case .unavailable = afterUnavailable.state else {
            return XCTFail("A fresh unavailable attempt must remain the primary state")
        }
        XCTAssertEqual(afterUnavailable.measuredAt, unavailable.measuredAt)
        XCTAssertFalse(afterUnavailable.isHistorical)
        XCTAssertTrue(afterUnavailable.lastAttemptUnavailable)
        XCTAssertEqual(afterUnavailable.previousSuccess?.state.rawDelay, 120)
    }

    func testSuccessAtSameTimeWinsAndNewSuccessClearsFailure() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let success = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 120), measuredAt: base
        )
        let failure = BenchmarkRowResolver.Evidence(
            state: .failed(displayName: "Leaf"), measuredAt: base
        )
        let tied = BenchmarkRowResolver.resolve(
            name: "Leaf", core: nil, cached: success, contextual: nil,
            activity: failure, now: base.addingTimeInterval(1)
        )
        XCTAssertEqual(tied.state.rawDelay, 120)
        XCTAssertFalse(tied.isHistorical)
        XCTAssertFalse(tied.lastAttemptUnavailable)

        let newSuccess = BenchmarkRowResolver.Evidence(
            state: .measured(displayName: "Leaf", delay: 85), measuredAt: base.addingTimeInterval(1)
        )
        let cleared = BenchmarkRowResolver.resolve(
            name: "Leaf", core: nil, cached: success, contextual: nil,
            activity: newSuccess, now: base.addingTimeInterval(2)
        )
        XCTAssertEqual(cleared.state.rawDelay, 85)
        XCTAssertEqual(cleared.measuredAt, newSuccess.measuredAt)
        XCTAssertFalse(cleared.isHistorical)
        XCTAssertFalse(cleared.lastAttemptUnavailable)
        XCTAssertNil(cleared.previousSuccess)
    }

    func testTimeoutHasItsOwnRowStateAndCancellationIsNotNodeFailure() {
        let timedOut = ProxyDelayOutcome.timedOut.rowState(name: "Leaf")
        guard case .timedOut = timedOut else {
            return XCTFail("Timeout must have its own row state")
        }
        XCTAssertNil(timedOut.rawDelay)
        XCTAssertEqual(timedOut.delayDisplay, NSLocalizedString("Benchmark timed out", comment: ""))

        let cancelled = ProxyDelayOutcome.cancelled.rowState(name: "Leaf")
        XCTAssertNil(cancelled.rawDelay)
        guard case .unavailable = cancelled else {
            return XCTFail("Cancellation must not become a node failure")
        }
    }

    func testProbeDetailsRequireTheSameMeasuredDelayAsTheRow() {
        XCTAssertTrue(BenchmarkFailurePresentation.matches(
            .measured(90),
            .measured(displayName: "Leaf", delay: 90)
        ))
        XCTAssertFalse(BenchmarkFailurePresentation.matches(
            .measured(90),
            .measured(displayName: "Leaf", delay: 100)
        ))
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
        XCTAssertEqual(displayDelay(for: result), "1177 ms · old")
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

        let lateFailure = BenchmarkRowResolver.Evidence(
            state: .failed(displayName: "Leaf"), measuredAt: boundary.addingTimeInterval(-1)
        )
        let currentAfterLateFailure = BenchmarkRowResolver.resolve(
            name: "Leaf", core: nil, cached: fresh, contextual: nil,
            activity: lateFailure, now: boundary
        )
        XCTAssertEqual(currentAfterLateFailure.state.rawDelay, 80)
        XCTAssertFalse(currentAfterLateFailure.isHistorical)
    }

    private func displayDelay(for presentation: BenchmarkRowResolver.Presentation) -> String? {
        BenchmarkRowDelayPresentation.applyingHistoryMarker(
            to: presentation.state.delayDisplay,
            isHistorical: presentation.isHistorical,
            localizedFormat: historyFormat
        )
    }
}

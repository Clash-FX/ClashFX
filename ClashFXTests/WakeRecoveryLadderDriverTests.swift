import XCTest

final class WakeRecoveryLadderDriverTests: XCTestCase {
    private final class Harness {
        var generation = 7
        var probeResults: [Bool?]
        var reloadErrors: [String?]
        var events: [String] = []
        private(set) var logs: [String] = []

        init(probes: [Bool?], reloads: [String?] = [nil]) {
            probeResults = probes
            reloadErrors = reloads
        }

        func run(ladderGeneration: Int = 7) {
            WakeRecoveryLadderDriver.run(WakeRecoveryLadder(generation: ladderGeneration), hooks: .init(
                port: 7874,
                generation: { self.generation },
                probe: { report in
                    self.events.append("probe")
                    report(self.probeResults.isEmpty ? nil : self.probeResults.removeFirst())
                },
                reload: { done in
                    self.events.append("reload")
                    done(self.reloadErrors.isEmpty ? nil : self.reloadErrors.removeFirst())
                },
                restart: { self.events.append("restart:\($0)") },
                log: { self.logs.append($0) }
            ))
        }
    }

    func testRespondingListenerOnlyProbes() {
        let h = Harness(probes: [true])
        h.run()
        XCTAssertEqual(h.events, ["probe"])
    }

    func testSilentThenRecoveredAfterReloadNeverRestarts() {
        let h = Harness(probes: [false, true])
        h.run()
        XCTAssertEqual(h.events, ["probe", "reload", "probe"])
        XCTAssertTrue(h.logs.contains { $0.contains("port 7874 is silent") })
        XCTAssertEqual(h.logs.filter { $0.contains("probe on port 7874") }.count, 2)
    }

    func testSilentAfterReloadRestartsExactlyOnce() {
        let h = Harness(probes: [false, false, false])
        h.run()
        XCTAssertEqual(h.events, ["probe", "reload", "probe", "restart:wake DNS listener unresponsive after reload"])
    }

    func testFailedReloadRestartsWithoutReprobing() {
        let h = Harness(probes: [false], reloads: ["config rejected"])
        h.run()
        XCTAssertEqual(h.events, ["probe", "reload", "restart:wake DNS listener reload failed"])
    }

    func testSupersededWakeBeforeProbeResultDoesNothing() {
        let h = Harness(probes: [false])
        h.generation = 8
        h.run()
        XCTAssertEqual(h.events, ["probe"])
    }

    func testSupersededWakeDuringReloadDoesNotRestart() {
        let h = Harness(probes: [false, false])
        var reloadStarted = false
        WakeRecoveryLadderDriver.run(WakeRecoveryLadder(generation: 7), hooks: .init(
            port: 7874,
            generation: { h.generation },
            probe: { report in report(h.probeResults.removeFirst()) },
            reload: { done in reloadStarted = true; h.generation = 9; done(nil) },
            restart: { h.events.append("restart:\($0)") },
            log: { _ in }
        ))
        XCTAssertTrue(reloadStarted)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testHealthyProbeLeavesPositiveEvidenceInTheLog() {
        let h = Harness(probes: [true])
        h.run()
        XCTAssertEqual(h.logs, ["DNS listener probe on port 7874: responding (wake generation 7)"])
    }

    func testUnknownPortStateTakesNoAction() {
        let h = Harness(probes: [nil])
        h.run()
        XCTAssertEqual(h.events, ["probe"])
    }
}

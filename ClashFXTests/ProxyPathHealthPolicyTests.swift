import XCTest

final class ProxyPathHealthPolicyTests: XCTestCase {
    // MARK: leaf resolution

    func testResolvesSelectorThroughAutoGroupToTheCarryingNode() {
        let nodes: [String: ProxyPathNode] = [
            "Proxies": ProxyPathNode(type: "Selector", now: "Auto"),
            "Auto": ProxyPathNode(type: "URLTest", now: "Tokyo 1"),
            "Tokyo 1": ProxyPathNode(type: "Vmess", now: nil)
        ]
        XCTAssertEqual(SelectedLeafResolver.leaves(in: nodes, limit: 3), ["Tokyo 1"])
    }

    func testRanksTheMostSharedLeafFirstAndHonoursTheLimit() {
        let nodes: [String: ProxyPathNode] = [
            "A": ProxyPathNode(type: "Selector", now: "n2"),
            "B": ProxyPathNode(type: "Selector", now: "n2"),
            "C": ProxyPathNode(type: "Selector", now: "n1"),
            "D": ProxyPathNode(type: "Selector", now: "n3"),
            "n1": ProxyPathNode(type: "Trojan", now: nil),
            "n2": ProxyPathNode(type: "Trojan", now: nil),
            "n3": ProxyPathNode(type: "Trojan", now: nil)
        ]
        XCTAssertEqual(SelectedLeafResolver.leaves(in: nodes, limit: 2), ["n2", "n1"])
    }

    func testSkipsDirectRejectAndCycles() {
        let nodes: [String: ProxyPathNode] = [
            "Direct group": ProxyPathNode(type: "Selector", now: "DIRECT"),
            "Block": ProxyPathNode(type: "Selector", now: "REJECT"),
            "Loop1": ProxyPathNode(type: "Selector", now: "Loop2"),
            "Loop2": ProxyPathNode(type: "Selector", now: "Loop1"),
            "Empty": ProxyPathNode(type: "Selector", now: nil),
            "DIRECT": ProxyPathNode(type: "Direct", now: nil),
            "REJECT": ProxyPathNode(type: "Reject", now: nil)
        ]
        XCTAssertTrue(SelectedLeafResolver.leaves(in: nodes, limit: 3).isEmpty)
    }

    func testIgnoresGroupsThatAreNotSelectors() {
        let nodes: [String: ProxyPathNode] = [
            "Auto": ProxyPathNode(type: "URLTest", now: "n1"),
            "n1": ProxyPathNode(type: "Trojan", now: nil)
        ]
        XCTAssertTrue(SelectedLeafResolver.leaves(in: nodes, limit: 3).isEmpty)
    }

    // MARK: verdict

    func testOneAnsweringNodeMakesThePathHealthy() {
        let samples = [ProxyPathSample(leaf: "a", failure: .nodeResolution), ProxyPathSample(leaf: "b", failure: nil)]
        XCTAssertEqual(ProxyPathEvaluator.verdict(for: samples), .healthy)
    }

    func testNoSamplesIsNotAFailure() {
        XCTAssertEqual(ProxyPathEvaluator.verdict(for: []), .noSample)
    }

    func testAllFailingWithOneCauseReportsThatCause() {
        let samples = [ProxyPathSample(leaf: "a", failure: .nodeResolution), ProxyPathSample(leaf: "b", failure: .nodeResolution)]
        XCTAssertEqual(ProxyPathEvaluator.verdict(for: samples), .failing(.nodeResolution))
    }

    func testMixedCausesAreReportedAsUnknown() {
        let samples = [ProxyPathSample(leaf: "a", failure: .nodeResolution), ProxyPathSample(leaf: "b", failure: .unreachable)]
        XCTAssertEqual(ProxyPathEvaluator.verdict(for: samples), .failing(.unknown))
    }

    // MARK: ladder

    func testResolutionFailureEscalatesFlushThenReloadThenNotifies() {
        var ladder = ProxyPathRecoveryLadder(generation: 1)
        let failing = ProxyPathVerdict.failing(.nodeResolution)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 1, verdict: failing), .flushDNSCache)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 1, verdict: failing), .reloadConfig)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 1, verdict: failing), .notify(.nodeResolution))
        XCTAssertEqual(ladder.nextStep(currentGeneration: 1, verdict: failing), .finish)
    }

    func testUnreachableWaitsOnceThenNotifiesWithoutTouchingDNSOrConfig() {
        var ladder = ProxyPathRecoveryLadder(generation: 1)
        let failing = ProxyPathVerdict.failing(.unreachable)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 1, verdict: failing), .retryLater)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 1, verdict: failing), .notify(.unreachable))
    }

    func testRecoveryAtAnyStageEndsTheLadder() {
        var ladder = ProxyPathRecoveryLadder(generation: 1)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 1, verdict: .failing(.nodeResolution)), .flushDNSCache)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 1, verdict: .healthy), .finish)
    }

    func testSupersededWakeAbandonsWithoutConsumingStages() {
        var ladder = ProxyPathRecoveryLadder(generation: 1)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 2, verdict: .failing(.nodeResolution)), .abandon)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 1, verdict: .failing(.nodeResolution)), .flushDNSCache)
    }

    // MARK: driver

    private final class Harness {
        var generation = 1
        var verdicts: [ProxyPathVerdict]
        var events: [String] = []
        var delays: [TimeInterval] = []

        init(_ verdicts: [ProxyPathVerdict]) { self.verdicts = verdicts }

        func run() {
            ProxyPathRecoveryDriver.run(ProxyPathRecoveryLadder(generation: 1), hooks: .init(
                generation: { self.generation },
                probe: { report in
                    self.events.append("probe")
                    report(self.verdicts.isEmpty ? .healthy : self.verdicts.removeFirst())
                },
                flushDNSCache: { done in self.events.append("flush"); done() },
                reloadConfig: { done in self.events.append("reload"); done(nil) },
                after: { delay, block in self.delays.append(delay); block() },
                notify: { self.events.append("notify:\($0)") },
                log: { _ in }
            ))
        }
    }

    func testDriverStopsAtFlushWhenTheCacheWasTheProblem() {
        let h = Harness([.failing(.nodeResolution), .healthy])
        h.run()
        XCTAssertEqual(h.events, ["probe", "flush", "probe"])
    }

    func testDriverReloadsAfterFlushFailsAndStopsOnRecovery() {
        let h = Harness([.failing(.nodeResolution), .failing(.nodeResolution), .healthy])
        h.run()
        XCTAssertEqual(h.events, ["probe", "flush", "probe", "reload", "probe"])
    }

    func testDriverNotifiesOnlyAfterEveryAutomaticStepFailed() {
        let failing = ProxyPathVerdict.failing(.nodeResolution)
        let h = Harness([failing, failing, failing])
        h.run()
        XCTAssertEqual(h.events, ["probe", "flush", "probe", "reload", "probe", "notify:nodeResolution"])
        XCTAssertEqual(h.delays, [ProxyPathRecoveryDriver.settleAfterFlush, ProxyPathRecoveryDriver.settleAfterReload])
    }

    func testDriverNeverFlushesOrReloadsForUnreachableNodes() {
        let failing = ProxyPathVerdict.failing(.unreachable)
        let h = Harness([failing, failing])
        h.run()
        XCTAssertEqual(h.events, ["probe", "probe", "notify:unreachable"])
    }

    func testDriverStaysQuietWhenHealthyOrWithoutSamples() {
        let healthy = Harness([.healthy]); healthy.run()
        XCTAssertEqual(healthy.events, ["probe"])
        let none = Harness([.noSample]); none.run()
        XCTAssertEqual(none.events, ["probe"])
    }

    func testDriverAbandonsWhenAnotherWakeStarts() {
        let h = Harness([.failing(.nodeResolution)])
        h.generation = 2
        h.run()
        XCTAssertEqual(h.events, ["probe"])
    }

    // MARK: throttle

    func testThrottleAllowsOneNotificationPerInterval() {
        var throttle = ProxyPathNotificationThrottle(interval: 1800)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(throttle.shouldNotify(now: start))
        XCTAssertFalse(throttle.shouldNotify(now: start.addingTimeInterval(600)))
        XCTAssertFalse(throttle.shouldNotify(now: start.addingTimeInterval(1799)))
        XCTAssertTrue(throttle.shouldNotify(now: start.addingTimeInterval(1800)))
    }
}

import XCTest

final class DiagnosticFormattingTests: XCTestCase {
    func testRedactorSanitizesReportMetadataAndLogLines() {
        let input = """
        - Primary IP: 192.168.3.22
        - DNS Servers: 198.18.0.2
        - Config: /Users/example/.config/clashfx/config.yaml
        - Interface: aa:bb:cc:dd:ee:ff
        [Info] ApiRequest.swift request --> api.example.com:443
        - URL: https://cp.cloudflare.com/generate_204?token=private-token
        - Authorization: Bearer private-credential
        """

        let output = DiagnosticRedactor.redact(input, homeDirectory: "/Users/example")

        XCTAssertFalse(output.contains("example/.config"))
        XCTAssertFalse(output.contains("192.168.3.22"))
        XCTAssertFalse(output.contains("198.18.0.2"))
        XCTAssertFalse(output.contains("aa:bb:cc:dd:ee:ff"))
        XCTAssertFalse(output.contains("api.example.com"))
        XCTAssertFalse(output.contains("cp.cloudflare.com"))
        XCTAssertFalse(output.contains("private-token"))
        XCTAssertFalse(output.contains("private-credential"))
        XCTAssertTrue(output.contains("<redacted-home>"))
        XCTAssertTrue(output.contains("<redacted-ipv4>"))
        XCTAssertTrue(output.contains("<redacted-mac>"))
        XCTAssertTrue(output.contains("<redacted-host>"))
        XCTAssertTrue(output.contains("ApiRequest.swift"))
    }

    func testLogTimestampsUseLocalTimeAndExplicitOffset() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 60 * 60))
        let date = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(
            LogTimestampFormatting.lineDateFormatter(timeZone: timeZone).string(from: date),
            "1970/01/01 08:00:00.000 +08:00"
        )
        XCTAssertEqual(
            LogTimestampFormatting.fileName(
                appName: "com.clashfx.app",
                date: date,
                timeZone: timeZone
            ),
            "com.clashfx.app 1970-01-01--08-00-00-000-+0800.log"
        )
    }
}

final class BenchmarkRegressionTests: XCTestCase {
    private func snapshot(_ proxyJSON: [[String: Any]]) -> ClashProxyResp {
        let proxies = Dictionary(uniqueKeysWithValues: proxyJSON.compactMap { proxy -> (String, Any)? in
            guard let name = proxy["name"] as? String else { return nil }
            return (name, proxy)
        })
        let data = try! JSONSerialization.data(withJSONObject: ["proxies": proxies])
        return ClashProxyResp(data)
    }

    func testSelectorPlanSharesNestedAutomaticFinalLeaf() throws {
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Direct", "Automatic"], "now": "Direct", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Direct"], "now": "Direct", "history": []],
            ["name": "Direct", "type": "Direct", "history": []]
        ])
        let selector = try XCTUnwrap(response.proxiesMap["Selector"])

        let plan = SelectorBenchmarkPlan.make(
            selector: selector,
            snapshot: response,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        )

        XCTAssertEqual(plan.orderedRows.map(\.displayName), ["Direct", "Automatic"])
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertEqual(plan.targets.first?.aliases.map(\.rowName), ["Direct", "Automatic"])
        XCTAssertEqual(plan.targets.first?.key.proxyName, "Direct")
        XCTAssertEqual(plan.maxConcurrentRequests, 1)

        let automatic = AutomaticGroupRetestSnapshot.make(
            groupName: "Automatic",
            candidateDelays: ["Direct": 42, "Unrelated": 1],
            snapshot: response
        )
        XCTAssertEqual(automatic.finalLeaf, "Direct")
        guard case let .measured(delay) = automatic.evidence else {
            return XCTFail("expected fresh final-path measurement")
        }
        XCTAssertEqual(delay, 42)
    }

    func testSelectorPlanHandlesNilEmptyAndSingleLeafMembers() throws {
        let nilMembers = snapshot([
            ["name": "Selector", "type": "Selector", "history": []]
        ])
        XCTAssertTrue(try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(nilMembers.proxiesMap["Selector"]),
            snapshot: nilMembers,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        ).orderedRows.isEmpty)

        let emptyMembers = snapshot([
            ["name": "Selector", "type": "Selector", "all": [], "history": []]
        ])
        XCTAssertTrue(try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(emptyMembers.proxiesMap["Selector"]),
            snapshot: emptyMembers,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        ).targets.isEmpty)

        let singleLeaf = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Direct"], "now": "Direct", "history": []],
            ["name": "Direct", "type": "Direct", "history": []]
        ])
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(singleLeaf.proxiesMap["Selector"]),
            snapshot: singleLeaf,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        )
        XCTAssertEqual(plan.orderedRows.map(\.rowName), ["Direct"])
        XCTAssertEqual(plan.targets.count, 1)
    }

    func testResolutionReportsCycleMissingNowAndUnknownTarget() {
        let cycle = snapshot([
            ["name": "A", "type": "Selector", "all": ["B"], "now": "B", "history": []],
            ["name": "B", "type": "URLTest", "all": ["A"], "now": "A", "history": []]
        ])
        guard case let .unavailable(_, .cycle(name)) = cycle.resolveSelectedPath(from: "A") else {
            return XCTFail("expected cycle")
        }
        XCTAssertEqual(name, "A")

        let missingNow = snapshot([
            ["name": "A", "type": "Selector", "all": ["Direct"], "history": []],
            ["name": "Direct", "type": "Direct", "history": []]
        ])
        guard case let .unavailable(_, .missingSelection(name)) = missingNow.resolveSelectedPath(from: "A") else {
            return XCTFail("expected missingNow")
        }
        XCTAssertEqual(name, "A")

        let unknownTarget = snapshot([
            ["name": "A", "type": "Selector", "all": ["Ghost"], "now": "Ghost", "history": []]
        ])
        guard case let .unavailable(_, .unknownTarget(name)) = unknownTarget.resolveSelectedPath(from: "A") else {
            return XCTFail("expected unknownTarget")
        }
        XCTAssertEqual(name, "Ghost")
    }

    func testDistinctLeavesDoNotCoalesceAndRowsKeepStableOrder() throws {
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["First", "Second", "First"], "now": "First", "history": []],
            ["name": "First", "type": "Direct", "history": []],
            ["name": "Second", "type": "Reject", "history": []]
        ])
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(response.proxiesMap["Selector"]),
            snapshot: response,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        )
        XCTAssertEqual(plan.orderedRows.map(\.rowName), ["First", "Second", "First"])
        XCTAssertEqual(plan.targets.map(\.key.proxyName), ["First", "Second"])
        XCTAssertEqual(plan.targets[0].aliases.map(\.rowName), ["First", "First"])
        XCTAssertNotEqual(plan.targets[0].key, plan.targets[1].key)
        XCTAssertEqual(plan.targets[0].key.endpoint, .inline)
        XCTAssertNil(plan.targets[0].key.providerName)
        XCTAssertEqual(plan.targets[0].key.benchmarkURL, "https://benchmark.example.test")
        XCTAssertEqual(plan.targets[0].key.timeout, 5)
    }

    func testSelectorConcurrencyStaysConservativeForLargeMenus() throws {
        let names = (1 ... 25).map { "Proxy \($0)" }
        var proxies: [[String: Any]] = [
            ["name": "Selector", "type": "Selector", "all": names, "now": names[0], "history": []]
        ]
        proxies.append(contentsOf: names.map {
            ["name": $0, "type": "Direct", "history": []]
        })
        let response = snapshot(proxies)
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(response.proxiesMap["Selector"]),
            snapshot: response,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        )

        XCTAssertEqual(plan.targets.count, 25)
        XCTAssertEqual(plan.maxConcurrentRequests, 4)
    }

    func testAutomaticSnapshotsMapOnlyFreshPathEvidence() {
        let response = snapshot([
            ["name": "Automatic", "type": "URLTest", "all": ["Final", "LowerSibling"], "now": "Final", "history": []],
            ["name": "Final", "type": "Direct", "history": []],
            ["name": "LowerSibling", "type": "Direct", "history": []]
        ])
        let measured = AutomaticGroupRetestSnapshot.make(
            groupName: "Automatic",
            candidateDelays: ["Final": 50, "LowerSibling": 1],
            snapshot: response
        )
        XCTAssertEqual(measured.finalLeaf, "Final")
        guard case let .measured(delay) = measured.evidence else {
            return XCTFail("expected fresh final evidence")
        }
        XCTAssertEqual(delay, 50)

        let noMatchingCandidate = AutomaticGroupRetestSnapshot.make(
            groupName: "Automatic",
            candidateDelays: ["LowerSibling": 1],
            snapshot: response
        )
        guard case .noMatchingCandidate = noMatchingCandidate.evidence else {
            return XCTFail("expected noMatchingCandidate")
        }

        let zeroDelay = AutomaticGroupRetestSnapshot.make(
            groupName: "Automatic",
            candidateDelays: ["Final": 0],
            snapshot: response
        )
        guard case let .zeroDelay(node) = zeroDelay.evidence else {
            return XCTFail("expected zeroDelay")
        }
        XCTAssertEqual(node, "Final")
    }

    func testCancelTerminatesObserversOnceAndRejectsObsoleteGeneration() {
        let session = IsolatedBenchmarkSession()
        var terminationCount = 0
        session.onTermination { terminationCount += 1 }
        session.cancel()
        session.cancel()
        session.terminate()
        XCTAssertTrue(session.isCancelled)
        XCTAssertEqual(terminationCount, 1)

        var ownership = IsolatedBenchmarkOwnership()
        let obsoleteSession = ownership.begin()
        let replacementSession = ownership.begin()
        XCTAssertFalse(ownership.finish(obsoleteSession))
        XCTAssertEqual(ownership.activeGeneration, replacementSession)
        XCTAssertTrue(ownership.finish(replacementSession))
        XCTAssertNil(ownership.activeGeneration)
    }
}

final class StartupProxyRecoveryPolicyTests: XCTestCase {
    private func observation(
        wantsSystemProxy: Bool = true,
        proxyPaused: Bool = false,
        enhancedModeActive: Bool = false,
        initialConfigLoaded: Bool = true,
        coreRunning: Bool = true,
        httpPort: Int = 7890,
        socksPort: Int = 7891,
        helperReady: Bool = true,
        primaryInterfaceReady: Bool = true
    ) -> StartupProxyRecoveryObservation {
        StartupProxyRecoveryObservation(
            wantsSystemProxy: wantsSystemProxy,
            proxyPaused: proxyPaused,
            enhancedModeActive: enhancedModeActive,
            initialConfigLoaded: initialConfigLoaded,
            coreRunning: coreRunning,
            httpPort: httpPort,
            socksPort: socksPort,
            helperReady: helperReady,
            primaryInterfaceReady: primaryInterfaceReady
        )
    }

    func testRecoveryStopsWhenSystemProxyIsNoLongerDesired() {
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(wantsSystemProxy: false)),
            .stop
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(proxyPaused: true)),
            .stop
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(enhancedModeActive: true)),
            .stop
        )
    }

    func testRecoveryWaitsForEveryStartupPrerequisite() {
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(initialConfigLoaded: false)),
            .waitForConfig
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(httpPort: 0)),
            .waitForConfig
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(coreRunning: false)),
            .waitForCore
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(helperReady: false)),
            .waitForHelper
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(primaryInterfaceReady: false)),
            .waitForNetwork
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation()),
            .verifyAndApply
        )
    }
}

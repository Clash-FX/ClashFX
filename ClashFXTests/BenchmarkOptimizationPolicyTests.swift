import Cocoa
import XCTest

final class BenchmarkOptimizationPolicyTests: XCTestCase {
    func testBenchmarkModeValuesAndTimeouts() {
        XCTAssertEqual(BenchmarkMode.quick.rawValue, "quick")
        XCTAssertEqual(BenchmarkMode.quick.timeoutMilliseconds, 2500)
        XCTAssertEqual(BenchmarkMode.complete.rawValue, "complete")
        XCTAssertEqual(BenchmarkMode.complete.timeoutMilliseconds, 5000)
        XCTAssertEqual(BenchmarkSortOrder.configuration.rawValue, "configuration")
        XCTAssertEqual(BenchmarkSortOrder.latency.rawValue, "latency")
        XCTAssertEqual(BenchmarkMeasurementMethod.followConfiguration.rawValue, "followConfiguration")
        XCTAssertEqual(BenchmarkMeasurementMethod.unified.rawValue, "unified")
        XCTAssertEqual(BenchmarkMeasurementMethod.connection.rawValue, "connection")
    }

    func testClientWatchdogUsesCoreTimeoutPlusMargin() {
        XCTAssertEqual(
            BenchmarkRequestPolicy.timeoutInterval(
                coreTimeoutMilliseconds: BenchmarkMode.quick.timeoutMilliseconds
            ),
            4.5
        )
        XCTAssertEqual(
            BenchmarkRequestPolicy.timeoutInterval(
                coreTimeoutMilliseconds: BenchmarkMode.complete.timeoutMilliseconds
            ),
            7.0
        )
    }

    func testOnlyMihomoTimeoutResponseIsCountedAsTimedOut() {
        let coreTimeout = ProxyDelayOutcome.decode(
            statusCode: 504,
            data: Data("{\"message\":\"Timeout\"}".utf8),
            transportFailed: false
        )
        XCTAssertEqual(coreTimeout, .timedOut)

        let clientTimeout = ProxyDelayOutcome.decode(
            statusCode: nil,
            data: nil,
            transportFailed: true
        )
        XCTAssertEqual(clientTimeout, .unavailable)

        let unrelatedGatewayFailure = ProxyDelayOutcome.decode(
            statusCode: 504,
            data: Data("{\"message\":\"gateway unavailable\"}".utf8),
            transportFailed: false
        )
        XCTAssertEqual(unrelatedGatewayFailure, .unavailable)
    }

    func testNodeFailuresDoNotReduceFixedRunnerConcurrency() {
        let defaultPolicy = SelectorBenchmarkConcurrencyPolicy(targetCount: 30)
        XCTAssertEqual(defaultPolicy.currentLimit, 10)
        XCTAssertEqual(defaultPolicy.minimumLimit, 10)
        XCTAssertEqual(defaultPolicy.maximumLimit, 10)

        XCTAssertEqual(
            SelectorBenchmarkConcurrencyPolicy(targetCount: 30, strategy: .eight).currentLimit,
            8
        )
        XCTAssertEqual(
            SelectorBenchmarkConcurrencyPolicy(targetCount: 30, strategy: .twelve).currentLimit,
            12
        )

        let lock = NSLock()
        var active = 0
        var peak = 0
        var limitChangeCount = 0
        let tasks: [AdaptiveAsyncTaskRunner.Task] = (0 ..< 25).map { _ in
            { done in
                lock.lock()
                active += 1
                peak = max(peak, active)
                lock.unlock()

                DispatchQueue.global().asyncAfter(deadline: .now() + 0.002) {
                    lock.lock()
                    active -= 1
                    lock.unlock()
                    done(false)
                }
            }
        }
        let finished = expectation(description: "fixed benchmark runner")
        let runner = AdaptiveAsyncTaskRunner(
            tasks: tasks,
            policy: defaultPolicy,
            limitChanged: { _, _ in
                lock.lock()
                limitChangeCount += 1
                lock.unlock()
            }
        )
        runner.start { finished.fulfill() }

        wait(for: [finished], timeout: 3)
        XCTAssertEqual(peak, 10)
        XCTAssertEqual(limitChangeCount, 0)
    }

    func testRetryPlanKeepsOnlyFailedTargetsAndMatchesAcrossTimeoutModes() throws {
        let previousPlan = try makePlan(timeout: 5000)
        let currentPlan = try makePlan(timeout: 2500)
        let previousOutcomes = Dictionary(uniqueKeysWithValues: previousPlan.targets.enumerated().map {
            ($0.element.key, $0.offset == 0 ? ProxyDelayOutcome.measured(37) : .timedOut)
        })

        let retryPlan = try XCTUnwrap(currentPlan.retryingFailures(from: previousOutcomes))
        XCTAssertEqual(retryPlan.targets.map(\.key.proxyName), ["Second"])
        XCTAssertEqual(retryPlan.targets.first?.key.timeout, 2500)
        XCTAssertNil(retryPlan.selectedAutomaticRetest)
        XCTAssertEqual(retryPlan.orderedRows.map(\.rowName), ["Second"])
    }

    func testRetryPlanRetainsAliasesAndRejectsChangedIdentityOrURL() throws {
        let original = try makePlan(timeout: 5000)
        let firstKey = try XCTUnwrap(original.targets.first?.key)
        let retryAliases = try XCTUnwrap(
            original.retryingFailures(from: [firstKey: .failed])
        )
        XCTAssertEqual(retryAliases.targets.first?.aliases.map(\.rowName), ["First", "Nested"])

        let changedIdentity = try makePlan(timeout: 2500, secondCoreID: "second-v2")
        XCTAssertNil(changedIdentity.retryingFailures(from: [original.targets[1].key: .timedOut]))

        let changedURL = try makePlan(timeout: 2500, benchmarkURL: "https://other.example.test")
        XCTAssertNil(changedURL.retryingFailures(from: [original.targets[1].key: .timedOut]))
    }

    func testRetryKeyComparesStatusAndIdentityButIgnoresTimeout() {
        let oldKey = SelectorBenchmarkMeasurementKey(
            endpoint: .provider,
            providerName: "Provider",
            proxyName: "Node",
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5000,
            coreID: "node-id",
            expectedStatus: "204"
        )
        let quickKey = SelectorBenchmarkMeasurementKey(
            endpoint: .provider,
            providerName: "Provider",
            proxyName: "Node",
            benchmarkURL: "https://benchmark.example.test",
            timeout: 2500,
            coreID: "node-id",
            expectedStatus: " 204 "
        )
        let differentStatus = SelectorBenchmarkMeasurementKey(
            endpoint: .provider,
            providerName: "Provider",
            proxyName: "Node",
            benchmarkURL: "https://benchmark.example.test",
            timeout: 2500,
            coreID: "node-id",
            expectedStatus: "200"
        )

        XCTAssertTrue(quickKey.matchesRetryConditions(of: oldKey))
        XCTAssertFalse(differentStatus.matchesRetryConditions(of: oldKey))
    }

    func testProgressIncludesReusedSuccessAndCoreTimeoutOnMainQueue() throws {
        let plan = try makePlan(timeout: 2500)
        let firstKey = try XCTUnwrap(plan.targets.first?.key)
        let finished = expectation(description: "benchmark completion")
        var finalProgress: BenchmarkProgressSnapshot?

        SelectorBenchmarkExecutor.runOutcomes(
            plan: plan,
            reusing: [firstKey: 37],
            executionPolicy: SelectorBenchmarkConcurrencyPolicy(targetCount: plan.targets.count, strategy: .eight),
            progress: { snapshot in
                XCTAssertTrue(Thread.isMainThread)
                if snapshot.completed == snapshot.total {
                    finalProgress = snapshot
                }
            },
            isCancelled: { false },
            request: { _, done in done(.timedOut) },
            result: { _, _ in },
            completion: { finished.fulfill() }
        )

        wait(for: [finished], timeout: 3)
        XCTAssertEqual(
            finalProgress,
            BenchmarkProgressSnapshot(
                total: 2,
                completed: 2,
                succeeded: 1,
                timedOut: 1,
                failed: 0,
                unavailable: 0,
                reused: 1
            )
        )
    }

    private func makePlan(
        timeout: Int,
        benchmarkURL: String = "https://benchmark.example.test",
        secondCoreID: String = "second-id"
    ) throws -> SelectorBenchmarkPlan {
        let proxyJSON: [String: Any] = [
            "proxies": [
                "Selector": [
                    "name": "Selector",
                    "type": "Selector",
                    "all": ["Automatic", "First", "Nested", "Second"],
                    "now": "Automatic",
                    "history": []
                ],
                "Automatic": [
                    "name": "Automatic",
                    "type": "URLTest",
                    "all": ["First"],
                    "now": "First",
                    "history": []
                ],
                "Nested": [
                    "name": "Nested",
                    "type": "Selector",
                    "all": ["First"],
                    "now": "First",
                    "history": []
                ],
                "First": [
                    "name": "First",
                    "id": "first-id",
                    "type": "Vless",
                    "history": []
                ],
                "Second": [
                    "name": "Second",
                    "id": secondCoreID,
                    "type": "Vless",
                    "history": []
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: proxyJSON)
        let snapshot = ClashProxyResp(data)
        let selector = try XCTUnwrap(snapshot.proxiesMap["Selector"])
        return SelectorBenchmarkPlan.make(
            selector: selector,
            snapshot: snapshot,
            benchmarkURL: benchmarkURL,
            timeout: timeout
        )
    }
}

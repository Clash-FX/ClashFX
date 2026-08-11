import XCTest

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

        XCTAssertEqual(plan.orderedRows.map(\.displayName), ["Direct", "Automatic → Direct"])
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertEqual(plan.targets.first?.aliases.map(\.rowName), ["Direct", "Automatic"])
        XCTAssertEqual(plan.targets.first?.key.proxyName, "Direct")

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
}

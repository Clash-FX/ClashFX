import XCTest

final class ProxySelectionMemoryRestorationTests: XCTestCase {
    private final class Harness {
        var current = true
        var refreshCount = 0
        var refreshCompletion: ((ClashProxyResp?) -> Void)?
        var selections = [(String, String)]()
        var selectionCompletions = [(Bool) -> Void]()

        func dependencies(stageTimeout: TimeInterval = 1) -> ProxySelectionMemoryRestorationController.Dependencies {
            ProxySelectionMemoryRestorationController.Dependencies(
                isCurrent: { self.current },
                refresh: { complete in
                    self.refreshCount += 1
                    self.refreshCompletion = complete
                },
                select: { group, name, complete in
                    self.selections.append((group, name))
                    self.selectionCompletions.append(complete)
                },
                stageTimeout: stageTimeout
            )
        }
    }

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Thread.isMainThread)
    }

    func testUsesFreshSnapshotSkipsAutomaticGroupsAndKeepsLastRecordPerSelector() {
        let harness = Harness()
        let controller = ProxySelectionMemoryRestorationController(dependencies: harness.dependencies())
        var completions = [Bool]()
        let records = [
            record("Selector", "A"),
            record("URLTest", "A"),
            record("Fallback", "B"),
            record("LoadBalance", "A"),
            record("Relay", "A"),
            record("MissingMember", "B"),
            record("CompatSelector", "COMPATIBLE"),
            record("Selector", "B")
        ]

        controller.restore(records: records) { completions.append($0) }

        XCTAssertEqual(harness.refreshCount, 1)
        XCTAssertTrue(harness.selections.isEmpty, "No cached-only selection should be issued before the fresh GET")
        harness.refreshCompletion?(snapshot())
        waitUntil("first eligible saved selection") { harness.selections.count == 1 }

        XCTAssertEqual(harness.selections.first?.0, "Selector")
        XCTAssertEqual(harness.selections.first?.1, "B", "The last saved record for a group wins")
        harness.selectionCompletions[0](true)
        waitUntil("restore completion") { completions.count == 1 }

        XCTAssertEqual(completions, [true])
        XCTAssertEqual(harness.selections.count, 1)
    }

    func testRestorationWritesAreSerialAndReportsAnySuccessfulSelection() {
        let harness = Harness()
        let controller = ProxySelectionMemoryRestorationController(dependencies: harness.dependencies())
        var completions = [Bool]()
        controller.restore(records: [record("Selector", "A"), record("OtherSelector", "B")]) {
            completions.append($0)
        }
        harness.refreshCompletion?(snapshot())
        waitUntil("first selection started") { harness.selections.count == 1 }
        XCTAssertEqual(harness.selections.map { $0.0 }, ["Selector"])

        harness.selectionCompletions[0](true)
        waitUntil("second selection started") { harness.selections.count == 2 }
        XCTAssertEqual(harness.selections.map { $0.0 }, ["Selector", "OtherSelector"])
        harness.selectionCompletions[1](false)
        waitUntil("partial restore completed") { completions.count == 1 }

        XCTAssertEqual(completions, [true])
    }

    func testCancelDuringMutationWaitsForStageAndStartsNoFurtherWrites() {
        let harness = Harness()
        var controller: ProxySelectionMemoryRestorationController? =
            ProxySelectionMemoryRestorationController(dependencies: harness.dependencies())
        weak var weakController = controller
        var completions = [Bool]()
        controller?.restore(records: [record("Selector", "A"), record("OtherSelector", "B")]) {
            completions.append($0)
        }
        harness.refreshCompletion?(snapshot())
        waitUntil("first selection started") { harness.selections.count == 1 }

        controller?.cancel()
        XCTAssertTrue(completions.isEmpty, "Keep the reload gate until the outstanding PUT settles")
        controller = nil
        XCTAssertNotNil(weakController, "An outstanding PUT must retain its cancellation state")
        harness.selectionCompletions[0](true)
        waitUntil("cancelled restore completed") { completions.count == 1 }
        waitUntil("cancelled controller released") { weakController == nil }

        XCTAssertEqual(completions, [false])
        XCTAssertEqual(harness.selections.count, 1)
    }

    func testFreshTopologyTypeAndMembershipMustMatchBeforeAnyPut() {
        let harness = Harness()
        let controller = ProxySelectionMemoryRestorationController(dependencies: harness.dependencies())
        var completions = [Bool]()
        controller.restore(records: [record("Selector", "A"), record("OtherSelector", "B")]) {
            completions.append($0)
        }
        harness.refreshCompletion?(snapshot(selectorType: "URLTest", selectorMembers: ["A"], otherMembers: ["A"]))
        waitUntil("invalid topology rejected") { completions.count == 1 }

        XCTAssertEqual(completions, [false])
        XCTAssertTrue(harness.selections.isEmpty)
    }

    func testStaleScopeAfterFreshGetPreventsWrites() {
        let harness = Harness()
        let controller = ProxySelectionMemoryRestorationController(dependencies: harness.dependencies())
        var completions = [Bool]()
        controller.restore(records: [record("Selector", "A")]) { completions.append($0) }
        harness.current = false
        harness.refreshCompletion?(snapshot())
        waitUntil("stale restore completed") { completions.count == 1 }

        XCTAssertEqual(completions, [false])
        XCTAssertTrue(harness.selections.isEmpty)
    }

    func testRefreshFailureAndLateSnapshotFinishOnceWithoutMutation() {
        let harness = Harness()
        let controller = ProxySelectionMemoryRestorationController(dependencies: harness.dependencies())
        var completions = [Bool]()
        controller.restore(records: [record("Selector", "A")]) { completions.append($0) }
        harness.refreshCompletion?(nil)
        waitUntil("refresh failure settled") { completions.count == 1 }

        harness.refreshCompletion?(snapshot())
        XCTAssertEqual(completions, [false])
        XCTAssertTrue(harness.selections.isEmpty)
    }

    func testRefreshTimeoutIgnoresLateSnapshot() {
        let harness = Harness()
        let controller = ProxySelectionMemoryRestorationController(
            dependencies: harness.dependencies(stageTimeout: 0.03)
        )
        var completions = [Bool]()
        controller.restore(records: [record("Selector", "A")]) { completions.append($0) }
        waitUntil("refresh timeout settled") { completions.count == 1 }

        harness.refreshCompletion?(snapshot())
        XCTAssertEqual(completions, [false])
        XCTAssertTrue(harness.selections.isEmpty)
    }

    func testSelectionTimeoutIgnoresLateSuccessAndStartsNoFurtherWrites() {
        let harness = Harness()
        let controller = ProxySelectionMemoryRestorationController(
            dependencies: harness.dependencies(stageTimeout: 0.03)
        )
        var completions = [Bool]()
        controller.restore(records: [record("Selector", "A"), record("OtherSelector", "B")]) {
            completions.append($0)
        }
        harness.refreshCompletion?(snapshot())
        waitUntil("selection request started") { harness.selections.count == 1 }
        waitUntil("selection timeout settled") { completions.count == 1 }

        harness.selectionCompletions[0](true)
        XCTAssertEqual(completions, [false])
        XCTAssertEqual(harness.selections.count, 1)
    }

    private func record(_ group: String, _ name: String) -> ProxySelectionMemoryRestorationController.Record {
        ProxySelectionMemoryRestorationController.Record(group: group, name: name)
    }

    private func snapshot(
        selectorType: String = "Selector",
        selectorMembers: [String] = ["A", "B"],
        otherMembers: [String] = ["B"]
    ) -> ClashProxyResp {
        let proxies: [String: Any] = [
            "Selector": ["name": "Selector", "type": selectorType, "all": selectorMembers, "now": "A", "history": []],
            "OtherSelector": ["name": "OtherSelector", "type": "Selector", "all": otherMembers, "now": "B", "history": []],
            "URLTest": ["name": "URLTest", "type": "URLTest", "all": ["A", "B"], "now": "A", "fixed": "B", "history": []],
            "Fallback": ["name": "Fallback", "type": "Fallback", "all": ["A", "B"], "now": "A", "fixed": "B", "history": []],
            "LoadBalance": ["name": "LoadBalance", "type": "LoadBalance", "all": ["A"], "history": []],
            "Relay": ["name": "Relay", "type": "Relay", "all": ["A"], "history": []],
            "CompatSelector": ["name": "CompatSelector", "type": "Selector", "all": ["COMPATIBLE"], "now": "COMPATIBLE", "history": []],
            "A": ["name": "A", "type": "Shadowsocks", "history": []],
            "B": ["name": "B", "type": "Vless", "history": []],
            "COMPATIBLE": ["name": "COMPATIBLE", "type": "Compatible", "history": []]
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["proxies": proxies])
        return ClashProxyResp(data)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) {
        let expectation = expectation(description: description)
        func poll() {
            if condition() {
                expectation.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: poll)
            }
        }
        poll()
        wait(for: [expectation], timeout: timeout)
    }
}

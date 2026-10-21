import Foundation
import XCTest

final class AutomaticRecoverySelectionTests: XCTestCase {
    static let allTests: [(String, (AutomaticRecoverySelectionTests) -> () throws -> Void)] = [
        ("testSavedNodeOverridesFreshFirstDirectFallback", testSavedNodeOverridesFreshFirstDirectFallback),
        ("testInvalidSavedTargetThrowsInsteadOfUsingFreshFallback", testInvalidSavedTargetThrowsInsteadOfUsingFreshFallback),
        ("testUnavailableSnapshotUsesOnlyCompleteExpectedCheckpoint", testUnavailableSnapshotUsesOnlyCompleteExpectedCheckpoint),
        ("testUnavailableSnapshotRejectsIncompleteCheckpoint", testUnavailableSnapshotRejectsIncompleteCheckpoint),
        ("testUnavailableSnapshotAllowsPureConfigurationWithoutSelectors", testUnavailableSnapshotAllowsPureConfigurationWithoutSelectors),
        ("testFreshSnapshotAllowsPureConfigurationWithoutSelectors", testFreshSnapshotAllowsPureConfigurationWithoutSelectors),
        ("testExplicitDirectChoiceIsPreservedAgainstSavedAlternative", testExplicitDirectChoiceIsPreservedAgainstSavedAlternative),
        ("testAutomaticGroupsAreExcludedAndNestedTargetRemainsValid", testAutomaticGroupsAreExcludedAndNestedTargetRemainsValid),
        ("testMissingExpectedSelectorThrows", testMissingExpectedSelectorThrows),
        ("testGlobalSelectorIsCapturedAndCanBeRequired", testGlobalSelectorIsCapturedAndCanBeRequired),
        ("testMalformedAndIncompleteSnapshotsThrow", testMalformedAndIncompleteSnapshotsThrow),
        ("testCompatibleCandidateIsRejected", testCompatibleCandidateIsRejected),
        ("testUnusedCompatibleCandidateDoesNotInvalidateSelectedNode", testUnusedCompatibleCandidateDoesNotInvalidateSelectedNode),
        ("testChineseDirectAliasIsRecognizedAsInitialFallback", testChineseDirectAliasIsRecognizedAsInitialFallback),
        ("testNestedSelectorPathToDirectIsRecognizedAsInitialFallback", testNestedSelectorPathToDirectIsRecognizedAsInitialFallback),
        ("testDirectResolutionStopsOnCycles", testDirectResolutionStopsOnCycles),
        ("testFreshCheckpointIncludesAllActualSelectors", testFreshCheckpointIncludesAllActualSelectors),
        ("testFreshNonFallbackSelectionSurvivesRemovedSavedNode", testFreshNonFallbackSelectionSurvivesRemovedSavedNode),
        ("testFreshFirstProxyNodeSurvivesRemovedSavedNode", testFreshFirstProxyNodeSurvivesRemovedSavedNode),
        ("testAutomaticDirectResultDoesNotBecomeManualFallback", testAutomaticDirectResultDoesNotBecomeManualFallback)
    ]

    func testSavedNodeOverridesFreshFirstDirectFallback() throws {
        let snapshot = makeSnapshot([
            selector("Proxy", now: "DIRECT", all: ["DIRECT", "Node"]),
            proxy("DIRECT", type: "Direct"),
            proxy("Node", type: "Shadowsocks")
        ])

        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: ["Proxy": "Node"],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        )

        XCTAssertEqual(result, ["Proxy": "Node"])
    }

    func testInvalidSavedTargetThrowsInsteadOfUsingFreshFallback() {
        let secretLikeTarget = "https://proxy.example/private-token"
        let snapshot = makeSnapshot([
            selector("Proxy", now: "DIRECT", all: ["DIRECT", "Node"]),
            proxy("DIRECT", type: "Direct"),
            proxy("Node", type: "Shadowsocks")
        ])

        XCTAssertThrowsError(try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: ["Proxy": secretLikeTarget],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        )) { error in
            XCTAssertFalse(error.localizedDescription.contains(secretLikeTarget))
            XCTAssertFalse(error.localizedDescription.contains("Proxy"))
        }
    }

    func testUnavailableSnapshotUsesOnlyCompleteExpectedCheckpoint() throws {
        let saved = [
            "Proxy": "Node",
            "GLOBAL": "DIRECT",
            "RemovedSelector": "OldNode",
            "OtherProfileSelector": "OtherNode"
        ]

        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: nil,
            saved: saved,
            expectedSelectors: ["Proxy"],
            requireGlobal: true
        )

        XCTAssertEqual(result, ["Proxy": "Node", "GLOBAL": "DIRECT"])
    }

    func testUnavailableSnapshotRejectsIncompleteCheckpoint() {
        XCTAssertThrowsError(try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: nil,
            saved: ["Proxy": "Node", "OldSelector": "OldNode"],
            expectedSelectors: ["Proxy", "OtherSelector"],
            requireGlobal: true
        ))
    }

    func testUnavailableSnapshotAllowsPureConfigurationWithoutSelectors() throws {
        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: nil,
            saved: ["StaleSelector": "StaleNode"],
            expectedSelectors: [],
            requireGlobal: false
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testFreshSnapshotAllowsPureConfigurationWithoutSelectors() throws {
        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: makeSnapshot([proxy("Node", type: "Shadowsocks")]),
            saved: [:],
            expectedSelectors: [],
            requireGlobal: false
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testExplicitDirectChoiceIsPreservedAgainstSavedAlternative() throws {
        let snapshot = makeSnapshot([
            selector("Proxy", now: "DIRECT", all: ["Node", "DIRECT"]),
            proxy("DIRECT", type: "Direct"),
            proxy("Node", type: "Shadowsocks")
        ])

        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: ["Proxy": "Node"],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        )

        XCTAssertEqual(result, ["Proxy": "DIRECT"])
    }

    func testAutomaticGroupsAreExcludedAndNestedTargetRemainsValid() throws {
        let snapshot = makeSnapshot([
            selector("Proxy", now: "Auto", all: ["DIRECT", "Auto"]),
            proxy("DIRECT", type: "Direct"),
            group("Auto", type: "URLTest", now: "Node", all: ["Node"]),
            proxy("Node", type: "Shadowsocks")
        ])

        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: ["Proxy": "DIRECT", "Auto": "Node"],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        )

        XCTAssertEqual(result, ["Proxy": "Auto"])
        XCTAssertNil(result["Auto"])
    }

    func testMissingExpectedSelectorThrows() {
        let snapshot = makeSnapshot([
            proxy("DIRECT", type: "Direct")
        ])

        XCTAssertThrowsError(try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: ["Proxy": "Node"],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        ))
    }

    func testGlobalSelectorIsCapturedAndCanBeRequired() throws {
        let snapshot = makeSnapshot([
            selector("Proxy", now: "Node", all: ["Node"]),
            selector("GLOBAL", now: "Proxy", all: ["DIRECT", "Proxy"]),
            proxy("DIRECT", type: "Direct"),
            proxy("Node", type: "Shadowsocks")
        ])

        let captured = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: [:],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        )
        XCTAssertEqual(captured, ["Proxy": "Node", "GLOBAL": "Proxy"])

        XCTAssertThrowsError(try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: makeSnapshot([selector("Proxy", now: "Node", all: ["Node"]), proxy("Node", type: "Shadowsocks")]),
            saved: [:],
            expectedSelectors: ["Proxy"],
            requireGlobal: true
        ))
    }

    func testMalformedAndIncompleteSnapshotsThrow() {
        XCTAssertThrowsError(try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: Data("not-json".utf8),
            saved: [:],
            expectedSelectors: [],
            requireGlobal: false
        ))

        let incompleteSelector = makeSnapshot([
            ["name": "Proxy", "type": "Selector", "now": "DIRECT"],
            proxy("DIRECT", type: "Direct")
        ])
        XCTAssertThrowsError(try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: incompleteSelector,
            saved: [:],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        ))

        let missingCandidate = makeSnapshot([
            selector("Proxy", now: "Missing", all: ["Missing"])
        ])
        XCTAssertThrowsError(try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: missingCandidate,
            saved: [:],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        ))
    }

    func testCompatibleCandidateIsRejected() {
        let snapshot = makeSnapshot([
            selector("Proxy", now: "COMPATIBLE", all: ["COMPATIBLE", "Node"]),
            proxy("COMPATIBLE", type: "Compatible"),
            proxy("Node", type: "Shadowsocks")
        ])

        XCTAssertThrowsError(try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: ["Proxy": "COMPATIBLE"],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        ))
    }

    func testUnusedCompatibleCandidateDoesNotInvalidateSelectedNode() throws {
        let snapshot = makeSnapshot([
            selector("Proxy", now: "Node", all: ["Node", "COMPATIBLE"]),
            proxy("COMPATIBLE", type: "Compatible"),
            proxy("Node", type: "Shadowsocks")
        ])

        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: [:],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        )

        XCTAssertEqual(result, ["Proxy": "Node"])
    }

    func testChineseDirectAliasIsRecognizedAsInitialFallback() throws {
        let bypassAlias = "🎯 绕过代理"
        let snapshot = makeSnapshot([
            selector("Proxy", now: bypassAlias, all: [bypassAlias, "Node"]),
            proxy(bypassAlias, type: "Direct"),
            proxy("Node", type: "Shadowsocks")
        ])

        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: ["Proxy": "Node"],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        )

        XCTAssertEqual(result, ["Proxy": "Node"])
    }

    func testNestedSelectorPathToDirectIsRecognizedAsInitialFallback() throws {
        let bypassAlias = "🎯 绕过代理"
        let snapshot = makeSnapshot([
            selector("Proxy", now: bypassAlias, all: [bypassAlias, "Node"]),
            selector(bypassAlias, now: "DIRECT", all: ["DIRECT"]),
            proxy("DIRECT", type: "Direct"),
            proxy("Node", type: "Shadowsocks")
        ])

        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: ["Proxy": "Node"],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        )

        XCTAssertEqual(result, ["Proxy": "Node", bypassAlias: "DIRECT"])
    }

    func testDirectResolutionStopsOnCycles() throws {
        let snapshot = makeSnapshot([
            selector("Proxy", now: "First", all: ["First", "Node"]),
            selector("First", now: "Second", all: ["Second"]),
            group("Second", type: "URLTest", now: "First", all: ["First"]),
            proxy("Node", type: "Shadowsocks")
        ])

        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot,
            saved: ["Proxy": "Node"],
            expectedSelectors: ["Proxy"],
            requireGlobal: false
        )

        XCTAssertEqual(result["Proxy"], "First", "A cyclic first candidate must not be treated as DIRECT")
    }

    func testFreshCheckpointIncludesAllActualSelectors() throws {
        var entries = [[String: Any]]()
        var saved = [String: String]()
        for index in 0 ..< 100 {
            let name = "Selector\(index)"
            let node = "Node\(index)"
            entries.append(selector(name, now: node, all: [node]))
            entries.append(proxy(node, type: "Shadowsocks"))
            saved[name] = node
            saved["Stale\(index)"] = "OldNode\(index)"
        }

        let expected: Set = ["Selector17", "Selector83"]
        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: makeSnapshot(entries),
            saved: saved,
            expectedSelectors: expected,
            requireGlobal: false
        )

        XCTAssertEqual(result.count, 100)
        XCTAssertEqual(result["Selector17"], "Node17")
        XCTAssertEqual(result["Selector83"], "Node83")
        XCTAssertNil(result["Stale17"])
    }

    func testFreshNonFallbackSelectionSurvivesRemovedSavedNode() throws {
        let snapshot = makeSnapshot([
            selector("Proxy", now: "Node", all: ["DIRECT", "Node"]),
            proxy("DIRECT", type: "Direct"), proxy("Node", type: "Shadowsocks")
        ])
        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot, saved: ["Proxy": "RemovedNode"],
            expectedSelectors: ["Proxy"], requireGlobal: false
        )
        XCTAssertEqual(result["Proxy"], "Node")
    }

    func testFreshFirstProxyNodeSurvivesRemovedSavedNode() throws {
        let snapshot = makeSnapshot([
            selector("Proxy", now: "Node", all: ["Node", "DIRECT"]),
            proxy("DIRECT", type: "Direct"), proxy("Node", type: "Shadowsocks")
        ])
        let result = try AutomaticRecoverySelectionPolicy.checkpoint(
            snapshotData: snapshot, saved: ["Proxy": "RemovedNode"],
            expectedSelectors: ["Proxy"], requireGlobal: false
        )
        XCTAssertEqual(result["Proxy"], "Node")
    }

    func testAutomaticDirectResultDoesNotBecomeManualFallback() throws {
        for type in ["URLTest", "Fallback", "LoadBalance"] {
            let snapshot = makeSnapshot([
                selector("Proxy", now: "Auto", all: ["Auto", "Node"]),
                group("Auto", type: type, now: "DIRECT", all: ["DIRECT", "Node"]),
                proxy("DIRECT", type: "Direct"), proxy("Node", type: "Shadowsocks")
            ])
            for saved in ["Node", "RemovedNode"] {
                let result = try AutomaticRecoverySelectionPolicy.checkpoint(
                    snapshotData: snapshot, saved: ["Proxy": saved],
                    expectedSelectors: ["Proxy"], requireGlobal: false
                )
                XCTAssertEqual(result["Proxy"], "Auto")
                XCTAssertNil(result["Auto"])
            }
        }
    }

    private func makeSnapshot(_ entries: [[String: Any]]) -> Data {
        let proxies = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, [String: Any])? in
            guard let name = entry["name"] as? String else { return nil }
            return (name, entry)
        })
        return try! JSONSerialization.data(withJSONObject: ["proxies": proxies])
    }

    private func selector(_ name: String, now: String, all: [String]) -> [String: Any] {
        ["name": name, "type": "Selector", "now": now, "all": all]
    }

    private func group(_ name: String, type: String, now: String, all: [String]) -> [String: Any] {
        ["name": name, "type": type, "now": now, "all": all]
    }

    private func proxy(_ name: String, type: String) -> [String: Any] {
        ["name": name, "type": type]
    }
}

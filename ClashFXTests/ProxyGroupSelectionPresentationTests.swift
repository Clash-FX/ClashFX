import AppKit
import XCTest

final class ProxyGroupSelectionPresentationTests: XCTestCase {
    private let benchmarkURL = "https://benchmark.example.test"
    private var previousMeasurementEpoch: Date?
    private var previousDisplayPreference = false

    override func setUp() {
        super.setUp()
        previousDisplayPreference = Settings.showFinalProxyNodeInMenu
        Settings.showFinalProxyNodeInMenu = false
        previousMeasurementEpoch = BenchmarkMeasurementEpoch.invalidate(at: .distantPast)
        AutomaticGroupBenchmarkPresentationStore.clearAll()
        GlobalLeafBenchmarkPresentationStore.clearAll()
    }

    override func tearDown() {
        if let previousMeasurementEpoch {
            _ = BenchmarkMeasurementEpoch.invalidate(at: previousMeasurementEpoch)
        }
        Settings.showFinalProxyNodeInMenu = previousDisplayPreference
        super.tearDown()
    }

    func testManualSelectorShowsSelectedGroupByDefaultWithoutModeLabel() throws {
        let snapshot = try makeSnapshot()
        let view = try makeView(snapshot: snapshot, groupName: "Selector")
        let label = try selectionLabel(in: view)

        XCTAssertEqual(label.stringValue, "Automatic")
        XCTAssertEqual(label.toolTip, formatted("Actual route: %@", "Selector → Automatic → Hong Kong"))
        XCTAssertEqual(accessibilityHelp(of: label), label.toolTip)
        XCTAssertNil(view.toolTip)
    }

    func testDisplayPreferenceUpdatesExistingMenuAndKeepsRouteHelp() throws {
        let snapshot = try makeSnapshot()
        let view = try makeView(snapshot: snapshot, groupName: "Selector")
        let label = try selectionLabel(in: view)
        let route = formatted("Actual route: %@", "Selector → Automatic → Hong Kong")

        Settings.showFinalProxyNodeInMenu = true
        XCTAssertEqual(label.stringValue, "Hong Kong")
        XCTAssertEqual(label.accessibilityLabel(), "Hong Kong")
        XCTAssertEqual(label.toolTip, route)

        let after = try makeSnapshot(automaticCurrent: "Japan")
        NotificationCenter.default.post(name: .proxyUpdate(for: "Selector"), object: after.proxiesMap["Selector"])
        XCTAssertEqual(label.stringValue, "Japan")

        Settings.showFinalProxyNodeInMenu = false
        XCTAssertEqual(label.stringValue, "Automatic")
        XCTAssertEqual(label.toolTip, formatted("Actual route: %@", "Selector → Automatic → Japan"))
    }

    func testKnownSelectedGroupRemainsVisibleWhenFinalRouteIsUnavailable() throws {
        let snapshot = try makeSnapshot(automaticCurrent: "Missing")
        let view = try makeView(snapshot: snapshot, groupName: "Selector")
        let label = try selectionLabel(in: view)
        XCTAssertEqual(label.stringValue, "Automatic")
        XCTAssertTrue(label.toolTip?.contains(localized("Actual route could not be fully resolved")) == true)

        Settings.showFinalProxyNodeInMenu = true
        XCTAssertEqual(label.stringValue, "")
        XCTAssertEqual(view.delayLabel.stringValue, "")
    }

    func testNestedAutomaticGroupUsesCoreNowInBothDisplayModes() throws {
        let snapshot = try decode([
            "Parent": ["name": "Parent", "type": "URLTest", "all": ["Child", "Japan"], "now": "Child", "fixed": "Japan", "history": []],
            "Child": ["name": "Child", "type": "Selector", "all": ["Japan"], "now": "Japan", "history": []],
            "Japan": ["name": "Japan", "type": "Trojan", "history": []]
        ])
        let view = try makeView(snapshot: snapshot, groupName: "Parent")
        let label = try selectionLabel(in: view)
        XCTAssertEqual(label.stringValue, selectionTitle("Manual Priority", leaf: "Child"))
        Settings.showFinalProxyNodeInMenu = true
        XCTAssertEqual(label.stringValue, selectionTitle("Manual Priority", leaf: "Japan"))
        XCTAssertTrue(label.toolTip?.contains(formatted("Actual route: %@", "Parent → Child → Japan")) == true)
    }

    func testManualSelectorCandidateDoesNotShowManualSelectionTooltip() throws {
        let snapshot = try makeSnapshot()
        let selector = try XCTUnwrap(snapshot.proxiesMap["Selector"])
        let candidate = try XCTUnwrap(snapshot.proxiesMap["Japan"])
        let item = ProxyMenuItem(proxy: candidate, group: selector, action: nil)
        let manualHint = NSLocalizedString("Manual Selection", comment: "")

        item.selectionHelp = manualHint

        XCTAssertEqual(item.selectionHelp, manualHint)
        XCTAssertNil(item.toolTip)
        XCTAssertNil(item.view?.toolTip)

        NotificationCenter.default.post(name: .proxyUpdate(for: "Selector"), object: selector)

        XCTAssertEqual(item.selectionHelp, manualHint)
        XCTAssertNil(item.toolTip)
        XCTAssertNil(item.view?.toolTip)
    }

    func testManualPriorityShowsPreferredNodeAndCurrentRouteSeparately() throws {
        let snapshot = try makeSnapshot(preferred: "Japan")
        let view = try makeView(snapshot: snapshot, groupName: "Automatic")
        let label = try selectionLabel(in: view)
        let tooltip = try XCTUnwrap(label.toolTip)

        XCTAssertEqual(label.stringValue, selectionTitle("Manual Priority", leaf: "Hong Kong"))
        XCTAssertTrue(tooltip.contains(formatted("Actual route: %@", "Automatic → Hong Kong")))
        XCTAssertTrue(tooltip.contains(formatted("Preferred node: %@", "Japan")))
        XCTAssertFalse(label.stringValue.contains("Japan"))
        XCTAssertEqual(accessibilityHelp(of: label), tooltip)
    }

    func testEmptyFixedRestoresAutomaticSelectionPresentation() throws {
        let snapshot = try makeSnapshot()
        let view = try makeView(snapshot: snapshot, groupName: "Automatic")
        let label = try selectionLabel(in: view)

        XCTAssertEqual(label.stringValue, selectionTitle("Automatic Selection", leaf: "Hong Kong"))
        XCTAssertEqual(label.toolTip, formatted("Actual route: %@", "Automatic → Hong Kong"))
    }

    func testLegacyCoreDoesNotInventLeafFromMissingNowOrPreferredTarget() throws {
        let snapshot = try makeSnapshot(automaticCurrent: "Missing", includesFixed: false)
        let view = try makeView(snapshot: snapshot, groupName: "Automatic")
        let label = try selectionLabel(in: view)
        let tooltip = try XCTUnwrap(label.toolTip)

        XCTAssertEqual(label.stringValue, selectionTitle("Core-managed Selection"))
        XCTAssertFalse(label.stringValue.contains("Missing"))
        XCTAssertFalse(tooltip.contains(localized("Preferred node: %@")))
        XCTAssertTrue(tooltip.contains(localized("Actual route could not be fully resolved")))
    }

    func testLegacyCoreShowsResolvedNowWithoutClaimingSelectionMode() throws {
        let snapshot = try makeSnapshot(includesFixed: false)
        let view = try makeView(snapshot: snapshot, groupName: "Automatic")
        let label = try selectionLabel(in: view)

        XCTAssertEqual(label.stringValue, selectionTitle("Core-managed Selection", leaf: "Hong Kong"))
        XCTAssertEqual(label.toolTip, formatted("Actual route: %@", "Automatic → Hong Kong"))
    }

    func testKnownPriorityRemainsAvailableWhenCurrentRouteCannotResolve() throws {
        let snapshot = try makeSnapshot(preferred: "Japan", automaticCurrent: "Missing")
        let view = try makeView(snapshot: snapshot, groupName: "Automatic")
        let label = try selectionLabel(in: view)
        let tooltip = try XCTUnwrap(label.toolTip)

        XCTAssertEqual(label.stringValue, selectionTitle("Manual Priority"))
        XCTAssertFalse(label.stringValue.contains("Japan"))
        XCTAssertFalse(label.stringValue.contains("Missing"))
        XCTAssertTrue(tooltip.contains(formatted("Preferred node: %@", "Japan")))
        XCTAssertTrue(tooltip.contains(localized("Actual route could not be fully resolved")))
    }

    func testNestedLeafChangeRefreshesParentRouteWhenParentNowIsUnchanged() throws {
        let before = try makeSnapshot()
        let view = try makeView(snapshot: before, groupName: "Selector")
        let originalParent = try XCTUnwrap(before.proxiesMap["Selector"])
        let originalLabel = try selectionLabel(in: view)
        XCTAssertEqual(originalParent.now, "Automatic")
        XCTAssertEqual(originalLabel.stringValue, "Automatic")
        XCTAssertEqual(originalLabel.toolTip, formatted("Actual route: %@", "Selector → Automatic → Hong Kong"))

        let after = try makeSnapshot(automaticCurrent: "Japan")
        let updatedParent = try XCTUnwrap(after.proxiesMap["Selector"])
        XCTAssertEqual(updatedParent.now, originalParent.now)
        NotificationCenter.default.post(name: .proxyUpdate(for: "Selector"), object: updatedParent)

        XCTAssertEqual(originalLabel.stringValue, "Automatic")
        XCTAssertEqual(originalLabel.toolTip, formatted("Actual route: %@", "Selector → Automatic → Japan"))
        XCTAssertEqual(accessibilityHelp(of: originalLabel), originalLabel.toolTip)
    }

    func testBenchmarkRenderingKeepsCurrentRouteAndDoesNotReuseOldLeafResult() throws {
        let snapshot = try makeSnapshot()
        let group = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        let view = try makeView(snapshot: snapshot, groupName: "Automatic")
        let staleRouteResult = AutomaticGroupBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(group: group, fallbackBenchmarkURL: benchmarkURL),
            selectedPath: ["Automatic", "Japan"],
            finalLeaf: "Japan",
            finalLeafID: snapshot.proxiesMap["Japan"]?.id,
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Japan", delay: 17)
        )

        NotificationCenter.default.post(name: .proxyUpdate(for: "Automatic"), object: staleRouteResult)

        let label = try selectionLabel(in: view)
        XCTAssertEqual(label.stringValue, selectionTitle("Automatic Selection", leaf: "Hong Kong"))
        XCTAssertEqual(label.toolTip, formatted("Actual route: %@", "Automatic → Hong Kong"))
        XCTAssertFalse(view.delayLabel.stringValue.contains("17 ms"))
        XCTAssertNil(view.toolTip)
        XCTAssertTrue(view.delayLabel.toolTip == nil || view.delayLabel.toolTip?.contains(benchmarkURL) == true)
    }

    func testHistoricalBenchmarkMarkerAndCompatibilityFallbackRemainVisible() throws {
        let snapshot = try makeSnapshot()
        let group = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        let view = try makeView(snapshot: snapshot, groupName: "Automatic")
        let historicalResult = AutomaticGroupBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(group: group, fallbackBenchmarkURL: benchmarkURL),
            selectedPath: ["Automatic", "Hong Kong"],
            finalLeaf: "Hong Kong",
            finalLeafID: snapshot.proxiesMap["Hong Kong"]?.id,
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Hong Kong", delay: 84),
            publishedAt: Date(timeIntervalSinceNow: -(31 * 60))
        )
        NotificationCenter.default.post(name: .proxyUpdate(for: "Automatic"), object: historicalResult)

        XCTAssertEqual(try selectionLabel(in: view).stringValue, selectionTitle("Automatic Selection", leaf: "Hong Kong"))
        XCTAssertEqual(
            view.delayLabel.stringValue,
            String(format: NSLocalizedString("Benchmark result with historical marker", value: "%@ · old", comment: ""), "84 ms")
        )
        XCTAssertNil(view.toolTip)
        XCTAssertNotNil(view.delayLabel.toolTip)

        let compatible = try makeCompatibilityFallbackSnapshot()
        let fallbackView = try makeView(snapshot: compatible, groupName: "Automatic")
        XCTAssertEqual(fallbackViewSelectionText(fallbackView), NSLocalizedString("Direct fallback (no proxy nodes)", comment: ""))
        XCTAssertEqual(fallbackView.delayLabel.stringValue, "")
    }

    func testLoadBalanceAndRelayKeepTheirLegacySelectionText() throws {
        for type in ["LoadBalance", "Relay"] {
            let snapshot = try makeSnapshot(automaticType: type)
            let view = try makeView(snapshot: snapshot, groupName: "Automatic")
            let legacyLabel = textFields(in: view.effectView).first(where: { $0.stringValue == "Hong Kong" })

            XCTAssertNotNil(legacyLabel, "Expected existing selection display for \(type)")
            XCTAssertNil(legacyLabel?.toolTip)
        }
    }

    private func makeSnapshot(preferred: String? = nil,
                              automaticCurrent: String = "Hong Kong",
                              includesFixed: Bool = true,
                              automaticType: String = "URLTest") throws -> ClashProxyResp {
        var automatic: [String: Any] = [
            "name": "Automatic",
            "type": automaticType,
            "all": ["Japan", "Hong Kong"],
            "now": automaticCurrent,
            "testUrl": benchmarkURL,
            "history": []
        ]
        if includesFixed {
            automatic["fixed"] = preferred ?? ""
        }
        let proxies: [String: Any] = [
            "Selector": ["name": "Selector", "type": "Selector", "all": ["Automatic", "Japan"], "now": "Automatic", "history": []],
            "Automatic": automatic,
            "Japan": ["name": "Japan", "id": "japan-v1", "type": "Trojan", "history": []],
            "Hong Kong": ["name": "Hong Kong", "id": "hong-kong-v1", "type": "Vless", "history": []]
        ]
        return try decode(proxies)
    }

    private func makeCompatibilityFallbackSnapshot() throws -> ClashProxyResp {
        return try decode([
            "Automatic": ["name": "Automatic", "type": "URLTest", "all": ["COMPATIBLE"], "now": "COMPATIBLE", "history": []]
        ])
    }

    private func decode(_ proxies: [String: Any]) throws -> ClashProxyResp {
        return try ClashProxyResp(JSONSerialization.data(withJSONObject: ["proxies": proxies]))
    }

    private func makeView(snapshot: ClashProxyResp, groupName: String) throws -> ProxyGroupMenuItemView {
        let group = try XCTUnwrap(snapshot.proxiesMap[groupName])
        return ProxyGroupMenuItemView(proxyGroup: group, targetProxy: group.now ?? "", hasLeftPadding: false)
    }

    private func selectionLabel(in view: ProxyGroupMenuItemView) throws -> NSTextField {
        let fields = textFields(in: view.effectView)
        return try XCTUnwrap(fields.first(where: { $0.accessibilityLabel() != nil }))
    }

    private func fallbackViewSelectionText(_ view: ProxyGroupMenuItemView) -> String? {
        let title = NSLocalizedString("Direct fallback (no proxy nodes)", comment: "")
        return textFields(in: view.effectView).first(where: { $0.stringValue == title })?.stringValue
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        let ownField = (view as? NSTextField).map { [$0] } ?? []
        return ownField + view.subviews.flatMap(textFields(in:))
    }

    private func accessibilityHelp(of field: NSTextField) -> String? {
        return field.accessibilityHelp()
    }

    private func formatted(_ key: String, _ value: String) -> String {
        return String(format: localized(key), value)
    }

    private func localized(_ key: String) -> String {
        return NSLocalizedString(key, value: key, comment: "")
    }

    private func selectionTitle(_ mode: String, leaf: String? = nil) -> String {
        let shortValue: String
        switch mode {
        case "Manual Selection": shortValue = "Manual"
        case "Automatic Selection": shortValue = "Auto"
        case "Manual Priority": shortValue = "Priority"
        case "Core-managed Selection": shortValue = "Core choice"
        default: shortValue = mode
        }
        let title = NSLocalizedString(mode, value: shortValue, comment: "")
        return leaf.map { "\(title) · \($0)" } ?? title
    }
}

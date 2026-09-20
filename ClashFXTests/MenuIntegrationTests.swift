import Cocoa
import XCTest

/// Real NSMenu/NSView classes and their production action/notification code.
/// The process has no production AppDelegate, controller or helper linkage.
final class MenuIntegrationTests: XCTestCase {
    private let urlA = "https://test-a.invalid/204"
    private let urlB = "https://test-b.invalid/204"
    private var snapshot: ClashProxyResp!
    private var menus = [ProxyGroupMenu]()
    private var header: ProxyGroupMenuItemView?
    private var refreshes = 0

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Thread.isMainThread)
        _ = NSApplication.shared
        AppDelegate.shared.onFinish = nil
        AppDelegate.shared.cancel()
        Settings.benchMarkUrl = urlA
        MenuItemFactory.useViewToRenderProxy = true
        GlobalLeafBenchmarkPresentationStore.clearAll()
        SelectorBenchmarkPresentationStore.clearAll()
        AutomaticChildBenchmarkStore.clearAll()
        AutomaticGroupBenchmarkPresentationStore.clearAll()
        MihomoMenuURLProtocol.reset()
        MihomoMenuURLProtocol.topology = [
            "Selector": ["name": "Selector", "type": "Selector", "now": "Leaf-A", "all": ["Automatic", "Leaf-A", "Leaf-B"], "testUrl": urlA, "history": []],
            "Selector-B": ["name": "Selector-B", "type": "Selector", "now": "Leaf-A", "all": ["Leaf-A"], "testUrl": urlB, "history": []],
            "Automatic": ["name": "Automatic", "type": "URLTest", "now": "Leaf-A", "all": ["Leaf-A", "Leaf-B"], "testUrl": urlB, "history": []],
            "Leaf-A": ["name": "Leaf-A", "type": "Vless", "id": "leaf-a-id", "history": []],
            "Leaf-B": ["name": "Leaf-B", "type": "Trojan", "id": "leaf-b-id", "history": []]
        ]
        refresh()
        AppDelegate.shared.onFinish = { [weak self] in self?.requestRefresh {} }
    }

    override func tearDown() {
        AppDelegate.shared.onFinish = nil
        AppDelegate.shared.cancel()
        MihomoMenuURLProtocol.releaseHeld()
        menus.removeAll()
        header = nil
        snapshot = nil
        super.tearDown()
    }

    private func waitUntil(_ description: String, _ predicate: @escaping () -> Bool) {
        let done = expectation(description: description)
        var stopped = false
        func poll() {
            guard !stopped else { return }
            if predicate() { done.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
        wait(for: [done], timeout: 4)
        stopped = true
    }

    private func refresh() {
        let done = expectation(description: "fixture /proxies snapshot")
        requestRefresh { done.fulfill() }
        wait(for: [done], timeout: 4)
    }

    private func requestRefresh(completion: @escaping () -> Void) {
        refreshes += 1
        ApiRequest.getMergedProxyData(session: .init(), timeout: 2) { response in
            defer { self.refreshes -= 1; completion() }
            guard let response else { XCTFail("fixture snapshot unavailable"); return }
            let previous = self.snapshot
            self.snapshot = response
            GlobalLeafBenchmarkPresentationStore.prune(using: response)
            AutomaticChildBenchmarkStore.prune(using: response)
            AutomaticGroupBenchmarkPresentationStore.prune(using: response)
            SelectorBenchmarkPresentationStore.prune(using: response)
            if let previous {
                for name in ProxyMenuSnapshotDelta.affectedNames(previous: previous, current: response).sorted() {
                    NotificationCenter.default.post(name: .proxyUpdate(for: name), object: response.proxiesMap[name])
                }
            }
        }
    }

    private func menu(_ name: String = "Selector") -> ProxyGroupMenu {
        let group = snapshot.proxiesMap[name]!
        let source = snapshot!
        let result = ProxyGroupMenu(title: name) { menu in
            menu.addItem(ProxyGroupSpeedTestMenuItem(group: group))
            for member in group.all ?? [] {
                menu.addItem(ProxyMenuItem(proxy: source.proxiesMap[member]!, group: group, action: nil))
            }
        }
        result.menuWillOpen(result)
        menus.append(result)
        return result
    }

    private func row(_ menu: NSMenu, _ name: String) -> ProxyMenuItem {
        menu.items.compactMap { $0 as? ProxyMenuItem }.first { $0.proxyName == name }!
    }

    private func text(_ menu: NSMenu, _ name: String) -> String {
        let item = row(menu, name)
        return (item.view as? ProxyItemView)?.delayLabel.stringValue ?? item.attributedTitle?.string ?? item.title
    }

    private func selected(_ menu: NSMenu, _ name: String) -> Bool {
        let item = row(menu, name)
        return (item.view as? ProxyItemView).map { $0.imageView != nil } ?? (item.state == .on)
    }

    private func clickBenchmark(_ menu: NSMenu) {
        let item = menu.items[0] as! ProxyGroupSpeedTestMenuItem
        (item.view as! MenuItemBaseView).didClickView()
    }

    private func finish(_ menu: NSMenu) {
        waitUntil("benchmark completed") {
            AppDelegate.shared.active == nil && self.refreshes == 0
                && menu.items[0].title != NSLocalizedString("Testing", comment: "")
        }
    }

    private func configure(_ node: String, _ url: String, _ delay: Int) {
        MihomoMenuURLProtocol.replies[MihomoMenuURLProtocol.key(node, url)] = .init(body: ["delay": delay])
    }

    private func setNow(_ group: String, _ name: String) {
        var value = MihomoMenuURLProtocol.topology[group] as! [String: Any]
        value["now"] = name
        MihomoMenuURLProtocol.topology[group] = value
    }

    func testRefreshingDuringBenchmarkKeepsRealRowsAndUpdatesCheckmark() {
        let menu = menu()
        let identities = menu.items.map(ObjectIdentifier.init)
        configure("Leaf-A", urlA, 83)
        configure("Leaf-B", urlA, 107)
        MihomoMenuURLProtocol.hold = true
        clickBenchmark(menu)
        waitUntil("two deduplicated requests held") { MihomoMenuURLProtocol.held.count == 2 }
        XCTAssertEqual(text(menu, "Leaf-A"), NSLocalizedString("Testing", comment: ""))
        setNow("Selector", "Leaf-B")
        refresh()
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), identities)
        XCTAssertFalse(selected(menu, "Leaf-A"))
        XCTAssertTrue(selected(menu, "Leaf-B"))
        XCTAssertEqual(text(menu, "Leaf-A"), NSLocalizedString("Testing", comment: ""))
        MihomoMenuURLProtocol.hold = false
        MihomoMenuURLProtocol.releaseHeld()
        finish(menu)
        XCTAssertEqual(text(menu, "Leaf-A"), "83 ms")
        XCTAssertEqual(text(menu, "Automatic"), "83 ms")
        XCTAssertEqual(text(menu, "Leaf-B"), "107 ms")
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), identities)
        let view = row(menu, "Leaf-B").view as! ProxyItemView
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        view.layoutSubtreeIfNeeded()
        view.layout()
        XCTAssertGreaterThan(view.imageView!.frame.width, 0)
        XCTAssertLessThanOrEqual(view.nameLabel.frame.maxX, view.delayLabel.frame.minX)
    }

    func testCancelThenRestartRejectsOldHTTPResultsAndSettlesSpinner() {
        let menu = menu()
        configure("Leaf-A", urlA, 999)
        MihomoMenuURLProtocol.hold = true
        clickBenchmark(menu)
        waitUntil("old requests held") { MihomoMenuURLProtocol.held.count == 2 }
        AppDelegate.shared.cancel()
        XCTAssertNil(AppDelegate.shared.active)
        XCTAssertNotEqual(text(menu, "Leaf-A"), NSLocalizedString("Testing", comment: ""))
        XCTAssertEqual(menu.items[0].title, NSLocalizedString("Benchmark", comment: ""))
        MihomoMenuURLProtocol.hold = false
        configure("Leaf-A", urlA, 42)
        clickBenchmark(menu)
        finish(menu)
        XCTAssertEqual(text(menu, "Leaf-A"), "42 ms")
        let delivered = MihomoMenuURLProtocol.delivered
        MihomoMenuURLProtocol.releaseHeld()
        waitUntil("late fixture replies delivered") { MihomoMenuURLProtocol.delivered == delivered + 2 }
        // Drain the real menu callback/coalescer queue, including its 150ms flush.
        let drained = expectation(description: "late callbacks drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(text(menu, "Leaf-A"), "42 ms")
        XCTAssertEqual(menu.items[0].title, NSLocalizedString("Benchmark", comment: ""))
    }

    func testAutomaticRetestUsesFreshNowRatherThanLowestDisplayedDelay() {
        _ = menu() // Also exercise the nested automatic row's observers.
        let automatic = menu("Automatic")
        let group = snapshot.proxiesMap["Automatic"]!
        header = ProxyGroupMenuItemView(proxyGroup: group, targetProxy: "Leaf-A", hasLeftPadding: true)
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 20, "Leaf-B": 80])
        MihomoMenuURLProtocol.groupDidRespond = { [weak self] in self?.setNow("Automatic", "Leaf-B") }
        clickBenchmark(automatic)
        finish(automatic)
        XCTAssertFalse(selected(automatic, "Leaf-A"))
        XCTAssertTrue(selected(automatic, "Leaf-B"))
        XCTAssertEqual(text(automatic, "Leaf-B"), "80 ms")
        let labels = header!.effectView.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains { $0.contains("Leaf-B") }, "\(labels)")
        XCTAssertEqual(header!.delayLabel.stringValue, "80 ms")
        XCTAssertNil(header!.toolTip)
        XCTAssertTrue(header!.delayLabel.toolTip?.contains(urlB) == true)
        header!.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        header!.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(header!.delayLabel.frame.width, 0)
        XCTAssertLessThan(header!.delayLabel.frame.width, 100)
        let nodeLabel = header!.effectView.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains("Leaf-B") }!
        XCTAssertLessThanOrEqual(nodeLabel.frame.maxX, header!.delayLabel.frame.minX)
        let request = MihomoMenuURLProtocol.requests.first { $0.url!.path == "/group/Automatic/delay" }!
        XCTAssertTrue(request.url!.absoluteString.contains("test-b.invalid"))
    }

    func testHistorySurvivesReopenAndUnavailableHTTPDoesNotDeclareNodeDead() {
        let first = menu()
        let node = snapshot.proxiesMap["Leaf-A"]!
        GlobalLeafBenchmarkPresentationStore.publish(.init(identity: .init(proxy: node), benchmarkURL: urlA,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 90),
            publishedAt: Date(timeIntervalSinceNow: -48 * 3600)))
        XCTAssertEqual(text(first, "Leaf-A"), "90 ms *")
        refresh()
        let reopened = menu()
        XCTAssertEqual(text(reopened, "Leaf-A"), "90 ms *")
        MihomoMenuURLProtocol.replies[MihomoMenuURLProtocol.key("Leaf-A", urlA)] = .init(status: 401, body: ["message": "Unauthorized"])
        clickBenchmark(reopened)
        finish(reopened)
        XCTAssertEqual(text(reopened, "Leaf-A"), "90 ms *")
        XCTAssertNil(row(reopened, "Leaf-A").toolTip)
        XCTAssertTrue((row(reopened, "Leaf-A").view as! ProxyItemView).delayLabel.toolTip!.contains(NSLocalizedString("Latest benchmark unavailable; showing the last measurement", comment: "")))
        XCTAssertEqual(text(first, "Leaf-A"), text(reopened, "Leaf-A"))
    }

    func testBenchmarkTooltipOnlyOnDelayAndClearedDuringRetest() {
        let menu = menu()
        let item = row(menu, "Leaf-A")
        let view = item.view as! ProxyItemView
        XCTAssertNil(view.delayLabel.toolTip)
        configure("Leaf-A", urlA, 83)
        clickBenchmark(menu)
        finish(menu)
        XCTAssertNil(item.toolTip)
        XCTAssertNil(view.toolTip)
        XCTAssertNil(view.nameLabel.toolTip)
        XCTAssertTrue(view.delayLabel.toolTip?.contains(urlA) == true)
        XCTAssertTrue(view.delayLabel.toolTip?.contains("Measured at:") == true)

        MihomoMenuURLProtocol.hold = true
        clickBenchmark(menu)
        waitUntil("retest held") { !MihomoMenuURLProtocol.held.isEmpty }
        XCTAssertNil(view.delayLabel.toolTip)
        refresh()
        XCTAssertNil(view.delayLabel.toolTip)
        AppDelegate.shared.cancel()
        finish(menu)
        XCTAssertNil(item.toolTip)
        XCTAssertNotNil(view.delayLabel.toolTip)
        XCTAssertTrue(view.delayLabel.stringValue.contains("*"))
    }

    func testAutomaticHeaderTooltipClearsWhileTestingAndAfterEvidenceReset() {
        let automatic = menu("Automatic")
        let group = snapshot.proxiesMap["Automatic"]!
        header = ProxyGroupMenuItemView(proxyGroup: group, targetProxy: "Leaf-A", hasLeftPadding: true)
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 20, "Leaf-B": 80])
        clickBenchmark(automatic)
        finish(automatic)
        XCTAssertNotNil(header!.delayLabel.toolTip)
        XCTAssertNil(header!.toolTip)
        for label in header!.effectView.subviews.compactMap({ $0 as? NSTextField }) where label !== header!.delayLabel {
            XCTAssertNil(label.toolTip)
        }
        MihomoMenuURLProtocol.hold = true
        clickBenchmark(automatic)
        waitUntil("automatic retest held") { !MihomoMenuURLProtocol.held.isEmpty }
        XCTAssertNil(header!.delayLabel.toolTip)
        XCTAssertNil(header!.toolTip)
        MihomoMenuURLProtocol.hold = false
        MihomoMenuURLProtocol.releaseHeld()
        finish(automatic)
        XCTAssertNotNil(header!.delayLabel.toolTip)
        AutomaticGroupBenchmarkPresentationStore.clearAll()
        setNow("Automatic", "Leaf-B")
        refresh()
        XCTAssertNil(header!.delayLabel.toolTip)
        XCTAssertEqual(header!.delayLabel.stringValue, "")
    }

    func testTextOnlyMenuDoesNotRestoreWholeRowTooltip() {
        MenuItemFactory.useViewToRenderProxy = false
        defer { MenuItemFactory.useViewToRenderProxy = true }
        let menu = menu()
        configure("Leaf-A", urlA, 83)
        clickBenchmark(menu)
        finish(menu)
        XCTAssertNil(row(menu, "Leaf-A").view)
        XCTAssertNil(row(menu, "Leaf-A").toolTip)
        XCTAssertTrue(text(menu, "Leaf-A").contains("83 ms"))
    }

    func testDifferentURLsStayIsolatedDuringNotificationsAndReopen() {
        let first = menu()
        let second = menu("Selector-B")
        configure("Leaf-A", urlA, 90)
        configure("Leaf-A", urlB, 180)
        clickBenchmark(first)
        finish(first)
        clickBenchmark(second)
        finish(second)
        XCTAssertEqual(text(first, "Leaf-A"), "90 ms")
        XCTAssertEqual(text(second, "Leaf-A"), "180 ms")
        XCTAssertEqual(text(menu(), "Leaf-A"), "90 ms")
        XCTAssertEqual(text(menu("Selector-B"), "Leaf-A"), "180 ms")
    }

    func testAutomaticActionRefreshesItsSnapshotAfterAnotherGroupCompletes() {
        MihomoMenuURLProtocol.topology["Other-Auto"] = ["name": "Other-Auto", "type": "Fallback",
            "now": "Leaf-A", "all": ["Leaf-A"], "testUrl": urlA, "history": []]
        refresh()
        let first = menu("Automatic")
        let second = menu("Other-Auto")
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 75, "Leaf-B": 90])
        clickBenchmark(first)
        finish(first)

        // Real Mihomo updates history after the first action, replacing the
        // snapshot referenced by every visible row. The second action must
        // update too, rather than retain a group whose weak enclosingResp dies.
        var leaf = MihomoMenuURLProtocol.topology["Leaf-A"] as! [String: Any]
        leaf["history"] = [["time": "2026-09-19T12:00:00.000+0000", "delay": 75]]
        MihomoMenuURLProtocol.topology["Leaf-A"] = leaf
        refresh()
        let action = second.items[0] as! ProxyGroupSpeedTestMenuItem
        XCTAssertTrue(action.proxyGroup === snapshot.proxiesMap["Other-Auto"])
        XCTAssertNotNil(action.proxyGroup.enclosingResp)
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 140])
        clickBenchmark(second)
        finish(second)
        XCTAssertEqual(text(second, "Leaf-A"), "140 ms")
        XCTAssertEqual(text(first, "Leaf-A"), "75 ms")
    }

    private func actionSnapshot(id: String, groupType: String = "URLTest") -> ClashProxyResp {
        let data: [String: Any] = ["proxies": [
            "Lifetime-Group": ["name": "Lifetime-Group", "type": groupType,
                               "all": ["Lifetime-Leaf"], "now": "Lifetime-Leaf", "history": []],
            "Lifetime-Leaf": ["name": "Lifetime-Leaf", "type": "Vless", "id": id, "history": []]
        ]]
        return ClashProxyResp(try! JSONSerialization.data(withJSONObject: data))
    }

    func testBenchmarkActionOwnsReplacesAndReleasesItsSnapshot() {
        weak var firstSnapshot: ClashProxyResp?
        weak var secondSnapshot: ClashProxyResp?
        weak var releasedAction: ProxyGroupSpeedTestMenuItem?
        autoreleasepool {
            var action: ProxyGroupSpeedTestMenuItem?
            autoreleasepool {
                let source = actionSnapshot(id: "first")
                firstSnapshot = source
                action = ProxyGroupSpeedTestMenuItem(group: source.proxiesMap["Lifetime-Group"]!)
            }
            XCTAssertNotNil(firstSnapshot)
            XCTAssertTrue(action?.proxyGroup.enclosingResp === firstSnapshot)
            autoreleasepool {
                let next = actionSnapshot(id: "second")
                secondSnapshot = next
                NotificationCenter.default.post(name: .proxyUpdate(for: "Lifetime-Group"),
                                                object: next.proxiesMap["Lifetime-Group"])
            }
            XCTAssertNil(firstSnapshot, "Replaced topology must not be retained indefinitely")
            XCTAssertNotNil(secondSnapshot)
            XCTAssertTrue(action?.proxyGroup.enclosingResp === secondSnapshot)
            releasedAction = action
            action = nil
        }
        XCTAssertNil(releasedAction, "Notification registration must not retain a removed action")
        XCTAssertNil(secondSnapshot, "Removing the action must release its topology")
    }

    func testBenchmarkActionIgnoresProgressDetachedAndWrongTypeUpdates() {
        let original = actionSnapshot(id: "original")
        let group = original.proxiesMap["Lifetime-Group"]!
        let action = ProxyGroupSpeedTestMenuItem(group: group)
        AutomaticGroupBenchmarkPresentationStore.begin(group: group, sessionIdentifier: UUID())
        XCTAssertTrue(action.proxyGroup === group)

        var detached: ClashProxy?
        autoreleasepool {
            detached = actionSnapshot(id: "detached").proxiesMap["Lifetime-Group"]
        }
        XCTAssertNil(detached?.enclosingResp)
        NotificationCenter.default.post(name: .proxyUpdate(for: "Lifetime-Group"), object: detached)
        XCTAssertTrue(action.proxyGroup === group)

        let wrongType = actionSnapshot(id: "wrong", groupType: "Selector")
        NotificationCenter.default.post(name: .proxyUpdate(for: "Lifetime-Group"),
                                        object: wrongType.proxiesMap["Lifetime-Group"])
        XCTAssertTrue(action.proxyGroup === group)
        XCTAssertTrue(action.proxyGroup.enclosingResp === original)
    }

    func testGenuineProbeFailureReplacesPreviousSuccessInRealView() {
        let menu = menu()
        configure("Leaf-A", urlA, 90)
        clickBenchmark(menu)
        finish(menu)
        MihomoMenuURLProtocol.replies[MihomoMenuURLProtocol.key("Leaf-A", urlA)] = .init(status: 503, body: ["message": "An error occurred in the delay test"])
        clickBenchmark(menu)
        finish(menu)
        XCTAssertEqual(text(menu, "Leaf-A"), NSLocalizedString("fail", comment: ""))
        XCTAssertTrue(selected(menu, "Leaf-A")) // Selection is independent.
    }

    func testSameNameReplacementInvalidatesVisibleMeasurement() {
        let menu = menu()
        configure("Leaf-A", urlA, 90)
        clickBenchmark(menu)
        finish(menu)
        var leaf = MihomoMenuURLProtocol.topology["Leaf-A"] as! [String: Any]
        leaf["id"] = "replacement-id"
        MihomoMenuURLProtocol.topology["Leaf-A"] = leaf
        refresh()
        XCTAssertFalse(text(menu, "Leaf-A").contains("90"))
        XCTAssertTrue(selected(menu, "Leaf-A"))
    }

    func testNativeAttributedMenuPathAlsoUpdatesSelectionAndDelay() {
        MenuItemFactory.useViewToRenderProxy = false
        let menu = menu()
        configure("Leaf-A", urlA, 90)
        clickBenchmark(menu)
        finish(menu)
        XCTAssertNil(row(menu, "Leaf-A").view)
        XCTAssertTrue(text(menu, "Leaf-A").contains("90 ms"))
        setNow("Selector", "Leaf-B")
        refresh()
        XCTAssertEqual(row(menu, "Leaf-A").state, .off)
        XCTAssertEqual(row(menu, "Leaf-B").state, .on)
    }

    private func addCompatible() {
        MihomoMenuURLProtocol.topology["COMPATIBLE"] = [
            "name": "COMPATIBLE", "type": "Compatible", "id": "fallback-id", "alive": true,
            "history": [["time": "2026-09-19T12:00:00.000+0000", "delay": 532]],
            "extra": [urlA: ["alive": true, "history": [["time": "2026-09-19T12:00:00.000+0000", "delay": 532]]]]
        ]
    }

    func testEmptyRegionsIgnoreFallbackLatencyButExplicitDirectStillMeasures() {
        addCompatible()
        MihomoMenuURLProtocol.topology["DIRECT"] = ["name": "DIRECT", "type": "Direct", "id": "direct-id", "history": []]
        for name in ["Singapore", "Taiwan"] {
            MihomoMenuURLProtocol.topology[name] = ["name": name, "type": "URLTest", "all": ["COMPATIBLE"], "now": "COMPATIBLE", "testUrl": urlA, "history": []]
        }
        MihomoMenuURLProtocol.topology["Selector"] = ["name": "Selector", "type": "Selector", "all": ["Singapore", "Taiwan", "DIRECT", "Leaf-A"], "now": "Singapore", "testUrl": urlA, "history": []]
        refresh()
        let first = menu()
        let fallback = snapshot.proxiesMap["COMPATIBLE"]!
        GlobalLeafBenchmarkPresentationStore.publish(.init(identity: .init(proxy: fallback), benchmarkURL: urlA,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "COMPATIBLE", delay: 532)))
        configure("DIRECT", urlA, 31)
        configure("Leaf-A", urlA, 90)
        clickBenchmark(first)
        finish(first)
        for name in ["Singapore", "Taiwan"] {
            XCTAssertEqual(text(first, name), NSLocalizedString("Direct fallback (no proxy nodes)", comment: ""))
            XCTAssertEqual(text(menu(), name), text(first, name))
        }
        XCTAssertTrue(selected(first, "Singapore")) // The core's now is unchanged.
        XCTAssertEqual(text(first, "DIRECT"), "31 ms")
        XCTAssertEqual(text(first, "Leaf-A"), "90 ms")
        let measured = MihomoMenuURLProtocol.requests.compactMap { $0.url?.path }.filter { $0.hasSuffix("/delay") }
        XCTAssertEqual(Set(measured), ["/proxies/DIRECT/delay", "/proxies/Leaf-A/delay"])
    }

    func testExplicitRetestOfEmptyAutomaticGroupMakesNoDelayRequest() {
        addCompatible()
        MihomoMenuURLProtocol.topology["Automatic"] = ["name": "Automatic", "type": "URLTest", "all": ["COMPATIBLE"], "now": "COMPATIBLE", "testUrl": urlB, "history": []]
        refresh()
        let automatic = menu("Automatic")
        header = ProxyGroupMenuItemView(proxyGroup: snapshot.proxiesMap["Automatic"]!, targetProxy: "COMPATIBLE", hasLeftPadding: true)
        let before = MihomoMenuURLProtocol.requests.count
        clickBenchmark(automatic)
        XCTAssertNil(AppDelegate.shared.active)
        XCTAssertEqual(MihomoMenuURLProtocol.requests.count, before)
        XCTAssertEqual(automatic.items[0].title, NSLocalizedString("No testable proxy nodes", comment: ""))
        XCTAssertEqual(text(automatic, "COMPATIBLE"), NSLocalizedString("Direct fallback (no proxy nodes)", comment: ""))
        let labels = header!.effectView.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains(NSLocalizedString("Direct fallback (no proxy nodes)", comment: "")))
    }

    func testGroupBecomingEmptyCannotReusePreviousRealNodeMeasurement() {
        let first = menu()
        configure("Leaf-A", urlA, 90)
        clickBenchmark(first)
        finish(first)
        XCTAssertEqual(text(first, "Automatic"), "90 ms")
        addCompatible()
        MihomoMenuURLProtocol.topology["Automatic"] = ["name": "Automatic", "type": "URLTest", "all": ["COMPATIBLE"], "now": "COMPATIBLE", "testUrl": urlB, "history": []]
        refresh()
        XCTAssertEqual(text(first, "Automatic"), NSLocalizedString("Direct fallback (no proxy nodes)", comment: ""))
        XCTAssertEqual(text(menu(), "Automatic"), text(first, "Automatic"))
        XCTAssertEqual(text(first, "Leaf-A"), "90 ms")
    }
}

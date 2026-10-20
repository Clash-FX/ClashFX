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
        ProxyGroupSpeedTestMenuItem.clearBenchmarkCancellationFeedback()
        AppDelegate.shared.isEnhancedModeTransitionInProgress = false
        Settings.benchMarkUrl = urlA
        Settings.benchmarkMode = .complete
        Settings.benchmarkSortOrder = .configuration
        Settings.benchmarkMeasurementMethod = .followConfiguration
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
        AppDelegate.shared.isEnhancedModeTransitionInProgress = false
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
            let speedTestItem = ProxyGroupSpeedTestMenuItem(group: group)
            menu.addItem(speedTestItem)
            menu.addItem(speedTestItem.retryFailedNodesMenuItem)
            menu.addItem(.separator())
            menu.add(delegate: speedTestItem)
            for member in group.all ?? [] {
                menu.addItem(ProxyMenuItem(proxy: source.proxiesMap[member]!, group: group, action: nil))
            }
        }
        result.menuWillOpen(result)
        menus.append(result)
        return result
    }

    private func retryMenuItem(_ menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first {
            $0.title == NSLocalizedString("Retry failed nodes", comment: "")
        })
    }

    private func containsRemovedBenchmarkMenuStructure(_ menu: NSMenu) -> Bool {
        menu.items.contains { item in
            item.title == NSLocalizedString("Benchmark options", comment: "")
                || item.title == NSLocalizedString("Display Order", comment: "Proxy menu row-order submenu")
                || item.representedObject as? String == "ClashFX.ProxyGroupMenu.DisplayOrder"
                || item.submenu.map(containsRemovedBenchmarkMenuStructure) == true
        }
    }

    private func delayRequests(for proxy: String) -> [URLRequest] {
        MihomoMenuURLProtocol.requests.filter { request in
            request.url?.pathComponents.contains(proxy) == true
                && request.url?.path.hasSuffix("/delay") == true
        }
    }

    private func timeoutMilliseconds(for request: URLRequest) -> Int? {
        guard let url = request.url else { return nil }
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "timeout" })?.value else { return nil }
        return Int(value)
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

    private func sortableProxyNames(_ menu: NSMenu) -> [String] {
        menu.items.compactMap { $0 as? ProxyMenuItem }
            .filter(\.isSortableProxyRow)
            .map(\.proxyName)
    }

    private func clickBenchmark(_ menu: NSMenu) {
        let item = menu.items[0] as! ProxyGroupSpeedTestMenuItem
        (item.view as! MenuItemBaseView).didClickView()
    }

    private func speedTestText(_ item: ProxyGroupSpeedTestMenuItem) -> String {
        item.view?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first ?? item.title
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

    func testBenchmarkModeSelectionUsesGlobalSettingsWithoutMenuOptions() throws {
        Settings.benchmarkMode = .quick
        let menu = menu()
        let action = try XCTUnwrap(menu.items.first as? ProxyGroupSpeedTestMenuItem)
        XCTAssertEqual(Settings.benchmarkMode, .quick)
        XCTAssertTrue(action.submenu == nil)
        XCTAssertFalse(containsRemovedBenchmarkMenuStructure(menu))
        let automatic = self.menu("Automatic")
        XCTAssertFalse(containsRemovedBenchmarkMenuStructure(automatic))
        XCTAssertTrue(try retryMenuItem(automatic).isHidden)
        configure("Leaf-A", urlA, 61)
        configure("Leaf-B", urlA, 92)

        clickBenchmark(menu)
        finish(menu)
        XCTAssertEqual(delayRequests(for: "Leaf-A").map { timeoutMilliseconds(for: $0) }, [2500])
        XCTAssertEqual(delayRequests(for: "Leaf-B").map { timeoutMilliseconds(for: $0) }, [2500])

        Settings.benchmarkMode = .complete
        clickBenchmark(menu)
        finish(menu)

        XCTAssertEqual(delayRequests(for: "Leaf-A").map { timeoutMilliseconds(for: $0) }, [2500, 5000])
        XCTAssertEqual(delayRequests(for: "Leaf-B").map { timeoutMilliseconds(for: $0) }, [2500, 5000])
        XCTAssertFalse(containsRemovedBenchmarkMenuStructure(menu))
        XCTAssertTrue(menu.items.first === action)
    }

    func testQuickTimeoutFeedbackAndRetryOnlyFailedTargets() throws {
        Settings.benchmarkMode = .quick
        let menu = menu()
        let action = try XCTUnwrap(menu.items.first as? ProxyGroupSpeedTestMenuItem)
        configure("Leaf-A", urlA, 90)
        MihomoMenuURLProtocol.replies[MihomoMenuURLProtocol.key("Leaf-B", urlA)] = .init(
            status: 504,
            body: ["message": "Timeout"]
        )

        clickBenchmark(menu)
        finish(menu)

        XCTAssertEqual(action.title, NSLocalizedString("Benchmark", comment: ""))
        XCTAssertNil(action.toolTip)
        XCTAssertEqual(text(menu, "Leaf-A"), "90 ms")
        XCTAssertEqual(text(menu, "Leaf-B"), NSLocalizedString("Benchmark timed out", comment: ""))
        let menuItemIdentities = menu.items.map(ObjectIdentifier.init)
        let retryItem = try retryMenuItem(menu)
        XCTAssertFalse(retryItem.isHidden)
        XCTAssertTrue(retryItem.isEnabled)
        XCTAssertFalse(containsRemovedBenchmarkMenuStructure(menu))

        menu.menuDidClose(menu)
        menu.menuWillOpen(menu)
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), menuItemIdentities)
        XCTAssertTrue(menu.items.first === action)
        XCTAssertFalse(retryItem.isHidden)
        XCTAssertTrue(retryItem.isEnabled)

        Settings.benchmarkMode = .complete
        MihomoMenuURLProtocol.replies[MihomoMenuURLProtocol.key("Leaf-B", urlA)] = .init(body: ["delay": 118])
        XCTAssertTrue(try NSApp.sendAction(XCTUnwrap(retryItem.action), to: retryItem.target, from: retryItem))
        XCTAssertTrue(retryItem.isHidden)
        XCTAssertFalse(retryItem.isEnabled)
        finish(menu)

        XCTAssertEqual(delayRequests(for: "Leaf-A").count, 1)
        XCTAssertEqual(delayRequests(for: "Leaf-B").count, 2)
        XCTAssertEqual(try timeoutMilliseconds(for: XCTUnwrap(delayRequests(for: "Leaf-B").last)), 5000)
        XCTAssertEqual(text(menu, "Leaf-A"), "90 ms")
        XCTAssertEqual(text(menu, "Leaf-B"), "118 ms")
        XCTAssertEqual(action.title, NSLocalizedString("Benchmark", comment: ""))
        XCTAssertNil(action.toolTip)
        XCTAssertTrue(retryItem.isHidden)
        XCTAssertFalse(retryItem.isEnabled)
    }

    func testClearBenchmarkRetryHistoryPreservesSuccessfulMeasurements() throws {
        Settings.benchmarkMode = .quick
        let menu = menu()
        let leafA = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        configure("Leaf-A", urlA, 95)
        MihomoMenuURLProtocol.replies[MihomoMenuURLProtocol.key("Leaf-B", urlA)] = .init(
            status: 504,
            body: ["message": "Timeout"]
        )

        clickBenchmark(menu)
        finish(menu)
        let retryItem = try retryMenuItem(menu)
        XCTAssertFalse(retryItem.isHidden)
        XCTAssertTrue(retryItem.isEnabled)

        let conditions = BenchmarkConditions(url: urlA)
        XCTAssertEqual(
            GlobalLeafBenchmarkPresentationStore.presentation(for: leafA, conditions: conditions)?.rowState.rawDelay,
            95
        )
        XCTAssertEqual(text(menu, "Leaf-A"), "95 ms")

        ProxyGroupSpeedTestMenuItem.clearBenchmarkRetryHistory()

        XCTAssertTrue(retryItem.isHidden)
        XCTAssertFalse(retryItem.isEnabled)
        XCTAssertEqual(
            GlobalLeafBenchmarkPresentationStore.presentation(for: leafA, conditions: conditions)?.rowState.rawDelay,
            95
        )
        XCTAssertEqual(text(menu, "Leaf-A"), "95 ms")
    }

    func testCancelledFullBenchmarkDropsPreviousRetryEligibility() throws {
        Settings.benchmarkMode = .quick
        let menu = menu()
        configure("Leaf-B", urlA, 74)
        MihomoMenuURLProtocol.replies[MihomoMenuURLProtocol.key("Leaf-A", urlA)] = .init(
            status: 504,
            body: ["message": "Timeout"]
        )

        clickBenchmark(menu)
        finish(menu)
        let retryItem = try retryMenuItem(menu)
        XCTAssertFalse(retryItem.isHidden)
        XCTAssertTrue(retryItem.isEnabled)

        configure("Leaf-A", urlA, 35)
        configure("Leaf-B", urlA, 48)
        MihomoMenuURLProtocol.hold = true
        clickBenchmark(menu)
        waitUntil("fresh full-benchmark targets held") { MihomoMenuURLProtocol.held.count == 2 }
        AppDelegate.shared.cancel()
        XCTAssertNil(AppDelegate.shared.active)
        XCTAssertTrue(retryItem.isHidden)
        XCTAssertFalse(retryItem.isEnabled)

        let deliveredBeforeRelease = MihomoMenuURLProtocol.delivered
        MihomoMenuURLProtocol.hold = false
        MihomoMenuURLProtocol.releaseHeld()
        waitUntil("cancelled full-benchmark replies drained") {
            MihomoMenuURLProtocol.delivered == deliveredBeforeRelease + 2
        }
        let drained = expectation(description: "cancelled full-benchmark callbacks drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(retryItem.isHidden)
        XCTAssertFalse(retryItem.isEnabled)
    }

    func testActualAppKitPopupDoesNotAddOptionsOrOrderRows() throws {
        let menu = menu()
        let action = try XCTUnwrap(menu.items.first as? ProxyGroupSpeedTestMenuItem)
        let identities = Set(menu.items.map(ObjectIdentifier.init))
        var mountedPopups = 0
        for _ in 0 ..< 3 {
            let timer = Timer(timeInterval: 0.08, repeats: false) { _ in
                if action.view?.window != nil { mountedPopups += 1 }
                menu.cancelTracking()
            }
            RunLoop.main.add(timer, forMode: .common)
            menu.popUp(positioning: nil, at: NSPoint(x: 40, y: 140), in: nil)
            timer.invalidate()
            XCTAssertEqual(Set(menu.items.map(ObjectIdentifier.init)), identities)
            XCTAssertFalse(containsRemovedBenchmarkMenuStructure(menu))
        }
        XCTAssertGreaterThan(mountedPopups, 0, "Exercise real view/window mounting, not only delegate calls")
        XCTAssertFalse(MihomoMenuURLProtocol.requests.contains {
            $0.url?.path.hasSuffix("/delay") == true
        }, "Opening the menu must not start a benchmark")
    }

    func testLatencySortSettingAppliesOnReopenWithoutAddingMenuItems() throws {
        Settings.benchmarkSortOrder = .configuration
        let menu = menu()
        let action = try XCTUnwrap(menu.items.first as? ProxyGroupSpeedTestMenuItem)
        let configurationOrder = sortableProxyNames(menu)
        XCTAssertEqual(configurationOrder, ["Automatic", "Leaf-A", "Leaf-B"])
        let initialCount = menu.items.count
        let initialIdentities = Set(menu.items.map(ObjectIdentifier.init))

        configure("Leaf-A", urlA, 152)
        configure("Leaf-B", urlA, 46)
        clickBenchmark(menu)
        finish(menu)
        XCTAssertEqual(sortableProxyNames(menu), configurationOrder)
        XCTAssertEqual(menu.items.count, initialCount)
        XCTAssertEqual(Set(menu.items.map(ObjectIdentifier.init)), initialIdentities)
        XCTAssertFalse(containsRemovedBenchmarkMenuStructure(menu))

        Settings.benchmarkSortOrder = .latency
        XCTAssertEqual(Settings.benchmarkSortOrder, .latency)
        XCTAssertEqual(sortableProxyNames(menu), configurationOrder)

        let viewsBeforeReopen = Dictionary(uniqueKeysWithValues: menu.items.compactMap { item -> (String, ObjectIdentifier)? in
            guard let proxyItem = item as? ProxyMenuItem, let view = proxyItem.view else { return nil }
            return (proxyItem.proxyName, ObjectIdentifier(view))
        })
        menu.menuDidClose(menu)
        menu.menuWillOpen(menu)

        let latencyOrder = sortableProxyNames(menu)
        XCTAssertEqual(latencyOrder.first, "Leaf-B")
        XCTAssertEqual(Set(latencyOrder), Set(configurationOrder))
        XCTAssertTrue(menu.items.first === action)
        XCTAssertEqual(menu.items.count, initialCount)
        XCTAssertEqual(Set(menu.items.map(ObjectIdentifier.init)), initialIdentities)
        XCTAssertFalse(containsRemovedBenchmarkMenuStructure(menu))
        for (name, identity) in viewsBeforeReopen {
            XCTAssertEqual(try ObjectIdentifier(XCTUnwrap(row(menu, name).view)), identity)
        }

        menu.menuDidClose(menu)
        menu.menuWillOpen(menu)
        XCTAssertEqual(sortableProxyNames(menu), latencyOrder)
        XCTAssertEqual(menu.items.count, initialCount)
        XCTAssertEqual(Set(menu.items.map(ObjectIdentifier.init)), initialIdentities)
        XCTAssertFalse(containsRemovedBenchmarkMenuStructure(menu))
    }

    func testAutomaticGroupRestoresReTestTitleAfterBenchmark() throws {
        Settings.benchmarkMode = .quick
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 72, "Leaf-B": 0])
        MihomoMenuURLProtocol.hold = true
        let menu = menu("Automatic")
        let action = try XCTUnwrap(menu.items.first as? ProxyGroupSpeedTestMenuItem)
        XCTAssertTrue(try retryMenuItem(menu).isHidden)
        XCTAssertFalse(containsRemovedBenchmarkMenuStructure(menu))

        clickBenchmark(menu)
        waitUntil("automatic group request is held") { MihomoMenuURLProtocol.held.count == 1 }
        XCTAssertEqual(action.title, NSLocalizedString("Testing automatic group", comment: ""))
        XCTAssertFalse(action.title.contains("/"))

        MihomoMenuURLProtocol.hold = false
        MihomoMenuURLProtocol.releaseHeld()
        finish(menu)

        let groupRequest = try XCTUnwrap(MihomoMenuURLProtocol.requests.first {
            $0.url?.path == "/group/Automatic/delay"
        })
        XCTAssertEqual(timeoutMilliseconds(for: groupRequest), 2500)
        XCTAssertEqual(action.title, NSLocalizedString("ReTest", comment: ""))
        XCTAssertNil(action.toolTip)
    }

    func testSelectorAutomaticRowUsesCurrentLeafMeasurementAfterRouteChanges() throws {
        var selector = try XCTUnwrap(MihomoMenuURLProtocol.topology["Selector"] as? [String: Any])
        selector["all"] = ["Automatic", "Leaf-A", "Leaf-B", "Leaf-C"]
        selector["now"] = "Automatic"
        MihomoMenuURLProtocol.topology["Selector"] = selector
        MihomoMenuURLProtocol.topology["Automatic"] = [
            "name": "Automatic", "type": "URLTest", "now": "Leaf-A",
            "all": ["Leaf-A", "Leaf-B"], "testUrl": urlA, "history": []
        ]
        MihomoMenuURLProtocol.topology["Leaf-C"] = [
            "name": "Leaf-C", "type": "Vless", "id": "leaf-c-id", "history": []
        ]
        refresh()

        let menu = menu()
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 486, "Leaf-B": 35])
        MihomoMenuURLProtocol.groupDidRespond = { MihomoMenuURLProtocol.hold = true }
        clickBenchmark(menu)
        waitUntil("sibling leaf probe is held after automatic retest") {
            MihomoMenuURLProtocol.held.count == 1
                && self.text(menu, "Automatic") == "486 ms"
        }

        // Preserve the ordering that causes the bug: the old-path row envelope
        // is newer than the other candidate's valid measurement. A late row
        // publication must not become a failed attempt on a different path.
        let oldLeaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        SelectorBenchmarkPresentationStore.publish(SelectorBenchmarkPresentation(
            selectorName: "Selector", rowName: "Automatic", resolvedLeafName: oldLeaf.name,
            resolvedCoreID: oldLeaf.id, benchmarkURL: urlA, sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Automatic", delay: 486)
        ))
        setNow("Automatic", "Leaf-B")
        refresh()

        XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Leaf-B")
        XCTAssertEqual(text(menu, "Automatic"), "35 ms")
        XCTAssertTrue(selected(menu, "Automatic"))
        let reopened = self.menu()
        XCTAssertEqual(text(reopened, "Automatic"), "35 ms")
        XCTAssertTrue(selected(reopened, "Automatic"))

        MihomoMenuURLProtocol.hold = false
        MihomoMenuURLProtocol.releaseHeld()
        finish(menu)
        XCTAssertEqual(text(menu, "Automatic"), "35 ms")
    }

    func testAutomaticHeaderUsesExistingCurrentLeafEvidenceAfterPathChanges() throws {
        let group = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        header = ProxyGroupMenuItemView(proxyGroup: group, targetProxy: "Leaf-A", hasLeftPadding: true)
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 486, "Leaf-B": 35])
        let automatic = menu("Automatic")
        clickBenchmark(automatic)
        finish(automatic)
        XCTAssertEqual(header?.delayLabel.stringValue, "486 ms")
        setNow("Automatic", "Leaf-B")
        refresh()
        XCTAssertEqual(header?.delayLabel.stringValue, "35 ms")
        let reopened = try ProxyGroupMenuItemView(proxyGroup: XCTUnwrap(snapshot.proxiesMap["Automatic"]),
                                                  targetProxy: "Leaf-B", hasLeftPadding: true)
        XCTAssertEqual(reopened.delayLabel.stringValue, "35 ms")
        XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Leaf-B")

        // An actual new attempt on the current leaf must still supersede its
        // earlier successful measurement, unlike old-path invalidation.
        let currentLeaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-B"])
        for state: ProxyBenchmarkRowState in [.unavailable(displayName: "Leaf-B"), .timedOut(displayName: "Leaf-B"), .failed(displayName: "Leaf-B")] {
            GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
                identity: LeafProxyBenchmarkIdentity(proxy: currentLeaf), benchmarkURL: urlB,
                sessionIdentifier: UUID(), rowState: state
            ))
            NotificationCenter.default.post(name: .proxyUpdate(for: "Automatic"), object: snapshot.proxiesMap["Automatic"])
            XCTAssertEqual(header?.delayLabel.stringValue, state.delayDisplay)
            XCTAssertEqual(reopened.delayLabel.stringValue, state.delayDisplay)
        }
    }

    func testAutomaticHeaderRejectsLateEvidenceFromDifferentURLOrExpectedStatus() throws {
        let oldGroup = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        let oldLeaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        let late = AutomaticGroupBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(group: oldGroup, fallbackBenchmarkURL: urlA),
            selectedPath: ["Automatic", "Leaf-A"], finalLeaf: "Leaf-A", finalLeafID: oldLeaf.id,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 131)
        )
        header = ProxyGroupMenuItemView(proxyGroup: oldGroup, targetProxy: "Leaf-A", hasLeftPadding: true)
        GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: oldLeaf), benchmarkURL: urlB,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 131)
        ))

        var changed = try XCTUnwrap(MihomoMenuURLProtocol.topology["Automatic"] as? [String: Any])
        changed["testUrl"] = urlA
        MihomoMenuURLProtocol.topology["Automatic"] = changed
        refresh()
        NotificationCenter.default.post(name: .proxyUpdate(for: "Automatic"), object: snapshot.proxiesMap["Automatic"])
        let currentLeaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: currentLeaf), benchmarkURL: urlA,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 42)
        ))
        // A late old-URL event must resolve against current group conditions.
        AutomaticGroupBenchmarkPresentationStore.publish(late)
        XCTAssertEqual(header?.delayLabel.stringValue, "42 ms")

        let previousGroup = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        let oldStatus = AutomaticGroupBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(group: previousGroup, fallbackBenchmarkURL: urlA),
            selectedPath: ["Automatic", "Leaf-A"], finalLeaf: "Leaf-A", finalLeafID: currentLeaf.id,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 42)
        )
        changed["expectedStatus"] = "204"
        MihomoMenuURLProtocol.topology["Automatic"] = changed
        refresh()
        NotificationCenter.default.post(name: .proxyUpdate(for: "Automatic"), object: snapshot.proxiesMap["Automatic"])
        try GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: XCTUnwrap(snapshot.proxiesMap["Leaf-A"])),
            benchmarkURL: urlA, expectedStatus: "204", sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Leaf-A", delay: 67)
        ))
        AutomaticGroupBenchmarkPresentationStore.publish(oldStatus)
        XCTAssertEqual(header?.delayLabel.stringValue, "67 ms")
        XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Leaf-A")
    }

    func testAutomaticHeaderKeepsHistoryAgeAndCurrentLeafFailuresAcrossRouteChanges() throws {
        let oldGroup = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        let oldLeaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        let measuredAt = Date().addingTimeInterval(-31 * 60)
        let otherLeaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-B"])
        GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: otherLeaf), benchmarkURL: urlB,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-B", delay: 35),
            publishedAt: measuredAt
        ))
        AutomaticGroupBenchmarkPresentationStore.publish(AutomaticGroupBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(group: oldGroup, fallbackBenchmarkURL: urlA),
            selectedPath: ["Automatic", "Leaf-A"], finalLeaf: "Leaf-A", finalLeafID: oldLeaf.id,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 486)
        ))
        header = ProxyGroupMenuItemView(proxyGroup: oldGroup, targetProxy: "Leaf-A", hasLeftPadding: true)
        setNow("Automatic", "Leaf-B")
        refresh()
        XCTAssertTrue(header?.delayLabel.stringValue.contains("35 ms") == true)
        XCTAssertNotEqual(header?.delayLabel.stringValue, "35 ms", "A route change must not freshen history")
        for state: ProxyBenchmarkRowState in [.failed(displayName: "Leaf-B"), .timedOut(displayName: "Leaf-B"), .unavailable(displayName: "Leaf-B")] {
            GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
                identity: LeafProxyBenchmarkIdentity(proxy: otherLeaf), benchmarkURL: urlB,
                sessionIdentifier: UUID(), rowState: state
            ))
            NotificationCenter.default.post(name: .proxyUpdate(for: "Automatic"), object: snapshot.proxiesMap["Automatic"])
            XCTAssertEqual(header?.delayLabel.stringValue, state.delayDisplay)
            XCTAssertTrue(header?.delayLabel.toolTip?.contains("35 ms") == true)
        }
        XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Leaf-B")
    }

    func testAutomaticHeaderDoesNotReuseAncestorEvidenceWhenOnlyInnerRouteChanges() throws {
        MihomoMenuURLProtocol.topology["Automatic"] = [
            "name": "Automatic", "type": "URLTest", "now": "Inner-A",
            "all": ["Inner-A", "Inner-B"], "testUrl": urlB, "history": []
        ]
        for name in ["Inner-A", "Inner-B"] {
            MihomoMenuURLProtocol.topology[name] = [
                "name": name, "type": "Selector", "now": "Leaf-A", "all": ["Leaf-A"], "history": []
            ]
        }
        refresh()
        let leaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: leaf), benchmarkURL: urlB,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 35),
            publishedAt: Date().addingTimeInterval(-1)
        ))
        header = try ProxyGroupMenuItemView(proxyGroup: XCTUnwrap(snapshot.proxiesMap["Automatic"]),
                                            targetProxy: "Inner-A", hasLeftPadding: true)
        for state: ProxyBenchmarkRowState in [.measured(displayName: "Leaf-A", delay: 486), .failed(displayName: "Leaf-A"), .timedOut(displayName: "Leaf-A"), .unavailable(displayName: "Leaf-A")] {
            setNow("Automatic", "Inner-A")
            refresh()
            let group = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
            AutomaticGroupBenchmarkPresentationStore.publish(AutomaticGroupBenchmarkPresentation(
                identity: AutomaticGroupBenchmarkIdentity(group: group, fallbackBenchmarkURL: urlA),
                selectedPath: ["Automatic", "Inner-A", "Leaf-A"], finalLeaf: "Leaf-A", finalLeafID: leaf.id,
                sessionIdentifier: UUID(), rowState: state
            ))
            XCTAssertEqual(header?.delayLabel.stringValue, state.delayDisplay)
            setNow("Automatic", "Inner-B")
            refresh()
            XCTAssertEqual(header?.delayLabel.stringValue, "35 ms")
            XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Inner-B")
        }
    }

    func testAutomaticHeaderRejectsSameNameProviderReplacementWithoutCoreID() throws {
        func attachProvider(_ name: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["providers": [name: [
                "name": name, "type": "Proxy", "vehicleType": "HTTP",
                "proxies": [["name": "Leaf-A", "type": "Vless", "history": []]]
            ]]])
            try snapshot.updateProvider(ClashProviderResp.decoder.decode(ClashProviderResp.self, from: data))
        }
        try attachProvider("P1")
        let group = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        let original = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        XCTAssertNil(original.id)
        let oldPresentation = AutomaticGroupBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(group: group, fallbackBenchmarkURL: urlA),
            selectedPath: ["Automatic", "Leaf-A"], finalLeaf: "Leaf-A", finalLeafID: original.id,
            finalLeafIdentity: LeafProxyBenchmarkIdentity(proxy: original),
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 131)
        )
        header = ProxyGroupMenuItemView(proxyGroup: group, targetProxy: "Leaf-A", hasLeftPadding: true)
        AutomaticGroupBenchmarkPresentationStore.publish(oldPresentation)
        XCTAssertEqual(header?.delayLabel.stringValue, "131 ms")
        try attachProvider("P2")
        let replacement = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        XCTAssertNil(replacement.id)
        XCTAssertEqual(replacement.enclosingProvider?.name, "P2")
        AutomaticGroupBenchmarkPresentationStore.publish(oldPresentation)
        XCTAssertNotEqual(header?.delayLabel.stringValue, "131 ms")
        GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: replacement), benchmarkURL: urlB,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 42)
        ))
        AutomaticGroupBenchmarkPresentationStore.publish(oldPresentation)
        XCTAssertEqual(header?.delayLabel.stringValue, "42 ms")
    }

    func testSelectorDistinguishesAncestorPathEvidenceFromDirectLeafMeasurements() throws {
        var selector = try XCTUnwrap(MihomoMenuURLProtocol.topology["Selector"] as? [String: Any])
        selector["now"] = "Automatic"
        MihomoMenuURLProtocol.topology["Selector"] = selector
        MihomoMenuURLProtocol.topology["Automatic"] = [
            "name": "Automatic", "type": "URLTest", "now": "Inner-A",
            "all": ["Inner-A", "Inner-B"], "testUrl": urlB, "history": []
        ]
        for name in ["Inner-A", "Inner-B"] {
            MihomoMenuURLProtocol.topology[name] = [
                "name": name, "type": "Selector", "now": "Leaf-A", "all": ["Leaf-A"], "history": []
            ]
        }
        refresh()
        let leaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: leaf), benchmarkURL: urlA,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 35),
            publishedAt: Date().addingTimeInterval(-1)
        ))
        let selectorMenu = menu()
        SelectorBenchmarkPresentationStore.publish(SelectorBenchmarkPresentation(
            selectorName: "Selector", rowName: "Automatic", resolvedLeafName: leaf.name,
            resolvedCoreID: leaf.id, resolvedPath: ["Automatic", "Inner-A", "Leaf-A"], benchmarkURL: urlA,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Automatic", delay: 486)
        ))
        XCTAssertEqual(text(selectorMenu, "Automatic"), "486 ms")
        setNow("Automatic", "Inner-B")
        refresh()
        XCTAssertEqual(text(selectorMenu, "Automatic"), "35 ms")
        XCTAssertEqual(text(menu(), "Automatic"), "35 ms")

        // A /proxies/Leaf-A/delay result is direct leaf evidence and remains
        // valid through another inner group that still resolves to that node.
        SelectorBenchmarkPresentationStore.publish(SelectorBenchmarkPresentation(
            selectorName: "Selector", rowName: "Automatic", resolvedLeafName: leaf.name,
            resolvedCoreID: leaf.id, benchmarkURL: urlA, sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Automatic", delay: 73)
        ))
        setNow("Automatic", "Inner-A")
        refresh()
        XCTAssertEqual(text(selectorMenu, "Automatic"), "73 ms")
        XCTAssertEqual(snapshot.proxiesMap["Selector"]?.now, "Automatic")
    }

    func testSelectorUnresolvedRowDoesNotMaskLeafHistoryAfterRouteResolves() throws {
        var selector = try XCTUnwrap(MihomoMenuURLProtocol.topology["Selector"] as? [String: Any])
        selector["all"] = ["Automatic", "Leaf-B"]
        selector["now"] = "Automatic"
        MihomoMenuURLProtocol.topology["Selector"] = selector
        var automatic = try XCTUnwrap(MihomoMenuURLProtocol.topology["Automatic"] as? [String: Any])
        automatic.removeValue(forKey: "now")
        MihomoMenuURLProtocol.topology["Automatic"] = automatic
        refresh()
        let leaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: leaf), benchmarkURL: urlA,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 35),
            publishedAt: Date().addingTimeInterval(-1)
        ))
        let selectorMenu = menu()
        clickBenchmark(selectorMenu)
        finish(selectorMenu)
        XCTAssertEqual(text(selectorMenu, "Automatic"), NSLocalizedString("Benchmark unavailable", comment: ""))
        setNow("Automatic", "Leaf-A")
        refresh()
        XCTAssertEqual(text(selectorMenu, "Automatic"), "35 ms")
        XCTAssertEqual(text(menu(), "Automatic"), "35 ms")
    }

    func testSelectedAutomaticReadbackFailureRemainsUnavailableOnKnownPath() throws {
        var selector = try XCTUnwrap(MihomoMenuURLProtocol.topology["Selector"] as? [String: Any])
        selector["all"] = ["Automatic"]
        selector["now"] = "Automatic"
        MihomoMenuURLProtocol.topology["Selector"] = selector
        var automatic = try XCTUnwrap(MihomoMenuURLProtocol.topology["Automatic"] as? [String: Any])
        automatic["testUrl"] = urlA
        MihomoMenuURLProtocol.topology["Automatic"] = automatic
        refresh()
        try GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: XCTUnwrap(snapshot.proxiesMap["Leaf-A"])),
            benchmarkURL: urlA, sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 35),
            publishedAt: Date().addingTimeInterval(-1)
        ))
        let selectorMenu = menu()
        // Initial topology succeeds; the retest's required fresh readback fails.
        MihomoMenuURLProtocol.proxyDataResponseStatuses = [200, 503, 200]
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 80, "Leaf-B": 150])
        clickBenchmark(selectorMenu)
        finish(selectorMenu)
        XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Leaf-A")
        XCTAssertEqual(text(selectorMenu, "Automatic"), NSLocalizedString("Benchmark unavailable", comment: ""))
        XCTAssertEqual(text(menu(), "Automatic"), NSLocalizedString("Benchmark unavailable", comment: ""))
    }

    func testAutomaticNestedChildDoesNotReuseAnotherLeafsAncestorResult() throws {
        MihomoMenuURLProtocol.topology["Automatic"] = [
            "name": "Automatic", "type": "URLTest", "now": "Inner-A",
            "all": ["Inner-A"], "testUrl": urlB, "history": []
        ]
        MihomoMenuURLProtocol.topology["Inner-A"] = [
            "name": "Inner-A", "type": "Selector", "now": "Leaf-A",
            "all": ["Leaf-A", "Leaf-B"], "history": []
        ]
        refresh()
        let group = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        let session = UUID()
        try GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: XCTUnwrap(snapshot.proxiesMap["Leaf-B"])),
            benchmarkURL: urlB, sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-B", delay: 35),
            publishedAt: Date().addingTimeInterval(-1)
        ))
        AutomaticChildBenchmarkStore.begin(group: group, sessionIdentifier: session)
        AutomaticChildBenchmarkStore.settle(group: group, candidateDelays: ["Inner-A": 486],
                                            hasProbeEvidence: true, sessionIdentifier: session)
        let automaticMenu = menu("Automatic")
        XCTAssertEqual(text(automaticMenu, "Inner-A"), "486 ms")
        setNow("Inner-A", "Leaf-B")
        refresh()
        XCTAssertEqual(text(automaticMenu, "Inner-A"), "35 ms")
        XCTAssertEqual(text(menu("Automatic"), "Inner-A"), "35 ms")
        XCTAssertEqual(snapshot.proxiesMap["Inner-A"]?.now, "Leaf-B")
    }

    func testQuickAutomaticGroupTimeoutRemainsUnavailable() throws {
        Settings.benchmarkMode = .quick
        MihomoMenuURLProtocol.groupReply = .init(
            status: 504,
            body: ["message": "get delay: all proxies timeout"]
        )
        let menu = menu("Automatic")
        let action = try XCTUnwrap(menu.items.first as? ProxyGroupSpeedTestMenuItem)

        clickBenchmark(menu)
        finish(menu)

        XCTAssertEqual(action.title, NSLocalizedString("ReTest", comment: ""))
        XCTAssertNil(action.toolTip)
        XCTAssertEqual(text(menu, "Leaf-A"), NSLocalizedString("Benchmark unavailable", comment: ""))
        XCTAssertFalse(text(menu, "Leaf-A").localizedCaseInsensitiveContains("fail"))
    }

    func testRefreshingDuringBenchmarkKeepsRealRowsAndUpdatesCheckmark() throws {
        let menu = menu()
        let action = try XCTUnwrap(menu.items.first as? ProxyGroupSpeedTestMenuItem)
        let identities = menu.items.map(ObjectIdentifier.init)
        configure("Leaf-A", urlA, 83)
        configure("Leaf-B", urlA, 107)
        MihomoMenuURLProtocol.hold = true
        clickBenchmark(menu)
        waitUntil("two deduplicated requests held") { MihomoMenuURLProtocol.held.count == 2 }
        let session = try XCTUnwrap(AppDelegate.shared.active)
        action.receiveBenchmarkProgress(
            BenchmarkProgressSnapshot(total: 2, completed: 1, succeeded: 1, reused: 1),
            session: session
        )
        XCTAssertNil(action.toolTip)
        let actionView = try XCTUnwrap(action.view)
        XCTAssertNil(actionView.toolTip)
        XCTAssertNil((actionView.subviews.first as? NSTextField)?.toolTip)
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
        let view = try XCTUnwrap(row(menu, "Leaf-B").view as? ProxyItemView)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        view.layoutSubtreeIfNeeded()
        view.layout()
        XCTAssertGreaterThan(try XCTUnwrap(view.imageView?.frame.width), 0)
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
        XCTAssertNil(menu.items[0].toolTip)
    }

    func testCoreSwitchCancellationExplainsWhyAcrossReopenedMenuAndNextBenchmark() throws {
        let current = menu()
        configure("Leaf-A", urlA, 1177)
        configure("Leaf-B", urlA, 2383)
        MihomoMenuURLProtocol.hold = true
        clickBenchmark(current)
        waitUntil("requests held before core switch") { MihomoMenuURLProtocol.held.count == 2 }
        let oldSession = try XCTUnwrap(AppDelegate.shared.active)
        let completedRequest = try XCTUnwrap(MihomoMenuURLProtocol.requests.first {
            $0.url?.path.hasSuffix("/delay") == true
        })
        let completedName = try XCTUnwrap(completedRequest.url?.pathComponents.dropLast().last)
        MihomoMenuURLProtocol.held.removeFirst()()
        waitUntil("first measurement displayed") {
            self.text(current, completedName).contains("ms")
                && current.items[0].title.contains("1/2")
        }
        XCTAssertEqual(
            current.items[0].title,
            String(format: NSLocalizedString("Benchmarking %d/%d", comment: ""), 1, 2)
        )
        let completedResult = text(current, completedName)

        AppDelegate.shared.isEnhancedModeTransitionInProgress = true
        AppDelegate.shared.cancel(reason: "core transition")
        let cancelledTitle = NSLocalizedString("Benchmark cancelled: core changed", comment: "")
        XCTAssertEqual(current.items[0].title, cancelledTitle)
        XCTAssertFalse(current.items[0].isEnabled)
        XCTAssertEqual(text(current, completedName), completedResult)
        XCTAssertTrue(current.items[0].toolTip?.contains("Completed results are kept") == true)

        AppDelegate.shared.isEnhancedModeTransitionInProgress = false
        let reopened = menu()
        XCTAssertEqual(reopened.items[0].title, cancelledTitle)
        XCTAssertTrue(reopened.items[0].isEnabled)
        XCTAssertEqual(text(reopened, completedName), completedResult)

        MihomoMenuURLProtocol.hold = false
        configure("Leaf-A", urlA, 42)
        configure("Leaf-B", urlA, 88)
        clickBenchmark(reopened)
        finish(reopened)
        ProxyGroupSpeedTestMenuItem.showBenchmarkCancellation(session: oldSession, reason: "core transition")
        let delivered = MihomoMenuURLProtocol.delivered
        let pendingCount = MihomoMenuURLProtocol.held.count
        MihomoMenuURLProtocol.releaseHeld()
        waitUntil("old replies delivered") { MihomoMenuURLProtocol.delivered == delivered + pendingCount }
        let drained = expectation(description: "old callbacks drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(text(reopened, "Leaf-A"), "42 ms")
        XCTAssertEqual(text(reopened, "Leaf-B"), "88 ms")
        XCTAssertEqual(reopened.items[0].title, NSLocalizedString("Benchmark", comment: ""))
        XCTAssertNil(reopened.items[0].toolTip)
    }

    func testBenchmarkBusyPresentationCoversMouseKeyboardAndCrossGroupActivation() throws {
        let selector = menu()
        let automatic = menu("Automatic")
        let selectorAction = try XCTUnwrap(selector.items[0] as? ProxyGroupSpeedTestMenuItem)
        let automaticAction = try XCTUnwrap(automatic.items[0] as? ProxyGroupSpeedTestMenuItem)
        let selectorView = try XCTUnwrap(selectorAction.view as? MenuItemBaseView)
        let automaticView = try XCTUnwrap(automaticAction.view as? MenuItemBaseView)

        selector.menu(selector, willHighlight: selectorAction)
        XCTAssertTrue(selectorView.isHighlighted)

        MihomoMenuURLProtocol.hold = true
        clickBenchmark(selector)
        waitUntil("benchmark requests held") { MihomoMenuURLProtocol.held.count == 2 }

        XCTAssertTrue(selectorAction.isEnabled)
        XCTAssertEqual(selectorAction.title, NSLocalizedString("Testing", comment: ""))
        XCTAssertLessThan(selectorView.alphaValue, 1)
        XCTAssertLessThan(automaticView.alphaValue, 1)
        XCTAssertEqual(selectorView.accessibilityValue() as? String, NSLocalizedString("Testing", comment: ""))
        XCTAssertNotNil(automaticView.accessibilityHelp())
        XCTAssertFalse(selectorView.isHighlighted)

        selector.menu(selector, willHighlight: selectorAction)
        automatic.menu(automatic, willHighlight: automaticAction)
        XCTAssertFalse(selectorView.isHighlighted)
        XCTAssertFalse(automaticView.isHighlighted)

        let heldCount = MihomoMenuURLProtocol.held.count
        let requestCount = MihomoMenuURLProtocol.requests.count
        let session = AppDelegate.shared.active
        clickBenchmark(selector)
        clickBenchmark(automatic)
        selectorAction.healthCheck()
        automaticAction.healthCheck()
        XCTAssertEqual(MihomoMenuURLProtocol.held.count, heldCount)
        XCTAssertEqual(MihomoMenuURLProtocol.requests.count, requestCount)
        XCTAssertTrue(AppDelegate.shared.active === session)

        AppDelegate.shared.cancel()
        XCTAssertEqual(selectorAction.title, NSLocalizedString("Benchmark", comment: ""))
        XCTAssertEqual(speedTestText(automaticAction), NSLocalizedString("ReTest", comment: ""))
        XCTAssertTrue(selectorAction.isEnabled)
        XCTAssertEqual(selectorView.alphaValue, 1)
        XCTAssertEqual(automaticView.alphaValue, 1)
        XCTAssertNil(selectorView.accessibilityValue())
        XCTAssertNil(automaticView.accessibilityHelp())
        waitUntil("cancelled benchmark views restored") {
            selectorView.alphaValue == 1 && automaticView.alphaValue == 1
        }

        let deliveredBeforeRelease = MihomoMenuURLProtocol.delivered
        MihomoMenuURLProtocol.hold = false
        MihomoMenuURLProtocol.releaseHeld()
        waitUntil("cancelled benchmark callbacks drained") {
            MihomoMenuURLProtocol.delivered == deliveredBeforeRelease + heldCount
        }
    }

    func testCoreTransitionExplainsAndBlocksBothBenchmarkEntrypoints() throws {
        AppDelegate.shared.isEnhancedModeTransitionInProgress = true
        let selector = menu()
        let automatic = menu("Automatic")
        let selectorAction = try XCTUnwrap(selector.items[0] as? ProxyGroupSpeedTestMenuItem)
        let automaticAction = try XCTUnwrap(automatic.items[0] as? ProxyGroupSpeedTestMenuItem)
        let reason = NSLocalizedString("Proxy core is changing. Please try again shortly.", comment: "")
        let switchingTitle = NSLocalizedString("Core switching…", comment: "")

        for action in [selectorAction, automaticAction] {
            let view = try XCTUnwrap(action.view as? MenuItemBaseView)
            XCTAssertFalse(action.isEnabled)
            XCTAssertEqual(action.title, switchingTitle)
            XCTAssertEqual(action.toolTip, reason)
            XCTAssertEqual(view.alphaValue, 0.5)
            XCTAssertEqual(view.accessibilityValue() as? String, switchingTitle)
            XCTAssertEqual(view.accessibilityHelp() as? String, reason)
            XCTAssertFalse(view.isHighlighted)
        }

        let requestCount = MihomoMenuURLProtocol.requests.count
        clickBenchmark(selector)
        clickBenchmark(automatic)
        XCTAssertEqual(MihomoMenuURLProtocol.requests.count, requestCount)
        XCTAssertNil(AppDelegate.shared.active)

        AppDelegate.shared.isEnhancedModeTransitionInProgress = false
        selector.menu(selector, willHighlight: selectorAction)
        automatic.menu(automatic, willHighlight: automaticAction)
        XCTAssertTrue(selectorAction.isEnabled)
        XCTAssertTrue(automaticAction.isEnabled)
        XCTAssertEqual(selectorAction.title, NSLocalizedString("Benchmark", comment: ""))
        XCTAssertEqual(speedTestText(automaticAction), NSLocalizedString("ReTest", comment: ""))
        XCTAssertNil(selectorAction.toolTip)
        XCTAssertNil(automaticAction.toolTip)
    }

    func testSelectorFreshTopologyFailureShowsReasonAndPreservesHistory() throws {
        let leaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        GlobalLeafBenchmarkPresentationStore.publish(.init(
            identity: .init(proxy: leaf),
            benchmarkURL: urlA,
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Leaf-A", delay: 90),
            publishedAt: Date(timeIntervalSinceNow: -48 * 3600)
        ))
        let menu = menu()
        let action = try XCTUnwrap(menu.items[0] as? ProxyGroupSpeedTestMenuItem)
        let previousDelay = text(menu, "Leaf-A")
        XCTAssertEqual(previousDelay, "90 ms · old")

        MihomoMenuURLProtocol.proxyDataResponseStatuses = [503]
        clickBenchmark(menu)
        finish(menu)

        XCTAssertEqual(action.title, NSLocalizedString("Benchmark unavailable", comment: ""))
        XCTAssertEqual(
            action.toolTip,
            NSLocalizedString("Proxy core unavailable. Please try again shortly.", comment: "")
        )
        XCTAssertEqual(text(menu, "Leaf-A"), previousDelay)
        XCTAssertEqual(
            GlobalLeafBenchmarkPresentationStore.presentation(
                for: leaf,
                conditions: BenchmarkConditions(url: urlA)
            )?.rowState.rawDelay,
            90
        )
    }

    func testAutomaticGroupFreshTopologyFailureShowsReasonAndPreservesHistory() throws {
        let leaf = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        GlobalLeafBenchmarkPresentationStore.publish(.init(
            identity: .init(proxy: leaf),
            benchmarkURL: urlB,
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Leaf-A", delay: 73),
            publishedAt: Date(timeIntervalSinceNow: -48 * 3600)
        ))
        let menu = menu("Automatic")
        let action = try XCTUnwrap(menu.items[0] as? ProxyGroupSpeedTestMenuItem)
        let previousDelay = text(menu, "Leaf-A")
        XCTAssertTrue(previousDelay.contains("73 ms"))

        MihomoMenuURLProtocol.proxyDataResponseStatuses = [503]
        clickBenchmark(menu)
        finish(menu)

        XCTAssertEqual(action.title, NSLocalizedString("Benchmark unavailable", comment: ""))
        XCTAssertEqual(
            action.toolTip,
            NSLocalizedString("Proxy core unavailable. Please try again shortly.", comment: "")
        )
        XCTAssertEqual(text(menu, "Leaf-A"), NSLocalizedString("Benchmark unavailable", comment: ""))
        XCTAssertTrue(try (XCTUnwrap(row(menu, "Leaf-A").view as? ProxyItemView)).delayLabel.toolTip?.contains("73 ms") == true)
        XCTAssertEqual(
            GlobalLeafBenchmarkPresentationStore.presentation(
                for: leaf,
                conditions: BenchmarkConditions(url: urlB)
            )?.rowState.rawDelay,
            73
        )
    }

    func testOldSessionCleanupCannotClearNewGroupBusyPresentation() throws {
        let first = menu()
        let second = menu("Selector-B")
        let secondAction = try XCTUnwrap(second.items[0] as? ProxyGroupSpeedTestMenuItem)
        let secondView = try XCTUnwrap(secondAction.view as? MenuItemBaseView)

        MihomoMenuURLProtocol.hold = true
        let deliveredBefore = MihomoMenuURLProtocol.delivered
        clickBenchmark(first)
        waitUntil("old group requests held") { MihomoMenuURLProtocol.held.count == 2 }
        AppDelegate.shared.cancel()

        clickBenchmark(second)
        waitUntil("new group request held") { MihomoMenuURLProtocol.held.count == 3 }
        let newSession = AppDelegate.shared.active
        XCTAssertNotNil(newSession)
        XCTAssertEqual(secondAction.title, NSLocalizedString("Testing", comment: ""))
        XCTAssertLessThan(secondView.alphaValue, 1)

        let oldCallbacks = Array(MihomoMenuURLProtocol.held.prefix(2))
        MihomoMenuURLProtocol.held.removeFirst(2)
        oldCallbacks.forEach { $0() }
        XCTAssertGreaterThanOrEqual(MihomoMenuURLProtocol.delivered, deliveredBefore + 2)

        XCTAssertTrue(AppDelegate.shared.active === newSession)
        XCTAssertEqual(secondAction.title, NSLocalizedString("Testing", comment: ""))
        XCTAssertLessThan(secondView.alphaValue, 1)

        AppDelegate.shared.cancel()
        MihomoMenuURLProtocol.hold = false
        MihomoMenuURLProtocol.releaseHeld()
        XCTAssertTrue(MihomoMenuURLProtocol.held.isEmpty)
    }

    func testAutomaticRetestUsesFreshNowRatherThanLowestDisplayedDelay() throws {
        _ = menu() // Also exercise the nested automatic row's observers.
        let automatic = menu("Automatic")
        let group = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        header = ProxyGroupMenuItemView(proxyGroup: group, targetProxy: "Leaf-A", hasLeftPadding: true)
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 20, "Leaf-B": 80])
        MihomoMenuURLProtocol.groupDidRespond = { [weak self] in self?.setNow("Automatic", "Leaf-B") }
        clickBenchmark(automatic)
        finish(automatic)
        XCTAssertFalse(selected(automatic, "Leaf-A"))
        XCTAssertTrue(selected(automatic, "Leaf-B"))
        XCTAssertEqual(text(automatic, "Leaf-B"), "80 ms")
        let labels = try XCTUnwrap(header?.effectView.subviews.compactMap { ($0 as? NSTextField)?.stringValue })
        XCTAssertTrue(labels.contains { $0.contains("Leaf-B") }, "\(labels)")
        XCTAssertEqual(header?.delayLabel.stringValue, "80 ms")
        XCTAssertNil(header?.toolTip)
        XCTAssertTrue(header?.delayLabel.toolTip?.contains(urlB) == true)
        header?.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        header?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(header?.delayLabel.frame.width), 0)
        XCTAssertLessThan(try XCTUnwrap(header?.delayLabel.frame.width), 100)
        let nodeLabel = try XCTUnwrap(header?.effectView.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains("Leaf-B") })
        XCTAssertLessThanOrEqual(nodeLabel.frame.maxX, try XCTUnwrap(header?.delayLabel.frame.minX))
        let request = try XCTUnwrap(MihomoMenuURLProtocol.requests.first { $0.url!.path == "/group/Automatic/delay" })
        XCTAssertTrue(try XCTUnwrap(request.url?.absoluteString.contains("test-b.invalid")))
    }

    func testHistorySurvivesReopenAndUnavailableHTTPDoesNotDeclareNodeDead() throws {
        let first = menu()
        let node = try XCTUnwrap(snapshot.proxiesMap["Leaf-A"])
        GlobalLeafBenchmarkPresentationStore.publish(.init(identity: .init(proxy: node), benchmarkURL: urlA,
                                                           sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf-A", delay: 90),
                                                           publishedAt: Date(timeIntervalSinceNow: -48 * 3600)))
        XCTAssertEqual(text(first, "Leaf-A"), "90 ms · old")
        refresh()
        let reopened = menu()
        XCTAssertEqual(text(reopened, "Leaf-A"), "90 ms · old")
        MihomoMenuURLProtocol.replies[MihomoMenuURLProtocol.key("Leaf-A", urlA)] = .init(status: 401, body: ["message": "Unauthorized"])
        clickBenchmark(reopened)
        finish(reopened)
        XCTAssertEqual(text(reopened, "Leaf-A"), NSLocalizedString("Benchmark unavailable", comment: ""))
        XCTAssertNil(row(reopened, "Leaf-A").toolTip)
        XCTAssertTrue(try XCTUnwrap((row(reopened, "Leaf-A").view as? ProxyItemView)?.delayLabel.toolTip?.contains("90 ms")))
        XCTAssertEqual(GlobalLeafBenchmarkPresentationStore.presentation(for: node, conditions: BenchmarkConditions(url: urlA))?.rowState.rawDelay, 90)
        XCTAssertEqual(text(first, "Leaf-A"), text(reopened, "Leaf-A"))
    }

    func testBenchmarkTooltipOnlyOnDelayAndClearedDuringRetest() throws {
        let menu = menu()
        let item = row(menu, "Leaf-A")
        let view = try XCTUnwrap(item.view as? ProxyItemView)
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
        XCTAssertEqual(view.delayLabel.stringValue, NSLocalizedString("Benchmark unavailable", comment: ""))
        XCTAssertTrue(view.delayLabel.toolTip?.contains("83 ms") == true)
    }

    func testAutomaticHeaderTooltipClearsWhileTestingAndAfterEvidenceReset() throws {
        let automatic = menu("Automatic")
        let group = try XCTUnwrap(snapshot.proxiesMap["Automatic"])
        header = ProxyGroupMenuItemView(proxyGroup: group, targetProxy: "Leaf-A", hasLeftPadding: true)
        MihomoMenuURLProtocol.groupReply = .init(body: ["Leaf-A": 20, "Leaf-B": 80])
        clickBenchmark(automatic)
        finish(automatic)
        XCTAssertNotNil(try XCTUnwrap(header?.delayLabel.toolTip))
        XCTAssertNil(header?.toolTip)
        let pathLabel = try XCTUnwrap(header?.effectView.subviews.compactMap { $0 as? NSTextField }
            .first { $0.toolTip?.contains("Automatic → Leaf-A") == true })
        XCTAssertNotNil(pathLabel.toolTip)
        MihomoMenuURLProtocol.hold = true
        clickBenchmark(automatic)
        waitUntil("automatic retest held") { !MihomoMenuURLProtocol.held.isEmpty }
        XCTAssertNil(header?.delayLabel.toolTip)
        XCTAssertNil(header?.toolTip)
        XCTAssertTrue(pathLabel.toolTip?.contains("Automatic → Leaf-A") == true)
        MihomoMenuURLProtocol.hold = false
        MihomoMenuURLProtocol.releaseHeld()
        finish(automatic)
        XCTAssertNotNil(try XCTUnwrap(header?.delayLabel.toolTip))
        AutomaticGroupBenchmarkPresentationStore.clearAll()
        setNow("Automatic", "Leaf-B")
        refresh()
        XCTAssertNil(header?.delayLabel.toolTip)
        XCTAssertEqual(header?.delayLabel.stringValue, "")
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

    func testAutomaticActionRefreshesItsSnapshotAfterAnotherGroupCompletes() throws {
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
        var leaf = try XCTUnwrap(MihomoMenuURLProtocol.topology["Leaf-A"] as? [String: Any])
        leaf["history"] = [["time": "2026-09-19T12:00:00.000+0000", "delay": 75]]
        MihomoMenuURLProtocol.topology["Leaf-A"] = leaf
        refresh()
        let action = try XCTUnwrap(second.items[0] as? ProxyGroupSpeedTestMenuItem)
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

    func testBenchmarkActionIgnoresProgressDetachedAndWrongTypeUpdates() throws {
        let original = actionSnapshot(id: "original")
        let group = try XCTUnwrap(original.proxiesMap["Lifetime-Group"])
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

    func testGenuineProbeFailureReplacesPreviousSuccessInRealView() throws {
        let menu = menu()
        let action = try XCTUnwrap(menu.items[0] as? ProxyGroupSpeedTestMenuItem)
        let view = try XCTUnwrap(action.view as? MenuItemBaseView)
        configure("Leaf-A", urlA, 90)
        clickBenchmark(menu)
        finish(menu)
        MihomoMenuURLProtocol.replies[MihomoMenuURLProtocol.key("Leaf-A", urlA)] = .init(status: 503, body: ["message": "An error occurred in the delay test"])
        clickBenchmark(menu)
        finish(menu)
        XCTAssertEqual(text(menu, "Leaf-A"), NSLocalizedString("fail", comment: ""))
        XCTAssertTrue(selected(menu, "Leaf-A")) // Selection is independent.
        XCTAssertTrue(action.isEnabled)
        XCTAssertEqual(view.alphaValue, 1)
    }

    func testSameNameReplacementInvalidatesVisibleMeasurement() throws {
        let menu = menu()
        configure("Leaf-A", urlA, 90)
        clickBenchmark(menu)
        finish(menu)
        var leaf = try XCTUnwrap(MihomoMenuURLProtocol.topology["Leaf-A"] as? [String: Any])
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

    func testEmptyRegionsIgnoreFallbackLatencyButExplicitDirectStillMeasures() throws {
        addCompatible()
        MihomoMenuURLProtocol.topology["DIRECT"] = ["name": "DIRECT", "type": "Direct", "id": "direct-id", "history": []]
        for name in ["Singapore", "Taiwan"] {
            MihomoMenuURLProtocol.topology[name] = ["name": name, "type": "URLTest", "all": ["COMPATIBLE"], "now": "COMPATIBLE", "testUrl": urlA, "history": []]
        }
        MihomoMenuURLProtocol.topology["Selector"] = ["name": "Selector", "type": "Selector", "all": ["Singapore", "Taiwan", "DIRECT", "Leaf-A"], "now": "Singapore", "testUrl": urlA, "history": []]
        refresh()
        let first = menu()
        let fallback = try XCTUnwrap(snapshot.proxiesMap["COMPATIBLE"])
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

    func testExplicitRetestOfEmptyAutomaticGroupMakesNoDelayRequest() throws {
        addCompatible()
        MihomoMenuURLProtocol.topology["Automatic"] = ["name": "Automatic", "type": "URLTest", "all": ["COMPATIBLE"], "now": "COMPATIBLE", "testUrl": urlB, "history": []]
        refresh()
        let automatic = menu("Automatic")
        header = try ProxyGroupMenuItemView(proxyGroup: XCTUnwrap(snapshot.proxiesMap["Automatic"]), targetProxy: "COMPATIBLE", hasLeftPadding: true)
        let before = MihomoMenuURLProtocol.requests.count
        clickBenchmark(automatic)
        XCTAssertNil(AppDelegate.shared.active)
        XCTAssertEqual(MihomoMenuURLProtocol.requests.count, before)
        XCTAssertEqual(automatic.items[0].title, NSLocalizedString("No testable proxy nodes", comment: ""))
        XCTAssertEqual(text(automatic, "COMPATIBLE"), NSLocalizedString("Direct fallback (no proxy nodes)", comment: ""))
        let labels = try XCTUnwrap(header?.effectView.subviews.compactMap { ($0 as? NSTextField)?.stringValue })
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

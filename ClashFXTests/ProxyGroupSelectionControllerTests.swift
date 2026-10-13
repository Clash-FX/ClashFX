import AppKit
import XCTest

final class ProxyGroupSelectionControllerTests: XCTestCase {
    private final class Harness {
        var current = true
        var coreChanging = false
        var benchmarkBusy = false
        var interactionReserved = false
        var selectCalls = [(String, String)]()
        var resetCalls = [String]()
        var selectCompletion: ((Bool) -> Void)?
        var resetCompletion: ((Bool) -> Void)?
        var refreshCompletion: ((ClashProxyResp?) -> Void)?
        var refreshCount = 0
        var published = [ClashProxyResp]()
        var remembered = [(String, String)]()
        var closeCount = 0
        var errors = [String]()
        var onRefresh: (() -> Void)?

        func dependencies(stageTimeout: TimeInterval = 1) -> ProxyGroupSelectionController.Dependencies {
            ProxyGroupSelectionController.Dependencies(
                isCurrent: { self.current },
                isCoreChanging: { self.coreChanging },
                isBusyBenchmark: { self.benchmarkBusy },
                isInteractionReserved: { self.interactionReserved },
                select: { group, name, complete in
                    self.selectCalls.append((group, name))
                    self.selectCompletion = complete
                },
                reset: { group, complete in
                    self.resetCalls.append(group)
                    self.resetCompletion = complete
                },
                refresh: { complete in
                    self.refreshCount += 1
                    self.refreshCompletion = complete
                    self.onRefresh?()
                },
                publish: { self.published.append($0) },
                rememberSelection: { self.remembered.append(($0, $1)) },
                closeConnections: { self.closeCount += 1 },
                showError: { self.errors.append($0) },
                stageTimeout: stageTimeout
            )
        }
    }

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Thread.isMainThread)
        _ = NSApplication.shared
    }

    func testSelectorRequiresReadbackBeforeRecordingAndPublishesMismatch() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")

        XCTAssertTrue(controller.isOperationInProgress)
        XCTAssertEqual(controller.proxyGroup.now, "A")
        harness.selectCompletion?(true)
        waitUntil("readback requested") { harness.refreshCompletion != nil }
        XCTAssertTrue(controller.isOperationInProgress)
        XCTAssertEqual(controller.proxyGroup.now, "A")

        let mismatch = snapshot(type: .select, now: "A")
        harness.refreshCompletion?(mismatch)
        waitUntil("mismatch settled") { !controller.isOperationInProgress }

        XCTAssertEqual(controller.proxyGroup.now, "A")
        XCTAssertEqual(harness.published.count, 1)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
        XCTAssertEqual(harness.errors.count, 1)
    }

    func testSelectorReadbackSuccessRemembersAndClosesConnections() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")
        harness.selectCompletion?(true)
        waitUntil("readback requested") { harness.refreshCompletion != nil }

        let selected = snapshot(type: .select, now: "B")
        harness.refreshCompletion?(selected)
        waitUntil("selection settled") { !controller.isOperationInProgress }

        XCTAssertEqual(controller.proxyGroup.now, "B")
        XCTAssertEqual(harness.published.count, 1)
        XCTAssertEqual(harness.remembered.count, 1)
        XCTAssertEqual(harness.remembered.first?.0, "Group")
        XCTAssertEqual(harness.remembered.first?.1, "B")
        XCTAssertEqual(harness.closeCount, 1)
        XCTAssertTrue(harness.errors.isEmpty)
    }

    func testAutomaticPriorityMayDifferFromNowWithoutFakingTheRoute() {
        let initial = snapshot(type: .urltest, now: "A", fixed: "")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        let rows = registerRows(on: controller, snapshot: initial)
        controller.select(group: "Group", name: "B")
        harness.selectCompletion?(true)
        waitUntil("readback requested") { harness.refreshCompletion != nil }

        let selected = snapshot(type: .urltest, now: "A", fixed: "B")
        harness.refreshCompletion?(selected)
        waitUntil("priority settled") { !controller.isOperationInProgress }

        XCTAssertEqual(controller.proxyGroup.fixed, "B")
        XCTAssertEqual(controller.proxyGroup.now, "A")
        XCTAssertEqual(rows["A"]?.state, .on)
        XCTAssertEqual(rows["B"]?.state, .off)
        XCTAssertEqual(rows["B"]?.selectionHelp, NSLocalizedString("Preferred node", comment: ""))
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 1)
    }

    func testAutomaticPriorityMismatchPublishesClearedFixedWithoutSuccessEffects() {
        let initial = snapshot(type: .fallback, now: "A", fixed: "")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")
        harness.selectCompletion?(true)
        waitUntil("readback requested") { harness.refreshCompletion != nil }

        let cleared = snapshot(type: .fallback, now: "A", fixed: "")
        harness.refreshCompletion?(cleared)
        waitUntil("priority mismatch settled") { !controller.isOperationInProgress }

        XCTAssertEqual(controller.proxyGroup.fixed, "")
        XCTAssertEqual(controller.proxyGroup.now, "A")
        XCTAssertEqual(harness.published.count, 1)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
        XCTAssertEqual(harness.errors.count, 1)
    }

    func testRestoreAutomaticSuccessUsesFreshEmptyFixedReadback() {
        let initial = snapshot(type: .fallback, now: "B", fixed: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.restoreAutomaticSelection()

        XCTAssertEqual(harness.resetCalls, ["Group"])
        harness.resetCompletion?(true)
        waitUntil("readback requested") { harness.refreshCompletion != nil }

        let reset = snapshot(type: .fallback, now: "B", fixed: "")
        harness.refreshCompletion?(reset)
        waitUntil("restore settled") { !controller.isOperationInProgress }

        XCTAssertEqual(controller.proxyGroup.fixed, "")
        XCTAssertEqual(controller.proxyGroup.now, "B")
        XCTAssertEqual(harness.closeCount, 1)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertTrue(harness.errors.isEmpty)
    }

    func testRestoreAutomaticFailureKeepsPriorSnapshot() {
        let initial = snapshot(type: .fallback, now: "A", fixed: "B")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.restoreAutomaticSelection()
        harness.resetCompletion?(false)
        waitUntil("failed reset settled") { !controller.isOperationInProgress }

        XCTAssertEqual(controller.proxyGroup.fixed, "B")
        XCTAssertEqual(harness.refreshCount, 0)
        XCTAssertEqual(harness.published.count, 0)
        XCTAssertEqual(harness.closeCount, 0)
        XCTAssertEqual(harness.errors.count, 1)
    }

    func testPendingDuplicateIsRejectedWithoutChangingSelection() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")
        controller.select(group: "Group", name: "B")

        XCTAssertEqual(harness.selectCalls.count, 1)
        XCTAssertEqual(controller.proxyGroup.now, "A")
        XCTAssertTrue(controller.isOperationInProgress)
        XCTAssertEqual(harness.errors.count, 1)

        harness.selectCompletion?(false)
        waitUntil("failed selection settled") { !controller.isOperationInProgress }
        XCTAssertEqual(controller.proxyGroup.now, "A")
        XCTAssertEqual(harness.closeCount, 0)
    }

    func testOldGenerationCannotStartReadbackOrCommit() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")
        harness.current = false
        harness.selectCompletion?(true)
        waitUntil("stale operation settled") { !controller.isOperationInProgress }

        XCTAssertEqual(harness.refreshCount, 0)
        XCTAssertEqual(controller.proxyGroup.now, "A")
        XCTAssertTrue(harness.published.isEmpty)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
        XCTAssertTrue(harness.errors.isEmpty)
    }

    func testCoreChangeDuringMutationSettlesWithoutReadback() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")
        harness.coreChanging = true
        harness.selectCompletion?(true)
        waitUntil("core change settled") { !controller.isOperationInProgress }

        XCTAssertEqual(harness.refreshCount, 0)
        XCTAssertTrue(harness.published.isEmpty)
        XCTAssertFalse(ProxyGroupSelectionController.isAnyOperationInProgress)
    }

    func testSelectionAndRestoreAreSerializedAcrossGroupsAndRowsRefreshImmediately() {
        let firstSnapshot = snapshot(type: .select, now: "A")
        let firstHarness = Harness()
        let firstController = makeController(firstSnapshot, harness: firstHarness)
        let firstRows = registerRows(on: firstController, snapshot: firstSnapshot)
        let benchmarkAction = ProxyGroupSpeedTestMenuItem(group: firstSnapshot.proxiesMap["Group"]!)
        AppDelegate.shared.cancel()

        let otherSnapshot = snapshot(type: .fallback, now: "A", fixed: "B", groupName: "Other")
        let otherHarness = Harness()
        let otherController = makeController(otherSnapshot, harness: otherHarness, groupName: "Other")
        let otherRows = registerRows(on: otherController, snapshot: otherSnapshot)

        firstController.select(group: "Group", name: "B")
        XCTAssertTrue(ProxyGroupSelectionController.isAnyOperationInProgress)
        XCTAssertFalse(benchmarkAction.isEnabled)
        XCTAssertNil(AppDelegate.shared.beginSpeedTest(showNotifications: false))
        XCTAssertTrue(otherRows.values.allSatisfy { !$0.isEnabled })
        otherController.restoreAutomaticSelection()
        otherController.select(group: "Other", name: "A")
        XCTAssertTrue(otherHarness.resetCalls.isEmpty)
        XCTAssertTrue(otherHarness.selectCalls.isEmpty)

        firstHarness.selectCompletion?(false)
        waitUntil("first group settled") { !firstController.isOperationInProgress }
        XCTAssertFalse(ProxyGroupSelectionController.isAnyOperationInProgress)
        XCTAssertTrue(benchmarkAction.isEnabled)
        XCTAssertTrue(otherRows.values.allSatisfy(\.isEnabled))

        otherController.restoreAutomaticSelection()
        XCTAssertEqual(otherHarness.resetCalls, ["Other"])
        XCTAssertTrue(firstRows.values.allSatisfy { !$0.isEnabled })
        let firstCallCount = firstHarness.selectCalls.count
        firstController.select(group: "Group", name: "B")
        XCTAssertEqual(firstHarness.selectCalls.count, firstCallCount)

        otherHarness.resetCompletion?(false)
        waitUntil("restore settled") { !otherController.isOperationInProgress }
        XCTAssertFalse(ProxyGroupSelectionController.isAnyOperationInProgress)
        XCTAssertTrue(benchmarkAction.isEnabled)
        XCTAssertTrue(firstRows.values.allSatisfy(\.isEnabled))
    }

    func testBusyBenchmarkPreventsNewSelection() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        harness.benchmarkBusy = true
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")

        XCTAssertTrue(harness.selectCalls.isEmpty)
        XCTAssertFalse(controller.isOperationInProgress)
        XCTAssertFalse(ProxyGroupSelectionController.isAnyOperationInProgress)
        XCTAssertEqual(harness.errors.count, 1)
    }

    func testQueuedConfigurationUpdatePreventsNewSelection() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        harness.interactionReserved = true
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")

        XCTAssertTrue(harness.selectCalls.isEmpty)
        XCTAssertFalse(controller.isOperationInProgress)
        XCTAssertTrue(harness.errors.last?.contains("Configuration update is queued") == true)
    }

    func testQueuedConfigurationUpdateDoesNotInvalidateCurrentSelectionReadback() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")
        harness.interactionReserved = true

        harness.selectCompletion?(true)
        waitUntil("readback requested while reload is queued") { harness.refreshCompletion != nil }
        harness.refreshCompletion?(snapshot(type: .select, now: "B"))
        waitUntil("selection settled before reload") { !controller.isOperationInProgress }

        XCTAssertEqual(harness.remembered.map { $0.1 }, ["B"])
        XCTAssertEqual(harness.closeCount, 1)
        XCTAssertTrue(harness.errors.isEmpty)
    }

    func testMembershipChangeInvalidatesPendingController() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")
        let changed = snapshot(type: .select, now: "A", members: ["A", "C"])
        NotificationCenter.default.post(name: .proxyUpdate(for: "Group"), object: changed.proxiesMap["Group"])

        XCTAssertTrue(controller.isOperationInProgress)
        XCTAssertTrue(ProxyGroupSelectionController.isAnyOperationInProgress)
        harness.selectCompletion?(true)
        waitUntil("invalidated mutation settled") { !controller.isOperationInProgress }
        XCTAssertEqual(harness.errors.count, 1)
        XCTAssertEqual(harness.refreshCount, 0)
        XCTAssertTrue(harness.published.isEmpty)
    }

    func testTypeChangeInvalidatesPendingController() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")
        let changed = snapshot(type: .fallback, now: "A", fixed: "", id: "group-id")
        NotificationCenter.default.post(name: .proxyUpdate(for: "Group"), object: changed.proxiesMap["Group"])

        XCTAssertTrue(controller.isOperationInProgress)
        XCTAssertTrue(ProxyGroupSelectionController.isAnyOperationInProgress)
        harness.selectCompletion?(true)
        waitUntil("invalidated mutation settled") { !controller.isOperationInProgress }
        XCTAssertEqual(harness.errors.count, 1)
        XCTAssertEqual(harness.refreshCount, 0)
        XCTAssertTrue(harness.published.isEmpty)
    }

    func testGroupIdentityChangeInvalidatesPendingController() {
        let initial = snapshot(type: .select, now: "A", id: "group-id")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        controller.select(group: "Group", name: "B")
        let changed = snapshot(type: .select, now: "A", id: "replacement-id")
        NotificationCenter.default.post(name: .proxyUpdate(for: "Group"), object: changed.proxiesMap["Group"])

        XCTAssertTrue(controller.isOperationInProgress)
        XCTAssertTrue(ProxyGroupSelectionController.isAnyOperationInProgress)
        harness.selectCompletion?(true)
        waitUntil("invalidated mutation settled") { !controller.isOperationInProgress }
        XCTAssertEqual(harness.errors.count, 1)
        XCTAssertEqual(harness.refreshCount, 0)
        XCTAssertTrue(harness.published.isEmpty)
    }

    func testMenuInvalidationKeepsOperationGuardUntilMutationSettles() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        var controller: ProxyGroupSelectionController? = makeController(initial, harness: harness)
        weak var weakController = controller
        autoreleasepool {
            controller?.select(group: "Group", name: "B")
    
            ProxyGroupSelectionController.invalidateAll()
            XCTAssertTrue(ProxyGroupSelectionController.isAnyOperationInProgress)
            XCTAssertTrue(weakController?.isOperationInProgress == true)
            controller = nil
            XCTAssertNotNil(weakController, "An in-flight mutation must retain its invalidated controller")
    
            harness.selectCompletion?(true)
            waitUntil("invalidated mutation callback drained") {
                !ProxyGroupSelectionController.isAnyOperationInProgress
            }
            XCTAssertEqual(harness.refreshCount, 0)
            XCTAssertTrue(harness.remembered.isEmpty)
            XCTAssertEqual(harness.closeCount, 0)
        }
        XCTAssertNil(weakController)
    }

    func testMutationTimeoutIgnoresLateHTTP204() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness, stageTimeout: 0.03)
        controller.select(group: "Group", name: "B")
        waitUntil("mutation timeout") { !controller.isOperationInProgress }

        XCTAssertEqual(harness.errors.count, 1)
        harness.selectCompletion?(true)
        XCTAssertEqual(harness.refreshCount, 0)
        XCTAssertEqual(controller.proxyGroup.now, "A")
        XCTAssertTrue(harness.published.isEmpty)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
    }

    func testReadbackTimeoutIgnoresLateSnapshot() {
        let initial = snapshot(type: .select, now: "A")
        let harness = Harness()
        let controller = makeController(initial, harness: harness, stageTimeout: 0.03)
        controller.select(group: "Group", name: "B")
        harness.selectCompletion?(true)
        waitUntil("readback starts") { harness.refreshCompletion != nil }
        waitUntil("readback timeout") { !controller.isOperationInProgress }

        harness.refreshCompletion?(snapshot(type: .select, now: "B"))
        XCTAssertEqual(controller.proxyGroup.now, "A")
        XCTAssertTrue(harness.published.isEmpty)
        XCTAssertTrue(harness.remembered.isEmpty)
        XCTAssertEqual(harness.closeCount, 0)
        XCTAssertEqual(harness.errors.count, 1)
    }

    func testUnknownFixedStateAndLoadBalanceAreReadOnly() {
        let oldCore = snapshot(type: .urltest, now: "A", includeFixed: false)
        let oldHarness = Harness()
        let oldController = makeController(oldCore, harness: oldHarness)
        let oldRows = registerRows(on: oldController, snapshot: oldCore)
        oldController.select(group: "Group", name: "B")

        XCTAssertFalse(oldRows["B"]?.isEnabled ?? true)
        XCTAssertTrue(oldRows["B"]?.selectionHelp?.contains("fixed state") == true)
        XCTAssertTrue(oldHarness.selectCalls.isEmpty)
        XCTAssertEqual(oldHarness.errors.count, 1)

        let balance = snapshot(type: .loadBalance, now: "A")
        let balanceHarness = Harness()
        let balanceController = makeController(balance, harness: balanceHarness)
        balanceController.select(group: "Group", name: "B")
        XCTAssertTrue(balanceHarness.selectCalls.isEmpty)
        XCTAssertTrue(balanceHarness.resetCalls.isEmpty)
        XCTAssertEqual(balanceHarness.errors.count, 1)
    }

    func testCompatibilityFallbackRemainsNoNodesWhileExplicitDirectCanBePrioritized() {
        let noNodes = snapshot(type: .urltest, now: "COMPATIBLE", fixed: "", members: ["COMPATIBLE"])
        XCTAssertFalse(noNodes.hasBenchmarkCandidates(in: "Group"))
        let fallbackHarness = Harness()
        let fallbackController = makeController(noNodes, harness: fallbackHarness)
        let fallbackRows = registerRows(on: fallbackController, snapshot: noNodes)
        fallbackController.select(group: "Group", name: "COMPATIBLE")

        XCTAssertFalse(fallbackRows["COMPATIBLE"]?.isEnabled ?? true)
        XCTAssertTrue(fallbackHarness.selectCalls.isEmpty)

        let withDirect = snapshot(type: .urltest, now: "DIRECT", fixed: "", members: ["DIRECT"])
        XCTAssertTrue(withDirect.hasBenchmarkCandidates(in: "Group"))
        let directHarness = Harness()
        let directController = makeController(withDirect, harness: directHarness)
        directController.select(group: "Group", name: "DIRECT")

        XCTAssertEqual(directHarness.selectCalls.count, 1)
        XCTAssertEqual(directHarness.selectCalls.first?.1, "DIRECT")
        directHarness.selectCompletion?(false)
        waitUntil("DIRECT request drained") { !directController.isOperationInProgress }
    }

    private func makeController(
        _ snapshot: ClashProxyResp,
        harness: Harness,
        stageTimeout: TimeInterval = 1,
        groupName: String = "Group"
    ) -> ProxyGroupSelectionController {
        ProxyGroupSelectionController(
            group: snapshot.proxiesMap[groupName]!,
            snapshot: snapshot,
            dependencies: harness.dependencies(stageTimeout: stageTimeout)
        )
    }

    @discardableResult
    private func registerRows(
        on controller: ProxyGroupSelectionController,
        snapshot: ClashProxyResp
    ) -> [String: ProxyMenuItem] {
        let group = snapshot.proxiesMap[controller.proxyGroup.name]!
        var rows = [String: ProxyMenuItem]()
        for name in group.all ?? [] {
            let row = ProxyMenuItem(proxy: snapshot.proxiesMap[name]!, group: group, action: nil)
            rows[name] = row
            controller.register(candidateItem: row)
        }
        return rows
    }

    func testNativeMenuActionsAndRestoreRowKeepStableStructure() throws {
        let originalRendering = MenuItemFactory.useViewToRenderProxy
        MenuItemFactory.useViewToRenderProxy = false
        defer { MenuItemFactory.useViewToRenderProxy = originalRendering }
        let initial = snapshot(type: .urltest, now: "A", fixed: "")
        let harness = Harness()
        let controller = makeController(initial, harness: harness)
        let menu = ProxyGroupMenu(title: "Group")
        menu.selectionController = controller
        let restore = try XCTUnwrap(controller.restoreAutomaticItem)
        menu.addItem(restore)
        for name in ["A", "B"] {
            let item = ProxyMenuItem(proxy: try XCTUnwrap(initial.proxiesMap[name]),
                                     group: try XCTUnwrap(initial.proxiesMap["Group"]),
                                     action: #selector(ProxyGroupSelectionController.selectProxy(sender:)))
            item.target = controller
            menu.addItem(item)
            controller.register(candidateItem: item)
            XCTAssertNil(item.view)
            XCTAssertNil(item.submenu)
        }
        let identities = menu.items.map(ObjectIdentifier.init)
        XCTAssertTrue(restore.isHidden)
        menu.update()
        menu.performActionForItem(at: 2)
        XCTAssertEqual(harness.selectCalls.first?.1, "B")
        harness.selectCompletion?(true)
        waitUntil("native action readback") { harness.refreshCount == 1 }
        harness.refreshCompletion?(snapshot(type: .urltest, now: "B", fixed: "B"))
        waitUntil("native action settled") { !controller.isOperationInProgress }
        XCTAssertFalse(restore.isHidden)
        XCTAssertEqual(menu.items[2].state, .on)
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), identities)
        menu.update()
        menu.performActionForItem(at: 0)
        XCTAssertEqual(harness.resetCalls, ["Group"])
        harness.resetCompletion?(true)
        waitUntil("native reset readback") { harness.refreshCount == 2 }
        harness.refreshCompletion?(snapshot(type: .urltest, now: "A", fixed: ""))
        waitUntil("native reset settled") { !controller.isOperationInProgress }
        XCTAssertTrue(restore.isHidden)
        XCTAssertEqual(menu.items[1].state, .on)
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), identities)
        XCTAssertTrue(harness.errors.isEmpty)
    }

    private func snapshot(
        type: ClashProxyType,
        now: String,
        fixed: String? = nil,
        includeFixed: Bool = true,
        members: [String] = ["A", "B"],
        id: String? = "group-id",
        groupName: String = "Group"
    ) -> ClashProxyResp {
        var group: [String: Any] = [
            "name": groupName,
            "type": type.rawValue,
            "all": members,
            "now": now,
            "history": []
        ]
        if let id { group["id"] = id }
        if includeFixed { group["fixed"] = fixed ?? "" }
        var proxies: [String: Any] = [groupName: group]
        for name in Set(members + ["A", "B", "C"]) {
            let typeName = name == "COMPATIBLE" ? "Compatible" : (name == "DIRECT" ? "Direct" : "Shadowsocks")
            proxies[name] = ["name": name, "type": typeName, "history": []]
        }
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

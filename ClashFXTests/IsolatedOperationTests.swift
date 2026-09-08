import Foundation
import XCTest

/// No sockets, XPC, app singleton or production preferences are available here.
final class IsolatedSystemProxyTests: XCTestCase {
    private var suites = [(UserDefaults, String)]()

    override func tearDown() {
        for (defaults, name) in suites {
            defaults.removePersistentDomain(forName: name)
        }
        suites.removeAll()
        super.tearDown()
    }

    private let original: [String: Any] = [
        SystemProxyOperationPolicy.capturedServiceIDsKey: ["wifi"],
        "wifi": ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.test/original.pac", "HTTPEnable": 0]
    ]

    private final class Helper {
        var current: [String: Any] = [:]
        var events = [String]()
        var readbackOverride: [String: Any]?
        var restoreError: String?
        var holdCapture = false
        var holdEnable = false
        var holdRestore = false
        var captureReply: ((Any?) -> Void)?
        var enableReply: ((String?) -> Void)?
        var restoreReply: ((String?) -> Void)?
        var onEvent: ((String) -> Void)?
        var duplicateReplies = false

        func record(_ event: String) {
            XCTAssertTrue(Thread.isMainThread)
            events.append(event)
            onEvent?(event)
        }

        var client: SystemProxyHelperClient {
            SystemProxyHelperClient(
                getCurrentProxySetting: { reply in
                    DispatchQueue.main.async {
                        self.record("capture")
                        if self.holdCapture { self.captureReply = reply; return }
                        reply(self.readbackOverride ?? self.current)
                        if self.duplicateReplies { reply(self.current) }
                    }
                },
                enable: { port, socks, _, _, reply in
                    DispatchQueue.main.async {
                        self.record("enable")
                        self.current = [SystemProxyOperationPolicy.capturedServiceIDsKey: ["wifi"],
                                        "wifi": ["HTTPEnable": 1, "HTTPPort": port, "SOCKSPort": socks]]
                        if self.holdEnable { self.enableReply = reply; return }
                        reply(nil)
                        if self.duplicateReplies { reply(nil) }
                    }
                },
                disable: { _, reply in
                    DispatchQueue.main.async { self.record("disable"); reply(nil) }
                },
                restore: { _, _, info, _, reply in
                    DispatchQueue.main.async {
                        self.record("restore")
                        if self.restoreError == nil { self.current = info }
                        if self.holdRestore { self.restoreReply = reply; return }
                        reply(self.restoreError)
                        if self.duplicateReplies { reply(self.restoreError) }
                    }
                }
            )
        }
    }

    private func environment(_ helper: Helper, timeout: TimeInterval = 1,
                             unavailable: Bool = false) throws -> (SystemProxyManager, UserDefaults) {
        let suite = "com.clashfx.isolated-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        suites.append((defaults, suite))
        helper.current = original
        let dependencies = SystemProxyDependencies(
            defaults: defaults, helper: { failure in
                if unavailable { failure(); return nil }
                return helper.client
            }, currentPorts: { (7890, 7891) },
            shouldSuspend: { false }, disableRestoreProxy: { false }, filterInterface: { true },
            proxyIgnoreList: { [] }, liveSystemPointsToClashFX: { false }, stageTimeout: timeout
        )
        return (SystemProxyManager(dependencies: dependencies), defaults)
    }

    private func enable(_ manager: SystemProxyManager) {
        let completed = expectation(description: "enable completed")
        completed.assertForOverFulfill = true
        manager.enableProxy { success in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(success)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    private func restore(_ manager: SystemProxyManager, succeeds: Bool) {
        let completed = expectation(description: "restore completed")
        completed.assertForOverFulfill = true
        manager.prepareForTermination()
        manager.restoreForTermination { success in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(success, succeeds)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testRealManagerRestoresPACAndVerifiesBeforeClearingSnapshot() throws {
        let helper = Helper()
        helper.duplicateReplies = true
        let (manager, defaults) = try environment(helper)
        enable(manager)
        XCTAssertTrue(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        restore(manager, succeeds: true)
        XCTAssertEqual(helper.events, ["capture", "enable", "restore", "capture"])
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: helper.current))
        XCTAssertNil(defaults.object(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        XCTAssertFalse(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
    }

    func testQuitWaitsForInFlightEnableAndRejectsNewEnable() throws {
        let helper = Helper()
        helper.holdEnable = true
        let (manager, _) = try environment(helper)
        let started = expectation(description: "in-flight enable")
        helper.onEvent = { if $0 == "enable" { started.fulfill() } }
        let first = expectation(description: "first enable completed")
        manager.enableProxy { XCTAssertTrue($0); first.fulfill() }
        wait(for: [started], timeout: 2)
        manager.prepareForTermination()
        let blocked = expectation(description: "new enable blocked")
        manager.enableProxy { XCTAssertFalse($0); blocked.fulfill() }
        let restored = expectation(description: "restore completed")
        manager.restoreForTermination { XCTAssertTrue($0); restored.fulfill() }
        XCTAssertEqual(helper.events, ["capture", "enable"])
        helper.enableReply?(nil)
        wait(for: [first, blocked, restored], timeout: 2)
        XCTAssertEqual(helper.events, ["capture", "enable", "restore", "capture"])
    }

    func testQuitDuringCaptureDoesNotEnableAfterCaptureCompletes() throws {
        let helper = Helper()
        helper.holdCapture = true
        let (manager, _) = try environment(helper)
        let started = expectation(description: "capture started")
        helper.onEvent = { if $0 == "capture" { started.fulfill() } }
        let enabled = expectation(description: "enable aborted")
        manager.enableProxy { XCTAssertFalse($0); enabled.fulfill() }
        wait(for: [started], timeout: 2)
        helper.onEvent = nil
        manager.prepareForTermination()
        let restored = expectation(description: "restored without enabling")
        manager.restoreForTermination { XCTAssertTrue($0); restored.fulfill() }
        helper.holdCapture = false
        helper.captureReply?(original)
        wait(for: [enabled, restored], timeout: 2)
        XCTAssertEqual(helper.events, ["capture", "restore", "capture"])
    }

    func testReadbackMismatchKeepsSnapshotAndAllowsRetry() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper)
        enable(manager)
        helper.readbackOverride = [SystemProxyOperationPolicy.capturedServiceIDsKey: ["wifi"], "wifi": ["HTTPEnable": 1]]
        restore(manager, succeeds: false)
        XCTAssertTrue(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertTrue(try NSDictionary(dictionary: original).isEqual(to: XCTUnwrap(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))))
        helper.readbackOverride = nil
        manager.resumeAfterCancelledTermination()
        restore(manager, succeeds: true)
        XCTAssertEqual(helper.events, ["capture", "enable", "restore", "capture", "restore", "capture"])
    }

    func testRestoreErrorRetainsOriginalSnapshotForRetry() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper)
        enable(manager)
        helper.restoreError = "simulated permission failure"
        restore(manager, succeeds: false)
        XCTAssertTrue(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertEqual(helper.events, ["capture", "enable", "restore"])
        helper.restoreError = nil
        manager.resumeAfterCancelledTermination()
        restore(manager, succeeds: true)
    }

    func testRestoreTimeoutAndLateCallbackCannotClearSnapshot() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper, timeout: 0.25)
        enable(manager)
        helper.holdRestore = true
        restore(manager, succeeds: false)
        helper.restoreReply?(nil)
        XCTAssertTrue(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        helper.holdRestore = false
        manager.resumeAfterCancelledTermination()
        restore(manager, succeeds: true)
        XCTAssertEqual(helper.events, ["capture", "enable", "restore", "restore", "capture"])
    }

    func testCaptureTimeoutAndLateCallbackNeverEnableOrSaveSnapshot() throws {
        let helper = Helper()
        helper.holdCapture = true
        let (manager, defaults) = try environment(helper, timeout: 0.25)
        let failed = expectation(description: "capture timed out")
        manager.enableProxy { XCTAssertFalse($0); failed.fulfill() }
        wait(for: [failed], timeout: 2)
        helper.captureReply?(original)
        // A following operation is a barrier through the production operation queue.
        manager.prepareForTermination()
        let blocked = expectation(description: "late enable blocked")
        manager.enableProxy { XCTAssertFalse($0); blocked.fulfill() }
        wait(for: [blocked], timeout: 2)
        XCTAssertEqual(helper.events, ["capture"])
        XCTAssertNil(defaults.object(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
    }

    func testUnavailableHelperSettlesOnceWithoutSavingOrEnabling() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper, unavailable: true)
        let failed = expectation(description: "unavailable helper")
        manager.enableProxy { XCTAssertFalse($0); failed.fulfill() }
        wait(for: [failed], timeout: 2)
        XCTAssertTrue(helper.events.isEmpty)
        XCTAssertNil(defaults.object(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
    }

    func testCaptureErrorDoesNotOverwriteOriginalOrEnable() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper)
        helper.readbackOverride = [SystemProxyOperationPolicy.captureErrorKey: "simulated read failure"]
        let failed = expectation(description: "capture rejected")
        manager.enableProxy { XCTAssertFalse($0); failed.fulfill() }
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(helper.events, ["capture"])
        XCTAssertNil(defaults.object(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
    }

    func testCancelledQuitCanEnableAgainWithoutReplacingOriginalSnapshot() throws {
        let helper = Helper()
        let (manager, _) = try environment(helper)
        enable(manager)
        manager.prepareForTermination()
        let blocked = expectation(description: "enable blocked during quit")
        manager.enableProxy { XCTAssertFalse($0); blocked.fulfill() }
        wait(for: [blocked], timeout: 2)
        manager.resumeAfterCancelledTermination()
        enable(manager)
        restore(manager, succeeds: true)
        XCTAssertEqual(helper.events, ["capture", "enable", "enable", "restore", "capture"])
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: helper.current))
    }
}

final class IsolatedSelectorExecutionTests: XCTestCase {
    /// Deadlines are virtual milliseconds. No real network or wall-clock waits.
    private final class Transport {
        struct Pending { let deadline: Int; let delay: Int; let reply: (Int) -> Void }
        let queue = DispatchQueue(label: "com.clashfx.tests.virtual-transport")
        var now = 0
        var peak = 0
        var pending = [Pending]()
        var requested = [String]()
        var launchedAt = [String: Int]()
        var results = [String: Int]()
        var cancelled = false
        var duplicateReplies = false
        var timing: (SelectorBenchmarkPlan.Target) -> (Int, Int) = { _ in (500, 120) }

        func request(_ target: SelectorBenchmarkPlan.Target, reply: @escaping (Int) -> Void) {
            requested.append(target.key.proxyName)
            launchedAt[target.key.proxyName] = now
            let (duration, delay) = timing(target)
            pending.append(Pending(deadline: now + duration, delay: delay, reply: reply))
            peak = max(peak, pending.count)
        }

        func advanceOneDeadline() -> Bool {
            queue.sync {
                guard let deadline = pending.map(\.deadline).min() else { return false }
                now = deadline
                let ready = pending.filter { $0.deadline == deadline }
                pending.removeAll { $0.deadline == deadline }
                for event in ready {
                    event.reply(event.delay)
                    if duplicateReplies { event.reply(event.delay) }
                }
                return true
            }
        }

        func drain() {
            // Each sync first drains the executor callbacks queued by the prior step.
            for _ in 0 ..< 1000 {
                if !advanceOneDeadline() { return }
            }
            XCTFail("executor did not settle")
        }
    }

    private func plan(count: Int) -> SelectorBenchmarkPlan {
        let names = (0 ..< count).map { "Node \($0)" }
        var proxies: [String: Any] = ["Selector": ["name": "Selector", "type": "Selector", "all": names, "now": names.first ?? "", "history": []]]
        for name in names {
            proxies[name] = ["name": name, "type": "Vless", "history": []]
        }
        let snapshot = ClashProxyResp(try! JSONSerialization.data(withJSONObject: ["proxies": proxies]))
        return SelectorBenchmarkPlan.make(selector: snapshot.proxiesMap["Selector"]!, snapshot: snapshot,
                                          benchmarkURL: "https://example.test/virtual", timeout: 5000)
    }

    private func start(_ plan: SelectorBenchmarkPlan, transport: Transport,
                       reused: [SelectorBenchmarkMeasurementKey: Int] = [:]) -> XCTestExpectation {
        let complete = expectation(description: "executor completes once")
        complete.assertForOverFulfill = true
        // Start on the injected serial queue; all fake transport state stays on it.
        transport.queue.async {
            SelectorBenchmarkExecutor.run(
                plan: plan, reusing: reused, isCancelled: { transport.cancelled },
                schedulingQueue: transport.queue,
                request: { transport.request($0, reply: $1) },
                result: { transport.results[$0.key.proxyName] = $1 },
                completion: { XCTAssertTrue(Thread.isMainThread); complete.fulfill() }
            )
        }
        transport.queue.sync {} // let run enqueue the runner's start
        transport.queue.sync {} // let the runner fill its initial slots
        return complete
    }

    func testHealthyBatchUsesBoundedRollingConcurrencyAndIgnoresDuplicateReplies() {
        let transport = Transport()
        transport.duplicateReplies = true
        let complete = start(plan(count: 24), transport: transport)
        transport.drain()
        wait(for: [complete], timeout: 2)
        XCTAssertEqual(transport.now, 1500)
        XCTAssertEqual(transport.peak, 12)
        XCTAssertEqual(transport.requested.count, 24)
        XCTAssertEqual(Set(transport.requested).count, 24)
        XCTAssertEqual(transport.results.count, 24)
    }

    func testAllTimeoutsHaveNoRetryTailOrConcurrencyCollapse() {
        let transport = Transport()
        transport.timing = { ($0.key.timeout, 0) }
        let complete = start(plan(count: 24), transport: transport)
        transport.drain()
        wait(for: [complete], timeout: 2)
        XCTAssertEqual(transport.now, 15000) // exactly three windows, not retry windows
        XCTAssertEqual(transport.peak, 8)
        XCTAssertEqual(transport.requested.count, 24)
        XCTAssertEqual(transport.results.count, 24)
        XCTAssertTrue(transport.results.values.allSatisfy { $0 == 0 })
    }

    func testOneSlowNodeDoesNotBlockOtherRequestsFromStarting() {
        let transport = Transport()
        transport.timing = { $0.key.proxyName == "Node 0" ? (5000, 0) : (500, 120) }
        let complete = start(plan(count: 24), transport: transport)
        transport.drain()
        wait(for: [complete], timeout: 2)
        XCTAssertEqual(transport.now, 5000)
        XCTAssertLessThan(transport.launchedAt.values.max() ?? 5000, 5000)
        XCTAssertEqual(transport.requested.count, 24)
        XCTAssertEqual(transport.results.count, 24)
    }

    func testReusedMeasurementsIssueNoRequests() {
        let transport = Transport()
        let plan = plan(count: 24)
        let measurements = Dictionary(uniqueKeysWithValues: plan.targets.map { ($0.key, 123) })
        let complete = start(plan, transport: transport, reused: measurements)
        transport.drain()
        wait(for: [complete], timeout: 2)
        XCTAssertEqual(transport.now, 0)
        XCTAssertTrue(transport.requested.isEmpty)
        XCTAssertEqual(transport.results.count, 24)
    }

    func testCancellationSuppressesLateResultsAndQueuedRequests() {
        let transport = Transport()
        let complete = start(plan(count: 24), transport: transport)
        transport.queue.sync { transport.cancelled = true }
        transport.drain()
        wait(for: [complete], timeout: 2)
        XCTAssertEqual(transport.requested.count, 8)
        XCTAssertTrue(transport.results.isEmpty)
    }

    func testInvalidReuseStillRequestsAndEmptyPlanCompletes() {
        for count in [0, 2] {
            let transport = Transport()
            let plan = plan(count: count)
            let measurements = Dictionary(uniqueKeysWithValues: plan.targets.map { ($0.key, 0) })
            let complete = start(plan, transport: transport, reused: measurements)
            transport.drain()
            wait(for: [complete], timeout: 2)
            XCTAssertEqual(transport.requested.count, count)
            XCTAssertEqual(transport.results.count, count)
        }
    }
}

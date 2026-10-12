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
        var enableError: String?
        var disableRestoreProxy = false
        var restoreArguments: (httpPort: Int32, socksPort: Int32, filterInterface: Bool)?
        var lastRestoreSnapshot: [String: Any]?
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
                        reply(self.enableError)
                        if self.duplicateReplies { reply(self.enableError) }
                    }
                },
                disable: { _, reply in
                    DispatchQueue.main.async { self.record("disable"); reply(nil) }
                },
                restore: { port, socks, info, filterInterface, reply in
                    DispatchQueue.main.async {
                        self.record("restore")
                        self.restoreArguments = (port, socks, filterInterface)
                        self.lastRestoreSnapshot = info
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
                             unavailable: Bool = false,
                             liveSystemPointsToClashFX: Bool = false,
                             canControlRuntime: @escaping () -> Bool = { true },
                             shouldSuspend: @escaping () -> Bool = { false }) throws -> (SystemProxyManager, UserDefaults) {
        let suite = "com.clashfx.isolated-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        suites.append((defaults, suite))
        helper.current = original
        let dependencies = SystemProxyDependencies(
            defaults: defaults, helper: { failure in
                if unavailable { failure(); return nil }
                return helper.client
            }, currentPorts: { (7890, 7891) },
            shouldSuspend: shouldSuspend, disableRestoreProxy: { helper.disableRestoreProxy }, filterInterface: { true },
            proxyIgnoreList: { [] }, liveSystemPointsToClashFX: { liveSystemPointsToClashFX }, stageTimeout: timeout,
            canControlRuntime: canControlRuntime
        )
        return (SystemProxyManager(dependencies: dependencies), defaults)
    }

    func testActiveReadbackRejectsDisabledResidualPortsForeignHostsAndPACOverrides() {
        let active: [String: Any] = [
            "HTTPEnable": 1, "HTTPSEnable": 1, "SOCKSEnable": 1,
            "HTTPPort": 7890, "HTTPSPort": 7890, "SOCKSPort": 7891,
            "HTTPProxy": "127.0.0.1", "HTTPSProxy": "127.0.0.1", "SOCKSProxy": "127.0.0.1"
        ]
        XCTAssertTrue(SystemProxyOperationPolicy.matchesActiveSystemProxy(active, httpPort: 7890, socksPort: 7891))
        for (key, value) in [("HTTPEnable", 0 as Any), ("HTTPSEnable", 0 as Any),
                             ("SOCKSEnable", 0 as Any), ("HTTPSProxy", "proxy.example.test" as Any),
                             ("ProxyAutoConfigEnable", 1 as Any), ("ProxyAutoDiscoveryEnable", 1 as Any)] {
            var altered = active
            altered[key] = value
            XCTAssertFalse(SystemProxyOperationPolicy.matchesActiveSystemProxy(altered, httpPort: 7890, socksPort: 7891), key)
        }
        XCTAssertFalse(SystemProxyOperationPolicy.matchesActiveSystemProxy(active, httpPort: 7088, socksPort: 7088))
    }

    func testRejectedRuntimeCannotCaptureEnableDisableOrChangeSavedSnapshot() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper, canControlRuntime: { false })
        defaults.set(original, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        defaults.set(true, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)
        let capture = try captureCheckpoint(manager)
        if case .success = capture { XCTFail("Unowned runtime captured a checkpoint") }
        let enabled = expectation(description: "unowned enable rejected")
        let disabled = expectation(description: "unowned disable rejected")
        manager.enableProxy { success in XCTAssertFalse(success); enabled.fulfill() }
        manager.disableProxy(forceDisable: true, result: { success in XCTAssertFalse(success); disabled.fulfill() })
        wait(for: [enabled, disabled], timeout: 2)
        XCTAssertTrue(helper.events.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertEqual(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey) as NSDictionary?, original as NSDictionary)
    }

    func testOwnershipLostDuringCaptureDoesNotEnableOrSaveSnapshot() throws {
        let helper = Helper()
        helper.holdCapture = true
        var ownsRuntime = true
        let (manager, defaults) = try environment(helper, canControlRuntime: { ownsRuntime })
        let captured = expectation(description: "capture started")
        let finished = expectation(description: "ownership loss finishes request")
        helper.onEvent = { event in
            if event == "capture" { captured.fulfill() }
        }
        manager.enableProxy { success in XCTAssertFalse(success); finished.fulfill() }
        wait(for: [captured], timeout: 2)
        ownsRuntime = false
        helper.captureReply?(helper.current)
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(helper.events, ["capture"])
        XCTAssertFalse(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertNil(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
    }

    func testPauseDuringCapturePreventsLateEnable() throws {
        let helper = Helper()
        helper.holdCapture = true
        var paused = false
        let (manager, _) = try environment(helper, shouldSuspend: { paused })
        let captured = expectation(description: "capture started")
        let finished = expectation(description: "pause finishes request")
        helper.onEvent = { event in if event == "capture" { captured.fulfill() } }
        manager.enableProxy { success in XCTAssertFalse(success); finished.fulfill() }
        wait(for: [captured], timeout: 2)
        paused = true
        helper.captureReply?(helper.current)
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(helper.events, ["capture"])
    }

    func testAutomaticEnableRechecksEligibilityAfterCaptureBeforeSavingOrWriting() throws {
        let helper = Helper()
        helper.holdCapture = true
        let (manager, defaults) = try environment(helper)
        var isCurrent = true
        var eligibilityChecks = 0
        let captured = expectation(description: "automatic capture started")
        let finished = expectation(description: "stale automatic request rejected")
        helper.onEvent = { if $0 == "capture" { captured.fulfill() } }

        manager.enableProxy(port: 7890, socksPort: 7891, isCurrent: {
            XCTAssertTrue(Thread.isMainThread)
            eligibilityChecks += 1
            return isCurrent
        }, complete: { success in
            XCTAssertFalse(success)
            finished.fulfill()
        })
        wait(for: [captured], timeout: 2)
        let finishCapture = helper.captureReply
        isCurrent = false
        helper.holdCapture = false
        finishCapture?(original)

        wait(for: [finished], timeout: 2)
        XCTAssertEqual(eligibilityChecks, 2)
        XCTAssertEqual(helper.events, ["capture"])
        XCTAssertNil(defaults.object(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        XCTAssertFalse(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
    }

    func testQueuedAutomaticEnableIsVetoedBeforeLockCheckpointRuns() throws {
        let helper = Helper()
        helper.holdCapture = true
        let (manager, _) = try environment(helper)
        let firstCaptureStarted = expectation(description: "explicit enable capture started")
        helper.onEvent = { if $0 == "capture" { firstCaptureStarted.fulfill() } }
        let explicitEnableFinished = expectation(description: "explicit enable finished")
        manager.enableProxy { success in
            XCTAssertTrue(success)
            explicitEnableFinished.fulfill()
        }
        wait(for: [firstCaptureStarted], timeout: 2)
        let finishExplicitCapture = helper.captureReply
        helper.onEvent = nil

        let capturedProxySelectionGeneration: UInt64 = 4
        var proxySelectionGeneration = capturedProxySelectionGeneration
        var lockIsActive = false
        let automaticEnableFinished = expectation(description: "queued automatic enable rejected")
        manager.enableProxy(port: 7892, socksPort: 7893, isCurrent: {
            XCTAssertTrue(Thread.isMainThread)
            return proxySelectionGeneration == capturedProxySelectionGeneration && !lockIsActive
        }, complete: { success in
            XCTAssertFalse(success)
            automaticEnableFinished.fulfill()
        })

        let checkpointFinished = expectation(description: "lock checkpoint captured after queued enable")
        manager.captureCheckpoint { result in
            guard case .success = result else {
                XCTFail("Lock checkpoint capture failed")
                checkpointFinished.fulfill()
                return
            }
            checkpointFinished.fulfill()
        }
        proxySelectionGeneration += 1
        lockIsActive = true
        helper.holdCapture = false
        finishExplicitCapture?(original)

        wait(for: [explicitEnableFinished, automaticEnableFinished, checkpointFinished], timeout: 2)
        XCTAssertEqual(helper.events, ["capture", "enable", "capture"])
    }

    func testTimedOutHelperWriteQuarantinesCheckpointAndLaterWritesUntilActualReply() throws {
        let helper = Helper()
        helper.holdEnable = true
        let (manager, _) = try environment(helper, timeout: 0.03)
        let timedOut = expectation(description: "enable caller times out")
        timedOut.assertForOverFulfill = true
        manager.enableProxy { success in XCTAssertFalse(success); timedOut.fulfill() }
        wait(for: [timedOut], timeout: 2)
        XCTAssertEqual(helper.events, ["capture", "enable"])
        if case .success = try captureCheckpoint(manager) { XCTFail("Unknown helper write allowed a lock checkpoint") }
        let rejected = expectation(description: "following disable does not overlap unknown write")
        manager.disableProxy(forceDisable: true, result: { success in XCTAssertFalse(success); rejected.fulfill() })
        wait(for: [rejected], timeout: 2)
        XCTAssertEqual(helper.events, ["capture", "enable"])
        helper.enableReply?(nil)
        if case .failure = try captureCheckpoint(manager) { XCTFail("Actual helper reply should release quarantine") }
        XCTAssertEqual(helper.events, ["capture", "enable", "capture"])
    }

    private func captureCheckpoint(_ manager: SystemProxyManager) throws -> Result<SystemProxyCheckpoint, Error> {
        let completed = expectation(description: "checkpoint capture completed")
        completed.assertForOverFulfill = true
        var result: Result<SystemProxyCheckpoint, Error>?
        manager.captureCheckpoint { value in
            XCTAssertTrue(Thread.isMainThread)
            result = value
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        return try XCTUnwrap(result)
    }

    private func restoreCheckpoint(
        _ checkpoint: SystemProxyCheckpoint,
        with manager: SystemProxyManager,
        isCurrent: @escaping () -> Bool = { true }
    ) -> Bool {
        let completed = expectation(description: "checkpoint restore completed")
        completed.assertForOverFulfill = true
        var succeeded = false
        manager.restoreCheckpoint(checkpoint, isCurrent: isCurrent) { value in
            XCTAssertTrue(Thread.isMainThread)
            succeeded = value
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        return succeeded
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

    private var matchingLoopbackProxy: [String: Any] {
        ["HTTPEnable": 1, "HTTPSEnable": 1, "SOCKSEnable": 1,
         "HTTPProxy": "127.0.0.1", "HTTPSProxy": "127.0.0.1", "SOCKSProxy": "127.0.0.1",
         "HTTPPort": 7890, "HTTPSPort": 7890, "SOCKSPort": 7891]
    }

    func testInactiveAdapterProxyDoesNotBlockEnableAndIsRestoredExactly() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper)
        let before: [String: Any] = [
            SystemProxyOperationPolicy.capturedServiceIDsKey: ["wifi", "disconnected-usb"],
            "wifi": ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                     "HTTPProxy": "127.0.0.1", "HTTPPort": 7892],
            "disconnected-usb": matchingLoopbackProxy
        ]
        helper.current = before
        enable(manager)
        XCTAssertTrue(try NSDictionary(dictionary: before).isEqual(
            to: XCTUnwrap(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        ))
        restore(manager, succeeds: true)
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: helper.current))
        XCTAssertEqual(helper.events, ["capture", "enable", "restore", "capture"])
    }

    func testLiveOwnedProxyWithoutOriginalSnapshotIsStillRejected() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper, liveSystemPointsToClashFX: true)
        helper.current = [SystemProxyOperationPolicy.capturedServiceIDsKey: ["wifi"],
                          "wifi": matchingLoopbackProxy]
        let failed = expectation(description: "live owned capture rejected")
        manager.enableProxy { XCTAssertFalse($0); failed.fulfill() }
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(helper.events, ["capture"])
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

    func testCheckpointCapturePreservesExistingSavedSnapshotAndValidity() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper)
        let previousSaved: [String: Any] = [
            "legacy-service": ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://saved.test/config.pac"]
        ]
        defaults.set(previousSaved, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        defaults.set(false, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)

        let result = try captureCheckpoint(manager)
        let checkpoint = try result.get()

        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: checkpoint.liveSnapshot))
        XCTAssertTrue(NSDictionary(dictionary: previousSaved).isEqual(to: checkpoint.savedSnapshot))
        XCTAssertFalse(checkpoint.savedSnapshotValid)
        XCTAssertEqual(checkpoint.httpPort, 7890)
        XCTAssertEqual(checkpoint.socksPort, 7891)
        XCTAssertTrue(NSDictionary(dictionary: previousSaved).isEqual(
            to: try XCTUnwrap(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        ))
        XCTAssertFalse(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertEqual(helper.events, ["capture"])
    }

    func testPartialEnableFailureRestoresCheckpointIncludingPACAndSavedValidity() throws {
        let helper = Helper()
        helper.duplicateReplies = true
        let (manager, defaults) = try environment(helper)
        let previousSaved: [String: Any] = [
            "legacy-service": ["HTTPEnable": 0, "ProxyAutoConfigEnable": 1,
                               "ProxyAutoConfigURLString": "https://saved.test/config.pac"]
        ]
        defaults.set(previousSaved, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        defaults.set(false, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)
        let checkpoint = try captureCheckpoint(manager).get()

        helper.enableError = "simulated partial enable failure"
        let enableFailed = expectation(description: "partial enable failed")
        manager.enableProxy { success in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(success)
            enableFailed.fulfill()
        }
        wait(for: [enableFailed], timeout: 2)
        XCTAssertTrue(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertFalse(NSDictionary(dictionary: original).isEqual(to: helper.current))

        helper.disableRestoreProxy = true
        XCTAssertTrue(restoreCheckpoint(checkpoint, with: manager))

        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: helper.current))
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: try XCTUnwrap(helper.lastRestoreSnapshot)))
        XCTAssertTrue(NSDictionary(dictionary: previousSaved).isEqual(
            to: try XCTUnwrap(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        ))
        XCTAssertFalse(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertEqual(helper.restoreArguments?.httpPort, 7890)
        XCTAssertEqual(helper.restoreArguments?.socksPort, 7891)
        XCTAssertEqual(helper.restoreArguments?.filterInterface, false)
        XCTAssertEqual(helper.events, ["capture", "capture", "enable", "restore", "capture"])
    }

    func testCheckpointCaptureRejectsCaptureErrorsAndInvalidPropertyLists() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper)
        let previousSaved: [String: Any] = ["saved": ["HTTPEnable": 0]]
        defaults.set(previousSaved, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        defaults.set(true, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)

        helper.readbackOverride = [SystemProxyOperationPolicy.captureErrorKey: "simulated capture error"]
        guard case .failure = try captureCheckpoint(manager) else {
            return XCTFail("capture error must reject checkpoint")
        }
        helper.readbackOverride = ["wifi": ["unsupported": NSObject()]]
        guard case .failure = try captureCheckpoint(manager) else {
            return XCTFail("non-property-list value must reject checkpoint")
        }

        XCTAssertTrue(NSDictionary(dictionary: previousSaved).isEqual(
            to: try XCTUnwrap(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        ))
        XCTAssertTrue(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertEqual(helper.events, ["capture", "capture"])
    }

    func testCheckpointRestoreTimeoutAndLateReplySettleOnlyOnce() throws {
        let helper = Helper()
        helper.holdRestore = true
        let (manager, defaults) = try environment(helper, timeout: 0.2)
        let checkpoint = try captureCheckpoint(manager).get()
        let saved: [String: Any] = ["saved": ["HTTPEnable": 1]]
        defaults.set(saved, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        defaults.set(true, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)

        XCTAssertFalse(restoreCheckpoint(checkpoint, with: manager))
        helper.restoreReply?(nil)

        XCTAssertTrue(NSDictionary(dictionary: saved).isEqual(
            to: try XCTUnwrap(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        ))
        XCTAssertTrue(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertEqual(helper.events, ["capture", "restore"])
    }

    func testCheckpointCaptureTimeoutAndLateReplyDoNotChangeSavedDefaults() throws {
        let helper = Helper()
        helper.holdCapture = true
        let (manager, defaults) = try environment(helper, timeout: 0.2)
        let saved: [String: Any] = ["saved": ["ProxyAutoConfigEnable": 1]]
        defaults.set(saved, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        defaults.set(false, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)

        guard case .failure = try captureCheckpoint(manager) else {
            return XCTFail("checkpoint capture must time out")
        }
        helper.captureReply?(original)

        XCTAssertTrue(NSDictionary(dictionary: saved).isEqual(
            to: try XCTUnwrap(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        ))
        XCTAssertFalse(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertEqual(helper.events, ["capture"])
    }

    func testCheckpointRestoreMismatchDoesNotRestoreSavedDefaults() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper)
        defaults.set(original, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        defaults.set(true, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)
        let checkpoint = try captureCheckpoint(manager).get()
        let changedSaved: [String: Any] = ["changed": ["HTTPEnable": 0]]
        defaults.set(changedSaved, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        defaults.set(false, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)
        helper.readbackOverride = [
            SystemProxyOperationPolicy.capturedServiceIDsKey: ["wifi"],
            "wifi": ["HTTPEnable": 1]
        ]

        XCTAssertFalse(restoreCheckpoint(checkpoint, with: manager))

        XCTAssertTrue(NSDictionary(dictionary: changedSaved).isEqual(
            to: try XCTUnwrap(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        ))
        XCTAssertFalse(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
        XCTAssertEqual(helper.events, ["capture", "restore", "capture"])
    }

    func testStaleCheckpointRestoreDoesNotInvokeHelper() throws {
        let helper = Helper()
        let (manager, defaults) = try environment(helper)
        let saved: [String: Any] = ["saved": ["HTTPEnable": 0]]
        defaults.set(saved, forKey: SystemProxyOperationPolicy.savedSnapshotKey)
        defaults.set(true, forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey)
        let checkpoint = try captureCheckpoint(manager).get()
        var tokenWasReadOnMain = false

        XCTAssertFalse(restoreCheckpoint(checkpoint, with: manager, isCurrent: {
            tokenWasReadOnMain = Thread.isMainThread
            return false
        }))

        XCTAssertTrue(tokenWasReadOnMain)
        XCTAssertEqual(helper.events, ["capture"])
        XCTAssertTrue(NSDictionary(dictionary: saved).isEqual(
            to: try XCTUnwrap(defaults.dictionary(forKey: SystemProxyOperationPolicy.savedSnapshotKey))
        ))
        XCTAssertTrue(defaults.bool(forKey: SystemProxyOperationPolicy.savedSnapshotValidityKey))
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
        XCTAssertEqual(transport.peak, 10)
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
        XCTAssertEqual(transport.peak, 10)
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
        XCTAssertEqual(transport.requested.count, 10)
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

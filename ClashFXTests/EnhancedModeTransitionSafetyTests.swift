import XCTest

final class EnhancedModeTransitionSafetyTests: XCTestCase {
    func testProtectedAndLegacyCoreExecutablesBothPassOwnershipPathCheck() {
        let bundle = "/Applications/ClashFX.app/Contents/Resources/mihomo_core"
        let approved = "/Library/PrivilegedHelperTools/com.clashfx.app.Helper.mihomo_core"
        for actual in [bundle, approved] {
            XCTAssertTrue(EnhancedModeDNSReadinessPolicy.matchesExpectedCoreBinary(
                actual, bundlePath: bundle, approvedPath: approved
            ))
        }
        let rejected: [String?] = [nil, "", "/tmp/mihomo_core", approved + ".other"]
        for actual in rejected {
            XCTAssertFalse(EnhancedModeDNSReadinessPolicy.matchesExpectedCoreBinary(
                actual, bundlePath: bundle, approvedPath: approved
            ))
        }
    }

    private enum RequestOutcome: Equatable {
        case reply
        case xpcFailure
        case timedOut
    }

    func testUnansweredStartRequestSettlesAtItsDeadline() {
        let settled = expectation(description: "request timeout settles")
        let queue = DispatchQueue(label: "EnhancedModeTransitionSafetyTests.timeout")
        var outcome: RequestOutcome?
        let settlement = ManagedOperationSettlement<RequestOutcome> { result in
            outcome = result
            settled.fulfill()
        }

        settlement.scheduleTimeout(after: 0.01, queue: queue) { .timedOut }

        wait(for: [settled], timeout: 1)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(settlement.finish(.reply))
    }

    func testXPCFailureSettlesOnce() {
        var outcomes = [RequestOutcome]()
        let settlement = ManagedOperationSettlement<RequestOutcome> { outcomes.append($0) }

        XCTAssertTrue(settlement.finish(.xpcFailure))
        XCTAssertFalse(settlement.finish(.reply))
        XCTAssertEqual(outcomes, [.xpcFailure])
    }

    func testLateStartSuccessCannotReplaceTimedOutSettlement() {
        let settled = expectation(description: "request timeout settles before late reply")
        let queue = DispatchQueue(label: "EnhancedModeTransitionSafetyTests.lateReply")
        var outcomes = [RequestOutcome]()
        let settlement = ManagedOperationSettlement<RequestOutcome> { result in
            outcomes.append(result)
            settled.fulfill()
        }

        settlement.scheduleTimeout(after: 0.01, queue: queue) { .timedOut }

        wait(for: [settled], timeout: 1)
        XCTAssertFalse(settlement.finish(.reply))
        XCTAssertEqual(outcomes, [.timedOut])
    }

    func testUnknownStartupCleanupNeverAuthorizesBuiltInHandoff() {
        XCTAssertTrue(StartupCoreHandoffPolicy.mayStartBuiltInCore(after: .confirmedAbsent))
        XCTAssertTrue(StartupCoreHandoffPolicy.mayStartBuiltInCore(after: .confirmedStopped))
        XCTAssertFalse(StartupCoreHandoffPolicy.mayStartBuiltInCore(after: .unknown))
        XCTAssertFalse(StartupCoreHandoffPolicy.mayStartBuiltInCore(after: .failed("stop unconfirmed")))
    }

    func testListenerPortArraysAreIgnoredUntilStatusIsKnown() {
        let expected = EnhancedModeDNSReadinessPolicy.ExpectedListeners(
            expectedConfigPath: "/tmp/.enhanced_config.current.yaml",
            proxyPorts: [7890],
            apiPort: 9090,
            port: 53
        )
        let base = (
            helperIsRunning: true,
            processID: 123,
            helperConfigPath: "/tmp/.enhanced_config.current.yaml",
            tcpListenPorts: [53, 7890, 9090],
            udpListenPorts: [53]
        )
        let unknown = EnhancedModeDNSReadinessPolicy.HelperListenerSnapshot(
            helperIsRunning: base.helperIsRunning,
            processID: base.processID,
            helperConfigPath: base.helperConfigPath,
            tcpListenPorts: base.tcpListenPorts,
            udpListenPorts: base.udpListenPorts,
            tcpListenPortsState: .unknown,
            udpListenPortsState: .unknown
        )
        let known = EnhancedModeDNSReadinessPolicy.HelperListenerSnapshot(
            helperIsRunning: base.helperIsRunning,
            processID: base.processID,
            helperConfigPath: base.helperConfigPath,
            tcpListenPorts: base.tcpListenPorts,
            udpListenPorts: base.udpListenPorts,
            tcpListenPortsState: .known,
            udpListenPortsState: .known
        )

        XCTAssertFalse(EnhancedModeDNSReadinessPolicy.currentLaunchOwnsDNSListeners(
            observed: unknown,
            expected: expected
        ))
        XCTAssertTrue(EnhancedModeDNSReadinessPolicy.currentLaunchOwnsDNSListeners(
            observed: known,
            expected: expected
        ))
    }

    func testOwnershipAndStartupCleanupFailuresLeaveTheToggleRetryable() {
        XCTAssertTrue(EnhancedModeCleanupPolicy.isRequired(
            enhancedModeActive: false,
            ownershipBlocked: true
        ))
        XCTAssertFalse(EnhancedModeCleanupPolicy.isRequired(
            enhancedModeActive: false,
            ownershipBlocked: false
        ))
        XCTAssertTrue(EnhancedModeOwnershipPolicy.matchesExpectedLaunch(
            running: true,
            observedConfigPath: "/tmp/.enhanced_config.current.yaml",
            observedLaunchID: "helper-launch-17",
            expectedConfigPath: "/tmp/.enhanced_config.current.yaml",
            expectedLaunchID: "helper-launch-17"
        ))
        XCTAssertFalse(EnhancedModeOwnershipPolicy.matchesExpectedLaunch(
            running: true,
            observedConfigPath: "/tmp/.enhanced_config.current.yaml",
            observedLaunchID: "helper-launch-newer",
            expectedConfigPath: "/tmp/.enhanced_config.current.yaml",
            expectedLaunchID: "helper-launch-17"
        ))
        XCTAssertTrue(EnhancedModeMenuAvailabilityPolicy.shouldEnableToggle(
            isTransitioning: false,
            isTerminating: false,
            isRestarting: false,
            coreIsRunning: false,
            ownershipRetryAvailable: true,
            startupCleanupRetryAvailable: false,
            builtInResumeRetryAvailable: false
        ))
        XCTAssertTrue(EnhancedModeMenuAvailabilityPolicy.shouldEnableToggle(
            isTransitioning: false,
            isTerminating: false,
            isRestarting: false,
            coreIsRunning: false,
            ownershipRetryAvailable: false,
            startupCleanupRetryAvailable: true,
            builtInResumeRetryAvailable: false
        ))
        XCTAssertFalse(EnhancedModeMenuAvailabilityPolicy.shouldEnableToggle(
            isTransitioning: true,
            isTerminating: false,
            isRestarting: false,
            coreIsRunning: false,
            ownershipRetryAvailable: true,
            startupCleanupRetryAvailable: true,
            builtInResumeRetryAvailable: false
        ))
    }

    func testSustainedAPIFailureHasAnAttemptAndTimeCeilingDuringFreshTraffic() {
        XCTAssertFalse(EnhancedModeRuntimeRecoveryPolicy.shouldRecover(
            from: .apiUnavailable,
            trafficIsFlowing: true,
            sustainedAPIFailureCount: 5,
            sustainedAPIFailureDuration: 75,
            apiFailureAttemptLimit: 6,
            apiFailureDeadline: 90
        ))
        XCTAssertTrue(EnhancedModeRuntimeRecoveryPolicy.shouldRecover(
            from: .apiUnavailable,
            trafficIsFlowing: true,
            sustainedAPIFailureCount: 6,
            sustainedAPIFailureDuration: 75,
            apiFailureAttemptLimit: 6,
            apiFailureDeadline: 90
        ))
        XCTAssertTrue(EnhancedModeRuntimeRecoveryPolicy.shouldRecover(
            from: .apiUnavailable,
            trafficIsFlowing: true,
            sustainedAPIFailureCount: 2,
            sustainedAPIFailureDuration: 90,
            apiFailureAttemptLimit: 6,
            apiFailureDeadline: 90
        ))
        // A healthy API check resets the production counters to zero.
        XCTAssertFalse(EnhancedModeRuntimeRecoveryPolicy.shouldRecover(
            from: .apiUnavailable,
            trafficIsFlowing: true,
            sustainedAPIFailureCount: 0,
            sustainedAPIFailureDuration: 0,
            apiFailureAttemptLimit: 6,
            apiFailureDeadline: 90
        ))
    }

    func testFailedLaunchClearsSwitchingStateAndLaunchIdentity() {
        let lifecycle = EnhancedModeLifecycleCoordinator()
        let generation = lifecycle.beginLaunch()
        let launchID = lifecycle.beginLaunchAttempt()

        lifecycle.finishFailedLaunch(generation: generation, launchID: launchID)

        XCTAssertFalse(lifecycle.isTransitionInProgress)
        XCTAssertNil(lifecycle.launchID)
    }
}

final class ClaudeProxyLockTransactionTests: XCTestCase {
    private final class Environment {
        var current = true
        var savedLock = false
        var runtime = "old"
        var proxy = "old"
        var events: [String] = []
        var runtimeError: String?
        var proxyError: String?
        var restoreRuntimeError: String?
        var restoreProxyError: String?
        var heldProxyReply: ((String?) -> Void)?
        var heldRuntimeReply: ((String?) -> Void)?
        var holdProxy = false
        var holdRuntime = false
        var duplicateReplies = false
        var completions = 0
        var failure: ClaudeProxyLockTransaction.Failure?

        func makeTransaction(finished: @escaping () -> Void) -> ClaudeProxyLockTransaction {
            ClaudeProxyLockTransaction(dependencies: .init(
                isCurrent: { self.current },
                applyRuntime: { reply in
                    self.events.append("apply runtime")
                    self.runtime = "new"
                    if self.holdRuntime { self.heldRuntimeReply = reply; return }
                    reply(self.runtimeError)
                    if self.duplicateReplies { reply(nil) }
                },
                applySystemProxy: { reply in
                    self.events.append("apply proxy")
                    self.proxy = "new"
                    if self.holdProxy { self.heldProxyReply = reply; return }
                    reply(self.proxyError)
                    if self.duplicateReplies { reply(nil) }
                },
                prepareRollback: { self.events.append("prepare rollback") },
                restoreRuntime: { reply in
                    self.events.append("restore runtime")
                    if self.restoreRuntimeError == nil { self.runtime = "old" }
                    reply(self.restoreRuntimeError)
                    if self.duplicateReplies { reply(nil) }
                },
                restoreSystemProxy: { reply in
                    self.events.append("restore proxy")
                    if self.restoreProxyError == nil { self.proxy = "old" }
                    reply(self.restoreProxyError)
                    if self.duplicateReplies { reply(nil) }
                },
                commit: { self.events.append("commit"); self.savedLock = true },
                finished: { failure in
                    XCTAssertTrue(Thread.isMainThread)
                    self.completions += 1
                    self.failure = failure
                    finished()
                }
            ))
        }
    }

    private func execute(_ environment: Environment) {
        let done = expectation(description: "lock transaction settled")
        done.assertForOverFulfill = true
        let transaction = environment.makeTransaction { done.fulfill() }
        transaction.start()
        wait(for: [done], timeout: 2)
        withExtendedLifetime(transaction) {}
        XCTAssertEqual(environment.completions, 1)
    }

    func testPreferencesCommitOnlyAfterBothStagesSucceed() {
        let environment = Environment()
        environment.holdProxy = true
        let done = expectation(description: "committed")
        let transaction = environment.makeTransaction { done.fulfill() }
        transaction.start()
        let proxyStarted = expectation(description: "proxy stage started")
        DispatchQueue.main.async {
            XCTAssertFalse(environment.savedLock)
            XCTAssertEqual(environment.runtime, "new")
            XCTAssertEqual(environment.events, ["apply runtime", "apply proxy"])
            environment.heldProxyReply?(nil)
            proxyStarted.fulfill()
        }
        wait(for: [proxyStarted, done], timeout: 2)
        XCTAssertTrue(environment.savedLock)
        XCTAssertNil(environment.failure)
        XCTAssertEqual(environment.events.last, "commit")
        withExtendedLifetime(transaction) {}
    }

    func testCoreFailureRestoresRuntimeAndProxyWithoutCommitting() {
        let environment = Environment()
        environment.runtimeError = "port occupied"
        execute(environment)
        XCTAssertFalse(environment.savedLock)
        XCTAssertEqual(environment.runtime, "old")
        XCTAssertEqual(environment.proxy, "old")
        XCTAssertEqual(environment.failure?.primary, "port occupied")
        XCTAssertEqual(environment.failure?.restorationErrors, [])
        XCTAssertFalse(environment.events.contains("apply proxy"))
    }

    func testPartiallyAppliedSystemProxyFailureRestoresBothStages() {
        let environment = Environment()
        environment.proxyError = "helper failed after mutation"
        execute(environment)
        XCTAssertEqual(environment.events, ["apply runtime", "apply proxy", "prepare rollback", "restore runtime", "restore proxy"])
        XCTAssertEqual(environment.runtime, "old")
        XCTAssertEqual(environment.proxy, "old")
        XCTAssertFalse(environment.savedLock)
    }

    func testRuntimeRecoveryFailureStillRestoresOriginalSystemProxy() {
        let environment = Environment()
        environment.proxyError = "enable failed"
        environment.restoreRuntimeError = "old core failed"
        execute(environment)
        XCTAssertEqual(environment.proxy, "old")
        XCTAssertEqual(environment.failure?.restorationErrors, ["old core failed"])
        XCTAssertFalse(environment.savedLock)
    }

    func testBothRecoveryFailuresAreReportedSeparatelyFromPrimaryFailure() {
        let environment = Environment()
        environment.runtimeError = "launch failed"
        environment.restoreRuntimeError = "restore core failed"
        environment.restoreProxyError = "restore proxy failed"
        execute(environment)
        XCTAssertEqual(environment.failure?.primary, "launch failed")
        XCTAssertEqual(environment.failure?.restorationErrors, ["restore core failed", "restore proxy failed"])
    }

    func testDuplicateSuccessAfterFailureCannotCommitOrRecoverTwice() {
        let environment = Environment()
        environment.runtimeError = "timed out"
        environment.duplicateReplies = true
        execute(environment)
        XCTAssertFalse(environment.savedLock)
        XCTAssertEqual(environment.events.filter { $0 == "restore runtime" }.count, 1)
        XCTAssertEqual(environment.events.filter { $0 == "restore proxy" }.count, 1)
    }

    func testSupersededCallbackCannotOverwriteNewerRuntime() {
        let environment = Environment()
        environment.holdRuntime = true
        let done = expectation(description: "cancelled")
        let transaction = environment.makeTransaction { done.fulfill() }
        transaction.start()
        environment.current = false
        environment.runtime = "newer lifecycle"
        environment.heldRuntimeReply?("late failure")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(environment.runtime, "newer lifecycle")
        XCTAssertEqual(environment.events, ["apply runtime"])
        XCTAssertTrue(environment.failure?.cancelled == true)
        XCTAssertFalse(environment.savedLock)
        withExtendedLifetime(transaction) {}
    }

    func testAlreadySupersededTransactionDoesNotTouchRuntime() {
        let environment = Environment()
        environment.current = false
        execute(environment)
        XCTAssertEqual(environment.runtime, "old")
        XCTAssertTrue(environment.events.isEmpty)
        XCTAssertTrue(environment.failure?.cancelled == true)
    }
}

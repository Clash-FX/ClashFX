import XCTest

final class EnhancedModeTransitionSafetyTests: XCTestCase {
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

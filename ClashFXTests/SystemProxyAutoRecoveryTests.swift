import Foundation
import XCTest

final class SystemProxyAutoRecoveryTests: XCTestCase {
    private final class ScheduledEntry {
        let id: Int
        let deadline: TimeInterval
        let action: () -> Void
        var isCancelled = false

        init(id: Int, deadline: TimeInterval, action: @escaping () -> Void) {
            self.id = id
            self.deadline = deadline
            self.action = action
        }
    }

    private final class FakeScheduler {
        private(set) var now: TimeInterval = 0
        private var nextID = 0
        private var entries = [ScheduledEntry]()

        var scheduler: SystemProxyAutoRecoveryScheduler {
            SystemProxyAutoRecoveryScheduler(
                now: { self.now },
                schedule: { delay, action in
                    self.nextID += 1
                    let entry = ScheduledEntry(
                        id: self.nextID,
                        deadline: self.now + max(0, delay),
                        action: action
                    )
                    self.entries.append(entry)
                    return { entry.isCancelled = true }
                }
            )
        }

        func advance(by interval: TimeInterval) {
            let target = now + interval
            while let next = entries
                .filter({ $0.deadline <= target })
                .min(by: { lhs, rhs in
                    lhs.deadline == rhs.deadline ? lhs.id < rhs.id : lhs.deadline < rhs.deadline
                }) {
                entries.removeAll { $0.id == next.id }
                now = next.deadline
                if !next.isCancelled {
                    next.action()
                }
            }
            now = target
        }
    }

    private final class PendingApply {
        private let completion: (Bool) -> Void
        private(set) var wasCalled = false

        init(_ completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }

        func finish(_ success: Bool) {
            guard !wasCalled else { return }
            wasCalled = true
            completion(success)
        }
    }

    private final class Harness {
        var observation = SystemProxyRecoveryObservation(
            scope: "config-a",
            shouldProtect: true,
            isPaused: false,
            isReady: true,
            matches: false,
            ownsRuntime: true
        )
        var applyCompletions = [PendingApply]()
        var applyOwners = [String]()
        var observed = [SystemProxyRecoveryObservation]()
        var suspendCount = 0

        func makeController(
            scheduler: FakeScheduler,
            coordination: SystemProxyAutoRecoveryCoordination,
            owner: String = "controller"
        ) -> SystemProxyAutoRecoveryController {
            SystemProxyAutoRecoveryController(
                observe: { self.observation },
                apply: { completion in
                    self.applyCompletions.append(PendingApply(completion))
                    self.applyOwners.append(owner)
                },
                didObserve: { self.observed.append($0) },
                didSuspend: { self.suspendCount += 1 },
                scheduler: scheduler.scheduler,
                coordination: coordination
            )
        }

        func finishNextApply(_ success: Bool) -> Bool {
            guard let pending = applyCompletions.first(where: { !$0.wasCalled }) else { return false }
            pending.finish(success)
            return true
        }
    }

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Thread.isMainThread)
    }

    func testNotificationStormCoalescesToOneApply() {
        let scheduler = FakeScheduler()
        let coordination = SystemProxyAutoRecoveryCoordination()
        let harness = Harness()
        let controller = harness.makeController(scheduler: scheduler, coordination: coordination)

        for _ in 0 ..< 20 {
            controller.request()
        }

        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay - 0.01)
        XCTAssertTrue(harness.applyCompletions.isEmpty)
        scheduler.advance(by: 0.01)
        XCTAssertEqual(harness.applyCompletions.count, 1)

        harness.observation.matches = true
        XCTAssertTrue(harness.finishNextApply(true))
        scheduler.advance(by: SystemProxyAutoRecoveryController.settleDelay)
        XCTAssertTrue(harness.observed.last?.matches == true)
        controller.cancel()
    }

    func testTwoControllersShareOneBoundedAttemptBudget() {
        let scheduler = FakeScheduler()
        let coordination = SystemProxyAutoRecoveryCoordination()
        let harness = Harness()
        let first = harness.makeController(scheduler: scheduler, coordination: coordination, owner: "first")
        let second = harness.makeController(scheduler: scheduler, coordination: coordination, owner: "second")

        first.request()
        second.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        XCTAssertEqual(harness.applyCompletions.count, 1)
        XCTAssertEqual(harness.applyOwners, ["first"])

        harness.observation.matches = true
        XCTAssertTrue(harness.finishNextApply(true))
        scheduler.advance(by: SystemProxyAutoRecoveryController.settleDelay)
        scheduler.advance(by: 0)

        harness.observation.matches = false
        first.request()
        second.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        first.cancel()
        scheduler.advance(by: SystemProxyAutoRecoveryController.retryCooldown / 2)
        XCTAssertEqual(harness.applyOwners, ["first", "second"])

        harness.observation.matches = true
        XCTAssertTrue(harness.finishNextApply(true))
        scheduler.advance(by: SystemProxyAutoRecoveryController.settleDelay)
        harness.observation.matches = false
        first.request()
        second.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        second.cancel()
        scheduler.advance(by: SystemProxyAutoRecoveryController.retryCooldown / 2)
        XCTAssertEqual(harness.applyOwners, ["first", "second", "first"])

        harness.observation.matches = true
        XCTAssertTrue(harness.finishNextApply(true))
        scheduler.advance(by: SystemProxyAutoRecoveryController.settleDelay)
        harness.observation.matches = false
        first.request()
        second.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        XCTAssertEqual(harness.applyCompletions.count, SystemProxyAutoRecoveryController.maximumAttempts)
        XCTAssertEqual(harness.suspendCount, 1)
        first.cancel()
        second.cancel()
    }

    func testBriefMatchAndWatchNotificationsDoNotResetAttemptBudget() {
        let scheduler = FakeScheduler()
        let coordination = SystemProxyAutoRecoveryCoordination()
        let harness = Harness()
        let controller = harness.makeController(scheduler: scheduler, coordination: coordination)

        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)

        for index in 0 ..< 2 {
            XCTAssertTrue(harness.finishNextApply(false))
            scheduler.advance(by: SystemProxyAutoRecoveryController.settleDelay)
            if index == 0 {
                scheduler.advance(by: SystemProxyAutoRecoveryController.retryCooldown)
            }
        }
        XCTAssertEqual(harness.applyCompletions.count, 2)
        XCTAssertEqual(harness.suspendCount, 0)

        harness.observation.matches = true
        for _ in 0 ..< 10 {
            controller.request()
        }
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        scheduler.advance(by: SystemProxyAutoRecoveryController.matchingResetInterval - 1)
        harness.observation.matches = false
        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        XCTAssertEqual(harness.applyCompletions.count, 3)

        XCTAssertTrue(harness.finishNextApply(false))
        scheduler.advance(by: SystemProxyAutoRecoveryController.settleDelay)

        XCTAssertEqual(harness.applyCompletions.count, SystemProxyAutoRecoveryController.maximumAttempts)
        XCTAssertEqual(harness.suspendCount, 1)
        controller.cancel()
    }

    func testStableMatchingIntervalClearsSuspensionAndBudget() {
        let scheduler = FakeScheduler()
        let coordination = SystemProxyAutoRecoveryCoordination()
        let harness = Harness()
        let controller = harness.makeController(scheduler: scheduler, coordination: coordination)

        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        for _ in 0 ..< SystemProxyAutoRecoveryController.maximumAttempts {
            XCTAssertTrue(harness.finishNextApply(false))
            scheduler.advance(by: SystemProxyAutoRecoveryController.settleDelay)
            if harness.applyCompletions.count < SystemProxyAutoRecoveryController.maximumAttempts {
                scheduler.advance(by: SystemProxyAutoRecoveryController.retryCooldown)
            }
        }
        XCTAssertEqual(harness.suspendCount, 1)

        harness.observation.matches = true
        harness.observation.shouldProtect = false
        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        scheduler.advance(by: SystemProxyAutoRecoveryController.matchingResetInterval)
        XCTAssertFalse(controller.isSuspended)
        harness.observation.matches = false
        harness.observation.shouldProtect = true
        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)

        XCTAssertEqual(harness.applyCompletions.count, SystemProxyAutoRecoveryController.maximumAttempts + 1)
        controller.cancel()
        XCTAssertTrue(harness.finishNextApply(false))
    }

    func testPausedUnreadyOrNonOwnerObservationsNeverWrite() {
        let blockedObservations = [
            SystemProxyRecoveryObservation(
                scope: "paused", shouldProtect: true, isPaused: true, isReady: true,
                matches: false, ownsRuntime: true
            ),
            SystemProxyRecoveryObservation(
                scope: "transition", shouldProtect: true, isPaused: false, isReady: false,
                matches: false, ownsRuntime: true
            ),
            SystemProxyRecoveryObservation(
                scope: "other-owner", shouldProtect: true, isPaused: false, isReady: true,
                matches: false, ownsRuntime: false
            ),
            SystemProxyRecoveryObservation(
                scope: "not-protected", shouldProtect: false, isPaused: false, isReady: true,
                matches: false, ownsRuntime: true
            )
        ]

        for observation in blockedObservations {
            let scheduler = FakeScheduler()
            let harness = Harness()
            harness.observation = observation
            let controller = harness.makeController(
                scheduler: scheduler,
                coordination: SystemProxyAutoRecoveryCoordination()
            )

            controller.request()
            scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
            XCTAssertTrue(harness.applyCompletions.isEmpty)
            controller.cancel()
        }
    }

    func testDuplicateCallbackIsIgnoredAndFreshReadbackWins() {
        let scheduler = FakeScheduler()
        let harness = Harness()
        let controller = harness.makeController(
            scheduler: scheduler,
            coordination: SystemProxyAutoRecoveryCoordination()
        )

        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        let callback = harness.applyCompletions[0]
        callback.finish(false)
        callback.finish(true)
        harness.observation.matches = true
        scheduler.advance(by: SystemProxyAutoRecoveryController.settleDelay)

        XCTAssertEqual(harness.observed.count, 2)
        XCTAssertTrue(harness.observed.last?.matches == true)
        XCTAssertEqual(harness.applyCompletions.count, 1)
        controller.cancel()
    }

    func testHungApplyTimesOutAndLateCallbackCannotPublishOrRetry() {
        let scheduler = FakeScheduler()
        let harness = Harness()
        let controller = harness.makeController(
            scheduler: scheduler,
            coordination: SystemProxyAutoRecoveryCoordination()
        )

        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        let lateCallback = harness.applyCompletions[0]
        scheduler.advance(by: SystemProxyAutoRecoveryController.applyTimeout)
        XCTAssertEqual(harness.applyCompletions.count, 1)
        XCTAssertEqual(harness.observed.count, 1)
        XCTAssertEqual(harness.suspendCount, 1)
        XCTAssertTrue(controller.isSuspended)
        let observationsBeforeLateCallback = harness.observed.count

        lateCallback.finish(true)
        XCTAssertEqual(harness.observed.count, observationsBeforeLateCallback)
        XCTAssertEqual(harness.applyCompletions.count, 1)
        controller.cancel()
    }

    func testResetCannotUnlockTimedOutWriteUntilItsCallbackArrives() {
        let scheduler = FakeScheduler()
        let harness = Harness()
        let controller = harness.makeController(
            scheduler: scheduler,
            coordination: SystemProxyAutoRecoveryCoordination()
        )

        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        let unresolvedCallback = harness.applyCompletions[0]
        scheduler.advance(by: SystemProxyAutoRecoveryController.applyTimeout)
        XCTAssertTrue(controller.isSuspended)

        controller.reset()
        harness.observation.scope = "config-b"
        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        XCTAssertEqual(harness.applyCompletions.count, 1)

        unresolvedCallback.finish(false)
        scheduler.advance(by: 0)
        XCTAssertEqual(harness.applyCompletions.count, 2)
        XCTAssertEqual(harness.applyOwners, ["controller", "controller"])

        harness.applyCompletions[1].finish(false)
        scheduler.advance(by: SystemProxyAutoRecoveryController.settleDelay)
        controller.cancel()
    }

    func testScopeResetAndCancelRearmKeepAnUnsettledWriteExclusive() {
        let scheduler = FakeScheduler()
        let harness = Harness()
        let controller = harness.makeController(
            scheduler: scheduler,
            coordination: SystemProxyAutoRecoveryCoordination()
        )

        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        let oldScopeCallback = harness.applyCompletions[0]
        controller.reset()
        harness.observation.scope = "config-b"
        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        XCTAssertEqual(harness.applyCompletions.count, 1)

        oldScopeCallback.finish(false)
        scheduler.advance(by: 0)
        XCTAssertEqual(harness.applyCompletions.count, 2)

        let secondCallback = harness.applyCompletions[1]
        controller.cancel()
        controller.request()
        scheduler.advance(by: SystemProxyAutoRecoveryController.requestCoalescingDelay)
        XCTAssertEqual(harness.applyCompletions.count, 2)

        secondCallback.finish(false)
        scheduler.advance(by: 0)
        XCTAssertEqual(harness.applyCompletions.count, 2)
        scheduler.advance(by: SystemProxyAutoRecoveryController.retryCooldown)
        XCTAssertEqual(harness.applyCompletions.count, 3)
        controller.cancel()
        XCTAssertTrue(harness.finishNextApply(false))
    }
}

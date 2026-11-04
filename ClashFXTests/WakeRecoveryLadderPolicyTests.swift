import XCTest

final class WakeRecoveryLadderPolicyTests: XCTestCase {
    func testRespondingListenerFinishesWithoutReload() {
        var ladder = WakeRecoveryLadder(generation: 3)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 3, dnsListenerResponding: true), .finish)
    }

    func testUnknownListenerFinishesWithoutReload() {
        var ladder = WakeRecoveryLadder(generation: 3)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 3, dnsListenerResponding: nil), .finish)
    }

    func testSilentListenerReloadsOnceBeforeRestarting() {
        var ladder = WakeRecoveryLadder(generation: 3)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 3, dnsListenerResponding: false), .reloadConfig)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 3, dnsListenerResponding: false), .restartEnhancedMode)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 3, dnsListenerResponding: false), .restartEnhancedMode)
    }

    func testReloadThatRestoresTheListenerEndsTheLadder() {
        var ladder = WakeRecoveryLadder(generation: 3)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 3, dnsListenerResponding: false), .reloadConfig)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 3, dnsListenerResponding: true), .finish)
    }

    func testSupersededWakeTakesNoAction() {
        var ladder = WakeRecoveryLadder(generation: 3)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 4, dnsListenerResponding: false), .abandon)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 4, dnsListenerResponding: true), .abandon)
    }

    func testStaleGenerationDoesNotConsumeTheReloadBudget() {
        var ladder = WakeRecoveryLadder(generation: 3)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 2, dnsListenerResponding: false), .abandon)
        XCTAssertEqual(ladder.nextStep(currentGeneration: 3, dnsListenerResponding: false), .reloadConfig)
    }
}

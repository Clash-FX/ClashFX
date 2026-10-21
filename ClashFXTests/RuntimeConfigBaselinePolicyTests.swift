import XCTest

final class RuntimeConfigBaselinePolicyTests: XCTestCase {
    func testStartupRollbackDoesNotClaimAProfileWasRestored() {
        let kind = RuntimeConfigBaselineKind(confirmedProfile: nil)
        XCTAssertEqual(kind, .startup)
        let text = kind.rollbackMessage(reason: "listen failed", localize: { $0 })
        XCTAssertTrue(text.contains("startup configuration"))
        XCTAssertTrue(text.contains("has not loaded successfully"))
        XCTAssertTrue(text.hasSuffix("listen failed"))
    }

    func testConfirmedProfileRollbackHasDistinctProvenance() {
        let kind = RuntimeConfigBaselineKind(confirmedProfile: "subscription")
        XCTAssertEqual(kind, .profile)
        let text = kind.rollbackMessage(reason: "connection refused", localize: { $0 })
        XCTAssertTrue(text.contains("verified profile configuration"))
        XCTAssertFalse(text.contains("has not loaded successfully"))
    }

    func testCoreReasonIsAnArgumentRatherThanAFormatString() {
        let text = RuntimeConfigBaselineKind.startup.rollbackMessage(reason: "%@ %s %%", localize: { $0 })
        XCTAssertTrue(text.hasSuffix("%@ %s %%"))
    }
}

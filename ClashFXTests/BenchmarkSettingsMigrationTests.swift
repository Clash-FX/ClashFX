import XCTest

final class BenchmarkSettingsMigrationTests: XCTestCase {
    func testFreshInstallDetectionUsesVersionAndLegacyPreferenceEvidence() {
        XCTAssertTrue(RuntimeBenchmarkSettingsPolicy.isFreshInstall(
            previousVersionExists: false,
            hasLegacyPreferenceDomainEvidence: false
        ))
        XCTAssertFalse(RuntimeBenchmarkSettingsPolicy.isFreshInstall(
            previousVersionExists: true,
            hasLegacyPreferenceDomainEvidence: false
        ))
        XCTAssertFalse(RuntimeBenchmarkSettingsPolicy.isFreshInstall(
            previousVersionExists: false,
            hasLegacyPreferenceDomainEvidence: true
        ))
        XCTAssertTrue(RuntimeBenchmarkSettingsPolicy.hasLegacyPreferenceDomainEvidence(
            keys: ["benchMarkUrl"]
        ))
        XCTAssertTrue(RuntimeBenchmarkSettingsPolicy.hasLegacyPreferenceDomainEvidence(
            keys: ["SavedProxyModels"]
        ))
    }

    func testInitialMeasurementMethodDefaultsByInstallationKindAndKeepsSavedChoice() {
        XCTAssertEqual(
            RuntimeBenchmarkSettingsPolicy.initialMeasurementMethod(
                isFreshInstall: true,
                savedRawValue: nil
            ).rawValue,
            BenchmarkMeasurementMethod.unified.rawValue
        )
        XCTAssertEqual(
            RuntimeBenchmarkSettingsPolicy.initialMeasurementMethod(
                isFreshInstall: false,
                savedRawValue: nil
            ).rawValue,
            BenchmarkMeasurementMethod.followConfiguration.rawValue
        )
        XCTAssertEqual(
            RuntimeBenchmarkSettingsPolicy.initialMeasurementMethod(
                isFreshInstall: true,
                savedRawValue: BenchmarkMeasurementMethod.connection.rawValue
            ).rawValue,
            BenchmarkMeasurementMethod.connection.rawValue
        )
    }

    func testRuntimeOverlayPreservesFollowConfigurationAndAppliesExplicitChoices() {
        var configuration: [String: Any] = ["unified-delay": false]
        XCTAssertFalse(RuntimeBenchmarkSettingsPolicy.apply(.followConfiguration, to: &configuration))
        XCTAssertEqual(configuration["unified-delay"] as? Bool, false)

        XCTAssertTrue(RuntimeBenchmarkSettingsPolicy.apply(.unified, to: &configuration))
        XCTAssertEqual(configuration["unified-delay"] as? Bool, true)

        XCTAssertTrue(RuntimeBenchmarkSettingsPolicy.apply(.connection, to: &configuration))
        XCTAssertEqual(configuration["unified-delay"] as? Bool, false)
    }

    func testSourceFieldConflictReportsMismatchAndLeavesMissingFieldUnknown() {
        XCTAssertEqual(
            RuntimeBenchmarkSettingsPolicy.sourceFieldConflict(
                sourceUnifiedDelay: false,
                method: .unified
            ),
            true
        )
        XCTAssertEqual(
            RuntimeBenchmarkSettingsPolicy.sourceFieldConflict(
                sourceUnifiedDelay: true,
                method: .connection
            ),
            true
        )
        XCTAssertNil(RuntimeBenchmarkSettingsPolicy.sourceFieldConflict(
            sourceUnifiedDelay: nil,
            method: .connection
        ))
        XCTAssertEqual(
            RuntimeBenchmarkSettingsPolicy.sourceFieldConflict(
                sourceUnifiedDelay: false,
                method: .followConfiguration
            ),
            false
        )
    }
}

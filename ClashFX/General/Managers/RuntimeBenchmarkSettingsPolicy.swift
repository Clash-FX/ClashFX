import Foundation

enum RuntimeBenchmarkSettingsPolicy {
    private static let legacyPreferenceKeys: Set<String> = [
        "actionShortcutScope",
        "api-secret",
        "benchMarkUrl",
        "disableNoti",
        "enhancedMode",
        "isLabChannel",
        "kBuiltInApiMode",
        "kRemoteConfigs",
        "kRemoteConfigUrl",
        "proxyIgnoreList",
        "proxyPort",
        "proxyPortAutoSet",
        "selectConfigName",
        "selectOutBoundMode",
        "selectedLocalConfigName",
        "selectedICloudConfigName",
        "selectedMenuIconID",
        "SavedProxyModels",
        "showNetSpeedIndicator",
        "tunMTU"
    ]

    static func hasLegacyPreferenceDomainEvidence(keys: Set<String>) -> Bool {
        !legacyPreferenceKeys.isDisjoint(with: keys)
    }

    static func isFreshInstall(
        previousVersionExists: Bool,
        hasLegacyPreferenceDomainEvidence: Bool
    ) -> Bool {
        !previousVersionExists && !hasLegacyPreferenceDomainEvidence
    }

    static func initialMeasurementMethod(
        isFreshInstall: Bool,
        savedRawValue: String?
    ) -> BenchmarkMeasurementMethod {
        if let savedRawValue = savedRawValue,
           let savedMethod = BenchmarkMeasurementMethod(rawValue: savedRawValue) {
            return savedMethod
        }
        return isFreshInstall ? .unified : .followConfiguration
    }

    static func requestedUnifiedDelay(
        for method: BenchmarkMeasurementMethod
    ) -> Bool? {
        switch method {
        case .followConfiguration:
            return nil
        case .unified:
            return true
        case .connection:
            return false
        }
    }

    @discardableResult
    static func apply(
        _ method: BenchmarkMeasurementMethod,
        to configuration: inout [String: Any]
    ) -> Bool {
        guard let requestedValue = requestedUnifiedDelay(for: method),
              (configuration["unified-delay"] as? Bool) != requestedValue else {
            return false
        }
        configuration["unified-delay"] = requestedValue
        return true
    }

    static func sourceFieldConflict(
        sourceUnifiedDelay: Bool?,
        method: BenchmarkMeasurementMethod
    ) -> Bool? {
        guard let requestedValue = requestedUnifiedDelay(for: method) else {
            return false
        }
        guard let sourceUnifiedDelay else { return nil }
        return sourceUnifiedDelay != requestedValue
    }
}

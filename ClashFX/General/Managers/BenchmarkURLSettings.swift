//
//  BenchmarkURLSettings.swift
//  ClashFX
//

import Foundation

enum BenchmarkURLSettings {
    // Keep the historical fallback for callers and upgraded installations.
    static let defaultURL = "http://cp.cloudflare.com/generate_204"
    static let freshInstallDefaultURL = "https://cp.cloudflare.com/generate_204"
    static let googleHTTPSURL = "https://www.google.com/generate_204"
    static let supersededBuiltInDefaultURL = "https://cp.cloudflare.com/generate_204"

    static func presetIndex(for url: String) -> Int {
        switch url {
        case freshInstallDefaultURL: return 0
        case googleHTTPSURL: return 1
        default: return 2
        }
    }

    static func url(forPresetIndex index: Int) -> String? {
        switch index {
        case 0: return freshInstallDefaultURL
        case 1: return googleHTTPSURL
        default: return nil
        }
    }

    static func normalizedURL(_ rawValue: String, defaultURL: String = BenchmarkURLSettings.defaultURL) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return defaultURL }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            return nil
        }
        return value
    }

    static func shouldRestoreSupersededBuiltInDefault(
        savedURL: String,
        restorationCompleted: Bool
    ) -> Bool {
        // Retained for source compatibility with existing callers. Startup no
        // longer uses this equality-based predicate to rewrite saved URLs.
        return !restorationCompleted && savedURL == supersededBuiltInDefaultURL
    }
}

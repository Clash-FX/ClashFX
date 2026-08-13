//
//  BenchmarkURLSettings.swift
//  ClashFX
//

import Foundation

enum BenchmarkURLSettings {
    static func normalizedURL(_ rawValue: String, defaultURL: String) -> String? {
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
}

//
//  ClaudeProxyLockPolicy.swift
//  ClashFX
//

import Foundation

enum ClaudeProxyLockPolicy {
    private static let protectedDomains = [
        "claude.ai",
        "claude.com",
        "anthropic.com"
    ]

    static func isValidTarget(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty &&
            !trimmed.contains(",") &&
            !trimmed.contains("\n") &&
            !trimmed.contains("\r") &&
            trimmed != "DIRECT" &&
            trimmed != "REJECT"
    }

    static func rules(target: String) -> [String] {
        guard isValidTarget(target) else { return [] }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let processRules = ["Claude", "claude"].map {
            "PROCESS-NAME,\($0),\(trimmed)"
        }
        let domainRules = protectedDomains.map {
            "DOMAIN-SUFFIX,\($0),\(trimmed)"
        }
        return processRules + domainRules
    }

    @discardableResult
    static func apply(to root: inout [String: Any], target: String) -> Bool {
        let injectedRules = rules(target: target)
        guard !injectedRules.isEmpty else { return false }

        let existingRules: [String]
        if let rules = root["rules"] {
            existingRules = rules as? [String] ?? []
        } else {
            existingRules = []
        }

        root["mode"] = "rule"
        root["find-process-mode"] = "always"
        root["rules"] = injectedRules + existingRules.filter { !injectedRules.contains($0) }
        return true
    }
}

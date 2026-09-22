//
//  ClaudeProxyLockPolicy.swift
//  ClashFX
//

import Foundation

enum ClaudeProxyLockPolicy {
    /// mihomo PROCESS-NAME is an exact match. Claude Desktop's network
    /// processes are "Claude", "Claude Helper", and "Claude Helper (Renderer|GPU|Plugin)".
    static let processNamePattern = "^claude( helper.*)?$"

    struct ProviderSnapshot {
        var name: String
        var dialerProxy: String?
        var overrideDialerProxy: String?
        var proxies: [[String: Any]]
    }

    struct ApplyOutcome {
        var applied: Bool
        var serverHost: String?
        /// Proxy that dials the locked node's server. The locked node remains the exit.
        var relayProxy: String?

        static let rejected = ApplyOutcome(
            applied: false,
            serverHost: nil,
            relayProxy: nil
        )
    }

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
        let processRule = "PROCESS-NAME-REGEX,\(processNamePattern),\(trimmed)"
        let domainRules = protectedDomains.map {
            "DOMAIN-SUFFIX,\($0),\(trimmed)"
        }
        return [processRule] + domainRules
    }

    /// The group selected by MATCH, when that choice cannot loop back into the locked node.
    static func relayName(in root: [String: Any], lockedTarget: String) -> String? {
        guard let rules = root["rules"] as? [String] else { return nil }
        guard let rawName = rules.reversed().compactMap({ matchTarget(in: $0) }).first else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "DIRECT" || name == "REJECT" || name == lockedTarget {
            return nil
        }
        guard relayExists(name, in: root) else { return nil }
        if let groups = root["proxy-groups"] as? [[String: Any]],
           let group = groups.first(where: { ($0["name"] as? String) == name }),
           let now = (group["now"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           now == lockedTarget {
            return nil
        }
        return name
    }

    @discardableResult
    static func apply(
        to root: inout [String: Any],
        target: String,
        providers: [ProviderSnapshot] = []
    ) -> ApplyOutcome {
        let injectedRules = rules(target: target)
        guard !injectedRules.isEmpty else { return .rejected }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)

        let located = locatedProxy(in: root, target: trimmed, providers: providers)
        let relay = assignRelay(
            in: &root,
            target: trimmed,
            located: located,
            relay: relayName(in: root, lockedTarget: trimmed)
        )

        let existingRules: [String]
        if let rules = root["rules"] {
            existingRules = rules as? [String] ?? []
        } else {
            existingRules = []
        }

        root["mode"] = "rule"
        root["find-process-mode"] = "always"
        root["rules"] = injectedRules + existingRules.filter { !injectedRules.contains($0) }
        return ApplyOutcome(
            applied: true,
            serverHost: located?.server,
            relayProxy: relay
        )
    }

    private struct LocatedProxy {
        var server: String?
        var providerName: String?
        var proxy: [String: Any]
    }

    private static func locatedProxy(
        in root: [String: Any],
        target: String,
        providers: [ProviderSnapshot]
    ) -> LocatedProxy? {
        if let proxies = root["proxies"] as? [[String: Any]],
           let proxy = proxies.first(where: { ($0["name"] as? String) == target }) {
            return LocatedProxy(
                server: normalizedServerHost(proxy["server"] as? String),
                providerName: nil,
                proxy: proxy
            )
        }
        for provider in providers {
            guard let proxy = provider.proxies.first(where: { ($0["name"] as? String) == target }) else {
                continue
            }
            return LocatedProxy(
                server: normalizedServerHost(proxy["server"] as? String),
                providerName: provider.name,
                proxy: proxy
            )
        }
        return nil
    }

    private static func assignRelay(
        in root: inout [String: Any],
        target: String,
        located: LocatedProxy?,
        relay: String?
    ) -> String? {
        guard let relay else { return nil }
        if setInlineDialer(in: &root, target: target, relay: relay) {
            return relay
        }
        guard let located, let providerName = located.providerName, !target.contains("`") else {
            return nil
        }
        var proxies = root["proxies"] as? [[String: Any]] ?? []
        guard !proxies.contains(where: { ($0["name"] as? String) == target }) else { return nil }
        var copy = located.proxy
        copy["dialer-proxy"] = relay
        proxies.append(copy)
        root["proxies"] = proxies
        appendExactNameExclusion(target, toProvider: providerName, in: &root)
        return relay
    }

    private static func setInlineDialer(
        in root: inout [String: Any],
        target: String,
        relay: String
    ) -> Bool {
        guard var proxies = root["proxies"] as? [[String: Any]] else { return false }
        var updated = false
        for index in proxies.indices {
            guard (proxies[index]["name"] as? String) == target else { continue }
            proxies[index]["dialer-proxy"] = relay
            updated = true
        }
        if updated {
            root["proxies"] = proxies
        }
        return updated
    }

    private static func matchTarget(in rule: String) -> String? {
        let parts = rule.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, parts[0] == "MATCH" else { return nil }
        return parts[1]
    }

    private static func relayExists(_ name: String, in root: [String: Any]) -> Bool {
        if let groups = root["proxy-groups"] as? [[String: Any]],
           groups.contains(where: { ($0["name"] as? String) == name }) {
            return true
        }
        if let proxies = root["proxies"] as? [[String: Any]],
           proxies.contains(where: { ($0["name"] as? String) == name }) {
            return true
        }
        return false
    }

    private static func appendExactNameExclusion(
        _ name: String,
        toProvider providerName: String,
        in root: inout [String: Any]
    ) {
        guard var providers = root["proxy-providers"] as? [String: Any],
              var provider = providers[providerName] as? [String: Any] else {
            return
        }
        let existing = provider["exclude-filter"] as? String
        provider["exclude-filter"] = excludeFilter(appendingExactName: name, to: existing)
        providers[providerName] = provider
        root["proxy-providers"] = providers
    }

    private static func excludeFilter(appendingExactName name: String, to existing: String?) -> String {
        guard !name.contains("`") else { return existing ?? "" }
        let clause = "^\(NSRegularExpression.escapedPattern(for: name))$"
        let current = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if current.isEmpty {
            return clause
        }
        let parts = current.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(clause) {
            return current
        }
        return current + "`" + clause
    }

    private static func normalizedServerHost(_ server: String?) -> String? {
        guard var host = server?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex) ..< end])
        }
        if host.isEmpty || host.contains(",") || host.contains("/") || host.contains(where: \.isWhitespace) {
            return nil
        }
        return host
    }
}

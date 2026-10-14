//
//  ClaudeProxyLockPolicy.swift
//  ClashFX
//

import Foundation

enum ClaudeProxyLockPolicy {
    static func requiresEnhancedMode(lockEnabled: Bool, preferredEnhancedMode: Bool) -> Bool {
        lockEnabled || preferredEnhancedMode
    }

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
        var rejectionReason: String?

        init(
            applied: Bool,
            serverHost: String?,
            relayProxy: String?,
            rejectionReason: String? = nil
        ) {
            self.applied = applied
            self.serverHost = serverHost
            self.relayProxy = relayProxy
            self.rejectionReason = rejectionReason
        }

        static let rejected = ApplyOutcome(
            applied: false,
            serverHost: nil,
            relayProxy: nil
        )
    }

    private enum DependencyNode {
        case proxy(dialerProxy: String?, unresolved: Bool)
        case group(candidates: [String], unresolved: Bool)
    }

    private struct ProviderProxyRecord {
        var name: String
        var proxy: [String: Any]
        var dialerProxy: String?
        var unresolved: Bool
    }

    private struct ProviderResolution {
        var proxies: [ProviderProxyRecord]
        var known: Bool
    }

    private struct DependencyGraph {
        var nodes: [String: DependencyNode]
        var ambiguousNames: Set<String>
        var referencedNames: Set<String>

        func knows(_ name: String) -> Bool {
            nodes[name] != nil || ambiguousNames.contains(name) || referencedNames.contains(name)
        }

        func isSafe(from start: String, avoiding forbiddenName: String? = nil) -> Bool {
            var active = Set<String>()
            var completed = Set<String>()

            func visit(_ name: String) -> Bool {
                if name == "DIRECT" || name == "REJECT" {
                    return true
                }
                if name.isEmpty || name == forbiddenName || ambiguousNames.contains(name) {
                    return false
                }
                if active.contains(name) {
                    return false
                }
                if completed.contains(name) {
                    return true
                }
                guard let node = nodes[name] else { return false }

                active.insert(name)
                let safe: Bool
                switch node {
                case let .proxy(dialerProxy, unresolved):
                    if unresolved {
                        safe = false
                    } else if let dialerProxy {
                        safe = visit(dialerProxy)
                    } else {
                        safe = true
                    }
                case let .group(candidates, unresolved):
                    if unresolved || candidates.isEmpty {
                        safe = false
                    } else {
                        safe = candidates.allSatisfy(visit)
                    }
                }
                active.remove(name)
                if safe {
                    completed.insert(name)
                }
                return safe
            }

            return visit(start)
        }
    }

    private struct LocatedProxy {
        var server: String?
        var providerName: String?
        var proxy: [String: Any]
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

    /// The group selected by MATCH, when every possible dependency is resolvable and safe.
    static func relayName(
        in root: [String: Any],
        lockedTarget: String,
        providers: [ProviderSnapshot] = []
    ) -> String? {
        guard let rules = root["rules"] as? [String] else { return nil }
        guard let rawName = rules.reversed().compactMap({ matchTarget(in: $0) }).first else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "DIRECT" || name == "REJECT" || name == lockedTarget {
            return nil
        }
        let graph = dependencyGraph(in: root, providers: providers)
        guard graph.knows(name), graph.isSafe(from: name, avoiding: lockedTarget) else { return nil }
        return name
    }

    @discardableResult
    static func apply(
        to root: inout [String: Any],
        target: String,
        providers: [ProviderSnapshot] = []
    ) -> ApplyOutcome {
        let injectedRules = rules(target: target)
        guard !injectedRules.isEmpty else {
            return rejected("The locked proxy target is invalid.")
        }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialGraph = dependencyGraph(in: root, providers: providers)

        guard initialGraph.knows(trimmed) else {
            return rejected("The locked proxy target could not be resolved.")
        }
        if !initialGraph.isSafe(from: trimmed) {
            return rejected("The locked proxy has cyclic or unresolved dialer dependencies.")
        }

        let located = locatedProxy(in: root, target: trimmed, providers: providers)
        var finalRoot = root
        var appliedRelay: String?

        if let relay = relayName(in: root, lockedTarget: trimmed, providers: providers) {
            var proposedRoot = root
            if assignRelay(
                in: &proposedRoot,
                target: trimmed,
                located: located,
                relay: relay
            ) {
                let finalGraph = dependencyGraph(in: proposedRoot, providers: providers)
                if finalGraph.isSafe(from: trimmed) {
                    finalRoot = proposedRoot
                    appliedRelay = relay
                }
            }
        }

        let existingRules: [String]
        if let rules = finalRoot["rules"] {
            existingRules = rules as? [String] ?? []
        } else {
            existingRules = []
        }

        finalRoot["mode"] = "rule"
        finalRoot["find-process-mode"] = "always"
        finalRoot["rules"] = injectedRules + existingRules.filter { !injectedRules.contains($0) }
        root = finalRoot
        return ApplyOutcome(
            applied: true,
            serverHost: located?.server,
            relayProxy: appliedRelay
        )
    }

    private static func rejected(_ reason: String) -> ApplyOutcome {
        ApplyOutcome(
            applied: false,
            serverHost: nil,
            relayProxy: nil,
            rejectionReason: reason
        )
    }

    private static func dependencyGraph(
        in root: [String: Any],
        providers: [ProviderSnapshot]
    ) -> DependencyGraph {
        var nodes: [String: DependencyNode] = [:]
        var ambiguousNames = Set<String>()
        var referencedNames = Set<String>()
        var providerMembers: [String: [ProviderProxyRecord]] = [:]
        var providersKnown: [String: Bool] = [:]
        var nodeOwners: [String: String] = [:]
        var proxyRecordsByName: [String: ProviderProxyRecord] = [:]

        func insert(_ name: String, node: DependencyNode, owner: String) {
            guard !name.isEmpty else { return }
            if let existingOwner = nodeOwners[name] {
                if existingOwner != owner {
                    ambiguousNames.insert(name)
                }
                return
            }
            nodeOwners[name] = owner
            nodes[name] = node
        }

        let rawProviderDefinitions = root["proxy-providers"]
        let providerDefinitions = rawProviderDefinitions as? [String: Any] ?? [:]
        let providerDefinitionsAreValid = rawProviderDefinitions == nil ||
            rawProviderDefinitions is [String: Any]
        var snapshotsByName: [String: [ProviderSnapshot]] = [:]
        for provider in providers {
            snapshotsByName[provider.name, default: []].append(provider)
        }

        for (providerName, snapshots) in snapshotsByName {
            guard snapshots.count == 1, let snapshot = snapshots.first else {
                providersKnown[providerName] = false
                for snapshot in snapshots {
                    let definition = providerDefinitions[providerName] as? [String: Any]
                    let resolution = resolveProvider(snapshot, definition: definition)
                    for proxy in resolution.proxies {
                        insert(
                            proxy.name,
                            node: .proxy(dialerProxy: proxy.dialerProxy, unresolved: true),
                            owner: "provider:\(providerName)"
                        )
                        proxyRecordsByName[proxy.name] = proxy
                    }
                }
                continue
            }
            let definition = providerDefinitions[providerName] as? [String: Any]
            let resolution = resolveProvider(snapshot, definition: definition)
            providersKnown[providerName] = resolution.known
            providerMembers[providerName] = resolution.proxies
            for proxy in resolution.proxies {
                insert(
                    proxy.name,
                    node: .proxy(
                        dialerProxy: proxy.dialerProxy,
                        unresolved: proxy.unresolved || !resolution.known
                    ),
                    owner: "provider:\(providerName)"
                )
                proxyRecordsByName[proxy.name] = proxy
            }
        }

        let inlineProxies = root["proxies"] as? [[String: Any]] ?? []
        let inlineProxiesAreValid = root["proxies"] == nil || root["proxies"] is [[String: Any]]
        var inlineRecords: [ProviderProxyRecord] = []
        for (index, proxy) in inlineProxies.enumerated() {
            guard let name = proxy["name"] as? String, !name.isEmpty else { continue }
            let dialer: String?
            var unresolved = false
            if let rawDialer = proxy["dialer-proxy"] {
                if let value = rawDialer as? String {
                    dialer = normalizedReference(value)
                } else {
                    dialer = nil
                    unresolved = true
                }
            } else {
                dialer = nil
            }
            let record = ProviderProxyRecord(
                name: name,
                proxy: proxy,
                dialerProxy: dialer,
                unresolved: unresolved
            )
            inlineRecords.append(record)
            proxyRecordsByName[name] = record
            insert(
                name,
                node: .proxy(dialerProxy: dialer, unresolved: unresolved),
                owner: "inline:\(index)"
            )
        }

        let groups = root["proxy-groups"] as? [[String: Any]] ?? []
        var groupDefinitionsByName: [String: [String: Any]] = [:]
        for group in groups {
            if let name = group["name"] as? String, groupDefinitionsByName[name] == nil {
                groupDefinitionsByName[name] = group
            }
        }

        for (index, group) in groups.enumerated() {
            guard let name = group["name"] as? String, !name.isEmpty else { continue }
            var candidates: [String] = []
            var unresolved = false

            let includeAll = groupFlag("include-all", in: group, unresolved: &unresolved)
            let includeAllProxiesFlag = groupFlag(
                "include-all-proxies",
                in: group,
                unresolved: &unresolved
            )
            let includeAllProvidersFlag = groupFlag(
                "include-all-providers",
                in: group,
                unresolved: &unresolved
            )
            let includeAllProxies = includeAll || includeAllProxiesFlag
            let includeAllProviders = includeAll || includeAllProvidersFlag

            func appendCandidate(
                _ rawName: String,
                applyIncludeFilter: Bool,
                record: ProviderProxyRecord?
            ) {
                let candidate = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else {
                    unresolved = true
                    return
                }
                let candidateType = record?.proxy["type"] as? String ??
                    groupDefinitionsByName[candidate]?["type"] as? String ??
                    builtinProxyType(candidate)
                guard let included = groupCandidateIncluded(
                    candidate,
                    proxyType: candidateType,
                    group: group,
                    applyIncludeFilter: applyIncludeFilter
                ) else {
                    unresolved = true
                    candidates.append(candidate)
                    referencedNames.insert(candidate)
                    return
                }
                if included {
                    candidates.append(candidate)
                    referencedNames.insert(candidate)
                }
            }

            if let rawCandidates = group["proxies"] {
                if let values = rawCandidates as? [String] {
                    for value in values {
                        appendCandidate(
                            value,
                            applyIncludeFilter: false,
                            record: proxyRecordsByName[value]
                        )
                    }
                } else {
                    unresolved = true
                }
            }

            if let rawNow = group["now"] {
                if let value = rawNow as? String {
                    appendCandidate(
                        value,
                        applyIncludeFilter: false,
                        record: proxyRecordsByName[value]
                    )
                } else {
                    unresolved = true
                }
            }

            if includeAllProxies {
                if !inlineProxiesAreValid {
                    unresolved = true
                } else {
                    for proxy in inlineRecords {
                        appendCandidate(
                            proxy.name,
                            applyIncludeFilter: true,
                            record: proxy
                        )
                    }
                }
            }

            let usedProviders: [String]
            if includeAllProviders {
                if !providerDefinitionsAreValid {
                    unresolved = true
                    usedProviders = []
                } else {
                    usedProviders = providerDefinitions.keys.sorted()
                }
            } else if let rawUse = group["use"] {
                if let values = rawUse as? [String] {
                    usedProviders = values
                } else {
                    unresolved = true
                    usedProviders = []
                }
            } else {
                usedProviders = []
            }

            for providerName in usedProviders {
                guard providersKnown[providerName] == true,
                      let members = providerMembers[providerName] else {
                    unresolved = true
                    continue
                }
                for member in members {
                    appendCandidate(
                        member.name,
                        applyIncludeFilter: true,
                        record: member
                    )
                }
            }

            if candidates.isEmpty {
                unresolved = true
            }
            insert(
                name,
                node: .group(candidates: unique(candidates), unresolved: unresolved),
                owner: "group:\(index)"
            )
        }

        return DependencyGraph(
            nodes: nodes,
            ambiguousNames: ambiguousNames,
            referencedNames: referencedNames
        )
    }

    private static func groupFlag(
        _ key: String,
        in group: [String: Any],
        unresolved: inout Bool
    ) -> Bool {
        guard let rawValue = group[key] else { return false }
        guard let value = rawValue as? Bool else {
            unresolved = true
            return false
        }
        return value
    }

    private static func groupCandidateIncluded(
        _ name: String,
        proxyType: String?,
        group: [String: Any],
        applyIncludeFilter: Bool
    ) -> Bool? {
        let include: String?
        if applyIncludeFilter, let raw = group["filter"] {
            guard let value = raw as? String else { return nil }
            include = value
        } else {
            include = nil
        }
        let exclude: String?
        if let raw = group["exclude-filter"] {
            guard let value = raw as? String else { return nil }
            exclude = value
        } else {
            exclude = nil
        }
        guard let nameMatches = matchesProviderFilters(name, include: include, exclude: exclude) else {
            return nil
        }
        guard nameMatches else { return false }

        guard let rawExcludeType = group["exclude-type"] else { return true }
        guard let excludeType = rawExcludeType as? String else { return nil }
        guard !excludeType.isEmpty else { return true }
        guard let proxyType else { return nil }
        let excludedTypes = excludeType.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !excludedTypes.contains { $0.caseInsensitiveCompare(proxyType) == .orderedSame }
    }

    private static func builtinProxyType(_ name: String) -> String? {
        switch name {
        case "DIRECT": return "Direct"
        case "REJECT": return "Reject"
        case "REJECT-DROP": return "Reject"
        case "PASS": return "Pass"
        case "COMPATIBLE": return "Compatible"
        default: return nil
        }
    }

    private static func resolveProvider(
        _ snapshot: ProviderSnapshot,
        definition: [String: Any]?
    ) -> ProviderResolution {
        var known = definition != nil && !snapshot.proxies.isEmpty
        let override = definition?["override"] as? [String: Any]
        if definition?["override"] != nil && override == nil {
            known = false
        }

        var providerDialer = snapshot.dialerProxy
        if providerDialer == nil, let raw = definition?["dialer-proxy"] as? String {
            providerDialer = raw
        }
        if definition?["dialer-proxy"] != nil,
           !(definition?["dialer-proxy"] is String) {
            known = false
        }

        var overrideDialer = snapshot.overrideDialerProxy
        if overrideDialer == nil, let raw = override?["dialer-proxy"] as? String {
            overrideDialer = raw
        }
        if override?["dialer-proxy"] != nil,
           !(override?["dialer-proxy"] is String) {
            known = false
        }

        let rawFilter: String?
        if let value = definition?["filter"] {
            rawFilter = value as? String
            if rawFilter == nil { known = false }
        } else {
            rawFilter = nil
        }
        let rawExcludeFilter: String?
        if let value = definition?["exclude-filter"] {
            rawExcludeFilter = value as? String
            if rawExcludeFilter == nil { known = false }
        } else {
            rawExcludeFilter = nil
        }

        let rawExcludeType: String?
        if let raw = definition?["exclude-type"] {
            rawExcludeType = raw as? String
            if rawExcludeType == nil { known = false }
        } else {
            rawExcludeType = nil
        }

        var records: [ProviderProxyRecord] = []
        var seenNames: [String: (rawName: String, fingerprint: Data?)] = [:]
        for rawProxy in snapshot.proxies {
            guard let rawName = rawProxy["name"] as? String, !rawName.isEmpty else {
                known = false
                continue
            }
            if let rawExcludeType, !rawExcludeType.isEmpty {
                guard let proxyType = rawProxy["type"] as? String else { continue }
                let excludedTypes = rawExcludeType.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if excludedTypes.contains(where: {
                    $0.caseInsensitiveCompare(proxyType) == .orderedSame
                }) {
                    continue
                }
            }
            guard let included = matchesProviderFilters(
                rawName,
                include: rawFilter,
                exclude: rawExcludeFilter
            ) else {
                known = false
                continue
            }
            if !included { continue }

            guard let effectiveName = providerProxyName(rawName, override: override) else {
                known = false
                continue
            }
            let fingerprint = proxyFingerprint(rawProxy)
            if let previous = seenNames[effectiveName] {
                if previous.rawName != rawName ||
                    previous.fingerprint == nil ||
                    fingerprint == nil ||
                    previous.fingerprint != fingerprint {
                    known = false
                }
                continue
            }
            seenNames[effectiveName] = (rawName, fingerprint)
            if fingerprint == nil { known = false }

            let rawProxyDialer: String?
            var proxyHasInvalidDialer = false
            if let rawValue = rawProxy["dialer-proxy"] {
                if let value = rawValue as? String {
                    rawProxyDialer = value
                } else {
                    rawProxyDialer = nil
                    proxyHasInvalidDialer = true
                }
            } else {
                rawProxyDialer = nil
            }

            let effectiveDialer: String?
            if let overrideDialer {
                effectiveDialer = normalizedReference(overrideDialer)
            } else if let providerDialer, !providerDialer.isEmpty {
                effectiveDialer = normalizedReference(providerDialer)
            } else if proxyHasInvalidDialer {
                effectiveDialer = nil
                known = false
            } else {
                effectiveDialer = normalizedReference(rawProxyDialer)
            }

            var materializedProxy = rawProxy
            materializedProxy["name"] = effectiveName
            records.append(ProviderProxyRecord(
                name: effectiveName,
                proxy: materializedProxy,
                dialerProxy: effectiveDialer,
                unresolved: !known || proxyHasInvalidDialer
            ))
        }

        if records.isEmpty {
            known = false
        }
        if !known {
            for index in records.indices {
                records[index].unresolved = true
            }
        }
        return ProviderResolution(proxies: records, known: known)
    }

    private static func providerProxyName(
        _ name: String,
        override: [String: Any]?
    ) -> String? {
        var result = name
        if let rawRules = override?["proxy-name"] {
            guard let rules = rawRules as? [Any] else { return nil }
            for rawRule in rules {
                guard let rule = rawRule as? [String: Any],
                      let pattern = rule["pattern"] as? String,
                      let target = rule["target"] as? String,
                      let expression = try? NSRegularExpression(pattern: pattern) else {
                    return nil
                }
                let range = NSRange(result.startIndex ..< result.endIndex, in: result)
                result = expression.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: target
                )
            }
        }

        let prefix: String
        if let rawPrefix = override?["additional-prefix"] {
            guard let value = rawPrefix as? String else { return nil }
            prefix = value
        } else {
            prefix = ""
        }
        let suffix: String
        if let rawSuffix = override?["additional-suffix"] {
            guard let value = rawSuffix as? String else { return nil }
            suffix = value
        } else {
            suffix = ""
        }
        return prefix + result + suffix
    }

    private static func matchesProviderFilters(
        _ name: String,
        include: String?,
        exclude: String?
    ) -> Bool? {
        if let exclude, !exclude.isEmpty {
            for pattern in exclude.components(separatedBy: "\u{60}") {
                guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
                let range = NSRange(name.startIndex ..< name.endIndex, in: name)
                if expression.firstMatch(in: name, options: [], range: range) != nil {
                    return false
                }
            }
        }

        guard let include, !include.isEmpty else { return true }
        var matched = false
        for pattern in include.components(separatedBy: "\u{60}") {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(name.startIndex ..< name.endIndex, in: name)
            if expression.firstMatch(in: name, options: [], range: range) != nil {
                matched = true
            }
        }
        return matched
    }

    private static func proxyFingerprint(_ proxy: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(proxy) else { return nil }
        return try? JSONSerialization.data(withJSONObject: proxy, options: [.sortedKeys])
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

        let definitions = root["proxy-providers"] as? [String: Any] ?? [:]
        for provider in providers {
            let definition = definitions[provider.name] as? [String: Any]
            let resolution = resolveProvider(provider, definition: definition)
            guard let proxy = resolution.proxies.first(where: { $0.name == target }) else { continue }
            return LocatedProxy(
                server: normalizedServerHost(proxy.proxy["server"] as? String),
                providerName: provider.name,
                proxy: proxy.proxy
            )
        }
        return nil
    }

    private static func assignRelay(
        in root: inout [String: Any],
        target: String,
        located: LocatedProxy?,
        relay: String
    ) -> Bool {
        if setInlineDialer(in: &root, target: target, relay: relay) {
            return true
        }
        guard let located,
              let providerName = located.providerName,
              !target.contains("\u{60}") else {
            return false
        }

        var proposedRoot = root
        var proxies = proposedRoot["proxies"] as? [[String: Any]] ?? []
        guard !proxies.contains(where: { ($0["name"] as? String) == target }) else { return false }
        var copy = located.proxy
        copy["dialer-proxy"] = relay
        proxies.append(copy)
        proposedRoot["proxies"] = proxies
        guard appendExactNameExclusion(target, toProvider: providerName, in: &proposedRoot) else {
            return false
        }
        root = proposedRoot
        return true
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

    private static func appendExactNameExclusion(
        _ name: String,
        toProvider providerName: String,
        in root: inout [String: Any]
    ) -> Bool {
        guard var providers = root["proxy-providers"] as? [String: Any],
              var provider = providers[providerName] as? [String: Any] else {
            return false
        }
        let existing: String?
        if let raw = provider["exclude-filter"] {
            guard let value = raw as? String else { return false }
            existing = value
        } else {
            existing = nil
        }
        provider["exclude-filter"] = excludeFilter(appendingExactName: name, to: existing)
        providers[providerName] = provider
        root["proxy-providers"] = providers
        return true
    }

    private static func excludeFilter(appendingExactName name: String, to existing: String?) -> String {
        guard !name.contains("\u{60}") else { return existing ?? "" }
        let clause = "^\(NSRegularExpression.escapedPattern(for: name))$"
        let current = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if current.isEmpty {
            return clause
        }
        let parts = current.components(separatedBy: "\u{60}")
        if parts.contains(clause) {
            return current
        }
        return current + "\u{60}" + clause
    }

    private static func normalizedReference(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
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

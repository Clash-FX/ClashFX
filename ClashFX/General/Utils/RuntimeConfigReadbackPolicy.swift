import CoreFoundation
import Foundation

/// Pure policy: metadata checks never invent core state or choose a new port.
enum RuntimeConfigReadbackPolicy {
    struct SyncIdentity: Equatable {
        let runtimeScope: String
        let apiURL: String
        let directAPI: Bool
        let secret: String
        let selectedConfig: String
        let coreUpdateEpoch: UInt64?
        var configurationGeneration: UInt64 = 0
    }

    static let proxyKeys = ["mixed-port", "port", "socks-port"]
    private static let confirmedListenerPortKeys = [
        "mixed-port", "port", "socks-port", "redir-port", "tproxy-port",
    ]

    static func canPromoteSyncReadback(
        captured: SyncIdentity,
        current: SyncIdentity,
        transactionBusy: Bool,
        transactionUncertain: Bool
    ) -> Bool {
        captured == current && !transactionBusy && !transactionUncertain
    }

    static func canRestoreVerifiedBaseline(
        scopeMatches: Bool,
        hasConfirmedBaseline: Bool,
        transactionBusy: Bool,
        transactionUncertain: Bool
    ) -> Bool {
        scopeMatches && hasConfirmedBaseline && !transactionBusy && !transactionUncertain
    }

    /// Publish the fresh baseline's basic metadata together with verification;
    /// never re-verify a currentConfig object left over from an earlier core.
    static func baselineMatchesReadback(confirmedID: UUID?, validatedID: UUID?) -> Bool {
        guard let confirmedID, let validatedID else { return false }
        return confirmedID == validatedID
    }

    static func confirmedBasicMetadata(_ root: [String: Any]) -> [String: Any]? {
        guard let mode = root["mode"] as? String,
              let logLevel = root["log-level"] as? String,
              let allowLan = root["allow-lan"].flatMap(boolean) else { return nil }
        var result: [String: Any] = ["mode": mode, "log-level": logLevel, "allow-lan": allowLan]
        for key in proxyKeys { result[key] = port(root[key]) }
        return result
    }

    static func port(_ value: Any?) -> Int {
        if let text = value as? String {
            guard let value = Int(text), (0 ... 65535).contains(value) else { return 0 }
            return value
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= 65535 else { return 0 }
        return number.intValue
    }

    static func preservingImplicitPorts(in source: [String: Any], confirmed: [String: Any]?, fallback: Int) -> [String: Any] {
        var root = source
        // Explicit values, including disabled ports, are a user request and must not be replaced.
        guard !proxyKeys.contains(where: { root[$0] != nil }) else { return root }
        if let confirmed, proxyKeys.contains(where: { port(confirmed[$0]) > 0 }) {
            for key in proxyKeys { root[key] = port(confirmed[key]) }
        } else {
            root["mixed-port"] = (1 ... 65535).contains(fallback) ? fallback : 7890
        }
        return root
    }

    /// The in-process bridge pins IPv6 to the value established by run/resume.
    /// A pending restart preference must not become a false readback expectation.
    static func preservingBuiltInSessionIPv6(in source: [String: Any], confirmed: [String: Any]?) -> [String: Any] {
        var root = source
        if let value = confirmed?["ipv6"], let enabled = boolean(value) {
            root["ipv6"] = enabled
        } else {
            root.removeValue(forKey: "ipv6")
        }
        return root
    }

    static func candidateError(_ root: [String: Any]) -> String? {
        guard proxyKeys.contains(where: { port(root[$0]) > 0 }) else {
            return "The desktop runtime configuration must keep a usable HTTP, SOCKS or mixed listener"
        }
        return nil
    }

    static func readbackError(expected: [String: Any], actual: [String: Any]) -> String? {
        for key in confirmedListenerPortKeys where port(expected[key]) != port(actual[key]) {
            return "Core readback did not confirm the requested \(key)"
        }
        if (expected["bind-address"] as? String ?? "*") != (actual["bind-address"] as? String ?? "*") {
            return "Core readback did not confirm the requested bind address"
        }
        if let mode = expected["mode"] as? String, actual["mode"] as? String != mode {
            return "Core readback did not confirm the requested outbound mode"
        }
        if (expected["allow-lan"] as? Bool ?? false) != (actual["allow-lan"] as? Bool ?? false) {
            return "Core readback did not confirm LAN access settings"
        }
        if let ipv6 = expected["ipv6"] as? Bool, actual["ipv6"] as? Bool != ipv6 {
            return "Core readback did not confirm IPv6 settings"
        }
        if let tun = expected["tun"] as? [String: Any], let enabled = tun["enable"] as? Bool {
            guard let liveTun = actual["tun"] as? [String: Any], liveTun["enable"] as? Bool == enabled else {
                return "Core readback did not confirm TUN settings"
            }
        }
        return nil
    }

    /// Refreshes only mutable scalar settings on a confirmed snapshot. The
    /// confirmed routing graph and all listener/TUN parameters stay intact.
    static func refreshedConfirmedRoot(
        _ confirmed: [String: Any],
        actual: [String: Any]
    ) -> [String: Any]? {
        guard listenerPortsMatch(confirmed, actual) else { return nil }

        if let expectedTunValue = confirmed["tun"] {
            guard let expectedTun = expectedTunValue as? [String: Any] else { return nil }
            if let expectedEnableValue = expectedTun["enable"] {
                guard let expectedEnable = boolean(expectedEnableValue),
                      let actualTun = actual["tun"] as? [String: Any],
                      let actualEnableValue = actualTun["enable"],
                      let actualEnable = boolean(actualEnableValue),
                      expectedEnable == actualEnable else {
                    return nil
                }
            }
        }

        var refreshed = confirmed
        for key in ["mode", "allow-lan", "ipv6", "log-level", "bind-address"] {
            guard let value = actual[key] else {
                refreshed.removeValue(forKey: key)
                continue
            }

            switch key {
            case "mode", "log-level", "bind-address":
                guard value is String else { return nil }
            case "allow-lan", "ipv6":
                guard boolean(value) != nil else { return nil }
            default:
                return nil
            }
            refreshed[key] = value
        }
        return refreshed
    }

    private static func listenerPortsMatch(_ expected: [String: Any], _ actual: [String: Any]) -> Bool {
        for key in confirmedListenerPortKeys {
            guard let expectedPort = comparablePort(expected[key]),
                  let actualPort = comparablePort(actual[key]),
                  expectedPort == actualPort else {
                return false
            }
        }
        return true
    }

    private static func comparablePort(_ value: Any?) -> Int? {
        guard let value = value else { return 0 }
        return exactPort(value)
    }

    private static func exactPort(_ value: Any) -> Int? {
        if let text = value as? String {
            guard let parsed = Int(text), (0 ... 65535).contains(parsed) else { return nil }
            return parsed
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              (0 ... 65535).contains(number.doubleValue) else {
            return nil
        }
        return number.intValue
    }

    private static func boolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// Persisted numbers are preferences for a new core, never proof of ownership.
    static func startupPortPreference(_ stored: [String: Any]?) -> [String: Any]? {
        guard let stored, let api = exactPort(stored["apiPort"] ?? 0), api > 0,
              let dns = exactPort(stored["dnsPort"] ?? 0), dns > 0 else { return nil }
        return ["apiPort": api, "dnsPort": dns, "owned": false]
    }

    static func portPlan(config: [String: Any], apiPort: Int, owned: Bool) -> [String: Any]? {
        guard let dns = config["dns"] as? [String: Any], let address = dns["listen"] as? String,
              let component = address.split(separator: ":").last,
              let dnsPort = Int(component), (1 ... 65535).contains(dnsPort),
              (1 ... 65535).contains(apiPort) else { return nil }
        return ["apiPort": apiPort, "dnsPort": dnsPort, "owned": owned]
    }
}

/// Sequences recovery teardown before the app publishes the stopped state.
/// Injected operations let tests verify the order without calling the core.
enum RuntimeConfigRecoveryFailureController {
    static func fence(
        suspendCore: () -> Void,
        invalidateScope: () -> Void,
        reportStopped: () -> Void
    ) {
        suspendCore()
        invalidateScope()
        reportStopped()
    }
}

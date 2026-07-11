//
//  Settings.swift
//  ClashX
//
//  Created by yicheng on 2020/12/18.
//  Copyright © 2020 west2online. All rights reserved.
//

import Foundation
import Network

enum Settings {
    /// Must be MaxMind MMDB format (verifyGEOIPDataBase uses oschwald/geoip2-golang, which rejects mihomo's proprietary .metadb).
    static let defaultMmdbDownloadUrl = "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"
    @UserDefault("mmdbDownloadUrl", defaultValue: defaultMmdbDownloadUrl)
    static var mmdbDownloadUrl: String

    @UserDefault("filterInterface", defaultValue: true)
    static var filterInterface: Bool

    @UserDefault("disableNoti", defaultValue: false)
    static var disableNoti: Bool

    @UserDefault("configAutoUpdateInterval", defaultValue: 48 * 60 * 60)
    static var configAutoUpdateInterval: TimeInterval

    static let proxyIgnoreListDefaultValue = ["192.168.0.0/16",
                                              "10.0.0.0/8",
                                              "172.16.0.0/12",
                                              "127.0.0.1",
                                              "localhost",
                                              "*.local",
                                              "timestamp.apple.com",
                                              "sequoia.apple.com",
                                              "seed-sequoia.siri.apple.com"]
    @UserDefault("proxyIgnoreList", defaultValue: proxyIgnoreListDefaultValue)
    static var proxyIgnoreList: [String]

    @UserDefault("tunRouteExcludeList", defaultValue: [])
    static var tunRouteExcludeList: [String]

    @UserDefault("tunRouteExcludeRawText", defaultValue: "")
    static var tunRouteExcludeRawText: String

    static func normalizeTunRouteExcludeEntries(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = legacyWildcardTunRouteExcludeEntry(trimmed) ?? trimmed
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    static func normalizeAndPersistTunRouteExcludeList() -> [String] {
        let rawEntries = tunRouteExcludeRawText
            .components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let source = rawEntries.isEmpty ? tunRouteExcludeList : rawEntries
        let normalized = normalizeTunRouteExcludeEntries(source)
        if normalized != tunRouteExcludeList {
            tunRouteExcludeList = normalized
        }
        if !rawEntries.isEmpty && normalized != rawEntries {
            tunRouteExcludeRawText = normalized.joined(separator: ",\n")
        }
        return normalized
    }

    private static func legacyWildcardTunRouteExcludeEntry(_ entry: String) -> String? {
        if entry == "10.*" {
            return "10.0.0.0/8"
        }
        if entry == "192.168.*" {
            return "192.168.0.0/16"
        }
        guard entry.hasPrefix("172."), entry.hasSuffix(".*") else {
            return nil
        }
        let components = entry.split(separator: ".")
        guard components.count == 3,
              let secondOctet = Int(components[1]),
              (16 ... 31).contains(secondOctet) else {
            return nil
        }
        return "172.\(secondOctet).0.0/16"
    }

    static func proxyIgnoreEntryToRule(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: { $0.isWhitespace || $0 == "," }) else { return nil }

        if let cidr = legacyWildcardTunRouteExcludeEntry(trimmed) {
            return "IP-CIDR,\(cidr),DIRECT,no-resolve"
        }

        if let slashIdx = trimmed.firstIndex(of: "/") {
            let host = String(trimmed[..<slashIdx])
            let prefix = String(trimmed[trimmed.index(after: slashIdx)...])
            guard let prefixLen = Int(prefix), prefixLen >= 0 else { return nil }
            if isValidIPv4(host), prefixLen <= 32 {
                return "IP-CIDR,\(host)/\(prefixLen),DIRECT,no-resolve"
            }
            if isValidIPv6(host), prefixLen <= 128 {
                return "IP-CIDR6,\(host)/\(prefixLen),DIRECT,no-resolve"
            }
            return nil
        }

        if trimmed.hasPrefix("*.") {
            let suffix = String(trimmed.dropFirst(2))
            guard isValidDomain(suffix) else { return nil }
            return "DOMAIN-SUFFIX,\(suffix),DIRECT"
        }

        if isValidIPv4(trimmed) {
            return "IP-CIDR,\(trimmed)/32,DIRECT,no-resolve"
        }

        if isValidIPv6(trimmed) {
            return "IP-CIDR6,\(trimmed)/128,DIRECT,no-resolve"
        }

        guard isValidDomain(trimmed) else { return nil }
        return "DOMAIN,\(trimmed),DIRECT"
    }

    static func proxyIgnoreListAsRules() -> [String] {
        proxyIgnoreList.compactMap { proxyIgnoreEntryToRule($0) }
    }

    private static func isValidIPv4(_ s: String) -> Bool {
        return IPv4Address(s) != nil
    }

    private static func isValidIPv6(_ s: String) -> Bool {
        return IPv6Address(s) != nil
    }

    private static func isValidDomain(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        guard !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        guard !s.contains("..") else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 1 else { return false }
        let labelRegex = try? NSRegularExpression(pattern: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
        for label in labels {
            let str = String(label)
            guard str.count <= 63 else { return false }
            guard labelRegex?.firstMatch(in: str, range: NSRange(0 ..< str.utf16.count)) != nil else { return false }
        }
        return true
    }

    static let defaultTunMTU = 1500
    static let minTunMTU = 1280
    static let maxTunMTU = 9000
    @UserDefault("tunMTU", defaultValue: defaultTunMTU)
    static var tunMTU: Int {
        didSet {
            if tunMTU < minTunMTU || tunMTU > maxTunMTU {
                tunMTU = defaultTunMTU
            }
        }
    }

    @UserDefault("tunInterfaceName", defaultValue: "")
    static var tunInterfaceName: String

    @UserDefault("disableMenubarNotice", defaultValue: false)
    static var disableMenubarNotice: Bool

    @UserDefault("proxyPort", defaultValue: 0)
    static var proxyPort: Int

    @UserDefault("apiPort", defaultValue: 0)
    static var apiPort: Int

    @UserDefault("apiPortAllowLan", defaultValue: false)
    static var apiPortAllowLan: Bool

    @UserDefault("disableSSIDList", defaultValue: [])
    static var disableSSIDList: [String]

    @UserDefault("enableIPV6", defaultValue: false)
    static var enableIPV6: Bool

    static let apiSecretKey = "api-secret"

    static var isApiSecretSet: Bool {
        return UserDefaults.standard.object(forKey: apiSecretKey) != nil
    }

    @UserDefault(apiSecretKey, defaultValue: "")
    static var apiSecret: String

    @UserDefault("overrideConfigSecret", defaultValue: false)
    static var overrideConfigSecret: Bool

    @UserDefault("kBuiltInApiMode", defaultValue: true)
    static var builtInApiMode: Bool

    static let disableShowCurrentProxyInMenu = !AppDelegate.isAboveMacOS14

    static let defaultBenchmarkUrl = "http://cp.cloudflare.com/generate_204"
    @UserDefault("benchMarkUrl", defaultValue: defaultBenchmarkUrl)
    static var benchMarkUrl: String {
        didSet {
            if benchMarkUrl.isEmpty {
                benchMarkUrl = defaultBenchmarkUrl
            }
        }
    }

    @UserDefault("lastDelayBenchmarkConfig", defaultValue: "")
    static var lastDelayBenchmarkConfig: String

    @UserDefault("lastDelayBenchmarkURL", defaultValue: defaultBenchmarkUrl)
    static var lastDelayBenchmarkURL: String

    @UserDefault("lastDelayBenchmarkTimeout", defaultValue: 5000)
    static var lastDelayBenchmarkTimeout: Int

    @UserDefault("hideDockIcon", defaultValue: false)
    static var hideDockIcon: Bool

    @UserDefault("kDisableRestoreProxy", defaultValue: false)
    static var disableRestoreProxy: Bool

    @UserDefault("enhancedMode", defaultValue: false)
    static var enhancedMode: Bool

    @UserDefault("enhancedModeUseCustomConfig", defaultValue: false)
    static var enhancedModeUseCustomConfig: Bool

    @UserDefault("bypassChineseApps", defaultValue: false)
    static var bypassChineseApps: Bool

    @UserDefault("appLanguage", defaultValue: "")
    static var appLanguage: String

    @UserDefault("selectedMenuIconID", defaultValue: "default")
    static var selectedMenuIconID: String

    // MARK: - Update Channel (Lab)

    /// When true, Sparkle additionally accepts items tagged <sparkle:channel>lab</sparkle:channel>; off = stable only.
    @UserDefault("isLabChannel", defaultValue: false)
    static var isLabChannel: Bool

    /// Posted on isLabChannel change. Observed by menu bar badge, settings pane, and about window.
    static let labChannelDidChangeNotification = Notification.Name("ClashFX.labChannelDidChange")

    static func setLabChannel(_ enabled: Bool) {
        let old = isLabChannel
        isLabChannel = enabled
        if old != enabled {
            NotificationCenter.default.post(name: labChannelDidChangeNotification, object: nil)
        }
    }

    // MARK: - Tray Menu Visibility

    @UserDefault("trayMenuShowProxyMode", defaultValue: true)
    static var trayMenuShowProxyMode: Bool

    @UserDefault("trayMenuShowNodeSwitch", defaultValue: true)
    static var trayMenuShowNodeSwitch: Bool

    /// Proxy Actions group
    @UserDefault("trayMenuShowProxyActions", defaultValue: true)
    static var trayMenuShowProxyActions: Bool

    @UserDefault("trayMenuShowSystemProxy", defaultValue: true)
    static var trayMenuShowSystemProxy: Bool

    @UserDefault("trayMenuShowTurnOffProxy", defaultValue: true)
    static var trayMenuShowTurnOffProxy: Bool

    @UserDefault("trayMenuShowEnhancedMode", defaultValue: true)
    static var trayMenuShowEnhancedMode: Bool

    @UserDefault("trayMenuShowAdvancedTun", defaultValue: true)
    static var trayMenuShowAdvancedTun: Bool

    @UserDefault("trayMenuShowBypassChineseApps", defaultValue: true)
    static var trayMenuShowBypassChineseApps: Bool

    @UserDefault("trayMenuShowCopyShellCmd", defaultValue: true)
    static var trayMenuShowCopyShellCmd: Bool

    /// General Settings group
    @UserDefault("trayMenuShowGeneralSettings", defaultValue: true)
    static var trayMenuShowGeneralSettings: Bool

    @UserDefault("trayMenuShowStartAtLogin", defaultValue: true)
    static var trayMenuShowStartAtLogin: Bool

    @UserDefault("trayMenuShowNetSpeed", defaultValue: true)
    static var trayMenuShowNetSpeed: Bool

    @UserDefault("trayMenuShowAllowLan", defaultValue: true)
    static var trayMenuShowAllowLan: Bool

    /// Tools group
    @UserDefault("trayMenuShowTools", defaultValue: true)
    static var trayMenuShowTools: Bool

    @UserDefault("trayMenuShowBenchmark", defaultValue: true)
    static var trayMenuShowBenchmark: Bool

    @UserDefault("trayMenuShowDashboard", defaultValue: true)
    static var trayMenuShowDashboard: Bool

    @UserDefault("trayMenuShowConnections", defaultValue: true)
    static var trayMenuShowConnections: Bool

    /// Configs group
    @UserDefault("trayMenuShowConfigs", defaultValue: true)
    static var trayMenuShowConfigs: Bool

    @UserDefault("trayMenuShowConfigSwitcher", defaultValue: true)
    static var trayMenuShowConfigSwitcher: Bool

    @UserDefault("trayMenuShowConfigEditor", defaultValue: true)
    static var trayMenuShowConfigEditor: Bool

    @UserDefault("trayMenuShowProfileMixin", defaultValue: true)
    static var trayMenuShowProfileMixin: Bool

    @UserDefault("trayMenuShowOpenConfigFolder", defaultValue: true)
    static var trayMenuShowOpenConfigFolder: Bool

    @UserDefault("trayMenuShowReloadConfig", defaultValue: true)
    static var trayMenuShowReloadConfig: Bool

    @UserDefault("trayMenuShowUpdateExternal", defaultValue: true)
    static var trayMenuShowUpdateExternal: Bool

    @UserDefault("trayMenuShowRemoteConfig", defaultValue: true)
    static var trayMenuShowRemoteConfig: Bool

    @UserDefault("trayMenuShowRemoteController", defaultValue: true)
    static var trayMenuShowRemoteController: Bool

    /// Language (single toggle)
    @UserDefault("trayMenuShowLanguage", defaultValue: true)
    static var trayMenuShowLanguage: Bool

    /// Help group
    @UserDefault("trayMenuShowHelp", defaultValue: true)
    static var trayMenuShowHelp: Bool

    @UserDefault("trayMenuShowAbout", defaultValue: true)
    static var trayMenuShowAbout: Bool

    @UserDefault("trayMenuShowCheckUpdate", defaultValue: true)
    static var trayMenuShowCheckUpdate: Bool

    @UserDefault("trayMenuShowLogLevel", defaultValue: true)
    static var trayMenuShowLogLevel: Bool

    @UserDefault("trayMenuShowShowLog", defaultValue: true)
    static var trayMenuShowShowLog: Bool

    @UserDefault("trayMenuShowPorts", defaultValue: true)
    static var trayMenuShowPorts: Bool

    @UserDefault("trayMenuShowFeedback", defaultValue: true)
    static var trayMenuShowFeedback: Bool

    @UserDefault("trayMenuShowCopyDiagnostic", defaultValue: true)
    static var trayMenuShowCopyDiagnostic: Bool

    @UserDefault("trayMenuShowCrashLogs", defaultValue: true)
    static var trayMenuShowCrashLogs: Bool

    @UserDefault("trayMenuShowRollback", defaultValue: true)
    static var trayMenuShowRollback: Bool
}

//
//  Settings.swift
//  ClashX
//
//  Created by yicheng on 2020/12/18.
//  Copyright © 2020 west2online. All rights reserved.
//

import Foundation

enum Settings {
    // Must be MaxMind MMDB format (verifyGEOIPDataBase uses oschwald/geoip2-golang, which rejects mihomo's proprietary .metadb).
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

    @UserDefault("kDisableRestoreProxy", defaultValue: false)
    static var disableRestoreProxy: Bool

    @UserDefault("enhancedMode", defaultValue: false)
    static var enhancedMode: Bool

    @UserDefault("appLanguage", defaultValue: "")
    static var appLanguage: String

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

    @UserDefault("trayMenuShowEnhancedMode", defaultValue: true)
    static var trayMenuShowEnhancedMode: Bool

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
}

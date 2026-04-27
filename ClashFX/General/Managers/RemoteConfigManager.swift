//
//  RemoteConfigManager.swift
//  ClashX
//
//  Created by yicheng on 2018/11/6.
//  Copyright © 2018 west2online. All rights reserved.
//

import Alamofire
import Cocoa

class RemoteConfigManager {
    private static let generatedShareLinkTemplateVersion = 4
    private static let generatedShareLinkMarker = "clashfx-generated: share-links"
    private static let generatedShareLinkMigrationKey = "kGeneratedShareLinkRemoteConfigMigrationVersion"
    private static let defaultGeoIPDataURL = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
    private static let defaultGeoSiteDataURL = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
    private static let defaultMMDBDataURL = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"

    private static let shareLinkSchemes = [
        "ss://", "vmess://", "trojan://", "vless://",
        "hysteria://", "hysteria2://", "hy2://",
    ]

    var configs: [RemoteConfigModel] = []
    var refreshActivity: NSBackgroundActivityScheduler?

    static let shared = RemoteConfigManager()

    private init() {
        if let savedConfigs = UserDefaults.standard.object(forKey: "kRemoteConfigs") as? Data {
            let decoder = JSONDecoder()
            if let loadedConfig = try? decoder.decode([RemoteConfigModel].self, from: savedConfigs) {
                configs = loadedConfig
            } else {
                assertionFailure()
            }
        }
        migrateOldRemoteConfig()
        setupAutoUpdateTimer()
    }

    func saveConfigs() {
        Logger.log("Saving Remote Config Setting")
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(configs) {
            UserDefaults.standard.set(encoded, forKey: "kRemoteConfigs")
        }
    }

    func migrateOldRemoteConfig() {
        if let url = UserDefaults.standard.string(forKey: "kRemoteConfigUrl"),
           let name = URL(string: url)?.host {
            configs.append(RemoteConfigModel(url: url, name: name))
            UserDefaults.standard.removeObject(forKey: "kRemoteConfigUrl")
            saveConfigs()
        }
    }

    func setupAutoUpdateTimer() {
        refreshActivity?.invalidate()
        refreshActivity = nil
        guard RemoteConfigManager.autoUpdateEnable else {
            Logger.log("autoUpdateEnable did not enable,autoUpateTimer invalidated.")
            return
        }
        Logger.log("set up autoUpateTimer")

        refreshActivity = NSBackgroundActivityScheduler(identifier: "com.clashfx.configupdate")
        refreshActivity?.repeats = true
        refreshActivity?.interval = 60 * 60 * 2 // Two hour
        refreshActivity?.tolerance = 60 * 60

        refreshActivity?.schedule { [weak self] completionHandler in
            self?.autoUpdateCheck()
            completionHandler(NSBackgroundActivityScheduler.Result.finished)
        }
    }

    static var autoUpdateEnable: Bool {
        get {
            return UserDefaults.standard.object(forKey: "kAutoUpdateEnable") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "kAutoUpdateEnable")
            RemoteConfigManager.shared.setupAutoUpdateTimer()
        }
    }

    @objc func autoUpdateCheck() {
        guard RemoteConfigManager.autoUpdateEnable else { return }
        Logger.log("Tigger config auto update check")
        updateCheck()
    }

    func updateCheck(ignoreTimeLimit: Bool = false, showNotification: Bool = false) {
        let currentConfigName = ConfigManager.selectConfigName

        let group = DispatchGroup()

        for config in configs {
            if config.updating { continue }
            let timeLimitNoMantians = Date().timeIntervalSince(config.updateTime ?? Date(timeIntervalSince1970: 0)) < Settings.configAutoUpdateInterval

            if timeLimitNoMantians && !ignoreTimeLimit {
                Logger.log("[Auto Upgrade] Bypassing \(config.name) due to time check")
                continue
            }
            Logger.log("[Auto Upgrade] Requesting \(config.name)")
            let isCurrentConfig = config.name == currentConfigName
            config.updating = true
            group.enter()
            RemoteConfigManager.updateConfig(config: config) {
                [weak config] error in
                guard let config = config else { return }

                config.updating = false
                group.leave()
                if error == nil {
                    config.updateTime = Date()
                }

                if isCurrentConfig {
                    if let error = error {
                        // Fail
                        if showNotification {
                            NSUserNotificationCenter.default
                                .post(title: NSLocalizedString("Remote Config Update Fail", comment: ""),
                                      info: "\(config.name): \(error)")
                        }

                    } else {
                        // Success
                        if showNotification {
                            let info = "\(config.name): \(NSLocalizedString("Succeed!", comment: ""))"
                            NSUserNotificationCenter.default
                                .post(title: NSLocalizedString("Remote Config Update", comment: ""), info: info)
                        }
                        AppDelegate.shared.updateConfig(showNotification: false)
                    }
                }
                Logger.log("[Auto Upgrade] Finish \(config.name) result: \(error ?? "succeed")")
            }
        }

        group.notify(queue: .main) {
            [weak self] in
            self?.saveConfigs()
        }
    }

    /// User-Agent used for remote subscription downloads.
    ///
    /// Some subscription providers return a dummy or legacy-only config when the
    /// request advertises itself as ClashX/ClashFX, because they assume an old
    /// Dreamacro/clash-based client without SS-2022 support. ClashFX ships a
    /// mihomo-based core, so using a mihomo UA avoids that false downgrade.
    private static let subscriptionUserAgent = "mihomo/1.19.24"

    static func getRemoteConfigData(config: RemoteConfigModel, complete: @escaping ((String?, String?) -> Void)) {
        guard var urlRequest = try? URLRequest(url: config.url, method: .get) else {
            assertionFailure()
            Logger.log("[getRemoteConfigData] url incorrect,\(config.name) \(config.url)")
            return
        }
        urlRequest.cachePolicy = .reloadIgnoringCacheData
        urlRequest.setValue(subscriptionUserAgent, forHTTPHeaderField: "User-Agent")

        AF.request(urlRequest)
            .validate()
            .responseString(encoding: .utf8) { res in
                complete(try? res.result.get(), res.response?.suggestedFilename)
            }
    }

    static func tryDecodeBase64(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("<html"),
              !trimmed.contains("<!DOCTYPE"),
              !trimmed.hasPrefix("{"),
              !trimmed.hasPrefix("port:"),
              !trimmed.hasPrefix("mixed-port:"),
              !trimmed.contains("proxies:"),
              !trimmed.contains("proxy-groups:"),
              !shareLinkSchemes.contains(where: { trimmed.hasPrefix($0) }) else {
            return nil
        }
        let base64Cleaned = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64Cleaned.padding(toLength: ((base64Cleaned.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }

        if decoded.contains("proxies:") || decoded.contains("proxy-groups:") || decoded.contains("port:") || decoded.contains("mixed-port:") {
            return decoded
        }

        // Decoded content is a list of share links (ss://, vmess://, etc.)
        if let generated = buildConfigFromShareLinks(decoded) {
            return generated
        }

        return decoded
    }

    // MARK: - Share link parsing

    private static func buildConfigFromShareLinks(_ decoded: String) -> String? {
        let lines = decoded
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }

        var proxies: [String] = []
        var names: [String] = []

        for line in lines {
            // Some subscriptions double-encode each URI: try base64-decoding
            // lines that don't start with a known scheme.
            let candidate: String
            if shareLinkSchemes.contains(where: { line.hasPrefix($0) }) {
                candidate = line
            } else if let innerDecoded = decodeBase64ToString(line),
                      shareLinkSchemes.contains(where: { innerDecoded.hasPrefix($0) }) {
                candidate = innerDecoded
            } else {
                continue
            }

            guard let proxy = parseShareLink(candidate) else {
                continue
            }
            proxies.append(proxy.yaml)
            names.append("\"\(escapeYAML(proxy.name))\"")
        }

        guard !proxies.isEmpty else { return nil }

        let proxyList = names.joined(separator: ", ")
        return """
        # \(generatedShareLinkMarker)
        # clashfx-template-version: \(generatedShareLinkTemplateVersion)
        # This file was auto-generated by ClashFX from share-link subscriptions.
        # It is a compatibility config, not a user-authored rule file.
        # ClashFX may safely auto-upgrade this generated template.
        # Current template: geosite + geoip CN direct routing.
        mode: rule
        log-level: info
        geodata-mode: true

        geox-url:
          geoip: "\(defaultGeoIPDataURL)"
          geosite: "\(defaultGeoSiteDataURL)"
          mmdb: "\(defaultMMDBDataURL)"

        dns:
          enable: true
          ipv6: false
          enhanced-mode: redir-host
          nameserver:
            - 223.5.5.5
            - 119.29.29.29
          fallback:
            - 1.1.1.1
            - 8.8.8.8
          fallback-filter:
            geoip: true
            geoip-code: CN

        proxies:
        \(proxies.joined(separator: "\n"))

        proxy-groups:
          - name: "Auto"
            type: url-test
            proxies: [\(proxyList)]
            url: "http://cp.cloudflare.com/generate_204"
            interval: 300
          - name: "Proxy"
            type: select
            proxies: ["Auto", "DIRECT", \(proxyList)]

        rules:
          - DOMAIN,localhost,DIRECT
          - DOMAIN-SUFFIX,local,DIRECT
          - DOMAIN-SUFFIX,cn,DIRECT
          - GEOSITE,private,DIRECT
          - GEOSITE,cn,DIRECT
          - DOMAIN,www.baidu.com,DIRECT
          - DOMAIN,baidu.com,DIRECT
          - DOMAIN-KEYWORD,baidu,DIRECT
          - DOMAIN-SUFFIX,baidu.com,DIRECT
          - DOMAIN-SUFFIX,bdimg.com,DIRECT
          - DOMAIN-SUFFIX,bdstatic.com,DIRECT
          - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
          - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
          - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
          - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
          - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
          - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
          - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve
          - IP-CIDR6,::1/128,DIRECT,no-resolve
          - IP-CIDR6,fc00::/7,DIRECT,no-resolve
          - IP-CIDR6,fe80::/10,DIRECT,no-resolve
          - GEOIP,private,DIRECT
          - GEOIP,CN,DIRECT
          - MATCH,Auto
        """
    }

    private static func isGeneratedShareLinkConfig(_ string: String) -> Bool {
        string.contains(generatedShareLinkMarker)
    }

    private static func generatedTemplateVersion(from string: String) -> Int? {
        guard let line = string
            .split(whereSeparator: \.isNewline)
            .map({ String($0) })
            .first(where: { $0.contains("clashfx-template-version:") }) else {
            return nil
        }

        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return Int(parts[1].trimmingCharacters(in: .whitespaces))
    }

    private static func isLegacyGeneratedShareLinkConfig(_ string: String) -> Bool {
        if isGeneratedShareLinkConfig(string) {
            return true
        }

        let hasCoreShape = string.contains("mode: rule") &&
            string.contains("log-level: info") &&
            string.contains("- name: \"Auto\"") &&
            string.contains("type: url-test") &&
            string.contains("url: \"http://cp.cloudflare.com/generate_204\"") &&
            string.contains("- name: \"Proxy\"")

        guard hasCoreShape else { return false }

        let matchesKnownLegacyRules = string.contains("- MATCH,Proxy") ||
            string.contains("- DOMAIN-SUFFIX,baidu.com,DIRECT") ||
            string.contains("- GEOIP,CN,DIRECT")

        return matchesKnownLegacyRules &&
            !string.contains("proxy-providers:") &&
            !string.contains("rule-providers:")
    }

    private static func classifyGeneratedTemplate(rawConfig: String, finalConfig: String) -> (generatedByShareLinks: Bool, templateVersion: Int?) {
        if isGeneratedShareLinkConfig(finalConfig) {
            return (true, generatedTemplateVersion(from: finalConfig) ?? generatedShareLinkTemplateVersion)
        }

        if verifyConfig(string: rawConfig) == nil {
            return (false, nil)
        }

        return (isLegacyGeneratedShareLinkConfig(finalConfig), isLegacyGeneratedShareLinkConfig(finalConfig) ? generatedShareLinkTemplateVersion : nil)
    }

    func migrateLegacyGeneratedRemoteConfigsIfNeeded() {
        let targetVersion = Self.generatedShareLinkTemplateVersion
        let completedVersion = UserDefaults.standard.integer(forKey: Self.generatedShareLinkMigrationKey)
        guard completedVersion < targetVersion else { return }
        guard AppVersionUtil.hasVersionChanged || AppVersionUtil.isFirstLaunch else { return }

        let candidates = configs.filter { config in
            if config.generatedByShareLinks,
               (config.generatedTemplateVersion ?? 0) < targetVersion {
                return true
            }

            let path = Paths.localConfigPath(for: config.name)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            return Self.isLegacyGeneratedShareLinkConfig(content)
        }

        guard !candidates.isEmpty else {
            UserDefaults.standard.set(targetVersion, forKey: Self.generatedShareLinkMigrationKey)
            return
        }

        let group = DispatchGroup()
        var didUpdateSelectedConfig = false
        var upgradedConfigs = [String]()

        for config in candidates {
            group.enter()
            Self.getRemoteConfigData(config: config) { rawConfig, _ in
                guard let rawConfig else {
                    group.leave()
                    return
                }
                guard let decoded = Self.tryDecodeBase64(rawConfig),
                      Self.isGeneratedShareLinkConfig(decoded) else {
                    group.leave()
                    return
                }

                Self.updateConfig(config: config) { error in
                    if error == nil {
                        upgradedConfigs.append(config.name)
                        Logger.log("[Generated Config Migration] Auto-upgraded remote config '\(config.name)' to geosite template v\(targetVersion)")
                        if config.name == ConfigManager.selectConfigName {
                            didUpdateSelectedConfig = true
                        }
                    } else {
                        let message = error ?? "unknown error"
                        Logger.log("[Generated Config Migration] Failed to upgrade remote config '\(config.name)': \(message)", level: .warning)
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            self.saveConfigs()
            UserDefaults.standard.set(targetVersion, forKey: Self.generatedShareLinkMigrationKey)
            if !upgradedConfigs.isEmpty {
                Logger.log("[Generated Config Migration] Upgraded \(upgradedConfigs.count) generated remote config(s): \(upgradedConfigs.joined(separator: ", "))")
            }
            if didUpdateSelectedConfig {
                NSUserNotificationCenter.default.post(title: NSLocalizedString("Compatibility Config Auto-Upgraded", comment: ""),
                                                      info: NSLocalizedString("The active ClashFX-generated remote compatibility config was upgraded to the geosite + geoip CN direct template. Your custom rule files were not changed.", comment: ""))
                AppDelegate.shared.updateConfig(showNotification: false)
            }
        }
    }

    private struct ParsedSSProxy {
        let name: String
        let server: String
        let port: Int
        let cipher: String
        let password: String

        var yaml: String {
            """
              - name: \"\(RemoteConfigManager.escapeYAML(name))\"
                type: ss
                server: \"\(RemoteConfigManager.escapeYAML(server))\"
                port: \(port)
                cipher: \"\(RemoteConfigManager.escapeYAML(cipher))\"
                password: \"\(RemoteConfigManager.escapeYAML(password))\"
                udp: true
            """
        }
    }

    private static func parseSSShareLink(_ line: String) -> ParsedSSProxy? {
        guard line.hasPrefix("ss://") else { return nil }

        let raw = String(line.dropFirst(5))
        let fragmentSplit = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let body = String(fragmentSplit[0])
        let name = fragmentSplit.count > 1 ? (fragmentSplit[1].removingPercentEncoding ?? String(fragmentSplit[1])) : "Proxy"

        let queryless = body.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let main = String(queryless[0])

        let userAndHost: String
        if main.contains("@") {
            userAndHost = main
        } else if let decoded = decodeBase64ToString(main), decoded.contains("@") {
            userAndHost = decoded
        } else {
            return nil
        }

        let parts = userAndHost.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let userInfo = String(parts[0])
        let hostPort = String(parts[1])

        let methodAndPassword: String
        if userInfo.contains(":") {
            methodAndPassword = userInfo
        } else if let decoded = decodeBase64ToString(userInfo), decoded.contains(":") {
            methodAndPassword = decoded
        } else {
            return nil
        }

        let mp = methodAndPassword.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard mp.count == 2 else { return nil }
        let cipher = String(mp[0])
        let password = String(mp[1])

        let hp = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard hp.count == 2, let port = Int(hp[1]) else { return nil }

        return ParsedSSProxy(name: name, server: String(hp[0]), port: port, cipher: cipher, password: password)
    }

    private static func decodeBase64ToString(_ string: String) -> String? {
        let base64Cleaned = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64Cleaned.padding(toLength: ((base64Cleaned.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    private static func escapeYAML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Generic proxy result

    private struct ParsedProxyResult {
        let name: String
        let yaml: String
    }

    private static func parseShareLink(_ line: String) -> ParsedProxyResult? {
        if line.hasPrefix("ss://") {
            guard let ss = parseSSShareLink(line) else { return nil }
            return ParsedProxyResult(name: ss.name, yaml: ss.yaml)
        } else if line.hasPrefix("vmess://") {
            return parseVmessShareLink(line)
        } else if line.hasPrefix("trojan://") {
            return parseTrojanShareLink(line)
        } else if line.hasPrefix("vless://") {
            return parseVlessShareLink(line)
        } else if line.hasPrefix("hysteria2://") || line.hasPrefix("hy2://") {
            return parseHysteria2ShareLink(line)
        } else if line.hasPrefix("hysteria://") {
            return parseHysteriaShareLink(line)
        }
        return nil
    }

    // MARK: - VMess share link parser (V2RayN base64 JSON format)

    private static func parseVmessShareLink(_ line: String) -> ParsedProxyResult? {
        guard line.hasPrefix("vmess://") else { return nil }
        let raw = String(line.dropFirst(8))
        guard let decoded = decodeBase64ToString(raw),
              let data = decoded.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let name = (json["ps"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "VMess Proxy"
        let server = json["add"] as? String ?? ""
        guard let port = intValue(json["port"]), !server.isEmpty else { return nil }
        let uuid = json["id"] as? String ?? ""
        guard !uuid.isEmpty else { return nil }

        let alterId = intValue(json["aid"]) ?? 0
        let cipher = json["scy"] as? String ?? "auto"
        let network = json["net"] as? String ?? "tcp"
        let headerType = json["type"] as? String ?? "none"
        let isTLS = (json["tls"] as? String ?? "") == "tls"
        let sni = json["sni"] as? String ?? ""
        let host = json["host"] as? String ?? ""
        let path = json["path"] as? String ?? ""
        let alpn = json["alpn"] as? String ?? ""
        let fp = json["fp"] as? String ?? ""

        var lines: [String] = []
        lines.append("  - name: \"\(escapeYAML(name))\"")
        lines.append("    type: vmess")
        lines.append("    server: \"\(escapeYAML(server))\"")
        lines.append("    port: \(port)")
        lines.append("    uuid: \"\(escapeYAML(uuid))\"")
        lines.append("    alterId: \(alterId)")
        lines.append("    cipher: \"\(escapeYAML(cipher))\"")
        lines.append("    udp: true")

        if isTLS {
            lines.append("    tls: true")
            if !sni.isEmpty { lines.append("    servername: \"\(escapeYAML(sni))\"") }
            if !fp.isEmpty { lines.append("    client-fingerprint: \"\(escapeYAML(fp))\"") }
            appendALPN(to: &lines, alpn: alpn)
        }

        appendTransportOpts(to: &lines, network: network, headerType: headerType,
                            host: host, path: path, serviceName: "")

        return ParsedProxyResult(name: name, yaml: lines.joined(separator: "\n"))
    }

    // MARK: - Trojan share link parser

    private static func parseTrojanShareLink(_ line: String) -> ParsedProxyResult? {
        guard line.hasPrefix("trojan://") else { return nil }
        guard let components = URLComponents(string: line) else { return nil }

        let password = components.user?.removingPercentEncoding ?? components.user ?? ""
        let server = components.host ?? ""
        let port = components.port ?? 443
        let name = (components.fragment?.removingPercentEncoding ?? "Trojan Proxy")
            .trimmingCharacters(in: .whitespaces)

        guard !password.isEmpty, !server.isEmpty else { return nil }

        let q = queryDict(from: components)
        let sni = q["sni"] ?? q["peer"] ?? ""
        let transport = q["type"] ?? "tcp"
        let host = q["host"] ?? ""
        let path = q["path"] ?? ""
        let serviceName = q["serviceName"] ?? ""
        let allowInsecure = q["allowInsecure"] == "1" || q["insecure"] == "1"
        let alpn = q["alpn"] ?? ""
        let fp = q["fp"] ?? ""

        var lines: [String] = []
        lines.append("  - name: \"\(escapeYAML(name))\"")
        lines.append("    type: trojan")
        lines.append("    server: \"\(escapeYAML(server))\"")
        lines.append("    port: \(port)")
        lines.append("    password: \"\(escapeYAML(password))\"")
        lines.append("    udp: true")

        if !sni.isEmpty { lines.append("    sni: \"\(escapeYAML(sni))\"") }
        if allowInsecure { lines.append("    skip-cert-verify: true") }
        if !fp.isEmpty { lines.append("    client-fingerprint: \"\(escapeYAML(fp))\"") }
        appendALPN(to: &lines, alpn: alpn)
        appendTransportOpts(to: &lines, network: transport, headerType: "none",
                            host: host, path: path, serviceName: serviceName)

        return ParsedProxyResult(name: name, yaml: lines.joined(separator: "\n"))
    }

    // MARK: - VLESS share link parser

    private static func parseVlessShareLink(_ line: String) -> ParsedProxyResult? {
        guard line.hasPrefix("vless://") else { return nil }
        guard let components = URLComponents(string: line) else { return nil }

        let uuid = components.user?.removingPercentEncoding ?? components.user ?? ""
        let server = components.host ?? ""
        let port = components.port ?? 443
        let name = (components.fragment?.removingPercentEncoding ?? "VLESS Proxy")
            .trimmingCharacters(in: .whitespaces)

        guard !uuid.isEmpty, !server.isEmpty else { return nil }

        let q = queryDict(from: components)
        let security = q["security"] ?? "none"
        let sni = q["sni"] ?? ""
        let transport = q["type"] ?? "tcp"
        let host = q["host"] ?? ""
        let path = q["path"] ?? ""
        let serviceName = q["serviceName"] ?? ""
        let flow = q["flow"] ?? ""
        let fp = q["fp"] ?? ""
        let alpn = q["alpn"] ?? ""
        let allowInsecure = q["allowInsecure"] == "1" || q["insecure"] == "1"

        // Reality parameters
        let pbk = q["pbk"] ?? ""
        let sid = q["sid"] ?? ""

        var lines: [String] = []
        lines.append("  - name: \"\(escapeYAML(name))\"")
        lines.append("    type: vless")
        lines.append("    server: \"\(escapeYAML(server))\"")
        lines.append("    port: \(port)")
        lines.append("    uuid: \"\(escapeYAML(uuid))\"")
        lines.append("    udp: true")

        if !flow.isEmpty { lines.append("    flow: \"\(escapeYAML(flow))\"") }

        if security == "tls" || security == "reality" {
            lines.append("    tls: true")
            if !sni.isEmpty { lines.append("    servername: \"\(escapeYAML(sni))\"") }
            if allowInsecure { lines.append("    skip-cert-verify: true") }
            if !fp.isEmpty { lines.append("    client-fingerprint: \"\(escapeYAML(fp))\"") }
            appendALPN(to: &lines, alpn: alpn)

            if security == "reality" {
                lines.append("    reality-opts:")
                lines.append("      public-key: \"\(escapeYAML(pbk))\"")
                if !sid.isEmpty { lines.append("      short-id: \"\(escapeYAML(sid))\"") }
            }
        }

        appendTransportOpts(to: &lines, network: transport, headerType: "none",
                            host: host, path: path, serviceName: serviceName)

        return ParsedProxyResult(name: name, yaml: lines.joined(separator: "\n"))
    }

    // MARK: - Hysteria2 share link parser

    private static func parseHysteria2ShareLink(_ line: String) -> ParsedProxyResult? {
        guard line.hasPrefix("hysteria2://") || line.hasPrefix("hy2://") else { return nil }
        guard let components = URLComponents(string: line) else { return nil }

        let password = components.user?.removingPercentEncoding ?? components.user ?? ""
        let server = components.host ?? ""
        let port = components.port ?? 443
        let name = (components.fragment?.removingPercentEncoding ?? "Hysteria2 Proxy")
            .trimmingCharacters(in: .whitespaces)

        guard !server.isEmpty else { return nil }

        let q = queryDict(from: components)
        let sni = q["sni"] ?? ""
        let allowInsecure = q["insecure"] == "1" || q["allowInsecure"] == "1"
        let obfs = q["obfs"] ?? ""
        let obfsPassword = q["obfs-password"] ?? ""

        var lines: [String] = []
        lines.append("  - name: \"\(escapeYAML(name))\"")
        lines.append("    type: hysteria2")
        lines.append("    server: \"\(escapeYAML(server))\"")
        lines.append("    port: \(port)")
        if !password.isEmpty { lines.append("    password: \"\(escapeYAML(password))\"") }
        lines.append("    udp: true")

        if !sni.isEmpty { lines.append("    sni: \"\(escapeYAML(sni))\"") }
        if allowInsecure { lines.append("    skip-cert-verify: true") }
        if !obfs.isEmpty { lines.append("    obfs: \"\(escapeYAML(obfs))\"") }
        if !obfsPassword.isEmpty { lines.append("    obfs-password: \"\(escapeYAML(obfsPassword))\"") }

        return ParsedProxyResult(name: name, yaml: lines.joined(separator: "\n"))
    }

    // MARK: - Hysteria (v1) share link parser

    private static func parseHysteriaShareLink(_ line: String) -> ParsedProxyResult? {
        guard line.hasPrefix("hysteria://") else { return nil }
        guard let components = URLComponents(string: line) else { return nil }

        let server = components.host ?? ""
        let port = components.port ?? 443
        let name = (components.fragment?.removingPercentEncoding ?? "Hysteria Proxy")
            .trimmingCharacters(in: .whitespaces)

        guard !server.isEmpty else { return nil }

        let q = queryDict(from: components)
        let authBase64 = q["auth"] ?? ""
        let authStr: String
        if !authBase64.isEmpty, let decoded = decodeBase64ToString(authBase64) {
            authStr = decoded
        } else {
            authStr = authBase64
        }
        let sni = q["peer"] ?? q["sni"] ?? ""
        let allowInsecure = q["insecure"] == "1"
        let upMbps = q["upmbps"] ?? "100"
        let downMbps = q["downmbps"] ?? "100"
        let obfs = q["obfs"] ?? ""
        let obfsParam = q["obfsParam"] ?? ""
        let alpn = q["alpn"] ?? ""

        var lines: [String] = []
        lines.append("  - name: \"\(escapeYAML(name))\"")
        lines.append("    type: hysteria")
        lines.append("    server: \"\(escapeYAML(server))\"")
        lines.append("    port: \(port)")
        lines.append("    udp: true")

        if !authStr.isEmpty { lines.append("    auth-str: \"\(escapeYAML(authStr))\"") }
        lines.append("    up: \"\(escapeYAML(upMbps)) Mbps\"")
        lines.append("    down: \"\(escapeYAML(downMbps)) Mbps\"")

        if !sni.isEmpty { lines.append("    sni: \"\(escapeYAML(sni))\"") }
        if allowInsecure { lines.append("    skip-cert-verify: true") }
        if obfs == "xplus" && !obfsParam.isEmpty {
            lines.append("    obfs: \"\(escapeYAML(obfsParam))\"")
        }
        appendALPN(to: &lines, alpn: alpn)

        return ParsedProxyResult(name: name, yaml: lines.joined(separator: "\n"))
    }

    // MARK: - Share link parser helpers

    private static func queryDict(from components: URLComponents) -> [String: String] {
        var dict: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                dict[item.name] = value
            }
        }
        return dict
    }

    /// JSON values may arrive as Int, String, or Double depending on the provider.
    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    private static func appendTransportOpts(to lines: inout [String],
                                            network: String,
                                            headerType: String,
                                            host: String,
                                            path: String,
                                            serviceName: String) {
        switch network {
        case "ws":
            lines.append("    network: ws")
            if !path.isEmpty || !host.isEmpty {
                lines.append("    ws-opts:")
                if !path.isEmpty { lines.append("      path: \"\(escapeYAML(path))\"") }
                if !host.isEmpty {
                    lines.append("      headers:")
                    lines.append("        Host: \"\(escapeYAML(host))\"")
                }
            }
        case "grpc":
            lines.append("    network: grpc")
            let svcName = !serviceName.isEmpty ? serviceName : path
            if !svcName.isEmpty {
                lines.append("    grpc-opts:")
                lines.append("      grpc-service-name: \"\(escapeYAML(svcName))\"")
            }
        case "h2":
            lines.append("    network: h2")
            if !path.isEmpty || !host.isEmpty {
                lines.append("    h2-opts:")
                if !host.isEmpty {
                    lines.append("      host:")
                    lines.append("        - \"\(escapeYAML(host))\"")
                }
                if !path.isEmpty { lines.append("      path: \"\(escapeYAML(path))\"") }
            }
        case "tcp" where headerType == "http":
            lines.append("    network: http")
            if !path.isEmpty || !host.isEmpty {
                lines.append("    http-opts:")
                if !path.isEmpty {
                    lines.append("      path:")
                    lines.append("        - \"\(escapeYAML(path))\"")
                }
                if !host.isEmpty {
                    lines.append("      headers:")
                    lines.append("        Host:")
                    lines.append("          - \"\(escapeYAML(host))\"")
                }
            }
        default:
            break // tcp with no obfuscation is the default
        }
    }

    private static func appendALPN(to lines: inout [String], alpn: String) {
        guard !alpn.isEmpty else { return }
        lines.append("    alpn:")
        for a in alpn.split(separator: ",") {
            lines.append("      - \"\(a.trimmingCharacters(in: .whitespaces))\"")
        }
    }

    private static func looksLikeShareLinks(_ string: String) -> Bool {
        guard let firstLine = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) else { return false }
        return shareLinkSchemes.contains(where: { firstLine.hasPrefix($0) })
    }

    static func updateConfig(config: RemoteConfigModel, complete: ((String?) -> Void)? = nil) {
        getRemoteConfigData(config: config) { configString, suggestedFilename in
            guard let rawConfig = configString else {
                complete?(NSLocalizedString("Download fail", comment: ""))
                return
            }

            let newConfig: String
            if verifyConfig(string: rawConfig) == nil {
                newConfig = rawConfig
            } else if looksLikeShareLinks(rawConfig), let converted = buildConfigFromShareLinks(rawConfig) {
                Logger.log("[Remote Config] Content was raw share links, converted successfully")
                newConfig = converted
            } else if let decoded = tryDecodeBase64(rawConfig) {
                Logger.log("[Remote Config] Content was base64 encoded, decoded successfully")
                newConfig = decoded
            } else {
                newConfig = rawConfig
            }

            let generatedInfo = classifyGeneratedTemplate(rawConfig: rawConfig, finalConfig: newConfig)
            config.generatedByShareLinks = generatedInfo.generatedByShareLinks
            config.generatedTemplateVersion = generatedInfo.templateVersion

            let verifyRes = verifyConfig(string: newConfig)
            if let error = verifyRes {
                complete?(NSLocalizedString("Remote Config Format Error", comment: "") + ": " + error)
                return
            }

            if let suggestName = suggestedFilename, config.isPlaceHolderName {
                let name = URL(fileURLWithPath: suggestName).deletingPathExtension().lastPathComponent
                if !shared.configs.contains(where: { $0.name == name }) {
                    config.name = name
                }
            }
            config.isPlaceHolderName = false

            if ICloudManager.shared.useiCloud.value {
                ConfigFileManager.shared.stopWatchConfigFile()
            }
            if config.name == ConfigManager.selectConfigName {
                ConfigFileManager.shared.pauseForNextChange()
            }

            let saveAction: ((String) -> Void) = {
                savePath in
                do {
                    if FileManager.default.fileExists(atPath: savePath) {
                        try FileManager.default.removeItem(atPath: savePath)
                    }
                    try newConfig.write(to: URL(fileURLWithPath: savePath), atomically: true, encoding: .utf8)
                    complete?(nil)
                } catch let err {
                    complete?(err.localizedDescription)
                }
            }

            if ICloudManager.shared.useiCloud.value {
                ICloudManager.shared.getUrl { url in
                    guard let url = url else { return }
                    let saveUrl = url.appendingPathComponent(Paths.configFileName(for: config.name))
                    saveAction(saveUrl.path)
                }
            } else {
                let savePath = Paths.localConfigPath(for: config.name)
                saveAction(savePath)
            }
        }
    }

    static func verifyConfig(string: String) -> ErrorString? {
        let res = verifyClashConfig(string.goStringBuffer())?.toString() ?? "unknown error"
        if res == "success" {
            return nil
        } else {
            Logger.log(res, level: .error)
            return res
        }
    }

    static func showAdd() {
        let alertView = NSAlert()
        alertView.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alertView.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alertView.messageText = NSLocalizedString("Update remote config update interval", comment: "")
        let setupView = RemoteConfigUpdateIntervalSettingView()
        setupView.frame = NSRect(x: 0, y: 0, width: 100, height: 22)
        alertView.accessoryView = setupView
        let response = alertView.runModal()

        guard response == .alertFirstButtonReturn else { return }
        let stringValue = setupView.textfield.stringValue
        guard let intValue = Int(stringValue), intValue > 0 else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.informativeText = NSLocalizedString("Should be a least 1 hour", comment: "")
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
            return
        }
        Settings.configAutoUpdateInterval = TimeInterval(intValue * 60 * 60)
        RemoteConfigManager.shared.autoUpdateCheck()
    }
}

//
//  LabSupport.swift
//  ClashFX
//

import AppKit
import Foundation

enum LabSupport {
    static let issueTrackerURL = "https://github.com/Clash-FX/ClashFX/issues/new"
    static let stableDownloadURL = "https://github.com/Clash-FX/ClashFX/releases/latest"

    // MARK: - Diagnostic Report

    static func generateDiagnosticReport() -> String {
        var lines: [String] = []
        lines.append("## ClashFX Diagnostic Report")
        lines.append("")
        lines.append("- App Version: \(AppVersionUtil.currentVersion) (build \(AppVersionUtil.currentBuild))")
        lines.append("- Channel: \(AutoUpgradeManager.currentChannelDisplayName)\(Settings.isLabChannel ? " (subscribed)" : "")")
        lines.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("- Architecture: \(hardwareArchitecture())")
        lines.append("- Locale: \(Locale.current.identifier)")
        lines.append("")
        lines.append("### Feature flags")
        lines.append("- Enhanced Mode (TUN): \(Settings.enhancedMode)")
        lines.append("- Bypass Chinese Apps: \(Settings.bypassChineseApps)")
        lines.append("- Built-in API mode: \(Settings.builtInApiMode)")
        lines.append("- IPv6: \(Settings.enableIPV6)")
        lines.append("- System Proxy Auto Set: \(ConfigManager.shared.proxyPortAutoSet)")
        lines.append("- Proxy Paused by SSID: \(ConfigManager.shared.proxyShouldPaused.value)")
        lines.append("- Proxy Marked Changed by Other App: \(ConfigManager.shared.isProxySetByOtherVariable.value)")
        lines.append("- Enhanced Mode Active Runtime: \(ConfigManager.shared.isEnhancedModeActive)")
        lines.append("")
        lines.append("### Network state")
        lines.append("- Primary Interface: \(NetworkChangeNotifier.getPrimaryInterface() ?? "none")")
        lines.append("- Primary IP: \(NetworkChangeNotifier.getPrimaryIPAddress() ?? "none")")
        let (http, https, socks) = NetworkChangeNotifier.currentSystemProxySetting()
        lines.append("- System Proxy Ports: http=\(http), https=\(https), socks=\(socks)")
        lines.append("- Clash Config Ports: http=\(ConfigManager.shared.currentConfig?.usedHttpPort ?? 0), socks=\(ConfigManager.shared.currentConfig?.usedSocksPort ?? 0), api=\(ConfigManager.shared.apiPort)")
        lines.append("- System Proxy Matches ClashFX: \(NetworkChangeNotifier.isCurrentSystemSetToClash())")
        lines.append("- DNS Servers: \(NetworkChangeNotifier.getCurrentDns().joined(separator: ", "))")
        lines.append("- TUN Interfaces: \(tunInterfaceSummary())")
        lines.append("")
        lines.append("### Recent log (last 50 lines, sensitive data redacted)")
        lines.append("```")
        lines.append(recentLogLines(count: 50))
        lines.append("```")
        lines.append("")
        lines.append("### Recent mihomo_core log (last 30 lines, sensitive data redacted)")
        lines.append("```")
        lines.append(fileTailLines(path: kConfigFolderPath + ".mihomo_core.log", count: 30))
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    static func hardwareArchitecture() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        return machine.isEmpty ? "unknown" : machine
    }

    // MARK: - Log redaction

    static func recentLogLines(count: Int) -> String {
        let path = Logger.shared.logFilePath()
        return fileTailLines(path: path, count: count)
    }

    static func fileTailLines(path: String, count: Int) -> String {
        guard !path.isEmpty,
              let handle = FileHandle(forReadingAtPath: path)
        else { return "(no log file available)" }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        let maxBytes: UInt64 = 256 * 1024
        handle.seek(toFileOffset: size > maxBytes ? size - maxBytes : 0)
        let data = handle.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
        return redact(tail)
    }

    static func tunInterfaceSummary() -> String {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return "unavailable" }
        defer { freeifaddrs(ifaddrPtr) }

        var summaries: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            defer { ptr = addr.pointee.ifa_next }
            guard let ifaAddr = addr.pointee.ifa_addr else { continue }
            let name = String(cString: addr.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            guard ifaAddr.pointee.sa_family == UInt8(AF_INET) else {
                if !summaries.contains(where: { $0.hasPrefix("\(name):") }) {
                    summaries.append("\(name): no IPv4")
                }
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifaAddr,
                        socklen_t(ifaAddr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST)
            summaries.append("\(name): \(String(cString: hostname))")
        }
        return summaries.isEmpty ? "none" : summaries.joined(separator: ", ")
    }

    static func redact(_ input: String) -> String {
        var output = input
        let patterns: [(String, String)] = [
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<redacted-ipv4>"),
            (#"(?i)\b([a-z][a-z0-9+.-]*://)(?:[^@\s/]+@)?([a-z0-9-]+(?:\.[a-z0-9-]+)+)(?=[:/?#\s]|$)"#, "$1<redacted-host>"),
            (#"(?i)\b((?:server|host|hostname|dns|nameserver|url|endpoint|proxy|sni)\s*[:=]\s*)([a-z0-9-]+(?:\.[a-z0-9-]+)+)(?=[:/\s]|$)"#, "$1<redacted-host>"),
            (#"(?i)(?<![:/@])\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
            (#"(?<![0-9a-fA-F:])(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(?![0-9a-fA-F:])"#, "<redacted-ipv6>"),
            (#"(?<![0-9a-fA-F:])[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{1,4}){0,6}::[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{1,4}){0,6}(?![0-9a-fA-F:])"#, "<redacted-ipv6>"),
            (#"(?i)\b(authorization|bearer|token|password|secret|auth|key|cookie)\s*[:=]?\s+\S+"#, "$1 <redacted>"),
            (#"(?i)\b(authorization|bearer|token|password|secret|auth|key|cookie)\s*[:=]\s*\S+"#, "$1=<redacted>")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(output.startIndex ..< output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: replacement)
        }
        return output
    }

    // MARK: - Actions

    static func copyDiagnosticToPasteboardWithPreview() {
        let report = generateDiagnosticReport()
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Diagnostic information ready", comment: "")
        alert.informativeText = NSLocalizedString(
            "The report below has been sanitized (IPs, domains, and credentials replaced with placeholders). Review it before sharing, then copy to clipboard.",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("Copy to Clipboard", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = NSFont.userFixedPitchFont(ofSize: 11) ?? NSFont.systemFont(ofSize: 11)
        textView.string = report
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        alert.accessoryView = scroll

        if alert.runModal() == .alertFirstButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(report, forType: .string)
        }
    }

    static let maxIssueURLLength = 7500

    static func openGitHubIssueWithTemplate() {
        let isLab = AutoUpgradeManager.isLabBuild
        let title = isLab
            ? "[Lab \(AppVersionUtil.currentVersion)] "
            : "[\(AppVersionUtil.currentVersion)] "
        let report = generateDiagnosticReport()
        let fullBody = """
        <!-- Please describe what happened. The diagnostic info below was auto-filled. -->

        ## What happened

        ## Steps to reproduce
        1.
        2.

        ## Expected vs actual

        ---
        \(report)
        """
        var components = URLComponents(string: issueTrackerURL)!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: fullBody),
            URLQueryItem(name: "labels", value: isLab ? "lab" : "bug")
        ]
        if let url = components.url, url.absoluteString.count <= maxIssueURLLength {
            NSWorkspace.shared.open(url)
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)

        var short = URLComponents(string: issueTrackerURL)!
        short.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: """
            <!-- Diagnostic info was too long for URL prefill and has been copied to your clipboard. Please paste it below. -->

            ## What happened

            ## Steps to reproduce
            1.
            2.

            ## Diagnostic Report
            (paste from clipboard)
            """),
            URLQueryItem(name: "labels", value: isLab ? "lab" : "bug")
        ]
        if let url = short.url {
            NSWorkspace.shared.open(url)
        }
    }

    static func openCrashLogFolder() {
        let path = "\(NSHomeDirectory())/Library/Logs/DiagnosticReports"
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    // MARK: - Roll back to Stable

    static func presentRollbackDialog() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Roll back to the latest Stable release", comment: "")
        let info = """
        \(NSLocalizedString("This opens the Stable download page in your browser. To complete the rollback:", comment: ""))

        1. \(NSLocalizedString("Download ClashFX.dmg, then mount it.", comment: ""))
        2. \(NSLocalizedString("Drag ClashFX into Applications and choose \"Replace\".", comment: ""))
        3. \(NSLocalizedString("Reopen ClashFX.", comment: ""))

        ✓ \(NSLocalizedString("Your settings and configuration are preserved.", comment: ""))
        ✓ \(NSLocalizedString("Stable will not auto-upgrade back to Lab.", comment: ""))
        ⚠︎ \(NSLocalizedString("If Enhanced Mode is on, please disable it before downgrading.", comment: ""))
        """
        alert.informativeText = info
        alert.addButton(withTitle: NSLocalizedString("Open Download Page", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: stableDownloadURL) {
            NSWorkspace.shared.open(url)
        }
    }
}

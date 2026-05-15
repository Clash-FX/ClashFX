//
//  ClashStatusTool.swift
//  ClashX Pro
//
//  Created by yicheng on 2020/4/28.
//  Copyright © 2020 west2online. All rights reserved.
//

import Cocoa

class ClashStatusTool {
    private static var portCheckRetried = false
    private static let enhancedConfigPath = kConfigFolderPath + ".enhanced_config.yaml"
    private static let mihomoCoreLogPath = kConfigFolderPath + ".mihomo_core.log"

    static func checkPortConfig(cfg: ClashConfig?) {
        guard ConfigManager.shared.isRunning else { return }
        guard let cfg = cfg else { return }
        if cfg.usedHttpPort == 0 {
            Logger.log("checkPortConfig: port 0, mixedPort: \(cfg.mixedPort)", level: .error)

            if !portCheckRetried {
                portCheckRetried = true
                Logger.log("checkPortConfig: retrying after killing stale processes...", level: .warning)
                killStaleMihomoCore()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    ConfigManager.shared.isRunning = false
                    AppDelegate.shared.isConfigUpdating = false
                    AppDelegate.shared.updateConfig(showNotification: false)
                }
                return
            }

            let configToOpen = activeConfigPath()

            var detail = NSLocalizedString(
                "The proxy core is running, but reports no listening port (both mixed-port and port are 0). The active configuration is missing required port fields.",
                comment: "Diagnostic shown when mihomo_core returns a config with no usable port"
            )
            if let logTail = tailOfMihomoLog(maxLines: 12) {
                detail += "\n\n"
                    + NSLocalizedString("Recent core log:", comment: "Header above the last lines of mihomo_core log")
                    + "\n"
                    + logTail
            }

            let alert = NSAlert()
            alert.messageText = NSLocalizedString("ClashFX Start Error!", comment: "")
            alert.informativeText = detail
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Edit Config", comment: ""))
            DispatchQueue.main.async {
                let ret = alert.runModal()
                if ret == .alertSecondButtonReturn {
                    NSWorkspace.shared.openFile(configToOpen)
                }
                NSApp.terminate(nil)
            }
        }
    }

    private static func killStaleMihomoCore() {
        PrivilegedHelperManager.shared.helper()?.stopMihomoCore { _ in
            Logger.log("checkPortConfig: stale mihomo_core cleanup attempted")
        }
    }

    private static func activeConfigPath() -> String {
        if FileManager.default.fileExists(atPath: enhancedConfigPath) {
            return enhancedConfigPath
        }
        return Paths.localConfigPath(for: "config")
    }

    private static func tailOfMihomoLog(maxLines: Int) -> String? {
        guard maxLines > 0,
              let content = try? String(contentsOfFile: mihomoCoreLogPath, encoding: .utf8)
        else { return nil }
        let tail = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }
}

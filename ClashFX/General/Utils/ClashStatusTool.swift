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

            let alert = NSAlert()
            alert.messageText = NSLocalizedString("ClashFX Start Error!", comment: "")
            alert.informativeText = NSLocalizedString("Ports Open Fail, Please try to restart ClashFX", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Edit Config", comment: ""))
            DispatchQueue.main.async {
                let ret = alert.runModal()
                if ret == .alertSecondButtonReturn {
                    NSWorkspace.shared.openFile(Paths.localConfigPath(for: "config"))
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
}

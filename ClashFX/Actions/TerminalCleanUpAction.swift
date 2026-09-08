//
//  TerminalCleanUpAction.swift
//  ClashX
//
//  Created by yicheng on 2023/9/5.
//  Copyright © 2023 west2online. All rights reserved.
//

import AppKit
import Foundation
import RxSwift

enum TerminalConfirmAction {
    static func run() -> NSApplication.TerminateReply {
        guard !AppDelegate.shared.isTerminating else { return .terminateLater }
        guard confirmAction() else {
            return .terminateCancel
        }
        let policy = TerminationCleanupPolicy.make(observation: TerminationCleanupObservation(
            enhancedModeActive: ConfigManager.shared.isEnhancedModeActive,
            proxyPortAutoSet: ConfigManager.shared.proxyPortAutoSet,
            isProxySetByOther: ConfigManager.shared.isProxySetByOtherVariable.value,
            currentSystemSetToClash: NetworkChangeNotifier.isCurrentSystemSetToClash(looser: true),
            hasInterfaceProxySetToClash: NetworkChangeNotifier.hasInterfaceProxySetToClash()
        ))
        AppDelegate.shared.prepareForTerminationCleanup()
        let group = DispatchGroup()
        var proxyCleanupSucceeded = !policy.cleanSystemProxy

        if policy.cleanEnhancedMode {
            Logger.log("ClashFX quit need clean Enhanced Mode")
            group.enter()
            AppDelegate.shared.cleanupEnhancedModeForTermination {
                group.leave()
            }
        }

        if policy.cleanSystemProxy {
            Logger.log("ClashFX quit need clean proxy setting")
            group.enter()

            SystemProxyManager.shared.restoreForTermination { success in
                proxyCleanupSucceeded = success
                group.leave()
            }
        }

        if !policy.shouldWait {
            Logger.log("ClashFX quit without clean waiting")
            return .terminateNow
        }

        DispatchQueue.main.async {
            if let statusItem = AppDelegate.shared.statusItem, statusItem.menu != nil {
                let quittingMenu = NSMenu()
                let quittingItem = NSMenuItem(
                    title: NSLocalizedString("Quitting…", comment: ""),
                    action: nil,
                    keyEquivalent: ""
                )
                quittingItem.isEnabled = false
                quittingMenu.addItem(quittingItem)
                statusItem.menu = quittingMenu
            }
        }

        let terminationSettlement = ManagedOperationSettlement<Bool> { succeeded in
            DispatchQueue.main.async {
                if !succeeded {
                    AppDelegate.shared.cancelTerminationCleanup()
                }
                NSApp.reply(toApplicationShouldTerminate: succeeded)
                if !succeeded {
                    NSAlert.alert(with: NSLocalizedString(
                        "Proxy cleanup failed. ClashFX remains open; please try quitting again.",
                        comment: ""
                    ))
                }
            }
        }
        // Include an in-flight capture/enable followed by restore and readback.
        // These XPC stages each have their own eight-second deadline.
        terminationSettlement.scheduleTimeout(after: 40, queue: .main, outcome: { false })
        group.notify(queue: .main) {
            Logger.log("ClashFX quit cleanup completed: proxy success=\(proxyCleanupSucceeded)")
            _ = terminationSettlement.finish(proxyCleanupSucceeded)
        }

        Logger.log("ClashFX quit wait for clean up")
        return .terminateLater
    }

    static func confirmAction() -> Bool {
        if NSApp.activationPolicy() == .regular {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Quit ClashFX?", comment: "")
            alert.informativeText = NSLocalizedString("The active connections will be interrupted.", comment: "")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            return alert.runModal() == .alertFirstButtonReturn
        }
        return true
    }
}

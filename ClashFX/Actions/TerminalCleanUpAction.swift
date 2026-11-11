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
    /// Set when the user chose "Retry" after a failed cleanup, so the quit that
    /// follows does not ask "Quit ClashFX?" a second time.
    private static var skipNextConfirmation = false

    static func run() -> NSApplication.TerminateReply {
        guard AppDelegate.shared.ownsRuntimeControl else { return .terminateNow }
        guard !AppDelegate.shared.isTerminating else { return .terminateLater }
        let skipConfirmation = skipNextConfirmation
        skipNextConfirmation = false
        guard skipConfirmation || confirmAction() else {
            return .terminateCancel
        }
        let policy = TerminationCleanupPolicy.make(observation: TerminationCleanupObservation(
            enhancedModeActive: AppDelegate.shared.isEnhancedModeCleanupRequired,
            proxyPortAutoSet: ConfigManager.shared.proxyPortAutoSet,
            isProxySetByOther: ConfigManager.shared.isProxySetByOtherVariable.value,
            currentSystemSetToClash: NetworkChangeNotifier.isCurrentSystemSetToClash(looser: true),
            hasInterfaceProxySetToClash: NetworkChangeNotifier.hasInterfaceProxySetToClash(),
            preserveSystemProxyForFailClosed: Settings.claudeProxyLockEnabled
        ))
        AppDelegate.shared.prepareForTerminationCleanup()
        let group = DispatchGroup()
        var proxyCleanupSucceeded = !policy.cleanSystemProxy
        var enhancedCleanupSucceeded = !policy.cleanEnhancedMode

        if policy.cleanEnhancedMode {
            Logger.log("ClashFX quit need clean Enhanced Mode")
            group.enter()
            AppDelegate.shared.cleanupEnhancedModeForTermination { error in
                enhancedCleanupSucceeded = error == nil
                if let error {
                    Logger.log("ClashFX quit could not confirm core cleanup: \(error)", level: .error)
                }
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
                if succeeded {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                let resolution = TerminationCleanupFailureResolution.resolve(confirmFailureChoice())
                if resolution.cancelTerminationCleanup {
                    AppDelegate.shared.cancelTerminationCleanup()
                }
                NSApp.reply(toApplicationShouldTerminate: resolution.allowTermination)
                if resolution.retryQuit {
                    skipNextConfirmation = true
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        }
        // Include an in-flight capture/enable followed by restore and readback.
        // These XPC stages each have their own eight-second deadline.
        terminationSettlement.scheduleTimeout(after: 40, queue: .main, outcome: { false })
        group.notify(queue: .main) {
            Logger.log("ClashFX quit cleanup completed: proxy success=\(proxyCleanupSucceeded), core success=\(enhancedCleanupSucceeded)")
            _ = terminationSettlement.finish(proxyCleanupSucceeded && enhancedCleanupSucceeded)
        }

        Logger.log("ClashFX quit wait for clean up")
        return .terminateLater
    }

    /// Asked on the main queue after cleanup could not be confirmed. The app is
    /// activated first: as a menu-bar app its modal would otherwise open behind
    /// other windows and look like a hang.
    private static func confirmFailureChoice() -> TerminationCleanupFailureChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("ClashFX could not finish restoring network settings.", comment: "")
        alert.informativeText = NSLocalizedString(
            "You can retry, or quit anyway. If you quit anyway, ClashFX will continue restoring on the next launch.",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("Retry", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Quit Anyway", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Keep ClashFX Open", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertSecondButtonReturn: return .quitAnyway
        default: return .stayOpen
        }
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

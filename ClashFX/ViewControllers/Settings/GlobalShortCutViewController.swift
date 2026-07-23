//
//  GlobalShortCutViewController.swift
//  ClashX Pro
//
//  Created by yicheng on 2023/5/26.
//  Copyright © 2023 west2online. All rights reserved.
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleSystemProxyMode = Self("shortCut.toggleSystemProxyMode")
    static let copyShellCommand = Self(
        "shortCut.copyShellCommand",
        default: .init(.c, modifiers: [.control, .option])
    )
    static let copyExternalShellCommand = Self(
        "shortCut.copyExternalShellCommand",
        default: .init(.c, modifiers: [.control, .option, .shift])
    )

    static let modeDirect = Self("shortCut.modeDirect")
    static let modeRule = Self("shortCut.modeRule")
    static let modeGlobal = Self("shortCut.modeGlobal")

    static let toggleEnhancedMode = Self(
        "shortCut.toggleEnhancedMode",
        default: .init(.e, modifiers: [.control, .option])
    )

    static let log = Self("shortCut.log")
    static let dashboard = Self("shortCut.dashboard")
    static let benchmark = Self("shortCut.benchmark")
    static let openMenu = Self("shortCut.openMenu")
    static let nativeDashboard = Self("shortCut.nativeDashboard")
}

enum KeyboardShortCutManager {
    private static let copyShortcutMigrationKey = "kCopyShortcutMigrationV2"
    private static let unsafeCommandShortcutMigrationKey = "kUnsafeCommandShortcutMigrationV1"
    private static let defaultProxyModeShortcutMigrationKey =
        "kDefaultProxyModeShortcutMigrationV1"

    static func setup() {
        migrateUnsafeCopyShortcutsIfNeeded()
        migrateUnsafeCommandShortcutsIfNeeded()
        migrateDefaultProxyModeShortcutsIfNeeded()

        KeyboardShortcuts.onKeyUp(for: .toggleSystemProxyMode) {
            AppDelegate.shared.actionSetSystemProxy(nil)
        }

        KeyboardShortcuts.onKeyUp(for: .copyShellCommand) {
            AppDelegate.shared.actionCopyExportCommand(AppDelegate.shared.copyExportCommandMenuItem)
        }

        KeyboardShortcuts.onKeyUp(for: .copyExternalShellCommand) {
            AppDelegate.shared.actionCopyExportCommand(AppDelegate.shared.copyExportCommandExternalMenuItem)
        }

        KeyboardShortcuts.onKeyUp(for: .modeDirect) {
            AppDelegate.shared.switchProxyMode(mode: .direct, source: .globalShortcut)
        }

        KeyboardShortcuts.onKeyUp(for: .modeRule) {
            AppDelegate.shared.switchProxyMode(mode: .rule, source: .globalShortcut)
        }

        KeyboardShortcuts.onKeyUp(for: .modeGlobal) {
            AppDelegate.shared.switchProxyMode(mode: .global, source: .globalShortcut)
        }

        KeyboardShortcuts.onKeyUp(for: .toggleEnhancedMode) {
            AppDelegate.shared.actionToggleEnhancedMode(nil)
        }

        KeyboardShortcuts.onKeyUp(for: .log) {
            AppDelegate.shared.actionShowLog(nil)
        }

        KeyboardShortcuts.onKeyUp(for: .dashboard) {
            AppDelegate.shared.actionDashboard(nil)
        }

        KeyboardShortcuts.onKeyUp(for: .benchmark) {
            AppDelegate.shared.actionSpeedTest(AppDelegate.shared)
        }

        KeyboardShortcuts.onKeyUp(for: .openMenu) {
            AppDelegate.shared.statusItem.button?.performClick(nil)
        }
        if #available(macOS 10.15, *) {
            KeyboardShortcuts.onKeyUp(for: .nativeDashboard) {
                ClashWindowController<DashboardViewController>.create().showWindow(self)
            }
        }
    }

    private static func migrateUnsafeCopyShortcutsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: copyShortcutMigrationKey) else { return }

        let legacyCopy = KeyboardShortcuts.Shortcut(.c, modifiers: .command)
        let legacyExternalCopy = KeyboardShortcuts.Shortcut(.c, modifiers: [.command, .option])
        var migrated = false

        if KeyboardShortcuts.getShortcut(for: .copyShellCommand) == legacyCopy {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.c, modifiers: [.control, .option]),
                for: .copyShellCommand
            )
            migrated = true
        }

        if KeyboardShortcuts.getShortcut(for: .copyExternalShellCommand) == legacyExternalCopy {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.c, modifiers: [.control, .option, .shift]),
                for: .copyExternalShellCommand
            )
            migrated = true
        }

        UserDefaults.standard.set(true, forKey: copyShortcutMigrationKey)
        guard migrated else { return }

        Logger.log("Migrated unsafe copy shortcuts away from Command-C")
        NSUserNotificationCenter.default.post(
            title: NSLocalizedString("Global Shortcut Updated", comment: ""),
            info: NSLocalizedString("Copy shortcuts were changed to avoid intercepting Command-C. You can customize them in Settings > Global Shortcut.", comment: "")
        )
    }

    private static func migrateUnsafeCommandShortcutsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: unsafeCommandShortcutMigrationKey) else { return }

        let unsafeShortcuts: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut)] = [
            (.toggleSystemProxyMode, .init(.s, modifiers: .command)),
            (.log, .init(.l, modifiers: .command)),
            (.dashboard, .init(.d, modifiers: .command)),
            (.nativeDashboard, .init(.d, modifiers: [.command, .shift]))
        ]
        var migrated = false

        for (name, unsafeShortcut) in unsafeShortcuts
            where KeyboardShortcuts.getShortcut(for: name) == unsafeShortcut {
            KeyboardShortcuts.setShortcut(nil, for: name)
            migrated = true
        }

        UserDefaults.standard.set(true, forKey: unsafeCommandShortcutMigrationKey)
        guard migrated else { return }

        Logger.log("Removed unsafe Command-key global shortcuts")
        NSUserNotificationCenter.default.post(
            title: NSLocalizedString("Global Shortcut Updated", comment: ""),
            info: NSLocalizedString("Unsafe Command-key shortcuts were removed to restore standard macOS shortcuts. You can assign custom combinations in Settings > Global Shortcut.", comment: "")
        )
    }

    private static func migrateDefaultProxyModeShortcutsIfNeeded() {
        guard !UserDefaults.standard.bool(
            forKey: defaultProxyModeShortcutMigrationKey
        ) else {
            return
        }

        let legacyShortcuts: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut)] = [
            (.modeDirect, .init(.d, modifiers: .option)),
            (.modeRule, .init(.r, modifiers: .option)),
            (.modeGlobal, .init(.g, modifiers: .option))
        ]
        var migrated = false

        for (name, legacyShortcut) in legacyShortcuts
            where KeyboardShortcuts.getShortcut(for: name) == legacyShortcut {
            KeyboardShortcuts.setShortcut(nil, for: name)
            migrated = true
        }

        UserDefaults.standard.set(
            true,
            forKey: defaultProxyModeShortcutMigrationKey
        )
        guard migrated else { return }

        Logger.log("Removed default global shortcuts for outbound proxy modes")
        NSUserNotificationCenter.default.post(
            title: NSLocalizedString("Global Shortcut Updated", comment: ""),
            info: NSLocalizedString(
                "Default proxy-mode shortcuts were removed to prevent accidental background mode changes. You can assign custom combinations in Settings > Global Shortcut.",
                comment: ""
            )
        )
    }
}

class GlobalShortCutViewController: NSViewController {
    @IBOutlet var proxyBox: NSBox!
    @IBOutlet var modeBoxView: NSView!
    @IBOutlet var otherBoxView: NSView!

    override func viewDidLoad() {
        super.viewDidLoad()
        let systemProxy = getRecoder(for: .toggleSystemProxyMode)
        let copyShellCommand = getRecoder(for: .copyShellCommand)
        let copyShellCommandExternal = getRecoder(for: .copyExternalShellCommand)
        addGridView(in: proxyBox.contentView!, with: [
            [NSTextField(labelWithString: NSLocalizedString("System Proxy", comment: "")), systemProxy],
            [NSTextField(labelWithString: NSLocalizedString("Copy Shell Command", comment: "")), copyShellCommand],
            [NSTextField(labelWithString: NSLocalizedString("Copy Shell Command (External)", comment: "")), copyShellCommandExternal]
        ])

        addGridView(in: modeBoxView, with: [
            [NSTextField(labelWithString: NSLocalizedString("Direct Mode", comment: "")), getRecoder(for: .modeDirect)],
            [NSTextField(labelWithString: NSLocalizedString("Rule Mode", comment: "")), getRecoder(for: .modeRule)],
            [NSTextField(labelWithString: NSLocalizedString("Global Mode", comment: "")), getRecoder(for: .modeGlobal)],
            [NSTextField(labelWithString: NSLocalizedString("Enhanced Mode", comment: "")), getRecoder(for: .toggleEnhancedMode)]
        ])

        var otherItems: [[NSView]] = [
            [NSTextField(labelWithString: NSLocalizedString("Benchmark", comment: "")), getRecoder(for: .benchmark)],
            [NSTextField(labelWithString: NSLocalizedString("Open Menu", comment: "")), getRecoder(for: .openMenu)],
            [NSTextField(labelWithString: NSLocalizedString("Open Log", comment: "")), getRecoder(for: .log)],
            [NSTextField(labelWithString: NSLocalizedString("Open Dashboard", comment: "")), getRecoder(for: .dashboard)]
        ]
        if #available(macOS 10.15, *) {
            otherItems.append([NSTextField(labelWithString: NSLocalizedString("Open Connection Details", comment: "")), getRecoder(for: .nativeDashboard)])
        }
        addGridView(in: otherBoxView, with: otherItems)
    }

    private func getRecoder(for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.RecorderCocoa {
        let view = KeyboardShortcuts.RecorderCocoa(for: name)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    private func addGridView(in superView: NSView, with views: [[NSView]]) {
        let gridView = NSGridView(views: views)
        gridView.rowSpacing = 10
        superView.addSubview(gridView)
        gridView.makeConstraintsToBindToSuperview(NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        gridView.setContentHuggingPriority(.required, for: .vertical)
        gridView.setContentCompressionResistancePriority(.required, for: .vertical)
        gridView.xPlacement = .trailing
        gridView.column(at: 0).xPlacement = .leading
    }
}

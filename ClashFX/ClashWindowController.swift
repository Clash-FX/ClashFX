//
//  ClashWindowController.swift
//  ClashX
//
//  Created by yicheng on 2023/7/5.
//  Copyright © 2023 west2online. All rights reserved.
//
import AppKit

enum DockIconVisibility {
    private static var hasManagedWindows = false

    static func updateManagedWindowPresence(_ hasWindows: Bool) {
        hasManagedWindows = hasWindows
        refresh()
        if !hasWindows {
            DispatchQueue.main.async {
                refresh()
            }
        }
    }

    static func refresh(windowWillBeVisible: Bool = false) {
        guard !Settings.hideDockIcon else {
            NSApp.setActivationPolicy(.accessory)
            return
        }

        let hasVisibleWindow = windowWillBeVisible || hasManagedWindows || NSApp.windows.contains {
            $0.isVisible && !$0.isKind(of: NSPanel.self) && $0.styleMask.contains(.titled)
        }
        NSApp.setActivationPolicy(hasVisibleWindow ? .regular : .accessory)
    }
}

private class ClashWindowsRecorder {
    static let shared = ClashWindowsRecorder()
    var windowControllers = [NSWindowController]() {
        didSet {
            DockIconVisibility.updateManagedWindowPresence(!windowControllers.isEmpty)
        }
    }
}

class ClashWindowController<T: NSViewController>: NSWindowController, NSWindowDelegate {
    var onWindowClose: (() -> Void)?
    private var fromCache = false
    private var shouldPersistWindowSize: Bool {
        !(T.self == SettingsSidebarViewController.self)
    }

    private var lastSize: CGSize? {
        get {
            if let str = UserDefaults.standard.value(forKey: "lastSize.\(T.className())") as? String {
                return NSSizeFromString(str) as CGSize
            }
            return nil
        }
        set {
            if let size = newValue {
                UserDefaults.standard.set(NSStringFromSize(size), forKey: "lastSize.\(T.className())")
            }
        }
    }

    static func create() -> NSWindowController {
        if let wc = ClashWindowsRecorder.shared.windowControllers.first(where: { $0 is Self }) {
            (wc as? ClashWindowController)?.fromCache = true
            return wc
        }
        let win = NSWindow()
        let wc = ClashWindowController(window: win)
        if let X = T.self as? NibLoadable.Type {
            wc.contentViewController = (X.createFromNib(in: .main) as! NSViewController)
        } else {
            wc.contentViewController = T()
        }
        win.titlebarAppearsTransparent = false
        win.styleMask.insert(.closable)
        win.styleMask.insert(.resizable)
        win.styleMask.insert(.miniaturizable)
        if let title = wc.contentViewController?.title {
            win.title = title
        }
        ClashWindowsRecorder.shared.windowControllers.append(wc)
        return wc
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        if shouldPersistWindowSize, !fromCache, let lastSize = lastSize, lastSize != .zero {
            window?.setContentSize(lastSize)
            window?.center()
        }
        window?.makeKeyAndOrderFront(self)
        window?.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        ClashWindowsRecorder.shared.windowControllers.removeAll(where: { $0 == self })
        onWindowClose?()
        if let win = window {
            if shouldPersistWindowSize, !win.styleMask.contains(.fullScreen) {
                lastSize = win.frame.size
            }
        }
    }
}

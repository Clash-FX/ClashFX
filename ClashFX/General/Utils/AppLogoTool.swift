//
//  AppLogoTool.swift
//  ClashFX
//

import AppKit

enum AppLogoTool {
    static let customLogoPath = (NSHomeDirectory() as NSString).appendingPathComponent("/.config/clashfx/appLogo.png")

    static func loadCustomLogo() -> NSImage? {
        guard let image = NSImage(contentsOfFile: customLogoPath) else { return nil }
        return image
    }

    /// Apply the custom logo (or restore default) to the running application.
    static func applyLogo() {
        if let custom = loadCustomLogo() {
            NSApp.applicationIconImage = custom
        } else {
            // nil restores the default icon from the asset catalog
            NSApp.applicationIconImage = nil
        }
    }
}

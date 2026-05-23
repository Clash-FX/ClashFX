//
//  AppLogoTool.swift
//  ClashFX
//

import AppKit
import CoreServices

enum AppLogoTool {
    static let customLogoPath = (NSHomeDirectory() as NSString).appendingPathComponent("/.config/clashfx/appLogo.png")
    private static let selectedLogoKey = "AppLogoTool.selectedLogo"
    private static let defaultLogoID = "default"
    private static let customLogoID = "custom"

    struct BuiltInLogo: Equatable {
        let id: String
        let title: String
        let resourceName: String
    }

    static let builtInLogos = [
        BuiltInLogo(id: "fx-portal", title: NSLocalizedString("FX Portal", comment: ""), resourceName: "fx-portal"),
        BuiltInLogo(id: "fx-frost", title: NSLocalizedString("FX Frost", comment: ""), resourceName: "fx-frost"),
        BuiltInLogo(id: "classic-face", title: NSLocalizedString("Classic Face", comment: ""), resourceName: "classic-face"),
        BuiltInLogo(id: "classic-sitting", title: NSLocalizedString("Classic Sitting", comment: ""), resourceName: "classic-sitting"),
        BuiltInLogo(id: "flat-blue", title: NSLocalizedString("Flat Blue", comment: ""), resourceName: "flat-blue")
    ]

    static var selectedLogoID: String {
        UserDefaults.standard.string(forKey: selectedLogoKey) ?? defaultLogoID
    }

    static var isDefaultLogoSelected: Bool {
        selectedLogoID == defaultLogoID
    }

    static var canPersistBundleIcon: Bool {
        #if DEBUG
            return false
        #else
            let bundlePath = Bundle.main.bundlePath
            return !bundlePath.contains("/DerivedData/") && !bundlePath.contains("/Build/Products/")
        #endif
    }

    static var isDebugBuild: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    static func loadCustomLogo() -> NSImage? {
        guard let image = NSImage(contentsOfFile: customLogoPath) else { return nil }
        return image
    }

    static func loadBuiltInLogo(_ logo: BuiltInLogo) -> NSImage? {
        guard let url = Bundle.main.url(forResource: logo.resourceName, withExtension: "png", subdirectory: "AppIcons") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func loadSelectedLogo() -> NSImage? {
        let selectedID = selectedLogoID
        if selectedID == customLogoID {
            return loadCustomLogo()
        }
        guard let logo = builtInLogos.first(where: { $0.id == selectedID }) else { return nil }
        return loadBuiltInLogo(logo)
    }

    @discardableResult
    static func selectDefaultLogo() -> Bool {
        UserDefaults.standard.set(defaultLogoID, forKey: selectedLogoKey)
        return applyLogo()
    }

    @discardableResult
    static func selectCustomLogo() -> Bool {
        UserDefaults.standard.set(customLogoID, forKey: selectedLogoKey)
        return applyLogo()
    }

    @discardableResult
    static func selectBuiltInLogo(id: String) -> Bool {
        UserDefaults.standard.set(id, forKey: selectedLogoKey)
        return applyLogo()
    }

    /// Apply the custom logo (or restore default) to the running application.
    @discardableResult
    static func applyLogo() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        let didSetIcon: Bool

        if let selectedLogo = loadSelectedLogo() {
            NSApp.applicationIconImage = selectedLogo
            didSetIcon = canPersistBundleIcon ? NSWorkspace.shared.setIcon(selectedLogo, forFile: bundlePath) : true
        } else {
            // nil restores the default icon from the asset catalog
            NSApp.applicationIconImage = nil
            didSetIcon = canPersistBundleIcon ? NSWorkspace.shared.setIcon(nil, forFile: bundlePath) : true
        }

        if canPersistBundleIcon {
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        }
        NSWorkspace.shared.noteFileSystemChanged(bundlePath)
        refreshIconAppearanceCache()
        return didSetIcon
    }

    private static func refreshIconAppearanceCache() {
        guard let iconAppearanceClass = NSClassFromString("SLSIconAppearanceConfiguration") as? NSObject.Type else { return }

        let fetchSelector = NSSelectorFromString("fetchCurrentIconAppearanceConfiguration")
        guard iconAppearanceClass.responds(to: fetchSelector),
              let config = iconAppearanceClass.perform(fetchSelector)?.takeUnretainedValue() as? NSObject else { return }

        let saveSelector = NSSelectorFromString("save")
        guard config.responds(to: saveSelector) else { return }
        config.perform(saveSelector)
    }
}

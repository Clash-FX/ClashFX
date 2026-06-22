//
//  StatusItemTool.swift
//  ClashX Pro
//
//  Created by yicheng on 2023/3/1.
//  Copyright © 2023 west2online. All rights reserved.
//

import AppKit

enum StatusItemTool {
    struct BuiltInMenuIcon {
        let id: String
        let title: String
        let resourceName: String
    }

    static let defaultMenuIconID = "default"
    static let customMenuIconID = "custom"
    static let customImagePath = (NSHomeDirectory() as NSString).appendingPathComponent("/.config/clashfx/menuImage.png")

    static let builtInMenuIcons: [BuiltInMenuIcon] = [
        BuiltInMenuIcon(id: "cat-outline-face", title: NSLocalizedString("Outline Face Cat", comment: ""), resourceName: "menu-cat-outline-face"),
        BuiltInMenuIcon(id: "cat-filled-face", title: NSLocalizedString("Filled Face Cat", comment: ""), resourceName: "menu-cat-filled-face"),
        BuiltInMenuIcon(id: "cat-lightning-solid", title: NSLocalizedString("Lightning Cat", comment: ""), resourceName: "menu-cat-lightning-solid"),
        BuiltInMenuIcon(id: "cat-network", title: NSLocalizedString("Network Nodes", comment: ""), resourceName: "menu-cat-network"),
        BuiltInMenuIcon(id: "cat-shield", title: NSLocalizedString("Shield Cat", comment: ""), resourceName: "menu-cat-shield"),
        BuiltInMenuIcon(id: "cat-lightning-outline", title: NSLocalizedString("Bolt Outline", comment: ""), resourceName: "menu-cat-lightning-outline")
    ]

    static var selectedMenuIconID: String {
        if UserDefaults.standard.object(forKey: "selectedMenuIconID") == nil,
           FileManager.default.fileExists(atPath: customImagePath) {
            return customMenuIconID
        }
        return Settings.selectedMenuIconID
    }

    static var isDefaultMenuIconSelected: Bool {
        selectedMenuIconID == defaultMenuIconID
    }

    /// Must be accessed on main thread only.
    static var menuImage: NSImage = loadMenuImage()

    static func loadMenuImage() -> NSImage {
        let selectedID = selectedMenuIconID
        if selectedID == customMenuIconID,
           let image = loadCustomMenuIcon() {
            return image
        }
        if let builtInIcon = builtInMenuIcons.first(where: { $0.id == selectedID }),
           let image = loadBuiltInMenuIcon(builtInIcon) {
            return image
        }
        return loadDefaultMenuIcon()
    }

    static func loadDefaultPreviewIcon() -> NSImage {
        loadDefaultMenuIcon()
    }

    static func selectDefaultMenuIcon() {
        Settings.selectedMenuIconID = defaultMenuIconID
        reloadMenuImage()
    }

    static func selectCustomMenuIcon() {
        Settings.selectedMenuIconID = customMenuIconID
        reloadMenuImage()
    }

    static func selectBuiltInMenuIcon(id: String) {
        Settings.selectedMenuIconID = id
        reloadMenuImage()
    }

    static func loadBuiltInMenuIcon(_ icon: BuiltInMenuIcon) -> NSImage? {
        guard let imagePath = Bundle.main.path(forResource: icon.resourceName, ofType: "png", inDirectory: "MenuIcons"),
              let image = NSImage(contentsOfFile: imagePath) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private static func loadCustomMenuIcon() -> NSImage? {
        guard let image = NSImage(contentsOfFile: customImagePath) else { return nil }
        image.isTemplate = true
        return image
    }

    private static func loadDefaultMenuIcon() -> NSImage {
        if let imagePath = Bundle.main.path(forResource: "menu_icon@2x", ofType: "png"),
           let image = NSImage(contentsOfFile: imagePath) {
            image.isTemplate = true
            return image
        }
        return NSImage()
    }

    static func reloadMenuImage() {
        menuImage = loadMenuImage()
    }

    static let font: NSFont = {
        let fontSize: CGFloat = 9
        let font: NSFont
        if let fontName = UserDefaults.standard.string(forKey: "kStatusMenuFontName"),
           let f = NSFont(name: fontName, size: fontSize) {
            font = f
        } else {
            font = NSFont.menuBarFont(ofSize: fontSize)
        }
        return font
    }()

    static let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
}

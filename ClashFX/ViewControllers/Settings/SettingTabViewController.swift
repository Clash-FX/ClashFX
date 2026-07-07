//
//  SettingTabViewController.swift
//  ClashX Pro
//
//  Created by yicheng on 2022/11/20.
//  Copyright © 2022 west2online. All rights reserved.
//

import Cocoa

class SettingTabViewController: NSTabViewController, NibLoadable {
    private let visibleFrameMargin: CGFloat = 12
    private let minimumContentSize = NSSize(width: 400, height: 360)

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(macOS 15, *) {
            // NSTabViewController .toolbar style renders as a large gray block
            // on macOS 15 Sequoia — the toolbar layout changed significantly.
            // Fall back to segmentedControlOnTop which renders cleanly.
            tabStyle = .segmentedControlOnTop
        } else {
            tabStyle = .toolbar
        }
        configureTabIcons()
        insertAppearanceTab()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureTabIcons() {
        let symbols = ["gearshape", "keyboard", "hammer"]
        let fallbackGlyphs = ["⚙︎", "⌨︎", "🔨"]

        for (idx, item) in tabViewItems.enumerated() where idx < min(symbols.count, fallbackGlyphs.count) {
            if #available(macOS 11, *), let image = NSImage(systemSymbolName: symbols[idx], accessibilityDescription: nil) {
                item.image = image
            } else {
                item.image = makeFallbackIcon(glyph: fallbackGlyphs[idx])
            }
        }
    }

    private func makeFallbackIcon(glyph: String) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]

        let rect = NSRect(x: 0, y: 1, width: size.width, height: size.height)
        (glyph as NSString).draw(in: rect, withAttributes: attrs)
        image.isTemplate = true
        return image
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        constrainWindowToVisibleScreen()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        constrainWindowToVisibleScreen()
        DispatchQueue.main.async { [weak self] in
            self?.constrainWindowToVisibleScreen()
        }
    }

    private func constrainWindowToVisibleScreen() {
        guard let window = view.window,
              !window.styleMask.contains(.fullScreen) else { return }
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumContentSize
        window.contentMaxSize = maximumContentSize(for: window)

        let frame = frameConstrainedToVisibleScreen(window.frame, window: window)
        if frame != window.frame {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private func maximumContentSize(for window: NSWindow) -> NSSize {
        guard let visibleFrame = window.screen?.visibleFrame else {
            return NSSize(width: 900, height: 620)
        }
        let sampleContentHeight: CGFloat = 400
        let sampleContentWidth: CGFloat = minimumContentSize.width
        let sampleFrame = window.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: NSSize(width: sampleContentWidth, height: sampleContentHeight)
            )
        )
        let windowChromeHeight = sampleFrame.height - sampleContentHeight
        let windowChromeWidth = sampleFrame.width - sampleContentWidth
        return NSSize(
            width: max(minimumContentSize.width, visibleFrame.width - (visibleFrameMargin * 2) - windowChromeWidth),
            height: max(minimumContentSize.height, visibleFrame.height - (visibleFrameMargin * 2) - windowChromeHeight)
        )
    }

    private func frameConstrainedToVisibleScreen(_ frame: NSRect, window: NSWindow) -> NSRect {
        guard let visibleFrame = window.screen?.visibleFrame else { return frame }
        var adjustedFrame = frame
        let maximumFrameHeight = max(360, visibleFrame.height - (visibleFrameMargin * 2))
        if adjustedFrame.height > maximumFrameHeight {
            adjustedFrame.size.height = maximumFrameHeight
        }
        if adjustedFrame.maxY > visibleFrame.maxY - visibleFrameMargin {
            adjustedFrame.origin.y = visibleFrame.maxY - visibleFrameMargin - adjustedFrame.height
        }
        if adjustedFrame.minY < visibleFrame.minY + visibleFrameMargin {
            adjustedFrame.origin.y = visibleFrame.minY + visibleFrameMargin
        }
        if adjustedFrame.maxX > visibleFrame.maxX - visibleFrameMargin {
            adjustedFrame.origin.x = visibleFrame.maxX - visibleFrameMargin - adjustedFrame.width
        }
        if adjustedFrame.minX < visibleFrame.minX + visibleFrameMargin {
            adjustedFrame.origin.x = visibleFrame.minX + visibleFrameMargin
        }
        return adjustedFrame
    }

    private func insertAppearanceTab() {
        let vc = AppearanceSettingViewController()
        let item = NSTabViewItem(viewController: vc)
        item.label = NSLocalizedString("Appearance", comment: "")
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: nil)
        } else {
            item.image = makeFallbackIcon(glyph: "🎨")
        }
        insertTabViewItem(item, at: 1)
    }
}

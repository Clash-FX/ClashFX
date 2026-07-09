//
//  SettingTabViewController.swift
//  ClashX Pro
//
//  Created by yicheng on 2022/11/20.
//  Copyright © 2022 west2online. All rights reserved.
//

import Cocoa

class SettingsSidebarViewController: NSViewController {
    private let minimumContentSize = NSSize(width: 900, height: 500)
    private let preferredContent = NSSize(width: 900, height: 620)
    private let visibleFrameMargin: CGFloat = 16
    private let sidebarWidth: CGFloat = 176
    private var pageRows: [SettingsSidebarRowView] = []
    private var pages: [SettingsPage] = []
    private let contentContainer = NSView()
    private let brandIconView = NSImageView()
    private let brandTitleField = NSTextField(labelWithString: "ClashFX")
    private var currentViewController: NSViewController?

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContent))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Settings", comment: "")
        preferredContentSize = preferredContent
        pages = makePages()
        buildLayout()
        selectPage(at: 0)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appLogoDidChange),
            name: .appLogoDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindow()
        DispatchQueue.main.async { [weak self] in
            self?.configureWindow()
        }
    }

    private func configureWindow() {
        guard let window = view.window else { return }
        window.title = NSLocalizedString("Settings", comment: "")
        window.styleMask.formUnion([.titled, .closable, .miniaturizable])
        window.styleMask.remove(.resizable)

        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maxVisibleHeight = visibleFrame.map { max(minimumContentSize.height, $0.height - visibleFrameMargin * 2) }
            ?? preferredContent.height
        let fixedContentSize = NSSize(
            width: preferredContent.width,
            height: min(preferredContent.height, maxVisibleHeight)
        )

        preferredContentSize = fixedContentSize
        window.contentMinSize = fixedContentSize
        window.contentMaxSize = fixedContentSize
        window.setContentSize(fixedContentSize)

        if let visibleFrame {
            var frame = window.frame
            if frame.maxY > visibleFrame.maxY - visibleFrameMargin {
                frame.origin.y = visibleFrame.maxY - visibleFrameMargin - frame.height
            }
            if frame.minY < visibleFrame.minY + visibleFrameMargin {
                frame.origin.y = visibleFrame.minY + visibleFrameMargin
            }
            if frame.maxX > visibleFrame.maxX - visibleFrameMargin {
                frame.origin.x = visibleFrame.maxX - visibleFrameMargin - frame.width
            }
            if frame.minX < visibleFrame.minX + visibleFrameMargin {
                frame.origin.x = visibleFrame.minX + visibleFrameMargin
            }
            window.setFrame(frame, display: true, animate: false)
        }

        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func makePages() -> [SettingsPage] {
        let storyboard = NSStoryboard(name: "Main", bundle: .main)
        return [
            SettingsPage(
                title: NSLocalizedString("General", comment: ""),
                image: makeIcon(systemName: "gearshape", fallbackGlyph: "⚙︎"),
                viewController: storyboard.instantiateController(withIdentifier: "GeneralSettingViewController") as! NSViewController
            ),
            SettingsPage(
                title: NSLocalizedString("Appearance", comment: ""),
                image: makeIcon(systemName: "paintbrush", fallbackGlyph: "🎨"),
                viewController: AppearanceSettingViewController()
            ),
            SettingsPage(
                title: NSLocalizedString("Global Shortcut", comment: ""),
                image: makeIcon(systemName: "keyboard", fallbackGlyph: "⌨︎"),
                viewController: storyboard.instantiateController(withIdentifier: "GlobalShortCutViewController") as! NSViewController
            ),
            SettingsPage(
                title: NSLocalizedString("Debug", comment: ""),
                image: makeIcon(systemName: "hammer", fallbackGlyph: "🔨"),
                viewController: storyboard.instantiateController(withIdentifier: "DebugSettingViewController") as! NSViewController
            )
        ]
    }

    private func makeIcon(systemName: String, fallbackGlyph: String) -> NSImage {
        if #available(macOS 11, *), let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
            image.isTemplate = true
            return image
        }
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
        (fallbackGlyph as NSString).draw(in: NSRect(x: 0, y: 1, width: size.width, height: size.height), withAttributes: attrs)
        image.isTemplate = true
        return image
    }

    private func makeBrandView() -> NSView {
        let brandView = NSView()
        brandView.translatesAutoresizingMaskIntoConstraints = false

        brandIconView.translatesAutoresizingMaskIntoConstraints = false
        brandIconView.imageScaling = .scaleProportionallyUpOrDown
        brandIconView.image = currentAppLogo()

        brandTitleField.translatesAutoresizingMaskIntoConstraints = false
        brandTitleField.alignment = .center
        brandTitleField.font = .systemFont(ofSize: 13, weight: .semibold)
        brandTitleField.textColor = .labelColor

        brandView.addSubview(brandIconView)
        brandView.addSubview(brandTitleField)

        NSLayoutConstraint.activate([
            brandIconView.topAnchor.constraint(equalTo: brandView.topAnchor),
            brandIconView.centerXAnchor.constraint(equalTo: brandView.centerXAnchor),
            brandIconView.widthAnchor.constraint(equalToConstant: 48),
            brandIconView.heightAnchor.constraint(equalToConstant: 48),

            brandTitleField.topAnchor.constraint(equalTo: brandIconView.bottomAnchor, constant: 7),
            brandTitleField.leadingAnchor.constraint(equalTo: brandView.leadingAnchor, constant: 8),
            brandTitleField.trailingAnchor.constraint(equalTo: brandView.trailingAnchor, constant: -8),
            brandTitleField.bottomAnchor.constraint(equalTo: brandView.bottomAnchor)
        ])

        return brandView
    }

    private func currentAppLogo() -> NSImage {
        return AppLogoTool.loadSelectedLogo() ?? AppLogoTool.originalDefaultIcon
    }

    @objc private func appLogoDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.brandIconView.image = self.currentAppLogo()
            self.brandIconView.needsDisplay = true
        }
    }

    private func buildLayout() {
        let sidebarView = NSVisualEffectView()
        sidebarView.material = .sidebar
        sidebarView.blendingMode = .withinWindow
        sidebarView.state = .active
        sidebarView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let brandView = makeBrandView()

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        view.addSubview(sidebarView)
        view.addSubview(contentContainer)
        sidebarView.addSubview(brandView)
        sidebarView.addSubview(stack)

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: sidebarWidth),

            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            brandView.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 28),
            brandView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 18),
            brandView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -18),

            stack.topAnchor.constraint(equalTo: brandView.bottomAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: sidebarView.bottomAnchor, constant: -18)
        ])

        pageRows = pages.enumerated().map { index, page in
            let row = SettingsSidebarRowView(title: page.title, image: page.image)
            row.tag = index
            row.target = self
            row.action = #selector(selectPageFromRow(_:))
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 36).isActive = true
            return row
        }
    }

    @objc private func selectPageFromRow(_ sender: SettingsSidebarRowView) {
        selectPage(at: sender.tag)
    }

    private func selectPage(at index: Int) {
        guard index >= 0, index < pages.count else { return }

        if let currentViewController {
            currentViewController.view.removeFromSuperview()
            currentViewController.removeFromParent()
        }

        let nextViewController = SettingsPageHostViewController(contentViewController: pages[index].viewController)
        addChild(nextViewController)
        contentContainer.addSubview(nextViewController.view)
        nextViewController.view.translatesAutoresizingMaskIntoConstraints = false
        nextViewController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nextViewController.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        nextViewController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nextViewController.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            nextViewController.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            nextViewController.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            nextViewController.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            nextViewController.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        currentViewController = nextViewController

        for (rowIndex, row) in pageRows.enumerated() {
            row.isSelected = rowIndex == index
        }
    }
}

private struct SettingsPage {
    let title: String
    let image: NSImage
    let viewController: NSViewController
}

private final class SettingsSidebarRowView: NSControl {
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet {
            needsDisplay = true
            titleField.textColor = isSelected ? .labelColor : .secondaryLabelColor
        }
    }

    init(title: String, image: NSImage) {
        super.init(frame: .zero)
        wantsLayer = true

        imageView.image = image
        if #available(macOS 11.0, *) {
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            imageView.contentTintColor = .secondaryLabelColor
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13.5, weight: .medium)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(titleField)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 3), xRadius: 6, yRadius: 6).fill()
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}

private final class SettingsPageHostViewController: NSViewController {
    private let contentViewController: NSViewController
    private let pageInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

    init(contentViewController: NSViewController) {
        self.contentViewController = contentViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: NSSize(width: 724, height: 620)))
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        addChild(contentViewController)
        let childView = contentViewController.view
        let originalHeight = max(childView.frame.height, contentViewController.preferredContentSize.height)
        childView.translatesAutoresizingMaskIntoConstraints = false
        childView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        childView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        childView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        childView.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        documentView.addSubview(childView)

        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            childView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: pageInsets.top),
            childView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: pageInsets.left),
            childView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -pageInsets.right),
            childView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -pageInsets.bottom),
            childView.heightAnchor.constraint(greaterThanOrEqualToConstant: originalHeight),
            childView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor, constant: -(pageInsets.top + pageInsets.bottom))
        ])

        view = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        view.layoutSubtreeIfNeeded()
    }
}

class SettingTabViewController: NSTabViewController, NibLoadable {
    private let visibleFrameMargin: CGFloat = 12
    private let minimumContentSize = NSSize(width: 700, height: 460)
    private let preferredSettingsSize = NSSize(width: 760, height: 560)
    private let sidebarWidth: CGFloat = 180
    private var sidebarButtons: [NSButton] = []
    private var didInstallSidebarLayout = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureTabIcons()
        insertAppearanceTab()
        installSidebarLayout()
        preferredContentSize = preferredSettingsSize
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
        updateSidebarSelection()
        constrainWindowToVisibleScreen()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        constrainWindowToVisibleScreen()
        DispatchQueue.main.async { [weak self] in
            self?.refreshWindowLayout()
        }
    }

    private func constrainWindowToVisibleScreen() {
        guard let window = view.window,
              !window.styleMask.contains(.fullScreen) else { return }
        window.styleMask.formUnion([.titled, .closable, .resizable, .miniaturizable])
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumContentSize
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
        window.maxSize = NSSize(width: 100_000, height: 100_000)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.resizeIncrements = NSSize(width: 1, height: 1)

        let frame = frameConstrainedToVisibleScreen(window.frame, window: window)
        if frame != window.frame {
            window.setFrame(frame, display: true, animate: false)
        }
        view.layoutSubtreeIfNeeded()
    }

    private func refreshWindowLayout() {
        constrainWindowToVisibleScreen()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func frameConstrainedToVisibleScreen(_ frame: NSRect, window: NSWindow) -> NSRect {
        guard let visibleFrame = window.screen?.visibleFrame else { return frame }
        var adjustedFrame = frame
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size
        let maximumFrameHeight = max(360, visibleFrame.height - (visibleFrameMargin * 2))
        if adjustedFrame.width < minimumFrameSize.width {
            adjustedFrame.size.width = minimumFrameSize.width
        }
        if adjustedFrame.height < minimumFrameSize.height {
            adjustedFrame.size.height = minimumFrameSize.height
        }
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

    private func installSidebarLayout() {
        guard !didInstallSidebarLayout else { return }
        didInstallSidebarLayout = true

        let initialSize = NSSize(
            width: max(view.frame.width, preferredSettingsSize.width),
            height: max(view.frame.height, preferredSettingsSize.height)
        )
        let rootView = NSView(frame: NSRect(origin: .zero, size: initialSize))
        rootView.autoresizingMask = [.width, .height]

        let sidebarView = NSVisualEffectView()
        sidebarView.material = .sidebar
        sidebarView.blendingMode = .withinWindow
        sidebarView.state = .active
        sidebarView.translatesAutoresizingMaskIntoConstraints = false

        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 4
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        let sidebarContentView = NSView()
        sidebarContentView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        tabView.removeFromSuperview()
        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabView.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        rootView.addSubview(sidebarView)
        rootView.addSubview(contentView)
        sidebarView.addSubview(sidebarContentView)
        sidebarContentView.addSubview(sidebarStack)
        contentView.addSubview(tabView)

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: sidebarWidth),

            contentView.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            contentView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebarContentView.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 28),
            sidebarContentView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 18),
            sidebarContentView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -14),
            sidebarContentView.bottomAnchor.constraint(lessThanOrEqualTo: sidebarView.bottomAnchor, constant: -18),

            sidebarStack.topAnchor.constraint(equalTo: sidebarContentView.topAnchor),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebarContentView.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarContentView.trailingAnchor),
            sidebarStack.bottomAnchor.constraint(lessThanOrEqualTo: sidebarContentView.bottomAnchor),

            tabView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        sidebarButtons = tabViewItems.enumerated().map { index, item in
            let button = makeSidebarButton(for: item, index: index)
            sidebarStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: sidebarContentView.widthAnchor).isActive = true
            return button
        }

        view = rootView
        updateSidebarSelection()
    }

    private func makeSidebarButton(for item: NSTabViewItem, index: Int) -> NSButton {
        let button = NSButton(title: item.label, target: self, action: #selector(selectSidebarItem(_:)))
        button.tag = index
        button.image = item.image
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.isBordered = false
        button.setButtonType(.toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        if #available(macOS 11.0, *) {
            button.contentTintColor = .labelColor
        }
        return button
    }

    @objc private func selectSidebarItem(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < tabViewItems.count else { return }
        tabView.selectTabViewItem(tabViewItems[sender.tag])
    }

    private func updateSidebarSelection() {
        guard let selectedItem = tabView.selectedTabViewItem else { return }
        let selectedIndex = tabViewItems.firstIndex { $0 === selectedItem }
        for (index, button) in sidebarButtons.enumerated() {
            let isSelected = index == selectedIndex
            button.state = isSelected ? .on : .off
            if #available(macOS 10.14, *) {
                button.layer?.backgroundColor = isSelected
                    ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                    : NSColor.clear.cgColor
            }
        }
    }
}

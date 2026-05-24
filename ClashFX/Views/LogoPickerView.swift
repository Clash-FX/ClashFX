//
//  LogoPickerView.swift
//  ClashFX
//

import Cocoa
import UniformTypeIdentifiers

class LogoPickerView: ImagePickerView {
    private let builtInStack = NSStackView()
    private var iconButtons: [String: NSButton] = [:]

    private lazy var _config = ImagePickerConfig(
        imagePreviewSize: 40,
        descriptionText: NSLocalizedString("Drag and drop an image to customize the app icon.\nRecommended: 512x512 px (1024x1024 for @2x), PNG or ICNS format.", comment: ""),
        selectPanelTitle: NSLocalizedString("Select App Logo Image", comment: ""),
        dragUTI: "public.image",
        maxDimension: 1024,
        customImagePath: AppLogoTool.customLogoPath,
        changeFailedText: NSLocalizedString("Failed to change app logo", comment: ""),
        resetFailedText: NSLocalizedString("Failed to reset app logo", comment: ""),
        sizeWarningFormat: NSLocalizedString("Logo image is too large (%d×%d). Maximum allowed size is %d×%d pixels. Recommended size is 512×512 pixels (1024×1024 for Retina @2x).", comment: ""),
        allowedFileTypes: ["png", "jpg", "jpeg", "icns"],
        allowedContentTypesProvider: {
            if #available(macOS 11.0, *) { return [UTType.png, .jpeg, .icns] }
            return []
        }
    )

    override var pickerConfig: ImagePickerConfig {
        _config
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    override func currentImage() -> NSImage {
        if let selectedLogo = AppLogoTool.loadSelectedLogo() {
            return selectedLogo
        }
        return AppLogoTool.originalDefaultIcon
    }

    override func makeAdditionalContentView() -> NSView? {
        builtInStack.translatesAutoresizingMaskIntoConstraints = false
        builtInStack.orientation = .vertical
        builtInStack.alignment = .leading
        builtInStack.spacing = 6

        let titleLabel = NSTextField(labelWithString: NSLocalizedString("Built-in app icons", comment: ""))
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        builtInStack.addArrangedSubview(titleLabel)

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 6

        let defaultButton = makeIconButton(
            id: "default",
            title: NSLocalizedString("Default", comment: ""),
            image: AppLogoTool.originalDefaultIcon
        )
        let buttons = [defaultButton] + AppLogoTool.builtInLogos.map { logo in
            makeIconButton(id: logo.id, title: logo.title, image: AppLogoTool.loadBuiltInLogo(logo))
        }

        for rowStart in stride(from: 0, to: buttons.count, by: 3) {
            grid.addRow(with: Array(buttons[rowStart ..< min(rowStart + 3, buttons.count)]))
        }
        builtInStack.addArrangedSubview(grid)
        updateIconSelection()

        return builtInStack
    }

    override func didReloadImage() {
        let didApplyLogo: Bool
        if FileManager.default.fileExists(atPath: AppLogoTool.customLogoPath) {
            didApplyLogo = AppLogoTool.selectCustomLogo()
        } else {
            didApplyLogo = AppLogoTool.selectDefaultLogo()
        }
        updateIconSelection()
        showLogoChangeResult(didApplyLogo)
    }

    override func updatePreview() {
        imageView.image = currentImage()
        resetButton.isEnabled = !AppLogoTool.isDefaultLogoSelected || FileManager.default.fileExists(atPath: pickerConfig.customImagePath)
        updateIconSelection()
    }

    private func makeIconButton(id: String, title: String, image: NSImage?) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(selectBuiltInIcon(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.isBordered = false
        button.setButtonType(.toggle)
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.borderWidth = 1

        let iconView = NSImageView(image: image ?? NSImage())
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        button.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        button.addSubview(titleLabel)

        iconButtons[id] = button

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 96),
            button.heightAnchor.constraint(equalToConstant: 116),

            iconView.topAnchor.constraint(equalTo: button.topAnchor, constant: 10),
            iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: button.bottomAnchor, constant: -6)
        ])

        return button
    }

    @objc private func selectBuiltInIcon(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let didApplyLogo: Bool
        if id == "default" {
            didApplyLogo = AppLogoTool.selectDefaultLogo()
        } else {
            didApplyLogo = AppLogoTool.selectBuiltInLogo(id: id)
        }
        updatePreview()
        showLogoChangeResult(didApplyLogo)
    }

    private func updateIconSelection() {
        let selectedID = AppLogoTool.selectedLogoID
        for (id, button) in iconButtons {
            let isSelected = id == selectedID
            button.state = isSelected ? .on : .off
            button.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
            button.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }

    private func showLogoChangeResult(_ didApplyLogo: Bool) {
        let alert = NSAlert()
        if didApplyLogo {
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("App logo changed", comment: "")
            alert.informativeText = AppLogoTool.isDebugBuild
                ? NSLocalizedString("Running from Xcode only updates the current Dock icon. Copy a Release app bundle out of DerivedData to test Finder icon changes.", comment: "")
                : AppLogoTool.canPersistBundleIcon
                ? NSLocalizedString("Dock and Finder may need a moment to refresh the app icon.", comment: "")
                : NSLocalizedString("Dock changed for this session, but this app bundle cannot persist Finder icon changes.", comment: "")
        } else {
            alert.alertStyle = .warning
            alert.messageText = pickerConfig.changeFailedText
            alert.informativeText = NSLocalizedString("macOS did not allow changing the app bundle icon. If you are running from Xcode, try testing a copied app bundle.", comment: "")
        }
        alert.runModal()
    }
}

//
//  LogoPickerView.swift
//  ClashFX
//

import Cocoa
import UniformTypeIdentifiers

class LogoPickerView: ImagePickerView {
    private lazy var _config = ImagePickerConfig(
        imagePreviewSize: 48,
        placeholderText: NSLocalizedString("Drop image here", comment: ""),
        selectPanelTitle: NSLocalizedString("Select App Logo Image", comment: ""),
        dragUTI: "public.image",
        maxDimension: 1024,
        customImagePath: AppLogoTool.customLogoPath,
        changeFailedText: NSLocalizedString("Failed to change app logo", comment: ""),
        resetFailedText: NSLocalizedString("Failed to reset app logo", comment: ""),
        sizeWarningFormat: NSLocalizedString("Logo image is too large (%d×%d). Maximum allowed size is %d×%d pixels. Recommended size is 512×512 pixels (1024×1024 for Retina @2x).", comment: ""),
        allowedFileTypes: ["png", "jpg", "jpeg", "icns"],
        allowedContentTypesProvider: {
            if #available(macOS 11.0, *) { return [.png, .jpeg, .icns] }
            return []
        }
    )

    override var pickerConfig: ImagePickerConfig { _config }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    override func currentImage() -> NSImage {
        if let custom = AppLogoTool.loadCustomLogo() {
            return custom
        }
        return NSApp.applicationIconImage
    }

    override func updatePreview() {
        let hasCustom = FileManager.default.fileExists(atPath: AppLogoTool.customLogoPath)
        // Always show the icon image (never show placeholder for logo)
        placeholderLabel.isHidden = true
        resetButton.isHidden = !hasCustom
    }

    override func didReloadImage() {
        AppLogoTool.applyLogo()
    }
}

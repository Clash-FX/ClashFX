//
//  TrayIconPickerView.swift
//  ClashFX
//
//  Created by copilot on 2026/4/15.
//

import Cocoa
import UniformTypeIdentifiers

class TrayIconPickerView: ImagePickerView {
    private lazy var _config = ImagePickerConfig(
        imagePreviewSize: 32,
        placeholderText: NSLocalizedString("Drop PNG here", comment: ""),
        selectPanelTitle: NSLocalizedString("Select Tray Icon Image", comment: ""),
        dragUTI: "public.png",
        maxDimension: 256,
        customImagePath: StatusItemTool.customImagePath,
        changeFailedText: NSLocalizedString("Failed to change tray icon", comment: ""),
        resetFailedText: NSLocalizedString("Failed to reset tray icon", comment: ""),
        sizeWarningFormat: NSLocalizedString("Image is too large (%d×%d). Maximum allowed size is %d×%d pixels. Recommended size is 36×36 pixels (72×72 for Retina @2x).", comment: ""),
        allowedFileTypes: ["png"],
        allowedContentTypesProvider: {
            if #available(macOS 11.0, *) { return [.png] }
            return []
        }
    )

    override var pickerConfig: ImagePickerConfig { _config }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    override func currentImage() -> NSImage {
        return StatusItemTool.menuImage
    }

    override func didReloadImage() {
        StatusItemTool.reloadMenuImage()
        if let view = AppDelegate.shared.statusItemView as? StatusItemView {
            view.imageView.image = StatusItemTool.menuImage
        }
    }
}

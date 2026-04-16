//
//  TrayIconPickerView.swift
//  ClashFX
//
//  Created by copilot on 2026/4/15.
//

import Cocoa
import UniformTypeIdentifiers

class TrayIconPickerView: NSView {
    private let previewWell = NSView()
    private let imageView = NSImageView()
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let selectButton = NSButton()
    private let resetButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Icon preview well
        previewWell.translatesAutoresizingMaskIntoConstraints = false
        previewWell.wantsLayer = true
        previewWell.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        previewWell.layer?.borderWidth = 1.0
        previewWell.layer?.borderColor = NSColor.separatorColor.cgColor
        previewWell.layer?.cornerRadius = 6
        addSubview(previewWell)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = StatusItemTool.menuImage
        previewWell.addSubview(imageView)

        // Right side content
        let rightStack = NSStackView()
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 8
        addSubview(rightStack)

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.stringValue = NSLocalizedString("Drag and drop a PNG image, or click to select.\nRecommended: 36x36 px (72x72 for Retina @2x), PNG format.", comment: "")
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.font = NSFont.systemFont(ofSize: 11)
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 0
        rightStack.addArrangedSubview(descriptionLabel)

        // Buttons
        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.title = NSLocalizedString("Select Image", comment: "") + "..."
        selectButton.bezelStyle = .rounded
        selectButton.target = self
        selectButton.action = #selector(selectImage)

        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.title = NSLocalizedString("Reset to Default", comment: "")
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetImage)

        let buttonStack = NSStackView(views: [selectButton, resetButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 6
        rightStack.addArrangedSubview(buttonStack)

        NSLayoutConstraint.activate([
            previewWell.topAnchor.constraint(equalTo: topAnchor),
            previewWell.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewWell.widthAnchor.constraint(equalToConstant: 48),
            previewWell.heightAnchor.constraint(equalToConstant: 48),

            imageView.centerXAnchor.constraint(equalTo: previewWell.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: previewWell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 32),
            imageView.heightAnchor.constraint(equalToConstant: 32),

            rightStack.leadingAnchor.constraint(equalTo: previewWell.trailingAnchor, constant: 12),
            rightStack.topAnchor.constraint(equalTo: topAnchor),
            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            descriptionLabel.widthAnchor.constraint(equalTo: rightStack.widthAnchor),

            bottomAnchor.constraint(equalTo: rightStack.bottomAnchor),
        ])

        updateIconPreview()
    }

    private func updateIconPreview() {
        let hasCustom = FileManager.default.fileExists(atPath: StatusItemTool.customImagePath)
        resetButton.isEnabled = hasCustom
        imageView.image = StatusItemTool.menuImage
    }

    // MARK: - Drag and Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.png"],
        ]) as? [URL], !urls.isEmpty else {
            return []
        }
        previewWell.layer?.borderColor = NSColor.controlAccentColor.cgColor
        previewWell.layer?.borderWidth = 2.0
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        previewWell.layer?.borderColor = NSColor.separatorColor.cgColor
        previewWell.layer?.borderWidth = 1.0
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        previewWell.layer?.borderColor = NSColor.separatorColor.cgColor
        previewWell.layer?.borderWidth = 1.0
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.png"],
        ]) as? [URL], let srcURL = urls.first else {
            return false
        }
        return applyImage(from: srcURL)
    }

    // MARK: - Actions

    @objc private func selectImage() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Select Tray Icon Image", comment: "")
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.png]
        } else {
            panel.allowedFileTypes = ["png"]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let srcURL = panel.url else { return }
        _ = applyImage(from: srcURL)
    }

    @objc private func resetImage() {
        let destPath = StatusItemTool.customImagePath
        if FileManager.default.fileExists(atPath: destPath) {
            do {
                try FileManager.default.removeItem(atPath: destPath)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = NSLocalizedString("Failed to reset tray icon", comment: "")
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
        }
        reloadIcon()
    }

    private static let maxIconDimension: CGFloat = 256

    private func applyImage(from srcURL: URL) -> Bool {
        guard let image = NSImage(contentsOf: srcURL) else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Failed to change tray icon", comment: "")
            alert.informativeText = NSLocalizedString("The file could not be loaded as an image.", comment: "")
            alert.runModal()
            return false
        }

        if let rep = image.representations.first {
            let pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            if pixelSize.width > TrayIconPickerView.maxIconDimension || pixelSize.height > TrayIconPickerView.maxIconDimension {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = NSLocalizedString("Failed to change tray icon", comment: "")
                alert.informativeText = String(
                    format: NSLocalizedString("Image is too large (%d×%d). Maximum allowed size is %d×%d pixels. Recommended size is 36×36 pixels (72×72 for Retina @2x).", comment: ""),
                    Int(pixelSize.width), Int(pixelSize.height),
                    Int(TrayIconPickerView.maxIconDimension), Int(TrayIconPickerView.maxIconDimension)
                )
                alert.runModal()
                return false
            }
        }

        let destPath = StatusItemTool.customImagePath
        let destURL = URL(fileURLWithPath: destPath)
        let destDir = destURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destPath) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: destURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Failed to change tray icon", comment: "")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
        reloadIcon()
        return true
    }

    private func reloadIcon() {
        StatusItemTool.reloadMenuImage()
        imageView.image = StatusItemTool.menuImage

        if let view = AppDelegate.shared.statusItemView as? StatusItemView {
            view.imageView.image = StatusItemTool.menuImage
        }

        updateIconPreview()
    }
}

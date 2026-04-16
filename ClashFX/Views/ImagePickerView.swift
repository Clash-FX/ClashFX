//
//  ImagePickerView.swift
//  ClashFX
//

import Cocoa
import UniformTypeIdentifiers

/// Configuration describing the differences between image picker variants.
struct ImagePickerConfig {
    let imagePreviewSize: CGFloat
    let placeholderText: String
    let selectPanelTitle: String
    let dragUTI: String
    let maxDimension: CGFloat
    let customImagePath: String

    let changeFailedText: String
    let resetFailedText: String
    let sizeWarningFormat: String

    /// File types for the open panel (macOS < 11).
    let allowedFileTypes: [String]

    /// Content types for the open panel (macOS 11+).
    /// The closure is typed as `() -> Any` to avoid referencing `UTType` on macOS < 11.
    /// Callers inside an `#available(macOS 11.0, *)` block cast the result to `[UTType]`.
    let allowedContentTypesProvider: () -> Any
}

/// Base image picker view with drop zone, preview, select and reset buttons.
/// Subclasses provide configuration via `pickerConfig` and override
/// `currentImage()` / `didReloadImage()` for variant-specific behaviour.
class ImagePickerView: NSView {
    let dropZone = NSView()
    let imageView = NSImageView()
    private(set) var placeholderLabel = NSTextField(labelWithString: "")
    private let selectButton = NSButton()
    let resetButton = NSButton()

    // MARK: - Subclass hooks

    /// Return the configuration for this picker variant.
    var pickerConfig: ImagePickerConfig {
        fatalError("Subclasses must override pickerConfig")
    }

    /// Return the image to display in the preview.
    func currentImage() -> NSImage {
        fatalError("Subclasses must override currentImage()")
    }

    /// Called after the image file has been changed or reset.
    func didReloadImage() {
        // Subclasses can override to perform additional actions (e.g. update status bar).
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Call from subclass init after `pickerConfig` is ready.
    func commonInit() {
        setupViews()
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - UI Setup

    private func setupViews() {
        let config = pickerConfig
        translatesAutoresizingMaskIntoConstraints = false

        // Drop zone
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.wantsLayer = true
        dropZone.layer?.borderWidth = 1.5
        dropZone.layer?.borderColor = NSColor.separatorColor.cgColor
        dropZone.layer?.cornerRadius = 8

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = currentImage()
        dropZone.addSubview(imageView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.stringValue = config.placeholderText
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.font = NSFont.systemFont(ofSize: 11)
        placeholderLabel.alignment = .center
        dropZone.addSubview(placeholderLabel)

        addSubview(dropZone)

        // Buttons
        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.title = NSLocalizedString("Select Image", comment: "")
        selectButton.bezelStyle = .rounded
        selectButton.target = self
        selectButton.action = #selector(selectImage)

        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.title = NSLocalizedString("Reset", comment: "")
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetImage)

        let buttonStack = NSStackView(views: [selectButton, resetButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        addSubview(buttonStack)

        let previewSize = config.imagePreviewSize

        NSLayoutConstraint.activate([
            dropZone.topAnchor.constraint(equalTo: topAnchor),
            dropZone.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropZone.widthAnchor.constraint(equalToConstant: 64),
            dropZone.heightAnchor.constraint(equalToConstant: 64),

            imageView.centerXAnchor.constraint(equalTo: dropZone.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: dropZone.centerYAnchor, constant: -8),
            imageView.widthAnchor.constraint(equalToConstant: previewSize),
            imageView.heightAnchor.constraint(equalToConstant: previewSize),

            placeholderLabel.centerXAnchor.constraint(equalTo: dropZone.centerXAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 2),
            placeholderLabel.widthAnchor.constraint(equalTo: dropZone.widthAnchor, constant: -4),

            buttonStack.leadingAnchor.constraint(equalTo: dropZone.trailingAnchor, constant: 12),
            buttonStack.centerYAnchor.constraint(equalTo: dropZone.centerYAnchor),

            bottomAnchor.constraint(equalTo: dropZone.bottomAnchor),
        ])

        updatePreview()
    }

    func updatePreview() {
        let hasCustom = FileManager.default.fileExists(atPath: pickerConfig.customImagePath)
        placeholderLabel.isHidden = hasCustom
        resetButton.isHidden = !hasCustom
    }

    // MARK: - Drag and Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let uti = pickerConfig.dragUTI
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [uti],
        ]) as? [URL], !urls.isEmpty else {
            return []
        }
        dropZone.layer?.borderColor = NSColor.controlAccentColor.cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropZone.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropZone.layer?.borderColor = NSColor.separatorColor.cgColor
        let uti = pickerConfig.dragUTI
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [uti],
        ]) as? [URL], let srcURL = urls.first else {
            return false
        }
        return applyImage(from: srcURL)
    }

    // MARK: - Actions

    @objc private func selectImage() {
        let config = pickerConfig
        let panel = NSOpenPanel()
        panel.title = config.selectPanelTitle
        if #available(macOS 11.0, *) {
            if let types = config.allowedContentTypesProvider() as? [UTType] {
                panel.allowedContentTypes = types
            }
        } else {
            panel.allowedFileTypes = config.allowedFileTypes
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let srcURL = panel.url else { return }
        _ = applyImage(from: srcURL)
    }

    @objc private func resetImage() {
        let config = pickerConfig
        let destPath = config.customImagePath
        if FileManager.default.fileExists(atPath: destPath) {
            do {
                try FileManager.default.removeItem(atPath: destPath)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = config.resetFailedText
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
        }
        reloadImage()
    }

    private func applyImage(from srcURL: URL) -> Bool {
        let config = pickerConfig
        guard let image = NSImage(contentsOf: srcURL) else {
            let alert = NSAlert()
            alert.messageText = config.changeFailedText
            alert.informativeText = NSLocalizedString("The file could not be loaded as an image.", comment: "")
            alert.runModal()
            return false
        }

        if let rep = image.representations.first {
            let pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            if pixelSize.width > config.maxDimension || pixelSize.height > config.maxDimension {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = config.changeFailedText
                alert.informativeText = String(
                    format: config.sizeWarningFormat,
                    Int(pixelSize.width), Int(pixelSize.height),
                    Int(config.maxDimension), Int(config.maxDimension)
                )
                alert.runModal()
                return false
            }
        }

        let destPath = config.customImagePath
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
            alert.messageText = config.changeFailedText
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
        reloadImage()
        return true
    }

    private func reloadImage() {
        didReloadImage()
        imageView.image = currentImage()
        updatePreview()
    }
}

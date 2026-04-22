import Cocoa

class ConfigEditorWindowController: NSWindowController {
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var filePath: String = ""
    private var statusLabel: NSTextField!
    private var filePopup: NSPopUpButton!
    private var modeSegment: NSSegmentedControl!
    private var visualEditorVC: VisualConfigEditorController?
    private var visualContainer: NSView!
    private var configDocument: ConfigDocument?
    private var isVisualMode = false

    private static var current: ConfigEditorWindowController?

    static func show(configPath: String? = nil) {
        if let existing = current, existing.window?.isVisible == true {
            if let path = configPath {
                existing.loadFile(path: path)
            }
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ConfigEditorWindowController()
        current = controller
        controller.showWindow(nil)
        if let path = configPath {
            controller.loadFile(path: path)
        } else {
            controller.loadCurrentConfig()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClashFX Config Editor"
        window.center()
        window.minSize = NSSize(width: 750, height: 450)
        super.init(window: window)
        // Show app in Dock when editor is open so user can find it easily
        window.delegate = self
        setupUI()
        NSApp.setActivationPolicy(.regular)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topBar)

        filePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        filePopup.translatesAutoresizingMaskIntoConstraints = false
        filePopup.target = self
        filePopup.action = #selector(fileSelectionChanged(_:))
        topBar.addSubview(filePopup)
        populateFileList()

        modeSegment = NSSegmentedControl(labels: [NSLocalizedString("Raw", comment: ""), NSLocalizedString("Visual", comment: "")], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modeSegment.translatesAutoresizingMaskIntoConstraints = false
        modeSegment.selectedSegment = 0
        if #available(macOS 10.13, *) {
            modeSegment.segmentDistribution = .fillEqually
        }
        topBar.addSubview(modeSegment)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        topBar.addSubview(statusLabel)

        let saveBtn = NSButton(title: NSLocalizedString("Save", comment: ""), target: self, action: #selector(saveFile))
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "s"
        saveBtn.keyEquivalentModifierMask = .command
        topBar.addSubview(saveBtn)

        let reloadBtn = NSButton(title: NSLocalizedString("Save & Reload", comment: ""), target: self, action: #selector(saveAndReload))
        reloadBtn.translatesAutoresizingMaskIntoConstraints = false
        reloadBtn.bezelStyle = .rounded
        topBar.addSubview(reloadBtn)

        setupRawEditor(in: contentView, below: topBar)
        setupVisualContainer(in: contentView, below: topBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            topBar.heightAnchor.constraint(equalToConstant: 32),

            filePopup.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            filePopup.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            filePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            modeSegment.leadingAnchor.constraint(equalTo: filePopup.trailingAnchor, constant: 12),
            modeSegment.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            modeSegment.widthAnchor.constraint(equalToConstant: 130),

            statusLabel.leadingAnchor.constraint(equalTo: modeSegment.trailingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: saveBtn.leadingAnchor, constant: -12),

            saveBtn.trailingAnchor.constraint(equalTo: reloadBtn.leadingAnchor, constant: -8),
            saveBtn.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            reloadBtn.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            reloadBtn.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])
    }

    private func setupRawEditor(in parent: NSView, below topBar: NSView) {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        parent.addSubview(scrollView)

        textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        if #available(macOS 10.15, *) {
            textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        } else {
            textView.font = NSFont(name: "Menlo", size: 13) ?? NSFont.systemFont(ofSize: 13)
        }
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self

        applyEditorColors()

        scrollView.documentView = textView

        let lineNumberView = LineNumberRulerView(textView: textView)
        // Fix for macOS 14+: clipsToBounds defaults to NO since Sonoma,
        // causing the ruler view to overlap and hide the text content.
        if #available(macOS 14.0, *) {
            lineNumberView.clipsToBounds = true
        }
        scrollView.verticalRulerView = lineNumberView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        // Re-highlight visible region on scroll for large files
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    private func setupVisualContainer(in parent: NSView, below topBar: NSView) {
        visualContainer = NSView()
        visualContainer.translatesAutoresizingMaskIntoConstraints = false
        visualContainer.isHidden = true
        parent.addSubview(visualContainer)

        NSLayoutConstraint.activate([
            visualContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            visualContainer.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            visualContainer.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            visualContainer.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
        // Visual editor is created lazily in switchToVisualMode() to avoid
        // constraint conflicts when the container has zero size while hidden.
    }

    private func ensureVisualEditor() {
        guard visualEditorVC == nil else { return }
        let vc = VisualConfigEditorController()
        visualEditorVC = vc
        let vcView = vc.view
        vcView.translatesAutoresizingMaskIntoConstraints = false
        visualContainer.addSubview(vcView)
        NSLayoutConstraint.activate([
            vcView.topAnchor.constraint(equalTo: visualContainer.topAnchor),
            vcView.leadingAnchor.constraint(equalTo: visualContainer.leadingAnchor),
            vcView.trailingAnchor.constraint(equalTo: visualContainer.trailingAnchor),
            vcView.bottomAnchor.constraint(equalTo: visualContainer.bottomAnchor),
        ])
    }

    // MARK: - Mode Switching

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            switchToRawMode()
        } else {
            switchToVisualMode()
        }
    }

    private func switchToVisualMode() {
        do {
            let doc = try ConfigDocument.loadFromYAML(textView.string)
            configDocument = doc
            ensureVisualEditor()
            visualEditorVC?.loadDocument(doc)
            scrollView.isHidden = true
            visualContainer.isHidden = false
            isVisualMode = true
            statusLabel.stringValue = NSLocalizedString("Visual", comment: "")
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("YAML Parse Error", comment: "")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            modeSegment.selectedSegment = 0
        }
    }

    private func switchToRawMode() {
        if isVisualMode, let doc = configDocument {
            visualEditorVC?.applyToDocument(doc)
            textView.string = doc.serializeToYAML()
            highlightYAML()
        }
        scrollView.isHidden = false
        visualContainer.isHidden = true
        isVisualMode = false
        let lineCount = textView.string.components(separatedBy: "\n").count
        statusLabel.stringValue = "\(lineCount) lines"
    }

    // MARK: - File Operations

    private func populateFileList() {
        filePopup.removeAllItems()
        let configs = ConfigManager.getConfigFilesList()
        for name in configs {
            filePopup.addItem(withTitle: name)
        }
        filePopup.selectItem(withTitle: ConfigManager.selectConfigName)
    }

    private func loadCurrentConfig() {
        let name = ConfigManager.selectConfigName
        let path = Paths.localConfigPath(for: name)
        loadFile(path: path)
    }

    func loadFile(path: String) {
        filePath = path
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)

            // Use the simplest possible text loading: set string, then font/color
            textView.string = content
            let monoFont: NSFont
            if #available(macOS 10.15, *) {
                monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            } else {
                monoFont = NSFont(name: "Menlo", size: 13) ?? NSFont.systemFont(ofSize: 13)
            }
            textView.font = monoFont
            applyEditorColors()

            let fileName = (path as NSString).lastPathComponent
            window?.title = "ClashFX Config Editor — \(fileName)"
            let lineCount = content.components(separatedBy: "\n").count
            statusLabel.stringValue = "\(lineCount) lines"

            // Syntax highlight after text is rendered
            let delay: TimeInterval = content.count > 500_000 ? 0.5 : (lineCount > 3000 ? 0.2 : 0)
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.highlightYAML()
                }
            } else {
                highlightYAML()
            }

            if isVisualMode {
                if let doc = try? ConfigDocument.loadFromYAML(content) {
                    configDocument = doc
                    ensureVisualEditor()
                    visualEditorVC?.loadDocument(doc)
                }
            }
        } catch {
            textView.string = "// Error loading file: \(error.localizedDescription)"
            statusLabel.stringValue = "Error"
        }
    }

    @objc private func fileSelectionChanged(_ sender: NSPopUpButton) {
        guard let name = sender.selectedItem?.title else { return }
        let path = Paths.localConfigPath(for: name)
        loadFile(path: path)
    }

    @objc private func saveFile() {
        guard !filePath.isEmpty else { return }

        if isVisualMode, let doc = configDocument {
            visualEditorVC?.applyToDocument(doc)
            let yaml = doc.serializeToYAML()
            textView.string = yaml
        }

        do {
            try textView.string.write(toFile: filePath, atomically: true, encoding: .utf8)
            statusLabel.stringValue = NSLocalizedString("Saved", comment: "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self else { return }
                if self.isVisualMode {
                    self.statusLabel.stringValue = NSLocalizedString("Visual", comment: "")
                } else {
                    self.statusLabel.stringValue = "\(self.textView.string.components(separatedBy: "\n").count) lines"
                }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func saveAndReload() {
        saveFile()
        let configName = filePopup.selectedItem?.title ?? ConfigManager.selectConfigName
        AppDelegate.shared.updateConfig(configName: configName)
    }

    // MARK: - YAML Syntax Highlighting

    private static let maxHighlightLength = 100_000 // ~3000 lines

    private var isDarkMode: Bool {
        if #available(macOS 10.14, *) {
            let appearance = textView.effectiveAppearance
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return false
    }

    private func applyEditorColors() {
        textView.textColor = editorBaseTextColor
        textView.backgroundColor = editorBackgroundColor
        textView.insertionPointColor = editorInsertionPointColor
    }

    private var editorBackgroundColor: NSColor {
        if #available(macOS 10.14, *) {
            return .textBackgroundColor
        }
        return .white
    }

    private var editorBaseTextColor: NSColor {
        if #available(macOS 10.14, *) {
            return .textColor
        }
        return .textColor
    }

    private var editorInsertionPointColor: NSColor {
        if #available(macOS 10.14, *) {
            return .labelColor
        }
        return .textColor
    }

    func highlightYAML() {
        let text = textView.string
        let nsText = text as NSString
        let totalLength = nsText.length
        guard totalLength > 0 else { return }

        // For very large files, only highlight a window around the visible area
        let highlightRange: NSRange
        if totalLength > Self.maxHighlightLength {
            let visibleRect = scrollView.documentVisibleRect
            let layoutManager = textView.layoutManager!
            let textContainer = textView.textContainer!
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

            // Expand by 5000 chars in each direction for smooth scrolling
            let start = max(0, charRange.location - 5000)
            let end = min(totalLength, charRange.location + charRange.length + 5000)
            highlightRange = NSRange(location: start, length: end - start)
        } else {
            highlightRange = NSRange(location: 0, length: totalLength)
        }

        let storage = textView.textStorage!
        storage.beginEditing()

        let baseColor = editorBaseTextColor
        storage.addAttribute(.foregroundColor, value: baseColor, range: highlightRange)

        let substring = nsText.substring(with: highlightRange)
        let subRange = NSRange(location: 0, length: (substring as NSString).length)

        // swiftlint:disable force_try
        let commentColor: NSColor = isDarkMode ? NSColor.systemGreen : NSColor.systemGreen
        let keyColor: NSColor = isDarkMode ? NSColor.systemBlue : NSColor.systemBlue
        let stringColor: NSColor = isDarkMode ? NSColor.systemOrange : NSColor.systemOrange
        let numberColor: NSColor = isDarkMode ? NSColor.systemPurple : NSColor.systemPurple
        let booleanColor: NSColor = isDarkMode ? NSColor.systemPink : NSColor.systemPink
        let listDashColor: NSColor = isDarkMode ? NSColor.systemYellow : NSColor.systemOrange
        let patterns: [(NSRegularExpression, NSColor, Int)] = [
            (try! NSRegularExpression(pattern: "#.*$", options: .anchorsMatchLines),
             commentColor, 0),
            (try! NSRegularExpression(pattern: "^(\\s*[\\w-]+)\\s*:", options: .anchorsMatchLines),
             keyColor, 1),
            (try! NSRegularExpression(pattern: "([\"'])(?:(?=(\\\\?))\\2.)*?\\1", options: []),
             stringColor, 0),
            (try! NSRegularExpression(pattern: "(?<=:\\s)\\d+\\.?\\d*(?=\\s*$)", options: .anchorsMatchLines),
             numberColor, 0),
            (try! NSRegularExpression(pattern: "(?<=:\\s)(true|false|yes|no)(?=\\s*$)", options: [.anchorsMatchLines, .caseInsensitive]),
             booleanColor, 0),
        ]

        for (regex, color, captureGroup) in patterns {
            for match in regex.matches(in: substring, range: subRange) {
                let matchRange = match.range(at: captureGroup)
                let adjustedRange = NSRange(location: highlightRange.location + matchRange.location, length: matchRange.length)
                if adjustedRange.location + adjustedRange.length <= totalLength {
                    storage.addAttribute(.foregroundColor, value: color, range: adjustedRange)
                }
            }
        }

        // List dash highlighting
        let listRegex = try! NSRegularExpression(pattern: "^(\\s*)-\\s", options: .anchorsMatchLines)
        for match in listRegex.matches(in: substring, range: subRange) {
            let dashRange = NSRange(location: match.range.location + match.range(at: 1).length, length: 1)
            let adjustedRange = NSRange(location: highlightRange.location + dashRange.location, length: 1)
            if adjustedRange.location + adjustedRange.length <= totalLength {
                storage.addAttribute(.foregroundColor, value: listDashColor, range: adjustedRange)
            }
        }
        // swiftlint:enable force_try

        storage.endEditing()
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        let totalLength = (textView.string as NSString).length
        guard totalLength > Self.maxHighlightLength else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(performHighlight), object: nil)
        perform(#selector(performHighlight), with: nil, afterDelay: 0.15)
    }
}

// MARK: - NSTextViewDelegate

extension ConfigEditorWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(performHighlight), object: nil)
        perform(#selector(performHighlight), with: nil, afterDelay: 0.3)
        statusLabel.stringValue = NSLocalizedString("Modified", comment: "")
    }

    @objc private func performHighlight() {
        highlightYAML()
    }
}

// MARK: - NSWindowDelegate

extension ConfigEditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        ConfigEditorWindowController.current = nil
        // Hide from Dock when no editor windows are open
        // (check if other key windows exist first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasVisibleWindows = NSApp.windows.contains {
                $0.isVisible && !$0.isKind(of: NSPanel.self) && $0.styleMask.contains(.titled)
            }
            if !hasVisibleWindows {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - Line Number Ruler

class LineNumberRulerView: NSRulerView {
    private weak var targetTextView: NSTextView?

    init(textView: NSTextView) {
        targetTextView = textView
        super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40

        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    @objc func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = targetTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let bgColor: NSColor = .controlBackgroundColor
        bgColor.setFill()
        rect.fill()

        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let text = textView.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        var lineNumber = 1
        var index = 0
        while index <= visibleCharRange.location && index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            if index < visibleCharRange.location {
                lineNumber += 1
            }
            index = NSMaxRange(lineRange)
        }

        var glyphIndex = visibleGlyphRange.location
        while glyphIndex < NSMaxRange(visibleGlyphRange) {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            var lineRect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil), in: textContainer)
            lineRect.origin.y += textView.textContainerInset.height - visibleRect.origin.y

            let numStr = "\(lineNumber)" as NSString
            let strSize = numStr.size(withAttributes: attrs)
            let drawPoint = NSPoint(x: ruleThickness - strSize.width - 6, y: lineRect.origin.y + (lineRect.height - strSize.height) / 2)
            numStr.draw(at: drawPoint, withAttributes: attrs)

            lineNumber += 1
            glyphIndex = NSMaxRange(layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil))
        }
    }
}

//
//  AppearanceSettingViewController.swift
//  ClashFX
//
//  Created by copilot on 2026/4/15.
//

import Cocoa

class AppearanceSettingViewController: NSViewController {
    private let trayMenuSettingViewHeight: CGFloat = 300
    private let preferredViewportHeight: CGFloat = 520

    override func loadView() {
        let width: CGFloat = 400
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: preferredViewportHeight))
        contentView.autoresizingMask = [.width, .height]
        contentView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentView.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let trayBox = SettingsGroupBox()
        trayBox.translatesAutoresizingMaskIntoConstraints = false
        trayBox.title = NSLocalizedString("Tray Icon", comment: "")

        let trayPicker = TrayIconPickerView()
        trayBox.contentView?.addSubview(trayPicker)

        if let cv = trayBox.contentView {
            NSLayoutConstraint.activate([
                trayPicker.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
                trayPicker.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
                trayPicker.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
                cv.bottomAnchor.constraint(equalTo: trayPicker.bottomAnchor, constant: 12)
            ])
        }

        let logoBox = SettingsGroupBox()
        logoBox.translatesAutoresizingMaskIntoConstraints = false
        logoBox.title = NSLocalizedString("App Logo", comment: "")

        let logoPicker = LogoPickerView()
        logoBox.contentView?.addSubview(logoPicker)

        if let cv = logoBox.contentView {
            NSLayoutConstraint.activate([
                logoPicker.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
                logoPicker.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
                logoPicker.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
                cv.bottomAnchor.constraint(equalTo: logoPicker.bottomAnchor, constant: 12)
            ])
        }

        let speedBox = SettingsGroupBox()
        speedBox.translatesAutoresizingMaskIntoConstraints = false
        speedBox.title = NSLocalizedString("Menu Bar Speed", comment: "")

        let speedAlignmentLabel = NSTextField(
            labelWithString: NSLocalizedString("Speed alignment", comment: "")
        )
        let speedAlignmentControl = NSSegmentedControl(
            labels: [
                NSLocalizedString("Speed Align Left", comment: ""),
                NSLocalizedString("Speed Align Center", comment: ""),
                NSLocalizedString("Speed Align Right", comment: "")
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(speedAlignmentChanged(_:))
        )
        speedAlignmentControl.selectedSegment = Settings.menuBarSpeedAlignment.rawValue
        speedAlignmentControl.setAccessibilityLabel(NSLocalizedString("Speed alignment", comment: ""))
        speedAlignmentControl.setContentHuggingPriority(.required, for: .horizontal)

        let speedAlignmentRow = NSStackView(views: [speedAlignmentLabel, speedAlignmentControl])
        speedAlignmentRow.translatesAutoresizingMaskIntoConstraints = false
        speedAlignmentRow.orientation = .horizontal
        speedAlignmentRow.alignment = .centerY
        speedAlignmentRow.distribution = .fill
        speedAlignmentRow.spacing = 12
        speedBox.contentView?.addSubview(speedAlignmentRow)

        if let cv = speedBox.contentView {
            NSLayoutConstraint.activate([
                speedAlignmentRow.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
                speedAlignmentRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
                speedAlignmentRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
                cv.bottomAnchor.constraint(equalTo: speedAlignmentRow.bottomAnchor, constant: 12)
            ])
        }

        let menuBox = SettingsGroupBox()
        menuBox.translatesAutoresizingMaskIntoConstraints = false
        menuBox.title = NSLocalizedString("Tray Menu", comment: "")

        let menuSettingView = TrayMenuSettingView()
        menuBox.contentView?.addSubview(menuSettingView)

        if let cv = menuBox.contentView {
            NSLayoutConstraint.activate([
                menuSettingView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
                menuSettingView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                menuSettingView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                menuSettingView.heightAnchor.constraint(equalToConstant: trayMenuSettingViewHeight),
                cv.bottomAnchor.constraint(equalTo: menuSettingView.bottomAnchor, constant: 8)
            ])
        }

        contentView.addSubview(scrollView)
        documentView.addSubview(trayBox)
        documentView.addSubview(speedBox)
        documentView.addSubview(logoBox)
        documentView.addSubview(menuBox)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            trayBox.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 18),
            trayBox.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            trayBox.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),

            speedBox.topAnchor.constraint(equalTo: trayBox.bottomAnchor, constant: 30),
            speedBox.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            speedBox.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),

            logoBox.topAnchor.constraint(equalTo: speedBox.bottomAnchor, constant: 30),
            logoBox.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            logoBox.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),

            menuBox.topAnchor.constraint(equalTo: logoBox.bottomAnchor, constant: 30),
            menuBox.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            menuBox.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),

            documentView.bottomAnchor.constraint(equalTo: menuBox.bottomAnchor, constant: 20)
        ])

        view = contentView
        title = NSLocalizedString("Appearance", comment: "")
        preferredContentSize = NSSize(width: 420, height: 520)
    }

    @objc private func speedAlignmentChanged(_ sender: NSSegmentedControl) {
        guard let alignment = MenuBarSpeedAlignment(rawValue: sender.selectedSegment) else { return }
        Settings.setMenuBarSpeedAlignment(alignment)
    }
}

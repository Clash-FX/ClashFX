//
//  AppearanceSettingViewController.swift
//  ClashFX
//
//  Created by copilot on 2026/4/15.
//

import Cocoa

class AppearanceSettingViewController: NSViewController {
    private var didComputePreferredSize = false

    override func loadView() {
        let width: CGFloat = 400
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 240))
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let trayBox = NSBox()
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

        let logoBox = NSBox()
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

        contentView.addSubview(trayBox)
        contentView.addSubview(logoBox)

        NSLayoutConstraint.activate([
            trayBox.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),
            trayBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            trayBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            logoBox.topAnchor.constraint(equalTo: trayBox.bottomAnchor, constant: 12),
            logoBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            logoBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: logoBox.bottomAnchor, constant: 20)
        ])

        view = contentView
        title = NSLocalizedString("Appearance", comment: "")
        preferredContentSize = NSSize(width: 420, height: 280)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didComputePreferredSize else { return }
        let fittingHeight = view.fittingSize.height
        if fittingHeight > 0 {
            didComputePreferredSize = true
            preferredContentSize = NSSize(width: preferredContentSize.width, height: fittingHeight)
            // If currently displayed, resize window immediately
            if let window = view.window, view.superview != nil {
                let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: preferredContentSize))
                var frame = window.frame
                frame.origin.y += frame.height - newFrame.height
                frame.size.height = newFrame.height
                window.setFrame(frame, display: true, animate: true)
            }
        }
    }
}

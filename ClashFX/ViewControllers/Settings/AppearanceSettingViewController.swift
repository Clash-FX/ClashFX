//
//  AppearanceSettingViewController.swift
//  ClashFX
//
//  Created by copilot on 2026/4/15.
//

import Cocoa

class AppearanceSettingViewController: NSViewController {
    override func loadView() {
        let width: CGFloat = 400
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 240))
        contentView.translatesAutoresizingMaskIntoConstraints = false

        // Tray Icon section
        let trayBox = NSBox()
        trayBox.translatesAutoresizingMaskIntoConstraints = false
        trayBox.title = NSLocalizedString("Tray Icon", comment: "")

        let trayPicker = TrayIconPickerView()
        trayBox.contentView?.addSubview(trayPicker)

        if let cv = trayBox.contentView {
            NSLayoutConstraint.activate([
                trayPicker.topAnchor.constraint(equalTo: cv.topAnchor, constant: 10),
                trayPicker.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
                trayPicker.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -20),
                cv.bottomAnchor.constraint(equalTo: trayPicker.bottomAnchor, constant: 10),
            ])
        }

        contentView.addSubview(trayBox)

        // App Logo section
        let logoBox = NSBox()
        logoBox.translatesAutoresizingMaskIntoConstraints = false
        logoBox.title = NSLocalizedString("App Logo", comment: "")

        let logoPicker = LogoPickerView()
        logoBox.contentView?.addSubview(logoPicker)

        if let cv = logoBox.contentView {
            NSLayoutConstraint.activate([
                logoPicker.topAnchor.constraint(equalTo: cv.topAnchor, constant: 10),
                logoPicker.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
                logoPicker.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -20),
                cv.bottomAnchor.constraint(equalTo: logoPicker.bottomAnchor, constant: 10),
            ])
        }

        contentView.addSubview(logoBox)

        NSLayoutConstraint.activate([
            trayBox.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            trayBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            trayBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            logoBox.topAnchor.constraint(equalTo: trayBox.bottomAnchor, constant: 12),
            logoBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            logoBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: logoBox.bottomAnchor, constant: 20),
        ])

        view = contentView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Appearance", comment: "")
        preferredContentSize = NSSize(width: 400, height: 280)
    }
}

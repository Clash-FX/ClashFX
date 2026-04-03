//
//  AutoUpgradeManager.swift
//  ClashFX
//

import Cocoa
import Sparkle

class AutoUpgradeManager: NSObject {
    static let shared = AutoUpgradeManager()

    private let updaterController: SPUStandardUpdaterController

    override private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    // MARK: Public

    func setup() {}

    func setupCheckForUpdatesMenuItem(_ item: NSMenuItem) {
        item.target = self
        item.action = #selector(checkForUpdates(_:))
    }

    @objc func checkForUpdates(_ sender: Any) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updaterController.checkForUpdates(sender)
        }
    }

    func addChannelMenuItem(_ button: NSPopUpButton) {}

    var updater: SPUUpdater {
        updaterController.updater
    }
}

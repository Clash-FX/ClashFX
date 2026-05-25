//
//  AutoUpgradeManager.swift
//  ClashFX
//

import Cocoa
import Sparkle

final class AutoUpgradeManager: NSObject {
    static let shared = AutoUpgradeManager()

    static let labChannelIdentifier = "lab"

    /// 4+ segment shortVersion (e.g. 1.0.38.1) marks a Lab build; 3 segments (1.0.38) = Stable.
    static var isLabBuild: Bool {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return v.split(separator: ".").count >= 4
    }

    static var currentChannelDisplayName: String {
        isLabBuild ? NSLocalizedString("Lab", comment: "Update channel name") : NSLocalizedString("Stable", comment: "Update channel name")
    }

    private var updaterController: SPUStandardUpdaterController!

    override private init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLabChannelChange),
            name: Settings.labChannelDidChangeNotification,
            object: nil
        )
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

    func addChannelMenuItem(_ button: NSPopUpButton) {
        button.removeAllItems()
        button.addItem(withTitle: NSLocalizedString("Stable", comment: "Update channel name"))
        button.lastItem?.tag = 0
        button.addItem(withTitle: NSLocalizedString("Lab (Experimental)", comment: "Update channel name"))
        button.lastItem?.tag = 1
        button.selectItem(withTag: Settings.isLabChannel ? 1 : 0)
        button.target = self
        button.action = #selector(handleChannelPopupChanged(_:))
    }

    @objc private func handleChannelPopupChanged(_ sender: NSPopUpButton) {
        let wantsLab = sender.selectedTag() == 1
        guard wantsLab != Settings.isLabChannel else { return }

        let alert = NSAlert()
        if wantsLab {
            alert.messageText = NSLocalizedString("Join the ClashFX Lab?", comment: "")
            alert.informativeText = NSLocalizedString(
                "Lab builds receive bug fixes and experimental features sooner, but update more often and are less stable than Stable. You can switch back any time. Please report any issues on GitHub.",
                comment: ""
            )
            alert.addButton(withTitle: NSLocalizedString("Join Lab", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        } else {
            alert.messageText = NSLocalizedString("Leave the ClashFX Lab?", comment: "")
            alert.informativeText = NSLocalizedString(
                "You will keep running your current Lab version until the next Stable release catches up. To downgrade immediately, use \"Roll back to Stable\" below.",
                comment: ""
            )
            alert.addButton(withTitle: NSLocalizedString("Leave Lab", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        }

        if alert.runModal() == .alertFirstButtonReturn {
            Settings.setLabChannel(wantsLab)
        } else {
            sender.selectItem(withTag: Settings.isLabChannel ? 1 : 0)
        }
    }

    var updater: SPUUpdater {
        updaterController.updater
    }

    @objc private func handleLabChannelChange() {
        updater.resetUpdateCycle()
    }
}

// MARK: - SPUUpdaterDelegate

extension AutoUpgradeManager: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Settings.isLabChannel ? [Self.labChannelIdentifier] : []
    }
}

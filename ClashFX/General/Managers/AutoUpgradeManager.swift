//
//  AutoUpgradeManager.swift
//  ClashX
//
//  Created by yicheng on 2019/10/28.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa

class AutoUpgradeManager: NSObject {
    var checkForUpdatesMenuItem: NSMenuItem?
    static let shared = AutoUpgradeManager()
    private static let feedURL = "https://clash-fx.github.io/ClashFX/appcast.xml"
    private static let releasesURL = "https://github.com/Clash-FX/ClashFX/releases"

    // MARK: Public

    func setup() {}

    func setupCheckForUpdatesMenuItem(_ item: NSMenuItem) {
        checkForUpdatesMenuItem = item
        checkForUpdatesMenuItem?.target = self
        checkForUpdatesMenuItem?.action = #selector(checkForUpdates(_:))
    }

    func addChannelMenuItem(_ button: NSPopUpButton) {}

    @objc func checkForUpdates(_ sender: Any?) {
        checkForUpdatesMenuItem?.isEnabled = false
        let url = URL(string: AutoUpgradeManager.feedURL)!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.checkForUpdatesMenuItem?.isEnabled = true
                if let error = error {
                    self?.showError(error.localizedDescription)
                    return
                }
                guard let data = data else {
                    self?.showError("No data received")
                    return
                }
                let parser = AppcastParser()
                if let item = parser.parse(data: data) {
                    self?.handleUpdate(item)
                } else {
                    self?.showError(NSLocalizedString("Unable to check for updates", comment: ""))
                }
            }
        }.resume()
    }

    // MARK: Private

    private func handleUpdate(_ item: AppcastItem) {
        let currentVersion = AppVersionUtil.currentVersion
        if item.version.compare(currentVersion, options: .numeric) == .orderedDescending {
            showUpdateAlert(item)
        } else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("You're up to date!", comment: "")
            alert.informativeText = String(format: NSLocalizedString("ClashFX %@ is the latest version.", comment: ""), currentVersion)
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
        }
    }

    private func showUpdateAlert(_ item: AppcastItem) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("ClashFX %@ is available", comment: ""), item.version)
        alert.informativeText = String(format: NSLocalizedString("You are currently running %@. Download the new version from GitHub?", comment: ""), AppVersionUtil.currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Download", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            let url = item.downloadURL.isEmpty
                ? URL(string: AutoUpgradeManager.releasesURL)!
                : URL(string: item.downloadURL)!
            NSWorkspace.shared.open(url)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Update Error", comment: "")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }
}

// MARK: - Appcast Parser

private struct AppcastItem {
    let version: String
    let downloadURL: String
}

private class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var currentVersion: String?
    private var currentURL: String?
    private var inItem = false
    private var collectingVersion = false

    func parse(data: Data) -> AppcastItem? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items.first
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "item" { inItem = true }
        if inItem && elementName == "sparkle:version" {
            currentVersion = ""
            collectingVersion = true
        }
        if inItem && elementName == "enclosure" {
            currentURL = attributes["url"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingVersion {
            currentVersion?.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        if elementName == "sparkle:version" {
            collectingVersion = false
        }
        if elementName == "item" && inItem {
            if let version = currentVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
               !version.isEmpty {
                items.append(AppcastItem(version: version, downloadURL: currentURL ?? ""))
            }
            currentVersion = nil
            currentURL = nil
            inItem = false
        }
    }
}

// MARK: - Channel Enum

extension AutoUpgradeManager {
    enum Channel: Int, CaseIterable {
        #if !PRO_VERSION
            case stable
            case prelease
        #endif
        case appcenter
    }
}

extension AutoUpgradeManager.Channel {
    var title: String {
        switch self {
        #if !PRO_VERSION
            case .stable:
                return NSLocalizedString("Stable", comment: "")
            case .prelease:
                return NSLocalizedString("Prelease", comment: "")
        #endif
        case .appcenter:
            return "Appcenter"
        }
    }

    var urlString: String {
        switch self {
        #if !PRO_VERSION
            case .stable:
                return "https://clash-fx.github.io/ClashFX/appcast.xml"
            case .prelease:
                return "https://clash-fx.github.io/ClashFX/appcast-prerelease.xml"
        #endif
        case .appcenter:
            #if PRO_VERSION
                return "https://api.appcenter.ms/v0.1/public/sparkle/apps/1cd052f7-e118-4d13-87fb-35176f9702c1"
            #else
                return "https://clash-fx.github.io/ClashFX/appcast.xml"
            #endif
        }
    }
}

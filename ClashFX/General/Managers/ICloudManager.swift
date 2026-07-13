//
//  ICloudManager.swift
//  ClashX
//
//  Created by yicheng on 2020/5/10.
//  Copyright © 2020 west2online. All rights reserved.
//

import Cocoa
import RxCocoa
import RxSwift

class ICloudManager {
    static let shared = ICloudManager()
    private let queue = DispatchQueue(label: "com.clashx.icloud")
    private var metaQuery: NSMetadataQuery?
    private var enableMenuItem: NSMenuItem?
    private var didFinishInitialSetup = false
    private(set) var icloudAvailable = false {
        didSet { useiCloud.accept(userEnableiCloud && icloudAvailable) }
    }

    private var disposeBag = DisposeBag()

    let useiCloud = BehaviorRelay<Bool>(value: false)
    let userEnableiCloudRelay = BehaviorRelay<Bool>(value: UserDefaults.standard.bool(forKey: "kUserEnableiCloud"))

    var userEnableiCloud: Bool = UserDefaults.standard.bool(forKey: "kUserEnableiCloud") {
        didSet {
            ConfigManager.rememberConfigName(
                ConfigManager.selectConfigName,
                forICloudStorage: useiCloud.value
            )
            UserDefaults.standard.set(userEnableiCloud, forKey: "kUserEnableiCloud")
            userEnableiCloudRelay.accept(userEnableiCloud)
            useiCloud.accept(userEnableiCloud && icloudAvailable)
        }
    }

    @discardableResult
    func setUserEnableiCloud(_ enabled: Bool) -> Bool {
        guard !enabled || icloudAvailable else {
            userEnableiCloud = false
            return false
        }

        userEnableiCloud = enabled
        return true
    }

    func setup() {
        addNotification()
        useiCloud.distinctUntilChanged().subscribe(onNext: {
            [weak self] enabled in
            guard let self = self else { return }
            self.handleICloudUseChange(enabled: enabled, notify: self.didFinishInitialSetup)
        }).disposed(by: disposeBag)

        icloudAvailable = isICloudAvailable()
        userEnableiCloudRelay.accept(userEnableiCloud)
        useiCloud.accept(userEnableiCloud && icloudAvailable)
        didFinishInitialSetup = true
    }

    func getConfigFilesList(configs: @escaping (([String]) -> Void)) {
        getUrl { url in
            guard let url = url,
                  let fileURLs = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                configs([])
                return
            }
            let list = fileURLs
                .filter { String($0.split(separator: ".").last ?? "") == "yaml" }
                .filter { !Paths.isProfileMixinFileName($0) }
                .map { $0.split(separator: ".").dropLast().joined(separator: ".") }
            configs(list)
        }
    }

    private func handleICloudUseChange(enabled: Bool, notify: Bool) {
        guard enabled else {
            if notify {
                NotificationCenter.default.post(name: .iCloudConfigStorageDidChange, object: nil)
            }
            return
        }

        checkiCloud {
            if notify {
                NotificationCenter.default.post(name: .iCloudConfigStorageDidChange, object: nil)
            }
        }
    }

    private func checkiCloud(complete: (() -> Void)? = nil) {
        getUrl { url in
            guard let url = url else {
                self.icloudAvailable = false
                complete?()
                return
            }
            let files = try? FileManager.default.contentsOfDirectory(atPath: url.path)
            if files?.isEmpty == true {
                let path = Bundle.main.path(forResource: "sampleConfig", ofType: "yaml")!
                try? FileManager.default.copyItem(atPath: path, toPath: kDefaultConfigFilePath)
                try? FileManager.default.copyItem(atPath: Bundle.main.path(forResource: "sampleConfig", ofType: "yaml")!, toPath: url.appendingPathComponent("config.yaml").path)
            }
            self.migrateProfileMixinIfNeeded(to: url)
            complete?()
        }
    }

    private func migrateProfileMixinIfNeeded(to documentsURL: URL) {
        let fm = FileManager.default
        let visibleCloudURL = Paths.iCloudProfileMixinURL(in: documentsURL)
        let legacyCloudURL = Paths.legacyICloudProfileMixinURL(in: documentsURL)

        if fm.fileExists(atPath: visibleCloudURL.path) {
            return
        }

        if fm.fileExists(atPath: legacyCloudURL.path) {
            do {
                try fm.moveItem(at: legacyCloudURL, to: visibleCloudURL)
                Logger.log("[iCloud] Migrated legacy Profile Mixin to \(visibleCloudURL.path)")
            } catch {
                Logger.log("[iCloud] Failed to migrate legacy Profile Mixin: \(error.localizedDescription)", level: .warning)
            }
            return
        }

        guard fm.fileExists(atPath: kProfileMixinFilePath) else { return }

        do {
            try fm.copyItem(atPath: kProfileMixinFilePath, toPath: visibleCloudURL.path)
            Logger.log("[iCloud] Copied local Profile Mixin to \(visibleCloudURL.path)")
        } catch {
            Logger.log("[iCloud] Failed to copy Profile Mixin to iCloud: \(error.localizedDescription)", level: .warning)
        }
    }

    private func isICloudAvailable() -> Bool {
        return FileManager.default.ubiquityIdentityToken != nil
    }

    func getUrl(complete: ((URL?) -> Void)? = nil) {
        queue.async {
            guard var url = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                DispatchQueue.main.async {
                    complete?(nil)
                }
                return
            }
            url.appendPathComponent("Documents")
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
                }
                DispatchQueue.main.async {
                    complete?(url)
                }
            } catch let err {
                Logger.log("\(err)")
                DispatchQueue.main.async {
                    complete?(nil)
                }
                return
            }
        }
    }

    private func addNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(iCloudAccountAvailabilityChanged), name: NSNotification.Name.NSUbiquityIdentityDidChange, object: nil)
    }

    @objc func iCloudAccountAvailabilityChanged() {
        icloudAvailable = isICloudAvailable()
    }
}

//
//  ConfigManager.swift
//  ClashX
//
//  Created by CYC on 2018/6/12.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import Cocoa
import Foundation
import RxCocoa
import RxSwift

class ConfigManager {
    static let shared = ConfigManager()
    private static let selectedLocalConfigNameKey = "selectedLocalConfigName"
    private static let selectedICloudConfigNameKey = "selectedICloudConfigName"
    private let disposeBag = DisposeBag()
    var apiPort = "8080"
    var allowExternalControl = false
    var apiSecret: String = ""
    var overrideApiURL: URL?
    var overrideSecret: String?
    var isEnhancedModeActive = false

    var currentConfig: ClashConfig? {
        get {
            return currentConfigVariable.value
        }

        set {
            currentConfigVariable.accept(newValue)
        }
    }

    var currentConfigVariable = BehaviorRelay<ClashConfig?>(value: nil)

    var isRunning: Bool {
        get {
            return isRunningVariable.value
        }

        set {
            isRunningVariable.accept(newValue)
        }
    }

    static var selectConfigName: String {
        get {
            return UserDefaults.standard.string(forKey: "selectConfigName") ?? "config"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "selectConfigName")
            rememberConfigName(newValue, forICloudStorage: ICloudManager.shared.useiCloud.value)
            watchCurrentConfigFile()
        }
    }

    static func rememberedConfigName(forICloudStorage usesICloud: Bool) -> String? {
        UserDefaults.standard.string(forKey: selectedConfigNameKey(forICloudStorage: usesICloud))
    }

    static func rememberConfigName(_ configName: String, forICloudStorage usesICloud: Bool) {
        UserDefaults.standard.set(configName, forKey: selectedConfigNameKey(forICloudStorage: usesICloud))
    }

    private static func selectedConfigNameKey(forICloudStorage usesICloud: Bool) -> String {
        usesICloud ? selectedICloudConfigNameKey : selectedLocalConfigNameKey
    }

    static func watchCurrentConfigFile() {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getUrl { url in
                guard let url = url else { return }
                let configUrl = url.appendingPathComponent(Paths.configFileName(for: selectConfigName))
                ConfigFileManager.shared.watchFile(path: configUrl.path)
            }
        } else {
            ConfigFileManager.shared.watchFile(path: Paths.localConfigPath(for: selectConfigName))
        }
    }

    let isRunningVariable = BehaviorRelay<Bool>(value: false)

    var proxyPortAutoSet: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "proxyPortAutoSet")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "proxyPortAutoSet")
        }
    }

    let proxyPortAutoSetObservable = UserDefaults.standard.rx.observe(Bool.self, "proxyPortAutoSet").map { $0 ?? false }

    var isProxySetByOtherVariable = BehaviorRelay<Bool>(value: false)
    var proxyShouldPaused = BehaviorRelay<Bool>(value: false)

    var showNetSpeedIndicator: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "showNetSpeedIndicator")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "showNetSpeedIndicator")
        }
    }

    let showNetSpeedIndicatorObservable = UserDefaults.standard.rx.observe(Bool.self, "showNetSpeedIndicator")

    static var apiUrl: String {
        if let override = shared.overrideApiURL {
            return override.absoluteString
        }
        return "http://127.0.0.1:\(shared.apiPort)"
    }

    static var webSocketUrl: String {
        if let override = shared.overrideApiURL, var comp = URLComponents(url: override, resolvingAgainstBaseURL: true) {
            if comp.scheme == "https" {
                comp.scheme = "wss"
            } else {
                comp.scheme = "ws"
            }
            return comp.url?.absoluteString ?? ""
        }
        return "ws://127.0.0.1:\(shared.apiPort)"
    }

    static var selectedProxyRecords = SavedProxyModel.loadsFromUserDefault() {
        didSet {
            SavedProxyModel.save(selectedProxyRecords)
        }
    }

    /// Keeps the active config and remembered proxy selections in sync when a
    /// remote subscription replaces its placeholder filename with the server name.
    static func renameConfigReferences(from oldName: String, to newName: String) {
        guard oldName != newName else { return }

        if selectConfigName == oldName {
            UserDefaults.standard.set(newName, forKey: "selectConfigName")
        }

        for usesICloud in [false, true] where rememberedConfigName(forICloudStorage: usesICloud) == oldName {
            rememberConfigName(newName, forICloudStorage: usesICloud)
        }

        let renamedRecords = selectedProxyRecords.map { record in
            guard record.config == oldName else { return record }
            return SavedProxyModel(group: record.group, selected: record.selected, config: newName)
        }
        var recordKeys = Set<String>()
        selectedProxyRecords = renamedRecords.filter { recordKeys.insert($0.key).inserted }
    }

    static var selectOutBoundMode: ClashProxyMode {
        get {
            return ClashProxyMode(rawValue: UserDefaults.standard.string(forKey: "selectOutBoundMode") ?? "") ?? .rule
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectOutBoundMode")
        }
    }

    static var allowConnectFromLan: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "allowConnectFromLan")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "allowConnectFromLan")
        }
    }

    static var selectLoggingApiLevel: ClashLogLevel {
        get {
            return ClashLogLevel(rawValue: UserDefaults.standard.string(forKey: "selectLoggingApiLevel") ?? "") ?? .info
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectLoggingApiLevel")
        }
    }

    static func getConfigPath(configName: String, complete: ((String) -> Void)? = nil) {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getUrl { url in
                guard let url = url else {
                    complete?(Paths.localConfigPath(for: configName))
                    return
                }
                let configPath = url.appendingPathComponent(Paths.configFileName(for: configName)).path
                complete?(configPath)
            }
        } else {
            let filePath = Paths.localConfigPath(for: configName)
            complete?(filePath)
        }
    }
}

extension ConfigManager {
    static func getConfigFilesList() -> [String] {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(atPath: kConfigFolderPath)
            return fileURLs
                .filter { String($0.split(separator: ".").last ?? "") == "yaml" }
                .filter { !$0.hasPrefix(".") }
                .filter { !Paths.isProfileMixinFileName($0) }
                .map { $0.split(separator: ".").dropLast().joined(separator: ".") }
        } catch {
            return ["config"]
        }
    }

    static func getActiveConfigFilesList(complete: @escaping (([String]) -> Void)) {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getConfigFilesList(configs: complete)
        } else {
            complete(getConfigFilesList())
        }
    }
}

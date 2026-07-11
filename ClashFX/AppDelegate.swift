//
//  AppDelegate.swift
//  ClashX
//
//  Created by CYC on 2018/6/10.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import Alamofire
import AppCenter
import AppCenterAnalytics
import AppCenterCrashes
import Cocoa
import CocoaLumberjack
import KeyboardShortcuts
import LetsMove
import RxCocoa
import RxSwift
import Yams

let statusItemLengthWithSpeed: CGFloat = 65

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private enum EnhancedModeLaunchPreparation {
        case success(port: String, secret: String)
        case failure(String)
    }

    private(set) var statusItem: NSStatusItem!
    @IBOutlet var checkForUpdateMenuItem: NSMenuItem!

    @IBOutlet var statusMenu: NSMenu!
    @IBOutlet var proxySettingMenuItem: NSMenuItem!
    @IBOutlet var autoStartMenuItem: NSMenuItem!

    @IBOutlet var proxyModeGlobalMenuItem: NSMenuItem!
    @IBOutlet var proxyModeDirectMenuItem: NSMenuItem!
    @IBOutlet var proxyModeRuleMenuItem: NSMenuItem!
    @IBOutlet var allowFromLanMenuItem: NSMenuItem!
    @IBOutlet var enhancedModeMenuItem: NSMenuItem!

    @IBOutlet var proxyModeMenuItem: NSMenuItem!
    @IBOutlet var showNetSpeedIndicatorMenuItem: NSMenuItem!
    @IBOutlet var dashboardMenuItem: NSMenuItem!
    @IBOutlet var separatorLineTop: NSMenuItem!
    @IBOutlet var sepatatorLineEndProxySelect: NSMenuItem!
    @IBOutlet var configSeparatorLine: NSMenuItem!
    @IBOutlet var logLevelMenuItem: NSMenuItem!
    @IBOutlet var httpPortMenuItem: NSMenuItem!
    @IBOutlet var socksPortMenuItem: NSMenuItem!
    @IBOutlet var apiPortMenuItem: NSMenuItem!
    @IBOutlet var ipMenuItem: NSMenuItem!
    @IBOutlet var remoteConfigAutoupdateMenuItem: NSMenuItem!
    @IBOutlet var copyExportCommandMenuItem: NSMenuItem!
    @IBOutlet var copyExportCommandExternalMenuItem: NSMenuItem!
    @IBOutlet var externalControlSeparator: NSMenuItem!
    @IBOutlet var connectionsMenuItem: NSMenuItem!

    // Items without existing outlets, wired via storyboard
    @IBOutlet var benchmarkMenuItem: NSMenuItem!
    @IBOutlet var configsMenuItem: NSMenuItem!
    @IBOutlet var helpMenuItem: NSMenuItem!
    @IBOutlet var aboutMenuItem: NSMenuItem!
    @IBOutlet var showLogMenuItem: NSMenuItem!
    @IBOutlet var portsMenuItem: NSMenuItem!
    @IBOutlet var openConfigFolderMenuItem: NSMenuItem!
    @IBOutlet var reloadConfigMenuItem: NSMenuItem!
    @IBOutlet var updateExternalResourceMenuItem: NSMenuItem!
    @IBOutlet var remoteConfigMenuItem: NSMenuItem!
    @IBOutlet var remoteControllerMenuItem: NSMenuItem!

    // Section separators
    @IBOutlet var proxyActionsSeparator: NSMenuItem!
    @IBOutlet var generalSettingsSeparator: NSMenuItem!
    @IBOutlet var toolsSeparator: NSMenuItem!

    // Programmatically-added items stored for visibility management
    var langMenuItem: NSMenuItem?
    var configEditorMenuItem: NSMenuItem?
    var profileMixinMenuItem: NSMenuItem?
    private var subscriptionStatusMenuItem: NSMenuItem?
    private var subscriptionStatusSeparator: NSMenuItem?
    private var localProxyProviderSubscriptionInfoCache: [String: SubscriptionInfo] = [:]
    private var localProxyProviderSubscriptionInfoRequests = Set<String>()
    private var localProxyProviderSubscriptionInfoAttemptTimes: [String: Date] = [:]
    private weak var advancedTunMenuItem: NSMenuItem?
    private weak var bypassChineseAppsMenuItem: NSMenuItem?
    private weak var turnOffProxyMenuItem: NSMenuItem?
    var labHelpMenuItems: [NSMenuItem] = []
    private weak var labFeedbackMenuItem: NSMenuItem?
    private weak var labCopyDiagMenuItem: NSMenuItem?
    private weak var labCrashLogsMenuItem: NSMenuItem?
    private weak var labRollbackMenuItem: NSMenuItem?
    private weak var labHelpSeparator: NSMenuItem?

    var disposeBag = DisposeBag()
    var statusItemView: StatusItemViewProtocol!
    var isSpeedTesting = false

    var runAfterConfigReload: (() -> Void)?
    var isConfigUpdating = false

    private var didRestoreLastSpeedTest = false
    private static let automaticSpeedTestDelay: TimeInterval = 1

    private var lastStreamResetTime: Date = .distantPast
    private var pendingStreamResetWork: DispatchWorkItem?
    private var pendingEnhancedModeRefreshWork: DispatchWorkItem?
    private var pendingWakeRecoveryWork: DispatchWorkItem?
    private static let enhancedModeRestoreMaxAttempts = 12
    private static let enhancedModeRestoreRetryDelay: TimeInterval = 5
    private static let wakeRecoveryDelay: TimeInterval = 3
    private static let wakeRecoveryRetryDelay: TimeInterval = 2
    private static let wakeRecoveryMaxAttempts = 3
    private static let runtimePatchedConfigPath = kConfigFolderPath + ".runtime_config.yaml"

    /// Short-circuits TerminalConfirmAction during self-relaunch so the old
    /// status bar icon does not linger on "Quitting…" beside the new one (#84 #91).
    private var isRestarting = false

    private static let tunDNSServer = "198.18.0.2"

    private var savedDNSInfo: [String: Any] {
        get { UserDefaults.standard.dictionary(forKey: "kSavedDNSInfo") ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "kSavedDNSInfo") }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Logger.log("applicationWillFinishLaunching")
        signal(SIGPIPE, SIG_IGN)
        // crash recorder
        failLaunchProtect()
        NSAppleEventManager.shared()
            .setEventHandler(self,
                             andSelector: #selector(handleURL(event:reply:)),
                             forEventClass: AEEventClass(kInternetEventClass),
                             andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.migrateFromLegacyIfNeeded()
        Logger.log("applicationDidFinishLaunching")
        Logger.log("Appversion: \(AppVersionUtil.currentVersion) \(AppVersionUtil.currentBuild)")
        ProcessInfo.processInfo.disableSuddenTermination()
        // setup menu item first
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemLengthWithSpeed)
        statusItemView = StatusItemView.create(statusItem: statusItem)
        statusItemView.updateSize(width: statusItemLengthWithSpeed)
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        AppLogoTool.applyLogo()
        NotificationCenter.default.addObserver(
            forName: Settings.labChannelDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppLogoTool.applyLogo()
        }
        setupStatusMenuItemData()
        installTurnOffProxyMenuItem()
        installAdvancedTunMenuItem()
        installBypassChineseAppsMenuItem()
        DispatchQueue.main.async {
            self.postFinishLaunching()
        }
    }

    func postFinishLaunching() {
        Logger.log("postFinishLaunching")
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                self.checkMenuIconVisable()
            }
        }
        if #unavailable(macOS 10.15) {
            // dashboard is not support in macOS 10.15 below
            dashboardMenuItem.isHidden = true
            connectionsMenuItem.isHidden = true
        }
        AppVersionUtil.showUpgradeAlert()
        ICloudManager.shared.setup()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onICloudConfigStorageDidChange),
            name: .iCloudConfigStorageDidChange,
            object: nil
        )

        if WebPortalManager.hasWebProtal {
            WebPortalManager.shared.addWebProtalMenuItem(&statusMenu)
        }
        setupLanguageMenu()
        setupConfigEditorMenuItem()
        setupProfileMixinMenuItem()
        // 启用自动更新检查（使用fork项目的GitHub Pages）
        AutoUpgradeManager.shared.setup()
        AutoUpgradeManager.shared.setupCheckForUpdatesMenuItem(checkForUpdateMenuItem)
        installLabHelpMenuItems()
        // install proxy helper
        _ = ClashResourceManager.check()
        PrivilegedHelperManager.shared.checkInstall()
        ConfigFileManager.copySampleConfigIfNeed()

        // PFMoveToApplicationsFolderIfNecessary() — disabled: App Translocation breaks path detection for ad-hoc signed builds

        // claer not existed selected model
        removeUnExistProxyGroups()

        // clash logger
        if ApiRequest.useDirectApi() {
            Logger.log("setup built in logger/traffic")
            clash_setLogBlock { line, level in
                let clashLevel = ClashLogLevel(rawValue: level ?? "info")
                Logger.log(line ?? "", level: clashLevel ?? .info, function: "")
            }
            clashSetupLogger()

            clash_setTrafficBlock { [weak self] up, down in
                if RemoteControlManager.selectConfig == nil,
                   ConfigManager.shared.isEnhancedModeActive == false {
                    DispatchQueue.main.async {
                        self?.didUpdateTraffic(up: Int(up), down: Int(down))
                    }
                }
            }
            clashSetupTraffic()

        } else {
            Logger.log("do not setup built in logger/traffic, useDirectApi = false")
        }
        cleanupStaleMihomoCoreOnLaunch()

        // start proxy
        Logger.log("initClashCore")
        initClashCore()
        Logger.log("initClashCore finish")
        setupData()
        runAfterConfigReload = { [weak self] in
            if !Settings.builtInApiMode {
                self?.selectAllowLanWithMenory()
            }
            self?.restoreLastSpeedTestIfNeeded()
        }
        updateConfig(showNotification: false)
        updateLoggingLevel()
        restoreEnhancedModeIfNeeded()

        // start watch config file change
        ConfigManager.watchCurrentConfigFile()

        RemoteConfigManager.shared.migrateLegacyGeneratedRemoteConfigsIfNeeded()

        RemoteConfigManager.shared.autoUpdateCheck()

        setupNetworkNotifier()
        registCrashLogger()
        KeyboardShortCutManager.setup()
        RemoteControlManager.setupMenuItem(separator: externalControlSeparator)
        applyTrayMenuVisibility()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onTrayMenuSettingsChanged),
            name: .trayMenuSettingsChanged,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isRestarting {
            Logger.log("ClashFX restart: skipping interactive terminate flow")
            return .terminateNow
        }
        return TerminalConfirmAction.run()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        UserDefaults.standard.set(0, forKey: "launch_fail_times")
        Logger.log("ClashFX will terminate")
        // Fallback: TerminalCleanUpAction.run() already handles Enhanced Mode cleanup
        // in the normal quit path. This guard only fires if applicationWillTerminate
        // is reached without going through TerminalCleanUpAction (e.g. forced termination).
        if ConfigManager.shared.isEnhancedModeActive {
            cleanupEnhancedModeForTermination {}
        }
        if NetworkChangeNotifier.isCurrentSystemSetToClash(looser: true) ||
            NetworkChangeNotifier.hasInterfaceProxySetToClash() {
            Logger.log("Need Reset Proxy Setting again", level: .error)
            SystemProxyManager.shared.disableProxy()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            sender.windows
                .filter(\.isVisible)
                .forEach { $0.makeKeyAndOrderFront(nil) }
        }
        return false
    }

    func checkMenuIconVisable() {
        guard let button = statusItem.button else { assertionFailure(); return }
        guard let window = button.window else { assertionFailure(); return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let onScreenRect = window.convertToScreen(buttonRect)
        var leftScreenX: CGFloat = 0
        for screen in NSScreen.screens where screen.frame.origin.x < leftScreenX {
            leftScreenX = screen.frame.origin.x
        }
        let isMenuIconHidden = onScreenRect.midX < leftScreenX

        var isCoverdByNotch = false
        if #available(macOS 12, *), NSScreen.screens.count == 1, let screen = NSScreen.screens.first {
            // 修复 macOS 15+ 兼容性：添加额外的安全检查
            // auxiliaryTopLeftArea 和 auxiliaryTopRightArea 在某些情况下可能为 nil
            if let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea {
                // 添加额外的尺寸验证，避免无效的 CGRect 导致崩溃
                if leftArea.width > 0 && rightArea.width > 0 && leftArea.maxX < rightArea.minX {
                    if onScreenRect.minX > leftArea.maxX, onScreenRect.maxX < rightArea.minX {
                        isCoverdByNotch = true
                    }
                }
            }
        }

        Logger.log("checkMenuIconVisable: \(onScreenRect) \(leftScreenX), hidden: \(isMenuIconHidden), coverd by notch:\(isCoverdByNotch)")

        if isMenuIconHidden || isCoverdByNotch, !Settings.disableMenubarNotice {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("The status icon is coverd or hide by other app.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Never show again", comment: ""))
            if alert.runModal() == .alertSecondButtonReturn {
                Settings.disableMenubarNotice = true
            }
        }
    }

    func setupStatusMenuItemData() {
        showNetSpeedIndicatorMenuItem.title = NSLocalizedString("Show Proxy Speed", comment: "")
        ConfigManager.shared
            .showNetSpeedIndicatorObservable
            .bind { [weak self] show in
                guard let self = self else { return }
                self.showNetSpeedIndicatorMenuItem.state = (show ?? true) ? .on : .off
                self.statusItemView.showSpeedContainer(show: show ?? true)
                let statusItemLength = self.statusItemView.preferredWidth
                self.statusItem.length = statusItemLength
                self.statusItemView.updateSize(width: statusItemLength)
            }.disposed(by: disposeBag)

        let speedToolTip = NSLocalizedString(
            "Shows traffic that passes through ClashFX's local proxy or Enhanced Mode, not total system traffic.",
            comment: ""
        )
        statusItem.button?.toolTip = speedToolTip
        statusItemView.updateSpeedToolTip(speedToolTip)

        refreshStatusItemViewStatus()
        enhancedModeMenuItem.state = Settings.enhancedMode ? .on : .off
        bypassChineseAppsMenuItem?.state = Settings.bypassChineseApps ? .on : .off
        setupMenuShortcutDisplay()
        installSubscriptionStatusMenuItemIfNeeded()
        refreshSubscriptionStatusMenuItem()
    }

    private func setupMenuShortcutDisplay() {
        proxySettingMenuItem.setShortcut(for: .toggleSystemProxyMode)
        copyExportCommandMenuItem.setShortcut(for: .copyShellCommand)
        copyExportCommandExternalMenuItem.setShortcut(for: .copyExternalShellCommand)
        proxyModeDirectMenuItem.setShortcut(for: .modeDirect)
        proxyModeRuleMenuItem.setShortcut(for: .modeRule)
        proxyModeGlobalMenuItem.setShortcut(for: .modeGlobal)
        enhancedModeMenuItem.setShortcut(for: .toggleEnhancedMode)
        showLogMenuItem.setShortcut(for: .log)
        dashboardMenuItem.setShortcut(for: .dashboard)
        connectionsMenuItem.setShortcut(for: .nativeDashboard)
    }

    private func refreshStatusItemViewStatus(systemProxyActive: Bool? = nil) {
        let activeSystemProxy = systemProxyActive ?? (
            ConfigManager.shared.proxyPortAutoSet &&
                !ConfigManager.shared.isProxySetByOtherVariable.value &&
                !ConfigManager.shared.proxyShouldPaused.value
        )
        statusItemView.updateViewStatus(enableProxy: activeSystemProxy || ConfigManager.shared.isEnhancedModeActive)
    }

    private func installSubscriptionStatusMenuItemIfNeeded() {
        guard subscriptionStatusMenuItem == nil else { return }
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.isHidden = true
        let separator = NSMenuItem.separator()
        separator.isHidden = true
        statusMenu.insertItem(item, at: 0)
        statusMenu.insertItem(separator, at: 1)
        subscriptionStatusMenuItem = item
        subscriptionStatusSeparator = separator
    }

    func refreshSubscriptionStatusMenuItem() {
        guard let item = subscriptionStatusMenuItem,
              let separator = subscriptionStatusSeparator else { return }

        let activeName = ConfigManager.selectConfigName
        let activeRemote = RemoteConfigManager.shared.configs.first { $0.name == activeName }
        let info = activeRemote?.subscriptionInfo ?? localProxyProviderSubscriptionInfoCache[activeName]

        guard let info,
              let summary = SubscriptionInfoFormatter.menuSubtitle(for: info),
              let fullSummary = SubscriptionInfoFormatter.fullMenuSubtitle(for: info) else {
            item.attributedTitle = NSAttributedString(string: "")
            item.title = ""
            item.toolTip = nil
            item.isHidden = true
            separator.isHidden = true
            refreshLocalProxyProviderSubscriptionStatus(configName: activeName)
            return
        }

        item.attributedTitle = SubscriptionInfoFormatter.statusRowAttributedTitle(
            name: activeName,
            summary: summary
        )
        item.toolTip = fullSummary
        item.isHidden = false
        separator.isHidden = false
    }

    private func refreshLocalProxyProviderSubscriptionStatus(configName: String) {
        guard !RemoteConfigManager.shared.configs.contains(where: { $0.name == configName }) else { return }
        guard !localProxyProviderSubscriptionInfoRequests.contains(configName) else { return }
        if let lastAttempt = localProxyProviderSubscriptionInfoAttemptTimes[configName],
           Date().timeIntervalSince(lastAttempt) < Settings.configAutoUpdateInterval {
            return
        }

        localProxyProviderSubscriptionInfoRequests.insert(configName)
        localProxyProviderSubscriptionInfoAttemptTimes[configName] = Date()

        ConfigManager.getConfigPath(configName: configName) { [weak self] path in
            DispatchQueue.global(qos: .utility).async {
                guard let yaml = try? String(contentsOfFile: path, encoding: .utf8),
                      let providerURL = Self.firstRemoteProxyProviderURL(in: yaml) else {
                    DispatchQueue.main.async {
                        self?.localProxyProviderSubscriptionInfoRequests.remove(configName)
                    }
                    return
                }

                let providerConfig = RemoteConfigModel(url: providerURL.absoluteString, name: configName)
                RemoteConfigManager.getRemoteConfigData(config: providerConfig) { providerBody, _, providerHeaders in
                    let headerInfo = RemoteConfigManager.parseSubscriptionUserinfoHeader(providerHeaders)
                    let bodyInfo = providerBody.flatMap(RemoteConfigManager.parseSubscriptionInfoFromBody)
                    let info = SubscriptionInfo.merging(primary: headerInfo, fallback: bodyInfo)

                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.localProxyProviderSubscriptionInfoRequests.remove(configName)
                        if let info {
                            self.localProxyProviderSubscriptionInfoCache[configName] = info
                        }
                        if ConfigManager.selectConfigName == configName {
                            self.refreshSubscriptionStatusMenuItem()
                        }
                    }
                }
            }
        }
    }

    private static func firstRemoteProxyProviderURL(in yaml: String) -> URL? {
        guard let document = try? ConfigDocument.loadFromYAML(yaml) else { return nil }
        for (_, provider) in document.proxyProviders {
            guard let dict = provider as? [String: Any],
                  let type = (dict["type"] as? String)?.lowercased(),
                  ["http", "https"].contains(type),
                  let rawURL = dict["url"] as? String,
                  let url = URL(string: rawURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                continue
            }
            return url
        }
        return nil
    }

    func setupData() {
        SSIDSuspendTool.shared.setup()
        ConfigManager.shared
            .showNetSpeedIndicatorObservable.skip(1)
            .bind {
                _ in
                ApiRequest.shared.resetTrafficStreamApi()
            }.disposed(by: disposeBag)

        Observable
            .merge([ConfigManager.shared.proxyPortAutoSetObservable,
                    ConfigManager.shared.isProxySetByOtherVariable.asObservable(),
                    ConfigManager.shared.proxyShouldPaused.asObservable()])
            .observe(on: MainScheduler.instance)
            .map { _ -> NSControl.StateValue in
                if (ConfigManager.shared.isProxySetByOtherVariable.value || ConfigManager.shared.proxyShouldPaused.value) && ConfigManager.shared.proxyPortAutoSet {
                    return .mixed
                }
                return ConfigManager.shared.proxyPortAutoSet ? .on : .off
            }.distinctUntilChanged()
            .bind { [weak self] status in
                guard let self = self else { return }
                self.proxySettingMenuItem.state = status
                self.refreshStatusItemViewStatus(systemProxyActive: status == .on)
            }.disposed(by: disposeBag)

        let configObservable = ConfigManager.shared
            .currentConfigVariable
            .asObservable()
        Observable.zip(configObservable, configObservable.skip(1))
            .filter { _, new in return new != nil }
            .observe(on: MainScheduler.instance)
            .bind { [weak self] old, config in
                guard let self = self, let config = config else { return }
                self.proxyModeDirectMenuItem.state = .off
                self.proxyModeGlobalMenuItem.state = .off
                self.proxyModeRuleMenuItem.state = .off

                switch config.mode {
                case .direct: self.proxyModeDirectMenuItem.state = .on
                case .global: self.proxyModeGlobalMenuItem.state = .on
                case .rule: self.proxyModeRuleMenuItem.state = .on
                }
                self.allowFromLanMenuItem.state = config.allowLan ? .on : .off

                self.proxyModeMenuItem.title = "\(NSLocalizedString("Proxy Mode", comment: "")) (\(config.mode.name))"

                if old?.usedHttpPort != config.usedHttpPort || old?.usedSocksPort != config.usedSocksPort {
                    Logger.log("port config updated,new: \(config.usedHttpPort),\(config.usedSocksPort)")
                    if ConfigManager.shared.proxyPortAutoSet {
                        SystemProxyManager.shared.enableProxy(port: config.usedHttpPort, socksPort: config.usedSocksPort)
                    }
                }

                self.httpPortMenuItem.title = "Http Port: \(config.usedHttpPort)"
                self.socksPortMenuItem.title = "Socks Port: \(config.usedSocksPort)"
                self.apiPortMenuItem.title = "Api Port: \(ConfigManager.shared.apiPort)"
                self.ipMenuItem.title = "IP: \(NetworkChangeNotifier.getPrimaryIPAddress() ?? "")"

                if RemoteControlManager.selectConfig == nil {
                    ClashStatusTool.checkPortConfig(cfg: config)
                }

            }.disposed(by: disposeBag)

        if !PrivilegedHelperManager.shared.isHelperCheckFinished.value &&
            ConfigManager.shared.proxyPortAutoSet {
            PrivilegedHelperManager.shared.isHelperCheckFinished
                .filter { $0 }
                .take(1)
                .take(while: { _ in ConfigManager.shared.proxyPortAutoSet })
                .observe(on: MainScheduler.instance)
                .bind(onNext: { _ in
                    SystemProxyManager.shared.enableProxy()
                }).disposed(by: disposeBag)
        } else if ConfigManager.shared.proxyPortAutoSet {
            SystemProxyManager.shared.enableProxy()
        }

        LaunchAtLogin.shared
            .isEnableVirable
            .asObservable()
            .subscribe(onNext: { [weak self] enable in
                guard let self = self else { return }
                self.autoStartMenuItem.state = enable ? .on : .off
            }).disposed(by: disposeBag)

        remoteConfigAutoupdateMenuItem.state = RemoteConfigManager.autoUpdateEnable ? .on : .off

        if !PrivilegedHelperManager.shared.isHelperCheckFinished.value {
            proxySettingMenuItem.target = nil
            PrivilegedHelperManager.shared.isHelperCheckFinished
                .filter { $0 }
                .take(1)
                .observe(on: MainScheduler.instance)
                .subscribe { [weak self] _ in
                    guard let self = self else { return }
                    self.proxySettingMenuItem.target = self
                }.disposed(by: disposeBag)
        }
    }

    func setupNetworkNotifier() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NetworkChangeNotifier.start()
        }

        NotificationCenter
            .default
            .rx
            .notification(.systemNetworkStatusDidChange)
            .observe(on: MainScheduler.instance)
            .delay(.milliseconds(200), scheduler: MainScheduler.instance)
            .bind { _ in
                guard NetworkChangeNotifier.getPrimaryInterface() != nil else { return }
                let proxySetted = NetworkChangeNotifier.isCurrentSystemSetToClash()
                ConfigManager.shared.isProxySetByOtherVariable.accept(!proxySetted)
                if !proxySetted && ConfigManager.shared.proxyPortAutoSet {
                    let proxiesSetting = NetworkChangeNotifier.getRawProxySetting()
                    Logger.log("Proxy changed by other process!, current:\(proxiesSetting), is Interface Set: \(NetworkChangeNotifier.hasInterfaceProxySetToClash())", level: .warning)
                }
            }.disposed(by: disposeBag)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(resetProxySettingOnWakeupFromSleep),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        NotificationCenter
            .default
            .rx
            .notification(.systemNetworkStatusIPUpdate).map { _ in
                NetworkChangeNotifier.getPrimaryIPAddress(allowIPV6: false)
            }
            .startWith(NetworkChangeNotifier.getPrimaryIPAddress(allowIPV6: false))
            .distinctUntilChanged()
            .skip(1)
            .filter { $0 != nil }
            .observe(on: MainScheduler.instance)
            .debounce(.seconds(5), scheduler: MainScheduler.instance).bind { [weak self] _ in
                self?.healthCheckOnNetworkChange()
            }.disposed(by: disposeBag)

        ConfigManager.shared
            .isProxySetByOtherVariable
            .asObservable()
            .filter { _ in ConfigManager.shared.proxyPortAutoSet }
            .distinctUntilChanged()
            .filter { $0 }
            .filter { _ in !ConfigManager.shared.proxyShouldPaused.value }
            .bind { _ in
                let rawProxy = NetworkChangeNotifier.getRawProxySetting()
                Logger.log("proxy changed to no clashX setting: \(rawProxy)", level: .warning)
                NSUserNotificationCenter.default.postProxyChangeByOtherAppNotice()
            }.disposed(by: disposeBag)

        NotificationCenter
            .default
            .rx
            .notification(.systemNetworkStatusIPUpdate).map { _ in
                NetworkChangeNotifier.getPrimaryIPAddress(allowIPV6: false)
            }.bind { [weak self] _ in
                if !ApiRequest.useDirectApi() {
                    self?.resetStreamApi()
                }
            }.disposed(by: disposeBag)
    }

    func updateProxyList(withMenus menus: [NSMenuItem]) {
        guard !menus.isEmpty else { return }
        let startIndex = statusMenu.items.firstIndex(of: separatorLineTop)! + 1
        sepatatorLineEndProxySelect.isHidden = false
        for each in menus {
            statusMenu.insertItem(each, at: startIndex)
        }
        let removeStart = startIndex + menus.count
        let removeEnd = statusMenu.items.firstIndex(of: sepatatorLineEndProxySelect)!
        for _ in 0 ..< removeEnd - removeStart {
            statusMenu.removeItem(at: removeStart)
        }
    }

    func updateConfigFiles() {
        guard let menu = configSeparatorLine.menu else { return }
        MenuItemFactory.generateSwitchConfigMenuItems {
            items in
            let lineIndex = menu.items.firstIndex(of: self.configSeparatorLine)!
            for _ in 0 ..< lineIndex {
                menu.removeItem(at: 0)
            }
            for item in items.reversed() {
                menu.insertItem(item, at: 0)
            }
            // Apply config-switcher visibility to newly inserted items
            self.applyConfigSwitcherVisibility(
                showConfigSwitcher: Settings.trayMenuShowConfigs && Settings.trayMenuShowConfigSwitcher
            )
        }
    }

    @objc private func onICloudConfigStorageDidChange() {
        ConfigManager.getActiveConfigFilesList { [weak self] configNames in
            guard let self = self else { return }

            self.updateConfigFiles()

            guard !configNames.isEmpty else {
                Logger.log("[iCloud] No configs available after changing storage", level: .warning)
                return
            }

            let usesICloud = ICloudManager.shared.useiCloud.value
            let selectedConfig = ConfigManager.selectConfigName
            let rememberedConfig = ConfigManager.rememberedConfigName(forICloudStorage: usesICloud)
            let configToLoad: String
            if let rememberedConfig, configNames.contains(rememberedConfig) {
                configToLoad = rememberedConfig
            } else if let firstUserConfig = configNames.first(where: { $0 != "config" }) {
                configToLoad = firstUserConfig
            } else {
                configToLoad = configNames[0]
            }

            if configToLoad != selectedConfig {
                Logger.log("[iCloud] Selected config \(selectedConfig) is unavailable after changing storage; switching to \(configToLoad)")
                ConfigManager.selectConfigName = configToLoad
            } else {
                ConfigManager.watchCurrentConfigFile()
            }

            self.updateConfig(configName: configToLoad, showNotification: false)
        }
    }

    func updateLoggingLevel() {
        ApiRequest.updateLogLevel(level: ConfigManager.selectLoggingApiLevel)
        for item in logLevelMenuItem.submenu?.items ?? [] {
            item.state = item.title.lowercased() == ConfigManager.selectLoggingApiLevel.rawValue ? .on : .off
        }
        NotificationCenter.default.post(name: .reloadDashboard, object: nil)
    }

    func startProxy() {
        if ConfigManager.shared.isRunning { return }

        if !Settings.isApiSecretSet {
            if #available(macOS 11.0, *), let password = SecCreateSharedWebCredentialPassword() as? String {
                Settings.apiSecret = password
            } else {
                Settings.apiSecret = UUID().uuidString
            }
        }

        if clash_checkSecret().toString().isEmpty || Settings.overrideConfigSecret {
            clash_setSecret(Settings.apiSecret.goStringBuffer())
        }

        struct StartProxyResp: Codable {
            let externalController: String
            let secret: String
        }

        // setup ui config first — copy bundled dashboard into ~/.config/clashfx/
        // so it passes mihomo's safe-path check (which rejects DerivedData paths)
        if let bundleDashboard = Bundle.main.resourceURL?.appendingPathComponent("dashboard"),
           FileManager.default.fileExists(atPath: bundleDashboard.path) {
            let clashHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/clashfx/dashboard")
            let fm = FileManager.default

            if fm.fileExists(atPath: clashHome.path) {
                do {
                    try fm.removeItem(at: clashHome)
                } catch {
                    Logger.log("dashboard removeItem failed: \(error), retrying with chmod", level: .warning)
                    let chmod = Process()
                    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                    chmod.arguments = ["-R", "u+rwx", clashHome.path]
                    try? chmod.run()
                    chmod.waitUntilExit()

                    if (try? fm.removeItem(at: clashHome)) == nil {
                        Logger.log("dashboard chmod+remove also failed, renaming old directory", level: .error)
                        let trash = clashHome.deletingLastPathComponent()
                            .appendingPathComponent("dashboard-old-\(ProcessInfo.processInfo.globallyUniqueString)")
                        try? fm.moveItem(at: clashHome, to: trash)
                    }
                }
            }

            do {
                try fm.copyItem(at: bundleDashboard, to: clashHome)
            } catch {
                Logger.log("dashboard copyItem failed: \(error)", level: .error)
            }

            setUIPath(clashHome.path.goStringBuffer())
        }

        Logger.log("Trying start proxy, build-in mode: \(Settings.builtInApiMode), allow lan: \(ConfigManager.allowConnectFromLan) custom port: \(Settings.proxyPort)")

        var apiAddr = ""
        if Settings.apiPort > 0 {
            if Settings.apiPortAllowLan {
                apiAddr = "0.0.0.0:\(Settings.apiPort)"
            } else {
                apiAddr = "127.0.0.1:\(Settings.apiPort)"
            }
        }
        let startRes = run(Settings.builtInApiMode.goObject(),
                           ConfigManager.allowConnectFromLan.goObject(),
                           Settings.enableIPV6.goObject(),
                           GoUint32(Settings.proxyPort),
                           apiAddr.goStringBuffer())?
            .toString() ?? ""
        let jsonData = startRes.data(using: .utf8) ?? Data()
        if let res = try? JSONDecoder().decode(StartProxyResp.self, from: jsonData) {
            let port = res.externalController.components(separatedBy: ":").last ?? "9090"
            ConfigManager.shared.allowExternalControl = !res.externalController.contains("127.0.0.1") && !res.externalController.contains("localhost")
            ConfigManager.shared.apiPort = port
            ConfigManager.shared.apiSecret = res.secret
            ConfigManager.shared.isRunning = true
            proxyModeMenuItem.isEnabled = true
            dashboardMenuItem.isEnabled = true
        } else {
            ConfigManager.shared.isRunning = false
            proxyModeMenuItem.isEnabled = false
            Logger.log(startRes, level: .error)
            NSUserNotificationCenter.default.postConfigErrorNotice(msg: startRes)
        }
        Logger.log("Start proxy done")
    }

    func syncConfig(completeHandler: (() -> Void)? = nil) {
        ApiRequest.requestConfig { config in
            ConfigManager.shared.currentConfig = config
            completeHandler?()
        }
    }

    func resetStreamApi() {
        let now = Date()
        let minInterval: TimeInterval = 0.5
        pendingStreamResetWork?.cancel()

        let elapsed = now.timeIntervalSince(lastStreamResetTime)
        if elapsed >= minInterval {
            lastStreamResetTime = now
            ApiRequest.shared.delegate = self
            ApiRequest.shared.resetStreamApis()
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastStreamResetTime = Date()
                ApiRequest.shared.delegate = self
                ApiRequest.shared.resetStreamApis()
            }
            pendingStreamResetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (minInterval - elapsed), execute: work)
        }
    }

    func updateConfig(configName: String? = nil, showNotification: Bool = true, completeHandler: ((ErrorString?) -> Void)? = nil) {
        guard !isConfigUpdating else {
            Logger.log("updateConfig: skipped, already updating", level: .warning)
            completeHandler?("Config update already in progress")
            return
        }
        startProxy()
        guard ConfigManager.shared.isRunning else { return }

        isConfigUpdating = true
        clashPauseCallbacks()
        let config = configName ?? ConfigManager.selectConfigName

        ClashProxy.cleanCache()

        let reloadCallback: (ErrorString?) -> Void = { [weak self] err in
            guard let self = self else { return }

            clashResumeCallbacks()
            self.isConfigUpdating = false

            defer {
                completeHandler?(err)
            }

            if let err {
                UpdateConfigAction.showError(text: err, configName: config)
            } else {
                self.syncConfig()
                self.resetStreamApi()
                self.runAfterConfigReload?()
                self.runAfterConfigReload = nil
                if showNotification {
                    NSUserNotificationCenter.default
                        .post(title: NSLocalizedString("Reload Config Succeed", comment: ""),
                              info: NSLocalizedString("Success", comment: ""))
                }

                if let newConfigName = configName {
                    ConfigManager.selectConfigName = newConfigName
                }
                self.selectProxyGroupWithMemory()
                self.selectOutBoundModeWithMenory()
                MenuItemFactory.recreateProxyMenuItems()
                NotificationCenter.default.post(name: .reloadDashboard, object: nil)
            }
        }

        requestConfigUpdateApplyingRuntimePatch(configName: config, callback: reloadCallback)
    }

    private func requestConfigUpdateApplyingRuntimePatch(configName: String, callback: @escaping ((ErrorString?) -> Void)) {
        ConfigManager.getConfigPath(configName: configName) { [weak self] sourcePath in
            guard let self = self else { return }
            if let patchedPath = self.writeRuntimePatchedConfigIfNeeded(
                for: configName,
                sourcePath: sourcePath,
                includeRulePatch: true
            ) {
                ApiRequest.requestConfigUpdate(configPath: patchedPath, callback: callback)
            } else {
                ApiRequest.requestConfigUpdate(configPath: sourcePath, callback: callback)
            }
        }
    }

    private func writeRuntimePatchedConfigIfNeeded(
        for configName: String,
        sourcePath: String,
        includeRulePatch: Bool
    ) -> String? {
        let removePatched: () -> Void = {
            try? FileManager.default.removeItem(atPath: Self.runtimePatchedConfigPath)
        }

        guard FileManager.default.fileExists(atPath: sourcePath) else {
            removePatched()
            return nil
        }

        do {
            let yaml = try String(contentsOfFile: sourcePath, encoding: .utf8)
            guard var root = try Yams.load(yaml: yaml) as? [String: Any] else {
                Logger.log("[Runtime Patch] YAML root is not a dictionary, skipping", level: .warning)
                removePatched()
                return nil
            }

            var changed = applyProfileRuleDirectives(in: &root)
            changed = applyProfileMixin(to: &root) || changed

            if includeRulePatch && !Settings.enhancedMode {
                let injectedRules = Settings.proxyIgnoreListAsRules()
                if !injectedRules.isEmpty {
                    let existingRules: [String]
                    if let rules = root["rules"] {
                        guard let parsedRules = rules as? [String] else {
                            Logger.log("[Runtime Patch] YAML rules is not a string array, skipping", level: .warning)
                            removePatched()
                            return nil
                        }
                        existingRules = parsedRules
                    } else {
                        existingRules = []
                    }
                    root["rules"] = injectedRules + existingRules
                    changed = true
                }
            }

            guard changed else {
                removePatched()
                return nil
            }

            let patched = try Yams.dump(object: root)
            try patched.write(toFile: Self.runtimePatchedConfigPath, atomically: true, encoding: .utf8)
            Logger.log("[Runtime Patch] Wrote runtime config for \(configName) to \(Self.runtimePatchedConfigPath)")
            return Self.runtimePatchedConfigPath
        } catch {
            Logger.log("[Runtime Patch] Failed: \(error.localizedDescription)", level: .warning)
            removePatched()
            return nil
        }
    }

    private func applyProfileMixin(to root: inout [String: Any]) -> Bool {
        guard FileManager.default.fileExists(atPath: Paths.profileMixinPath) else { return false }

        do {
            let yaml = try String(contentsOfFile: Paths.profileMixinPath, encoding: .utf8)
            guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard var mixin = try Yams.load(yaml: yaml) as? [String: Any] else {
                Logger.log("[Profile Mixin] YAML root is not a dictionary, skipping", level: .warning)
                return false
            }
            applyProfileRuleDirectives(from: &mixin, to: &root)
            root = mergeProfileMixin(mixin, into: root)
            Logger.log("[Profile Mixin] Applied \(Paths.profileMixinPath)")
            return true
        } catch {
            Logger.log("[Profile Mixin] Failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    private func applyProfileRuleDirectives(in root: inout [String: Any]) -> Bool {
        guard let ruleDirectives = takeProfileRuleDirectives(from: &root) else { return false }

        logProfileProcessRuleWarningIfNeeded(ruleDirectives.prepend + ruleDirectives.append)
        let existingRules = profileMixinRules(from: root["rules"])
        root["rules"] = mergeUniqueRules(ruleDirectives.prepend + existingRules + ruleDirectives.append)
        return true
    }

    private func applyProfileRuleDirectives(from mixin: inout [String: Any], to root: inout [String: Any]) {
        guard let ruleDirectives = takeProfileRuleDirectives(from: &mixin) else { return }

        logProfileProcessRuleWarningIfNeeded(ruleDirectives.prepend + ruleDirectives.append)
        let existingRules = profileMixinRules(from: root["rules"])
        root["rules"] = mergeUniqueRules(ruleDirectives.prepend + existingRules + ruleDirectives.append)
    }

    private func takeProfileRuleDirectives(from root: inout [String: Any]) -> (prepend: [String], append: [String])? {
        guard var profile = root["profile"] as? [String: Any] else { return nil }

        let prependRules = profileMixinRules(from: profile.removeValue(forKey: "prepend-rules"))
        let appendRules = profileMixinRules(from: profile.removeValue(forKey: "append-rules"))
        guard !prependRules.isEmpty || !appendRules.isEmpty else { return nil }

        if profile.isEmpty {
            root["profile"] = nil
        } else {
            root["profile"] = profile
        }

        return (prependRules, appendRules)
    }

    private func logProfileProcessRuleWarningIfNeeded(_ rules: [String]) {
        guard !Settings.enhancedMode else { return }
        let hasProcessRule = rules.contains { rule in
            rule.hasPrefix("PROCESS-NAME,") || rule.hasPrefix("PROCESS-PATH,")
        }
        if hasProcessRule {
            Logger.log("[Profile Rules] PROCESS-NAME and PROCESS-PATH rules require Enhanced Mode (TUN) to match reliably", level: .warning)
        }
    }

    private func profileMixinRules(from value: Any?) -> [String] {
        guard let value = value else { return [] }
        if let rules = value as? [String] {
            return rules
        }
        if let rules = value as? [Any] {
            return rules.compactMap { $0 as? String }
        }
        Logger.log("[Profile Mixin] Rule directive is not a string array, skipping", level: .warning)
        return []
    }

    private func mergeUniqueRules(_ rules: [String]) -> [String] {
        var seen = Set<String>()
        return rules.filter { rule in
            guard !seen.contains(rule) else { return false }
            seen.insert(rule)
            return true
        }
    }

    private func mergeProfileMixin(_ mixin: [String: Any], into base: [String: Any]) -> [String: Any] {
        var merged = base
        for (key, mixinValue) in mixin {
            if let baseDict = merged[key] as? [String: Any], let mixinDict = mixinValue as? [String: Any] {
                merged[key] = mergeProfileMixin(mixinDict, into: baseDict)
            } else if let baseArray = merged[key] as? [[String: Any]], let mixinArray = mixinValue as? [[String: Any]] {
                merged[key] = mergeNamedArray(baseArray, with: mixinArray)
            } else if let baseArray = merged[key] as? [String], let mixinArray = mixinValue as? [String] {
                merged[key] = baseArray + mixinArray.filter { !baseArray.contains($0) }
            } else {
                merged[key] = mixinValue
            }
        }
        return merged
    }

    private func mergeNamedArray(_ base: [[String: Any]], with mixin: [[String: Any]]) -> [[String: Any]] {
        var merged = base
        for item in mixin {
            if let name = item["name"] as? String,
               let index = merged.firstIndex(where: { ($0["name"] as? String) == name }) {
                merged[index] = mergeProfileMixin(item, into: merged[index])
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    @objc func resetProxySettingOnWakeupFromSleep() {
        Logger.log("Wake recovery: didWake received")

        if !ApiRequest.useDirectApi() {
            resetStreamApi()
        }

        if ConfigManager.shared.isProxySetByOtherVariable.value {
            Logger.log("Wake recovery: skip immediate system proxy restore because proxy is marked as changed by another process", level: .warning)
        } else if !ConfigManager.shared.proxyPortAutoSet {
            Logger.log("Wake recovery: skip immediate system proxy restore because System Proxy is off", level: .debug)
        } else if NetworkChangeNotifier.getPrimaryInterface() == nil {
            Logger.log("Wake recovery: primary interface is not ready yet", level: .warning)
        } else if !NetworkChangeNotifier.isCurrentSystemSetToClash() {
            let rawProxy = NetworkChangeNotifier.getRawProxySetting()
            Logger.log("Wake recovery: restoring system proxy, current:\(rawProxy)", level: .warning)
            SystemProxyManager.shared.disableProxy()
            SystemProxyManager.shared.enableProxy()
        } else {
            Logger.log("Wake recovery: system proxy already points to ClashFX; scheduling core health check")
        }

        scheduleWakeRecovery()
    }

    private func scheduleWakeRecovery() {
        pendingWakeRecoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recoverProxyAfterWake(attemptsLeft: Self.wakeRecoveryMaxAttempts)
        }
        pendingWakeRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeRecoveryDelay, execute: work)
    }

    private func recoverProxyAfterWake(attemptsLeft: Int) {
        guard NetworkChangeNotifier.getPrimaryInterface() != nil else {
            guard attemptsLeft > 1 else {
                Logger.log("Wake recovery: primary interface never became ready", level: .error)
                return
            }
            Logger.log("Wake recovery: waiting for primary interface (\(attemptsLeft - 1) retries left)", level: .warning)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeRecoveryRetryDelay) { [weak self] in
                self?.recoverProxyAfterWake(attemptsLeft: attemptsLeft - 1)
            }
            return
        }

        checkCoreHealthAfterWake { [weak self] healthy in
            guard let self = self else { return }
            if healthy {
                Logger.log("Wake recovery: core API is healthy")
                self.finishHealthyWakeRecovery()
                return
            }

            Logger.log("Wake recovery: core API is not responding; restoring active proxy mode", level: .error)
            self.restoreCoreAfterWake()
        }
    }

    private func finishHealthyWakeRecovery() {
        if ConfigManager.shared.proxyPortAutoSet,
           !ConfigManager.shared.proxyShouldPaused.value,
           !ConfigManager.shared.isProxySetByOtherVariable.value,
           !NetworkChangeNotifier.isCurrentSystemSetToClash() {
            let rawProxy = NetworkChangeNotifier.getRawProxySetting()
            Logger.log("Wake recovery: core healthy but system proxy missing, current:\(rawProxy)", level: .warning)
            SystemProxyManager.shared.disableProxy()
            SystemProxyManager.shared.enableProxy()
        }

        if ConfigManager.shared.isEnhancedModeActive {
            verifyTunStatus(port: ConfigManager.shared.apiPort, secret: ConfigManager.shared.apiSecret)
            overrideDNSForTun()
        }

        if !ApiRequest.useDirectApi() {
            resetStreamApi()
        }
    }

    private func restoreCoreAfterWake() {
        if Settings.enhancedMode {
            Logger.log("Wake recovery: restoring Enhanced Mode")
            restoreEnhancedMode(attemptsLeft: 3)
            return
        }

        if ConfigManager.shared.isEnhancedModeActive {
            Logger.log("Wake recovery: Enhanced Mode active without persisted setting; restarting Enhanced Mode", level: .warning)
            enableEnhancedMode { [weak self] error in
                if let error = error {
                    Logger.log("Wake recovery: Enhanced Mode restart failed: \(error)", level: .error)
                    return
                }
                self?.scheduleEnhancedModePostToggleRefresh()
            }
            return
        }

        Logger.log("Wake recovery: restarting built-in core")
        ConfigManager.shared.isRunning = false
        updateConfig(showNotification: false) { [weak self] error in
            if let error = error {
                Logger.log("Wake recovery: built-in core restore failed: \(error)", level: .error)
                return
            }
            if ConfigManager.shared.proxyPortAutoSet,
               !ConfigManager.shared.proxyShouldPaused.value,
               !ConfigManager.shared.isProxySetByOtherVariable.value {
                SystemProxyManager.shared.enableProxy()
            }
            self?.resetStreamApi()
        }
    }

    private func checkCoreHealthAfterWake(complete: @escaping (Bool) -> Void) {
        guard let url = URL(string: ConfigManager.apiUrl.appending("/configs")) else {
            complete(false)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 2)
        for header in ApiRequest.authHeader() {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let healthy = statusCode == 200
            if !healthy {
                Logger.log("Wake recovery: /configs health failed status=\(statusCode), error=\(error?.localizedDescription ?? "none")", level: .warning)
            }
            DispatchQueue.main.async {
                complete(healthy)
            }
        }.resume()
    }

    @objc func healthCheckOnNetworkChange() {
        ApiRequest.getMergedProxyData {
            proxyResp in
            guard let proxyResp = proxyResp else { return }

            var providers = Set<ClashProxyName>()

            let groups = proxyResp.proxyGroups.filter(\.type.isAutoGroup)
            for group in groups {
                group.all?.compactMap {
                    proxyResp.proxiesMap[$0]?.enclosingProvider?.name
                }.forEach {
                    providers.insert($0)
                }
            }

            for group in groups {
                Logger.log("Start auto health check for group \(group.name)")
                ApiRequest.healthCheck(proxy: group.name)
            }

            for provider in providers {
                Logger.log("Start auto health check for provider \(provider)")
                ApiRequest.healthCheck(proxy: provider)
            }
        }
    }
}

// MARK: Main actions

extension AppDelegate {
    @IBAction func actionDashboard(_ sender: NSMenuItem?) {
        DispatchQueue.main.async {
            ClashWindowController<ClashWebViewContoller>.create().showWindow(sender)
        }
    }

    @IBAction func actionConnections(_ sender: NSMenuItem?) {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                ClashWindowController<DashboardViewController>.create().showWindow(sender)
            }
        }
    }

    @IBAction func actionToggleEnhancedMode(_ sender: NSMenuItem?) {
        let newState = !Settings.enhancedMode
        guard ConfigManager.shared.isRunning else { return }
        enhancedModeMenuItem.isEnabled = false

        let completion: (String?) -> Void = { [weak self] error in
            guard let self = self else { return }
            self.enhancedModeMenuItem.isEnabled = true
            if let error = error {
                Settings.enhancedMode = !newState
                self.enhancedModeMenuItem.state = !newState ? .on : .off
                Logger.log("Enhanced Mode toggle failed: \(error)", level: .error)
                NSUserNotificationCenter.default.postConfigErrorNotice(msg: error)
            } else {
                Settings.enhancedMode = newState
                self.enhancedModeMenuItem.state = newState ? .on : .off
                Logger.log("Enhanced Mode \(newState ? "enabled" : "disabled")")
                let info = newState ? "Enhanced Mode Enabled" : "Enhanced Mode Disabled"
                NSUserNotificationCenter.default
                    .post(title: NSLocalizedString("Enhanced Mode", comment: ""),
                          info: NSLocalizedString(info, comment: ""))
            }
            self.scheduleEnhancedModePostToggleRefresh()
        }

        if newState {
            enableEnhancedMode(completion: completion)
        } else {
            disableEnhancedMode(completion: completion)
        }
    }

    private func installTurnOffProxyMenuItem() {
        let item = NSMenuItem(
            title: NSLocalizedString("Turn Off All Proxy Modes", comment: ""),
            action: #selector(actionTurnOffAllProxyModes(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.toolTip = NSLocalizedString(
            "Disable System Proxy and Enhanced Mode together",
            comment: ""
        )

        let parentMenu = proxySettingMenuItem.menu ?? statusMenu
        let insertIndex = parentMenu?.index(of: proxySettingMenuItem) ?? -1
        if let menu = parentMenu, insertIndex >= 0 {
            menu.insertItem(item, at: insertIndex)
        } else {
            statusMenu.addItem(item)
        }
        turnOffProxyMenuItem = item
    }

    @objc func actionTurnOffAllProxyModes(_ sender: Any?) {
        if ConfigManager.shared.proxyPortAutoSet || ConfigManager.shared.isProxySetByOtherVariable.value {
            ConfigManager.shared.isProxySetByOtherVariable.accept(false)
            ConfigManager.shared.proxyPortAutoSet = false
            SystemProxyManager.shared.disableProxy()
            proxySettingMenuItem.state = .off
        }

        guard Settings.enhancedMode || ConfigManager.shared.isEnhancedModeActive else {
            refreshStatusItemViewStatus(systemProxyActive: false)
            return
        }

        enhancedModeMenuItem.isEnabled = false
        disableEnhancedMode { [weak self] error in
            guard let self = self else { return }
            self.enhancedModeMenuItem.isEnabled = true
            if let error = error {
                Logger.log("Turn off proxy modes failed: \(error)", level: .error)
                NSUserNotificationCenter.default.postConfigErrorNotice(msg: error)
                return
            }
            Settings.enhancedMode = false
            self.enhancedModeMenuItem.state = .off
            Logger.log("All proxy modes disabled")
            self.scheduleEnhancedModePostToggleRefresh()
        }
    }

    private func installLabHelpMenuItems() {
        guard let parent = helpMenuItem.submenu ?? helpMenuItem.menu else { return }

        let sep = NSMenuItem.separator()
        parent.addItem(sep)
        labHelpSeparator = sep

        let feedback = NSMenuItem(
            title: NSLocalizedString("Send Feedback…", comment: ""),
            action: #selector(actionLabSendFeedback(_:)),
            keyEquivalent: ""
        )
        feedback.target = self
        parent.addItem(feedback)
        labHelpMenuItems.append(feedback)
        labFeedbackMenuItem = feedback

        let copyDiag = NSMenuItem(
            title: NSLocalizedString("Copy Diagnostic Info…", comment: ""),
            action: #selector(actionLabCopyDiagnostic(_:)),
            keyEquivalent: ""
        )
        copyDiag.target = self
        parent.addItem(copyDiag)
        labHelpMenuItems.append(copyDiag)
        labCopyDiagMenuItem = copyDiag

        let crashLogs = NSMenuItem(
            title: NSLocalizedString("Open Crash Log Folder", comment: ""),
            action: #selector(actionLabOpenCrashLogs(_:)),
            keyEquivalent: ""
        )
        crashLogs.target = self
        parent.addItem(crashLogs)
        labHelpMenuItems.append(crashLogs)
        labCrashLogsMenuItem = crashLogs

        if AutoUpgradeManager.isLabBuild {
            let rollback = NSMenuItem(
                title: NSLocalizedString("Roll Back to Stable…", comment: ""),
                action: #selector(actionLabRollback(_:)),
                keyEquivalent: ""
            )
            rollback.target = self
            parent.addItem(rollback)
            labHelpMenuItems.append(rollback)
            labRollbackMenuItem = rollback
        }
    }

    @objc private func actionLabSendFeedback(_ sender: Any) {
        LabSupport.openGitHubIssueWithTemplate()
    }

    @objc private func actionLabCopyDiagnostic(_ sender: Any) {
        LabSupport.copyDiagnosticToPasteboardWithPreview()
    }

    @objc private func actionLabOpenCrashLogs(_ sender: Any) {
        LabSupport.openCrashLogFolder()
    }

    @objc private func actionLabRollback(_ sender: Any) {
        LabSupport.presentRollbackDialog()
    }

    private func installAdvancedTunMenuItem() {
        let item = NSMenuItem(
            title: NSLocalizedString("Advanced TUN Settings…", comment: ""),
            action: #selector(showAdvancedTunSettings(_:)),
            keyEquivalent: ""
        )
        item.target = self
        let parentMenu = enhancedModeMenuItem.menu ?? statusMenu
        let insertIndex = (parentMenu?.index(of: enhancedModeMenuItem) ?? -1) + 1
        if let menu = parentMenu, insertIndex > 0 {
            menu.insertItem(item, at: insertIndex)
        } else {
            statusMenu.addItem(item)
        }
        advancedTunMenuItem = item
    }

    private func installBypassChineseAppsMenuItem() {
        let item = NSMenuItem(
            title: NSLocalizedString("Bypass Common Chinese Apps", comment: ""),
            action: #selector(actionToggleBypassChineseApps(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = Settings.bypassChineseApps ? .on : .off
        item.toolTip = NSLocalizedString(
            "Requires Enhanced Mode (uses PROCESS-NAME rules)",
            comment: ""
        )
        let parentMenu = enhancedModeMenuItem.menu ?? statusMenu
        let anchor = advancedTunMenuItem ?? enhancedModeMenuItem
        let insertIndex = (parentMenu?.index(of: anchor!) ?? -1) + 1
        if let menu = parentMenu, insertIndex > 0 {
            menu.insertItem(item, at: insertIndex)
        } else {
            statusMenu.addItem(item)
        }
        bypassChineseAppsMenuItem = item
    }

    @objc func actionToggleBypassChineseApps(_ sender: NSMenuItem) {
        let newState = !Settings.bypassChineseApps
        Settings.bypassChineseApps = newState
        bypassChineseAppsMenuItem?.state = newState ? .on : .off
        Logger.log("Bypass Common Chinese Apps \(newState ? "enabled" : "disabled")")

        if Settings.enhancedMode {
            disableEnhancedMode { [weak self] _ in
                self?.enableEnhancedMode { _ in }
            }
        }
    }

    @objc func showAdvancedTunSettings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Advanced TUN Settings", comment: "")
        let advancedTunInfo = "MTU 1500 matches the real internet path; 4064 is the macOS utun ceiling. " +
            "Pinning Interface avoids the macOS sleep/wake auto-detect bug. " +
            "Use Custom Config keeps your config file as-is; " +
            "Enhanced Mode still verifies TUN and applies macOS DNS override. " +
            "Toggle Enhanced Mode off then on to apply."
        alert.informativeText = NSLocalizedString(
            advancedTunInfo,
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("Apply", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let mtuField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        mtuField.placeholderString = "1500"
        mtuField.stringValue = "\(Settings.tunMTU)"

        let mtuLabel = NSTextField(labelWithString: String(
            format: NSLocalizedString("TUN MTU (%d–%d):", comment: ""),
            Settings.minTunMTU, Settings.maxTunMTU
        ))

        let ifaceField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        ifaceField.placeholderString = "en0"
        ifaceField.stringValue = Settings.tunInterfaceName

        let ifaceLabel = NSTextField(labelWithString: NSLocalizedString(
            "Interface (empty = auto-detect):",
            comment: ""
        ))

        let customConfigButton = NSButton(
            checkboxWithTitle: NSLocalizedString("Use Custom Config as-is", comment: ""),
            target: nil,
            action: nil
        )
        customConfigButton.state = Settings.enhancedModeUseCustomConfig ? .on : .off
        customConfigButton.toolTip = NSLocalizedString(
            "Requires your config to define tun, DNS hijack/fake-ip DNS, external-controller, and LAN binding correctly. ClashFX will still apply and restore macOS DNS while Enhanced Mode is on.",
            comment: ""
        )

        let stack = NSStackView(views: [mtuLabel, mtuField, ifaceLabel, ifaceField, customConfigButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 140)

        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trimmedMTU = mtuField.stringValue.trimmingCharacters(in: .whitespaces)
        if let mtu = Int(trimmedMTU), mtu >= Settings.minTunMTU, mtu <= Settings.maxTunMTU {
            Settings.tunMTU = mtu
        } else if !trimmedMTU.isEmpty {
            NSUserNotificationCenter.default.postConfigErrorNotice(
                msg: NSLocalizedString("Invalid MTU. Kept previous value.", comment: "")
            )
        }
        Settings.tunInterfaceName = ifaceField.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        Settings.enhancedModeUseCustomConfig = customConfigButton.state == .on
    }

    private func enableEnhancedMode(completion: @escaping (String?) -> Void) {
        // Allow one retry: each attempt regenerates .enhanced_config.yaml, which
        // re-picks the controller port (stable 19090, or a fresh free port if it
        // is occupied by a stale core). This absorbs transient port races and
        // leftover mihomo_core processes that would otherwise fail the launch.
        attemptEnableEnhancedMode(attemptsLeft: 1, alreadySuspended: false, completion: completion)
    }

    private func scheduleEnhancedModePostToggleRefresh() {
        pendingEnhancedModeRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.syncConfig()
            self.resetStreamApi()
            MenuItemFactory.refreshExistingMenuItems()
        }
        pendingEnhancedModeRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func attemptEnableEnhancedMode(attemptsLeft: Int, alreadySuspended: Bool, completion: @escaping (String?) -> Void) {
        let tempConfigPath = kConfigFolderPath + ".enhanced_config.yaml"
        let selectedConfigName = ConfigManager.selectConfigName

        ConfigManager.getConfigPath(configName: selectedConfigName) { selectedConfigPath in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let runtimeConfigPath = self.writeRuntimePatchedConfigIfNeeded(
                    for: selectedConfigName,
                    sourcePath: selectedConfigPath,
                    includeRulePatch: false
                ) ?? selectedConfigPath

                if Settings.enhancedModeUseCustomConfig {
                    let launchInfo = self.readCustomEnhancedModeLaunchInfo(configPath: runtimeConfigPath)
                    DispatchQueue.main.async {
                        self.finishEnhancedModeLaunchPreparation(
                            result: launchInfo,
                            configPath: runtimeConfigPath,
                            attemptsLeft: attemptsLeft,
                            alreadySuspended: alreadySuspended,
                            completion: completion
                        )
                    }
                    return
                }

                let writeResult = clashWriteEnhancedConfig(
                    runtimeConfigPath.goStringBuffer(),
                    tempConfigPath.goStringBuffer(),
                    Settings.normalizeAndPersistTunRouteExcludeList().joined(separator: ",").goStringBuffer(),
                    GoUint32(Settings.tunMTU),
                    Settings.tunInterfaceName.goStringBuffer(),
                    Settings.bypassChineseApps ? 1 : 0
                )?.toString() ?? ""

                DispatchQueue.main.async {
                    guard !writeResult.hasPrefix("error:") else {
                        self.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: alreadySuspended)
                        completion(writeResult)
                        return
                    }

                    guard let jsonData = writeResult.data(using: .utf8),
                          let portInfo = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String],
                          let extController = portInfo["externalController"],
                          let port = extController.components(separatedBy: ":").last else {
                        self.resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: alreadySuspended)
                        completion(NSLocalizedString("Failed to parse enhanced config", comment: ""))
                        return
                    }

                    self.finishEnhancedModeLaunchPreparation(
                        result: .success(port: port, secret: portInfo["secret"] ?? ""),
                        configPath: tempConfigPath,
                        attemptsLeft: attemptsLeft,
                        alreadySuspended: alreadySuspended,
                        completion: completion
                    )
                }
            }
        }
    }

    private func readCustomEnhancedModeLaunchInfo(configPath: String) -> EnhancedModeLaunchPreparation {
        do {
            let yaml = try String(contentsOfFile: configPath, encoding: .utf8)
            guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
                return .failure(NSLocalizedString("Failed to parse enhanced config", comment: ""))
            }
            guard let controller = root["external-controller"] as? String,
                  let port = controller.components(separatedBy: ":").last,
                  !port.isEmpty,
                  Int(port) != nil else {
                return .failure(NSLocalizedString("Custom config must set external-controller", comment: ""))
            }
            return .success(port: port, secret: root["secret"] as? String ?? "")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: Bool) {
        if alreadySuspended {
            clashResumeCallbacks()
            _ = clashResumeCore()
        }
    }

    private func finishEnhancedModeLaunchPreparation(
        result: EnhancedModeLaunchPreparation,
        configPath: String,
        attemptsLeft: Int,
        alreadySuspended: Bool,
        completion: @escaping (String?) -> Void
    ) {
        guard case let .success(port, secret) = result else {
            resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: alreadySuspended)
            if case let .failure(error) = result {
                completion(error)
            }
            return
        }

        guard let binaryPath = Bundle.main.path(forResource: "mihomo_core", ofType: nil) else {
            resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: alreadySuspended)
            completion(NSLocalizedString("mihomo_core not found", comment: ""))
            return
        }

        guard let helper = PrivilegedHelperManager.shared.helper() else {
            resumeEnhancedModeCallbacksIfNeeded(alreadySuspended: alreadySuspended)
            completion(NSLocalizedString("Helper not available", comment: ""))
            return
        }

        if !alreadySuspended {
            clashPauseCallbacks()
            clashSuspendCore()
        }

        helper.startMihomoCore(
            withBinaryPath: binaryPath,
            configPath: configPath,
            homeDir: kConfigFolderPath
        ) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    if attemptsLeft > 0, !Settings.enhancedModeUseCustomConfig {
                        Logger.log("External core launch failed (\(error)), retrying (\(attemptsLeft) left)", level: .warning)
                        helper.stopMihomoCore { _ in
                            DispatchQueue.main.async {
                                self.attemptEnableEnhancedMode(attemptsLeft: attemptsLeft - 1, alreadySuspended: true, completion: completion)
                            }
                        }
                    } else {
                        clashResumeCallbacks()
                        _ = clashResumeCore()
                        completion(error)
                    }
                    return
                }

                ConfigManager.shared.apiPort = port
                ConfigManager.shared.apiSecret = secret
                ConfigManager.shared.isEnhancedModeActive = true
                self.refreshStatusItemViewStatus()
                self.waitForExternalCore(port: port, secret: secret, retriesLeft: 10) { success in
                    if success {
                        clashResumeCallbacks()
                        if Settings.enhancedModeUseCustomConfig {
                            Logger.log("Enhanced Mode started with custom config as-is; applying TUN checks and system DNS override")
                        } else {
                            Logger.log("Enhanced Mode started with generated enhanced config")
                        }
                        self.verifyTunStatus(port: port, secret: secret)
                        self.overrideDNSForTun()
                        self.restoreSelectedOutboundModeAfterCoreChange {
                            completion(nil)
                        }
                    } else if attemptsLeft > 0, !Settings.enhancedModeUseCustomConfig {
                        Logger.log("External core not ready, regenerating config and retrying (\(attemptsLeft) left)", level: .warning)
                        ConfigManager.shared.isEnhancedModeActive = false
                        self.refreshStatusItemViewStatus()
                        helper.stopMihomoCore { _ in
                            DispatchQueue.main.async {
                                self.attemptEnableEnhancedMode(attemptsLeft: attemptsLeft - 1, alreadySuspended: true, completion: completion)
                            }
                        }
                    } else {
                        Logger.log("External core failed to start, rolling back", level: .error)
                        helper.stopMihomoCore { _ in
                            DispatchQueue.main.async {
                                ConfigManager.shared.isEnhancedModeActive = false
                                ConfigManager.shared.isRunning = false
                                self.refreshStatusItemViewStatus()
                                clashReopenCacheDB()
                                clashResumeCallbacks()
                                self.startProxy()
                                completion(NSLocalizedString("Enhanced Mode failed: core not responding", comment: ""))
                            }
                        }
                    }
                }
            }
        }
    }

    private func waitForExternalCore(port: String, secret: String, retriesLeft: Int, ready: @escaping (Bool) -> Void) {
        let url = URL(string: "http://127.0.0.1:\(port)/configs")!
        var request = URLRequest(url: url, timeoutInterval: 2)
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                // mihomo's REST server can answer /configs while listeners are still being created,
                // returning port=0. Require port>0 so the GUI never observes that transient.
                let listenersUp: Bool = {
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return false }
                    let mixed = (json["mixed-port"] as? NSNumber)?.intValue ?? 0
                    let httpPort = (json["port"] as? NSNumber)?.intValue ?? 0
                    return mixed > 0 || httpPort > 0
                }()

                if listenersUp {
                    Logger.log("External core API + listeners ready on port \(port)")
                    ready(true)
                } else if retriesLeft > 0 {
                    Logger.log("Waiting for external core listeners (\(retriesLeft) retries left)...", level: .debug)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.waitForExternalCore(port: port, secret: secret, retriesLeft: retriesLeft - 1, ready: ready)
                    }
                } else {
                    Logger.log("External core listeners not ready after all retries", level: .error)
                    ready(false)
                }
            }
        }.resume()
    }

    private func disableEnhancedMode(completion: @escaping (String?) -> Void) {
        let group = DispatchGroup()

        group.enter()
        restoreDNSAfterTun {
            group.leave()
        }

        if let helper = PrivilegedHelperManager.shared.helper() {
            group.enter()
            helper.stopMihomoCore { _ in
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            clashPauseCallbacks()
            ConfigManager.shared.isEnhancedModeActive = false
            ConfigManager.shared.isRunning = false
            self?.refreshStatusItemViewStatus()
            clashReopenCacheDB()
            self?.startProxy()
            guard ConfigManager.shared.isRunning else {
                clashResumeCallbacks()
                completion(NSLocalizedString("Failed to restart built-in core", comment: ""))
                return
            }
            let selectedConfig = ConfigManager.selectConfigName
            self?.requestConfigUpdateApplyingRuntimePatch(configName: selectedConfig) { [weak self] error in
                clashResumeCallbacks()
                if error == nil {
                    self?.selectProxyGroupWithMemory()
                }
                completion(error)
            }
        }
    }

    private func verifyTunStatus(port: String, secret: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.checkTunInterface()
            self.queryTunFromApi(port: port, secret: secret)
        }
    }

    private func checkTunInterface() {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return }
        defer { freeifaddrs(ifaddrPtr) }

        var tunInterfaces: [(name: String, hasIPv4: Bool, ipv4: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            let name = String(cString: addr.pointee.ifa_name)
            if name.hasPrefix("utun") {
                let family = addr.pointee.ifa_addr.pointee.sa_family
                if family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr.pointee.ifa_addr, socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if let existing = tunInterfaces.firstIndex(where: { $0.name == name }) {
                        tunInterfaces[existing] = (name, true, ip)
                    } else {
                        tunInterfaces.append((name, true, ip))
                    }
                } else if !tunInterfaces.contains(where: { $0.name == name }) {
                    tunInterfaces.append((name, false, ""))
                }
            }
            ptr = addr.pointee.ifa_next
        }

        for iface in tunInterfaces {
            if iface.hasIPv4 {
                Logger.log("TUN interface \(iface.name) has IPv4: \(iface.ipv4)")
            } else {
                Logger.log("TUN interface \(iface.name) has NO IPv4", level: .warning)
            }
        }

        let mihomoTun = tunInterfaces.first(where: { $0.hasIPv4 && $0.ipv4.hasPrefix("198.18.") })
        if mihomoTun == nil {
            let logPath = kConfigFolderPath + ".mihomo_core.log"
            let coreLog = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            let tunError = coreLog.components(separatedBy: "\n")
                .first(where: { $0.contains("Start TUN") || $0.contains("operation not permitted") })
                ?? "Check Console.app for [mihomo_core] logs"
            Logger.log("TUN failed. Core log: \(tunError)", level: .error)
            NSUserNotificationCenter.default
                .post(title: NSLocalizedString("Enhanced Mode", comment: ""),
                      info: "TUN: \(tunError)")
        } else {
            Logger.log("TUN verified: \(mihomoTun!.name) @ \(mihomoTun!.ipv4)")
        }
    }

    private func queryTunFromApi(port: String, secret: String) {
        let url = URL(string: "http://127.0.0.1:\(port)/configs")!
        var request = URLRequest(url: url, timeoutInterval: 3)
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tun = json["tun"] as? [String: Any] else { return }

            let tunEnabled = tun["enable"] as? Bool ?? false
            let device = tun["device"] as? String ?? "unknown"
            let stack = tun["stack"] as? String ?? "unknown"
            Logger.log("API TUN status: enable=\(tunEnabled), device=\(device), stack=\(stack)")
        }.resume()
    }

    private func overrideDNSForTun() {
        guard let helper = PrivilegedHelperManager.shared.helper() else { return }
        helper.getCurrentDNSSetting { [weak self] info in
            guard let self = self else { return }
            if let dns = info as? [String: Any], !dns.isEmpty {
                if Self.isTunDNSOnly(dns) {
                    Logger.log("Skip saving TUN DNS as original DNS", level: .warning)
                } else {
                    self.savedDNSInfo = dns
                }
            }
            helper.overrideDNS(withServers: [Self.tunDNSServer],
                               filterInterface: Settings.filterInterface) { _ in
                helper.flushDNSCache { _ in
                    Logger.log("TUN DNS override: system DNS → \(Self.tunDNSServer)")
                }
            }
        }
    }

    private func restoreDNSAfterTun(completion: (() -> Void)? = nil) {
        guard let helper = PrivilegedHelperManager.shared.helper() else {
            completion?()
            return
        }
        let saved = savedDNSInfo
        let restoreInfo: [String: Any]
        if Self.isTunDNSOnly(saved) {
            Logger.log("Discarding polluted TUN DNS restore snapshot", level: .warning)
            restoreInfo = [:]
        } else {
            restoreInfo = saved
        }
        helper.restoreDNS(withSavedInfo: restoreInfo,
                          filterInterface: Settings.filterInterface) { [weak self] _ in
            self?.savedDNSInfo = [:]
            helper.flushDNSCache { _ in
                Logger.log("TUN DNS restored")
                completion?()
            }
        }
    }

    func cleanupEnhancedModeForTermination(completion: @escaping () -> Void) {
        guard ConfigManager.shared.isEnhancedModeActive else {
            completion()
            return
        }

        let group = DispatchGroup()
        group.enter()
        restoreDNSAfterTun {
            group.leave()
        }

        if let helper = PrivilegedHelperManager.shared.helper() {
            group.enter()
            helper.stopMihomoCore { _ in
                group.leave()
            }
        }

        group.notify(queue: .main) {
            ConfigManager.shared.isEnhancedModeActive = false
            Logger.log("Enhanced Mode cleanup finished")
            completion()
        }
    }

    private static func isTunDNSOnly(_ dnsInfo: [String: Any]) -> Bool {
        var foundDNSServer = false
        for value in dnsInfo.values {
            guard let settings = value as? [String: Any] else { continue }
            let servers = dnsServers(from: settings["ServerAddresses"])
            guard !servers.isEmpty else { continue }
            foundDNSServer = true
            if servers.contains(where: { $0 != tunDNSServer }) {
                return false
            }
        }
        return foundDNSServer
    }

    private static func dnsServers(from value: Any?) -> [String] {
        if let servers = value as? [String] {
            return servers
        }
        if let servers = value as? [Any] {
            return servers.compactMap { $0 as? String }
        }
        return []
    }

    private func cleanupStaleMihomoCoreOnLaunch() {
        guard Settings.enhancedMode else { return }
        Logger.log("Cleanup stale mihomo_core from previous session", level: .info)
        guard let binaryPath = Bundle.main.path(forResource: "mihomo_core", ofType: nil) else { return }
        let semaphore = DispatchSemaphore(value: 0)
        guard let helper = PrivilegedHelperManager.shared.helper(failture: {
            semaphore.signal()
        }) else { return }

        helper.cleanupMihomoCore(
            withBinaryPath: binaryPath,
            configPath: kConfigFolderPath + ".enhanced_config.yaml",
            homeDir: kConfigFolderPath
        ) { error in
            if let error = error {
                Logger.log("Stale mihomo_core cleanup failed: \(error)", level: .warning)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3.0)
    }

    private func restoreEnhancedModeIfNeeded() {
        guard Settings.enhancedMode else { return }
        restoreEnhancedMode(attemptsLeft: Self.enhancedModeRestoreMaxAttempts)
    }

    private func restoreEnhancedMode(attemptsLeft: Int) {
        guard Settings.enhancedMode else { return }

        let retryOrFail: (String) -> Void = { [weak self] error in
            guard let self = self else { return }

            if attemptsLeft > 1, Settings.enhancedMode {
                Logger.log("Failed to restore Enhanced Mode: \(error). Retrying in \(Self.enhancedModeRestoreRetryDelay)s (\(attemptsLeft - 1) left)", level: .warning)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.enhancedModeRestoreRetryDelay) { [weak self] in
                    self?.restoreEnhancedMode(attemptsLeft: attemptsLeft - 1)
                }
                return
            }

            self.finishFailedEnhancedModeRestore(error: error)
        }

        guard ConfigManager.shared.isRunning else {
            retryOrFail(NSLocalizedString("Failed to restart built-in core", comment: ""))
            return
        }

        guard PrivilegedHelperManager.shared.isHelperCheckFinished.value else {
            retryOrFail(NSLocalizedString("Helper not available", comment: ""))
            return
        }

        enhancedModeMenuItem.isEnabled = false
        enableEnhancedMode { [weak self] error in
            guard let self = self else { return }
            self.enhancedModeMenuItem.isEnabled = true
            if let error = error {
                retryOrFail(error)
            } else {
                self.enhancedModeMenuItem.state = .on
                Logger.log("Enhanced Mode restored successfully")
                self.scheduleEnhancedModePostToggleRefresh()
            }
        }
    }

    private func finishFailedEnhancedModeRestore(error: String) {
        Settings.enhancedMode = false
        enhancedModeMenuItem.state = .off
        Logger.log("Failed to restore Enhanced Mode: \(error)", level: .error)
        scheduleEnhancedModePostToggleRefresh()
    }

    @IBAction func actionAllowFromLan(_ sender: NSMenuItem) {
        ApiRequest.updateAllowLan(allow: !ConfigManager.allowConnectFromLan) {
            [weak self] in
            guard let self = self else { return }
            self.syncConfig()
            ConfigManager.allowConnectFromLan = !ConfigManager.allowConnectFromLan
        }
    }

    @IBAction func actionStartAtLogin(_ sender: NSMenuItem) {
        LaunchAtLogin.shared.isEnabled = !LaunchAtLogin.shared.isEnabled
    }

    @IBAction func actionSwitchProxyMode(_ sender: NSMenuItem) {
        let mode: ClashProxyMode
        switch sender {
        case proxyModeGlobalMenuItem:
            mode = .global
        case proxyModeDirectMenuItem:
            mode = .direct
        case proxyModeRuleMenuItem:
            mode = .rule
        default:
            return
        }
        switchProxyMode(mode: mode)
    }

    func switchProxyMode(mode: ClashProxyMode) {
        let config = ConfigManager.shared.currentConfig?.copy()
        config?.mode = mode
        ApiRequest.updateOutBoundMode(mode: mode) { _ in
            ConfigManager.shared.currentConfig = config
            ConfigManager.selectOutBoundMode = mode
            MenuItemFactory.recreateProxyMenuItems()
        }
    }

    @IBAction func actionShowNetSpeedIndicator(_ sender: NSMenuItem) {
        ConfigManager.shared.showNetSpeedIndicator = !(sender.state == .on)
    }

    @IBAction func actionSetSystemProxy(_ sender: Any?) {
        var canSaveProxy = true
        if ConfigManager.shared.proxyPortAutoSet && ConfigManager.shared.proxyShouldPaused.value {
            ConfigManager.shared.proxyPortAutoSet = false
        } else if ConfigManager.shared.isProxySetByOtherVariable.value {
            // should reset proxy to clashx
            ConfigManager.shared.isProxySetByOtherVariable.accept(false)
            ConfigManager.shared.proxyPortAutoSet = true
            // clear then reset.
            canSaveProxy = false
            SystemProxyManager.shared.disableProxy(port: 0, socksPort: 0, forceDisable: true)
        } else {
            ConfigManager.shared.proxyPortAutoSet = !ConfigManager.shared.proxyPortAutoSet
        }

        if ConfigManager.shared.proxyPortAutoSet {
            if canSaveProxy {
                SystemProxyManager.shared.saveProxy()
            }
            SystemProxyManager.shared.enableProxy()
        } else {
            SystemProxyManager.shared.disableProxy()
        }
    }

    @IBAction func actionCopyExportCommand(_ sender: NSMenuItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let port = ConfigManager.shared.currentConfig?.usedHttpPort ?? 0
        let socksport = ConfigManager.shared.currentConfig?.usedSocksPort ?? 0
        let localhost = "127.0.0.1"
        let isLocalhostCopy = sender == copyExportCommandMenuItem
        let ip = isLocalhostCopy ? localhost :
            NetworkChangeNotifier.getPrimaryIPAddress() ?? localhost
        pasteboard.setString("export https_proxy=http://\(ip):\(port) http_proxy=http://\(ip):\(port) all_proxy=socks5://\(ip):\(socksport)", forType: .string)
    }

    @IBAction func actionSpeedTest(_ sender: Any) {
        runSpeedTest(
            benchmarkURL: Settings.benchMarkUrl,
            timeout: 5000,
            showNotifications: true,
            rememberForNextLaunch: true
        )
    }

    private func restoreLastSpeedTestIfNeeded() {
        guard !didRestoreLastSpeedTest else { return }
        didRestoreLastSpeedTest = true

        guard Settings.lastDelayBenchmarkConfig == ConfigManager.selectConfigName,
              !Settings.lastDelayBenchmarkURL.isEmpty else {
            return
        }

        let benchmarkURL = Settings.lastDelayBenchmarkURL
        let timeout = max(Settings.lastDelayBenchmarkTimeout, 1000)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.automaticSpeedTestDelay) { [weak self] in
            guard Settings.lastDelayBenchmarkConfig == ConfigManager.selectConfigName else { return }
            self?.runSpeedTest(
                benchmarkURL: benchmarkURL,
                timeout: timeout,
                showNotifications: false,
                rememberForNextLaunch: false
            )
        }
    }

    private func runSpeedTest(benchmarkURL: String,
                              timeout: Int,
                              showNotifications: Bool,
                              rememberForNextLaunch: Bool) {
        if isSpeedTesting {
            if showNotifications {
                NSUserNotificationCenter.default.postSpeedTestingNotice()
            }
            return
        }
        if showNotifications {
            NSUserNotificationCenter.default.postSpeedTestBeginNotice()
        }

        if rememberForNextLaunch {
            Settings.lastDelayBenchmarkConfig = ConfigManager.selectConfigName
            Settings.lastDelayBenchmarkURL = benchmarkURL
            Settings.lastDelayBenchmarkTimeout = timeout
        }

        isSpeedTesting = true

        ApiRequest.getMergedProxyData { [weak self] resp in
            guard let self = self else { return }
            guard let resp = resp else {
                self.finishSpeedTest(showNotifications: showNotifications)
                return
            }

            let group = DispatchGroup()

            for (name, _) in resp.enclosingProviderResp?.providers ?? [:] {
                group.enter()
                ApiRequest.healthCheck(proxy: name) {
                    group.leave()
                }
            }

            for p in resp.proxiesMap["GLOBAL"]?.all ?? [] {
                group.enter()
                ApiRequest.getProxyDelay(proxyName: p, benchmarkURL: benchmarkURL, timeout: timeout) { _ in
                    group.leave()
                }
            }
            group.notify(queue: DispatchQueue.main) {
                self.finishSpeedTest(showNotifications: showNotifications)
            }
        }
    }

    private func finishSpeedTest(showNotifications: Bool) {
        isSpeedTesting = false
        MenuItemFactory.refreshExistingMenuItems()
        if showNotifications {
            NSUserNotificationCenter.default.postSpeedTestFinishNotice()
        }
    }

    @IBAction func actionUpdateExternalResource(_ sender: Any) {
        UpdateExternalResourceAction.run()
    }

    @IBAction func actionQuit(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }

    @IBAction func actionRestart(_ sender: Any) {
        restartApp()
    }

    @IBAction func actionMoreSetting(_ sender: Any) {
        DispatchQueue.main.async {
            ClashWindowController<SettingsSidebarViewController>.create().showWindow(sender)
        }
    }

    // MARK: - Language

    private static let supportedLanguages: [(code: String, nativeName: String)] = [
        ("", NSLocalizedString("Follow System", comment: "")),
        ("en", "English"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("ja", "日本語"),
        ("ru", "Русский")
    ]

    func setupLanguageMenu() {
        let langItem = NSMenuItem()
        langItem.title = NSLocalizedString("Language", comment: "")

        let submenu = NSMenu()
        for lang in Self.supportedLanguages {
            let item = NSMenuItem(
                title: lang.nativeName,
                action: #selector(actionSelectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lang.code
            item.state = Settings.appLanguage == lang.code ? .on : .off
            submenu.addItem(item)
            if lang.code.isEmpty {
                submenu.addItem(.separator())
            }
        }
        langItem.submenu = submenu

        if let settingsIndex = statusMenu.items.firstIndex(where: { $0.action == #selector(actionMoreSetting(_:)) }) {
            statusMenu.insertItem(langItem, at: settingsIndex + 1)
            langMenuItem = langItem
        }
    }

    @objc func actionSelectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String,
              code != Settings.appLanguage else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Language", comment: "")
        alert.informativeText = NSLocalizedString("Language change requires restart", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Restart Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            Settings.appLanguage = code
            if code.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([code], forKey: "AppleLanguages")
            }
            UserDefaults.standard.synchronize()
            restartApp()
        }
    }

    private func restartApp() {
        guard !isRestarting else { return }
        isRestarting = true
        let path = Bundle.main.bundlePath

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }

        let launchAndExit: () -> Void = {
            let terminate = {
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
            if #available(macOS 10.15, *) {
                let url = URL(fileURLWithPath: path)
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                    if let error = error {
                        Logger.log("ClashFX restart: openApplication failed: \(error.localizedDescription)", level: .error)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: terminate)
                }
            } else {
                let task = Process()
                task.launchPath = "/bin/sh"
                task.arguments = ["-c", "sleep 0.5 && open \"\(path)\""]
                task.launch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: terminate)
            }
        }

        if ConfigManager.shared.isEnhancedModeActive {
            Logger.log("ClashFX restart: cleaning Enhanced Mode before relaunch")
            cleanupEnhancedModeForTermination {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: launchAndExit)
            }
        } else {
            launchAndExit()
        }
    }
}

// MARK: Streaming Info

extension AppDelegate: ApiRequestStreamDelegate {
    func didUpdateTraffic(up: Int, down: Int) {
        statusItemView.updateSpeedLabel(up: up, down: down)
    }

    func didGetLog(log: String, level: String) {
        Logger.log(log, level: ClashLogLevel(rawValue: level) ?? .unknow)
    }
}

// MARK: Help actions

extension AppDelegate {
    @IBAction func actionShowLog(_ sender: Any?) {
        NSWorkspace.shared.openFile(Logger.shared.logFilePath())
    }
}

// MARK: Config actions

extension AppDelegate {
    func setupConfigEditorMenuItem() {
        guard let configMenu = configSeparatorLine.menu else { return }
        let editorItem = NSMenuItem(
            title: NSLocalizedString("Config Editor", comment: ""),
            action: #selector(actionOpenConfigEditor(_:)),
            keyEquivalent: "e"
        )
        editorItem.target = self
        if let separatorIndex = configMenu.items.firstIndex(of: configSeparatorLine) {
            configMenu.insertItem(editorItem, at: separatorIndex + 1)
            configEditorMenuItem = editorItem
        }
    }

    func setupProfileMixinMenuItem() {
        guard let configMenu = configSeparatorLine.menu else { return }
        let item = NSMenuItem(
            title: NSLocalizedString("Profile Mixin", comment: ""),
            action: #selector(actionOpenProfileMixinEditor(_:)),
            keyEquivalent: ""
        )
        item.target = self
        if let editorItem = configEditorMenuItem,
           let editorIndex = configMenu.items.firstIndex(of: editorItem) {
            configMenu.insertItem(item, at: editorIndex + 1)
        } else if let separatorIndex = configMenu.items.firstIndex(of: configSeparatorLine) {
            configMenu.insertItem(item, at: separatorIndex + 1)
        }
        profileMixinMenuItem = item
    }

    @objc func actionOpenConfigEditor(_ sender: Any) {
        ConfigEditorWindowController.show()
    }

    @objc func actionOpenProfileMixinEditor(_ sender: Any) {
        if !FileManager.default.fileExists(atPath: Paths.profileMixinPath) {
            let template = """
            # Profile Mixin is merged into the selected profile at runtime.
            # Example:
            # proxy-groups:
            #   - name: Auto 1x
            #     type: url-test
            #     use:
            #       - ProviderName
            #
            # Rules can be inserted before or after the selected profile's rules:
            # profile:
            #   prepend-rules:
            #     - "DOMAIN-SUFFIX,example.com,DIRECT"
            #   append-rules:
            #     - "MATCH,Proxy"
            #
            # PROCESS-NAME and PROCESS-PATH rules require Enhanced Mode (TUN).

            """
            try? template.write(toFile: Paths.profileMixinPath, atomically: true, encoding: .utf8)
        }
        ConfigEditorWindowController.show(configPath: Paths.profileMixinPath)
    }

    @IBAction func openConfigFolder(_ sender: Any) {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getUrl {
                url in
                if let url = url {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            NSWorkspace.shared.openFile(kConfigFolderPath)
        }
    }

    @IBAction func actionUpdateConfig(_ sender: AnyObject) {
        updateConfig()
    }

    @IBAction func actionSetLogLevel(_ sender: NSMenuItem) {
        let level = ClashLogLevel(rawValue: sender.title.lowercased()) ?? .unknow
        ConfigManager.selectLoggingApiLevel = level
        dynamicLogLevel = level.toDDLogLevel()
        updateLoggingLevel()
        resetStreamApi()
    }

    @IBAction func actionAutoUpdateRemoteConfig(_ sender: Any) {
        RemoteConfigManager.autoUpdateEnable = !RemoteConfigManager.autoUpdateEnable
        remoteConfigAutoupdateMenuItem.state = RemoteConfigManager.autoUpdateEnable ? .on : .off
    }

    @IBAction func actionUpdateRemoteConfig(_ sender: Any) {
        RemoteConfigManager.shared.updateCheck(ignoreTimeLimit: true, showNotification: true)
    }

    @IBAction func actionSetUpdateInterval(_ sender: Any) {
        RemoteConfigManager.showAdd()
    }
}

// MARK: crash hanlder

extension AppDelegate {
    func registCrashLogger() {
        #if DEBUG
            return
        #else
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                AppCenter.start(withAppSecret: "dce6e9a3-b6e3-4fd2-9f2d-35c767a99663", services: [
                    Analytics.self,
                    Crashes.self
                ])
            }

        #endif
    }

    func failLaunchProtect() {
        #if DEBUG
            return
        #else
            UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": false])
            let x = UserDefaults.standard
            var launch_fail_times = 0
            if let xx = x.object(forKey: "launch_fail_times") as? Int { launch_fail_times = xx }
            launch_fail_times += 1
            x.set(launch_fail_times, forKey: "launch_fail_times")
            if launch_fail_times > 3 {
                // 发生连续崩溃
                ConfigFileManager.backupAndRemoveConfigFile()
                try? FileManager.default.removeItem(atPath: kConfigFolderPath + "Country.mmdb")
                if let domain = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: domain)
                    UserDefaults.standard.synchronize()
                }
                NSUserNotificationCenter.default.post(title: "Fail on launch protect", info: "You origin Config has been renamed", notiOnly: false)
            }
            DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + Double(Int64(5 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                x.set(0, forKey: "launch_fail_times")
            }
        #endif
    }
}

// MARK: Memory

extension AppDelegate {
    func selectProxyGroupWithMemory() {
        let copy = [SavedProxyModel](ConfigManager.selectedProxyRecords)
        let records = copy.filter { $0.config == ConfigManager.selectConfigName }
        guard !records.isEmpty else { return }

        let group = DispatchGroup()
        var didRestoreProxySelection = false
        for item in records {
            Logger.log("Auto selecting \(item.group) \(item.selected)", level: .debug)
            group.enter()
            ApiRequest.updateProxyGroup(group: item.group, selectProxy: item.selected) { success in
                if success {
                    didRestoreProxySelection = true
                } else {
                    Logger.log("Failed to restore proxy selection: \(item.group) -> \(item.selected), keeping record for next retry", level: .warning)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if didRestoreProxySelection {
                ConnectionManager.closeAllConnection()
            }
        }
    }

    func removeUnExistProxyGroups() {
        let action: (([String]) -> Void) = { list in
            let unexists = ConfigManager.selectedProxyRecords.filter {
                !list.contains($0.config)
            }
            ConfigManager.selectedProxyRecords.removeAll {
                unexists.contains($0)
            }
        }

        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getConfigFilesList { list in
                action(list)
            }
        } else {
            let list = ConfigManager.getConfigFilesList()
            action(list)
        }
    }

    func selectOutBoundModeWithMenory() {
        restoreSelectedOutboundModeAfterCoreChange()
    }

    private func restoreSelectedOutboundModeAfterCoreChange(completion: (() -> Void)? = nil) {
        let mode = ConfigManager.selectOutBoundMode
        ApiRequest.updateOutBoundMode(mode: mode) { [weak self] success in
            if success {
                Logger.log("Restored outbound mode after core change: \(mode.rawValue)")
                ConnectionManager.closeAllConnection()
                self?.syncConfig()
            } else {
                Logger.log("Failed to restore outbound mode after core change: \(mode.rawValue)", level: .warning)
            }
            completion?()
        }
    }

    func selectAllowLanWithMenory() {
        ApiRequest.updateAllowLan(allow: ConfigManager.allowConnectFromLan) {
            [weak self] in
            self?.syncConfig()
        }
    }

    func hasMenuSelected() -> Bool {
        if #available(macOS 11, *) {
            return statusMenu.items.contains { $0.state == .on }
        } else {
            return true
        }
    }
}

// MARK: NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        ensureMenuTargets(in: menu)
        MenuItemFactory.refreshExistingMenuItems()
        updateConfigFiles()
        refreshSubscriptionStatusMenuItem()
        syncConfig()
        NotificationCenter.default.post(name: .proxyMeneViewShowLeftPadding,
                                        object: nil,
                                        userInfo: ["show": hasMenuSelected()])
    }

    private func ensureMenuTargets(in menu: NSMenu) {
        for item in menu.items {
            if item.action != nil, item.target == nil {
                item.target = self
            }
            if let submenu = item.submenu {
                ensureMenuTargets(in: submenu)
            }
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for element in menu.items {
            (element.view as? ProxyGroupMenuHighlightDelegate)?.highlight(item: item)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        for element in menu.items {
            (element.view as? ProxyGroupMenuHighlightDelegate)?.highlight(item: nil)
        }
    }
}

// MARK: NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }

        // Bypass Common Chinese Apps relies on PROCESS-NAME rules,
        // which only resolve under Enhanced Mode (TUN). In Rule mode
        // mihomo cannot see the originating process, so the toggle is
        // a no-op there. Disable it and surface the reason via tooltip.
        if action == #selector(actionToggleBypassChineseApps(_:)) {
            return Settings.enhancedMode
        }

        // When an External Control instance is selected, local-only
        // actions don't apply to the remote core.
        if RemoteControlManager.selectConfig != nil {
            let disabledInRemoteMode: Set<Selector> = [
                #selector(actionSetSystemProxy(_:)),
                #selector(actionTurnOffAllProxyModes(_:)),
                #selector(actionCopyExportCommand(_:))
            ]
            if disabledInRemoteMode.contains(action) {
                return false
            }
        }

        if action == #selector(actionTurnOffAllProxyModes(_:)) {
            return ConfigManager.shared.proxyPortAutoSet || Settings.enhancedMode || ConfigManager.shared.isEnhancedModeActive
        }

        return true
    }
}

// MARK: URL Scheme

extension AppDelegate {
    @objc func handleURL(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            return
        }

        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              scheme.hasPrefix("clash"),
              let host = components.host
        else { return }

        if host == "install-config" {
            guard let url = components.queryItems?.first(where: { item in
                item.name == "url"
            })?.value else { return }

            var userInfo = ["url": url]
            if let name = components.queryItems?.first(where: { item in
                item.name == "name"
            })?.value {
                userInfo["name"] = name
            }

            remoteConfigAutoupdateMenuItem.menu?.performActionForItem(at: 0)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: Notification.Name(rawValue: "didGetUrl"), object: nil, userInfo: userInfo)
            }
        } else if host == "update-config" {
            updateConfig()
        }
    }
}

// MARK: Tray Menu Visibility

extension AppDelegate {
    @objc func onTrayMenuSettingsChanged() {
        applyTrayMenuVisibility()
    }

    /// Hides or shows dynamic config-switch items and the separator that follows them.
    private func applyConfigSwitcherVisibility(showConfigSwitcher: Bool) {
        guard let menu = configSeparatorLine.menu,
              let lineIndex = menu.items.firstIndex(of: configSeparatorLine) else { return }
        for i in 0 ..< lineIndex {
            menu.items[i].isHidden = !showConfigSwitcher
        }
        configSeparatorLine.isHidden = !showConfigSwitcher || lineIndex == 0
    }

    func applyTrayMenuVisibility() {
        // Proxy Mode (single item)
        proxyModeMenuItem.isHidden = !Settings.trayMenuShowProxyMode

        // Node Switch: hide/show proxy group items that sit between the two separators
        let nodeHidden = !Settings.trayMenuShowNodeSwitch
        if let topIdx = statusMenu.items.firstIndex(of: separatorLineTop),
           let endIdx = statusMenu.items.firstIndex(of: sepatatorLineEndProxySelect) {
            let hasItems = endIdx > topIdx + 1
            for i in (topIdx + 1) ..< endIdx {
                statusMenu.items[i].isHidden = nodeHidden
            }
            sepatatorLineEndProxySelect.isHidden = !hasItems || nodeHidden
        }

        // Proxy Actions group
        let showProxyActions = Settings.trayMenuShowProxyActions
        turnOffProxyMenuItem?.isHidden = !(showProxyActions && Settings.trayMenuShowTurnOffProxy)
        proxySettingMenuItem.isHidden = !(showProxyActions && Settings.trayMenuShowSystemProxy)
        enhancedModeMenuItem.isHidden = !(showProxyActions && Settings.trayMenuShowEnhancedMode)
        advancedTunMenuItem?.isHidden = !(showProxyActions && Settings.trayMenuShowAdvancedTun)
        bypassChineseAppsMenuItem?.isHidden = !(showProxyActions && Settings.trayMenuShowBypassChineseApps)
        let showCopy = showProxyActions && Settings.trayMenuShowCopyShellCmd
        copyExportCommandMenuItem.isHidden = !showCopy
        copyExportCommandExternalMenuItem.isHidden = !showCopy
        let anyProxyAction = showProxyActions && (Settings.trayMenuShowTurnOffProxy || Settings.trayMenuShowSystemProxy || Settings.trayMenuShowEnhancedMode || Settings.trayMenuShowAdvancedTun || Settings.trayMenuShowBypassChineseApps || Settings.trayMenuShowCopyShellCmd)
        proxyActionsSeparator.isHidden = !anyProxyAction

        // General Settings group
        let showGeneral = Settings.trayMenuShowGeneralSettings
        autoStartMenuItem.isHidden = !(showGeneral && Settings.trayMenuShowStartAtLogin)
        showNetSpeedIndicatorMenuItem.isHidden = !(showGeneral && Settings.trayMenuShowNetSpeed)
        allowFromLanMenuItem.isHidden = !(showGeneral && Settings.trayMenuShowAllowLan)
        let anyGeneral = showGeneral && (Settings.trayMenuShowStartAtLogin || Settings.trayMenuShowNetSpeed || Settings.trayMenuShowAllowLan)
        generalSettingsSeparator.isHidden = !anyGeneral

        // Tools group
        let showTools = Settings.trayMenuShowTools
        benchmarkMenuItem.isHidden = !(showTools && Settings.trayMenuShowBenchmark)
        if #available(macOS 10.15, *) {
            dashboardMenuItem.isHidden = !(showTools && Settings.trayMenuShowDashboard)
            connectionsMenuItem.isHidden = !(showTools && Settings.trayMenuShowConnections)
            let anyTools = showTools && (Settings.trayMenuShowBenchmark || Settings.trayMenuShowDashboard || Settings.trayMenuShowConnections)
            toolsSeparator.isHidden = !anyTools
        } else {
            toolsSeparator.isHidden = !(showTools && Settings.trayMenuShowBenchmark)
        }

        // Configs group
        let showConfigs = Settings.trayMenuShowConfigs
        let anyConfigChild = Settings.trayMenuShowConfigSwitcher
            || Settings.trayMenuShowConfigEditor
            || Settings.trayMenuShowProfileMixin
            || Settings.trayMenuShowOpenConfigFolder
            || Settings.trayMenuShowReloadConfig
            || Settings.trayMenuShowUpdateExternal
            || Settings.trayMenuShowRemoteConfig
            || Settings.trayMenuShowRemoteController
        configsMenuItem.isHidden = !(showConfigs && anyConfigChild)
        configEditorMenuItem?.isHidden = !(showConfigs && Settings.trayMenuShowConfigEditor)
        profileMixinMenuItem?.isHidden = !(showConfigs && Settings.trayMenuShowProfileMixin)
        openConfigFolderMenuItem.isHidden = !(showConfigs && Settings.trayMenuShowOpenConfigFolder)
        reloadConfigMenuItem.isHidden = !(showConfigs && Settings.trayMenuShowReloadConfig)
        updateExternalResourceMenuItem.isHidden = !(showConfigs && Settings.trayMenuShowUpdateExternal)
        remoteConfigMenuItem.isHidden = !(showConfigs && Settings.trayMenuShowRemoteConfig)
        remoteControllerMenuItem.isHidden = !(showConfigs && Settings.trayMenuShowRemoteController)

        // Dynamic config switch items (at top of Configs submenu, before configSeparatorLine)
        applyConfigSwitcherVisibility(showConfigSwitcher: showConfigs && Settings.trayMenuShowConfigSwitcher)

        // Language (single item, added dynamically)
        langMenuItem?.isHidden = !Settings.trayMenuShowLanguage

        // Help group
        let showHelp = Settings.trayMenuShowHelp
        let feedbackVisible = showHelp && Settings.trayMenuShowFeedback && labFeedbackMenuItem != nil
        let copyDiagVisible = showHelp && Settings.trayMenuShowCopyDiagnostic && labCopyDiagMenuItem != nil
        let crashLogsVisible = showHelp && Settings.trayMenuShowCrashLogs && labCrashLogsMenuItem != nil
        let rollbackVisible = showHelp && Settings.trayMenuShowRollback && labRollbackMenuItem != nil
        let anyLabHelpChild = feedbackVisible || copyDiagVisible || crashLogsVisible || rollbackVisible
        let anyHelpChild = Settings.trayMenuShowAbout || Settings.trayMenuShowCheckUpdate || Settings.trayMenuShowLogLevel || Settings.trayMenuShowShowLog || Settings.trayMenuShowPorts || anyLabHelpChild
        helpMenuItem.isHidden = !(showHelp && anyHelpChild)
        aboutMenuItem.isHidden = !(showHelp && Settings.trayMenuShowAbout)
        checkForUpdateMenuItem.isHidden = !(showHelp && Settings.trayMenuShowCheckUpdate)
        logLevelMenuItem.isHidden = !(showHelp && Settings.trayMenuShowLogLevel)
        showLogMenuItem.isHidden = !(showHelp && Settings.trayMenuShowShowLog)
        portsMenuItem.isHidden = !(showHelp && Settings.trayMenuShowPorts)
        labFeedbackMenuItem?.isHidden = !feedbackVisible
        labCopyDiagMenuItem?.isHidden = !copyDiagVisible
        labCrashLogsMenuItem?.isHidden = !crashLogsVisible
        labRollbackMenuItem?.isHidden = !rollbackVisible
        labHelpSeparator?.isHidden = !anyLabHelpChild
    }
}

//
//  GeneralSettingViewController.swift
//  ClashX Pro
//
//  Created by yicheng on 2022/11/20.
//  Copyright © 2022 west2online. All rights reserved.
//

import Cocoa
import RxSwift

class GeneralSettingViewController: NSViewController {
    @IBOutlet var ignoreListTextView: NSTextView!
    @IBOutlet var tunRouteExcludeTextView: NSTextView!
    @IBOutlet var launchAtLoginButton: NSButton!

    @IBOutlet var reduceNotificationsButton: NSButton!
    @IBOutlet var useiCloudButton: NSButton!
    @IBOutlet var applicationSettingsStack: NSStackView!

    @IBOutlet var allowApiLanUsageSwitcher: NSButton!
    @IBOutlet var proxyPortTextField: NSTextField!
    @IBOutlet var apiPortTextField: NSTextField!
    @IBOutlet var ssidSuspendTextField: NSTextView!

    @IBOutlet var apiSecretTextField: NSTextField!

    @IBOutlet var apiSecretOverrideButton: NSButton!

    @IBOutlet var ipv6Button: NSButton!
    @IBOutlet var speedTestUrlField: NSTextField!

    var disposeBag = DisposeBag()
    override func viewDidLoad() {
        super.viewDidLoad()
        installDockIconToggle()
        speedTestUrlField.stringValue = Settings.benchMarkUrl
        speedTestUrlField.placeholderString = Settings.defaultBenchmarkUrl
        ignoreListTextView.string = Settings.proxyIgnoreList.joined(separator: ",")
        let tunRouteExcludes = Settings.normalizeAndPersistTunRouteExcludeList()
        tunRouteExcludeTextView.string = Settings.tunRouteExcludeRawText.isEmpty
            ? tunRouteExcludes.joined(separator: ",\n")
            : Settings.tunRouteExcludeRawText
        ignoreListTextView.rx
            .string.debounce(.milliseconds(500), scheduler: MainScheduler.instance)
            .map { $0.components(separatedBy: ",").filter { !$0.isEmpty } }
            .subscribe { arr in
                Settings.proxyIgnoreList = arr
            }.disposed(by: disposeBag)

        tunRouteExcludeTextView.rx
            .string.debounce(.milliseconds(500), scheduler: MainScheduler.instance)
            .subscribe { text in
                Settings.tunRouteExcludeRawText = text
                let arr = text
                    .components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let normalized = Settings.normalizeTunRouteExcludeEntries(arr)
                if normalized != arr {
                    Settings.tunRouteExcludeRawText = normalized.joined(separator: ",\n")
                }
                Settings.tunRouteExcludeList = normalized
            }.disposed(by: disposeBag)

        ssidSuspendTextField.string = Settings.disableSSIDList.joined(separator: ",")
        ssidSuspendTextField.rx
            .string.debounce(.milliseconds(500), scheduler: MainScheduler.instance)
            .map { $0.components(separatedBy: ",").filter { !$0.isEmpty } }
            .subscribe { arr in
                Settings.disableSSIDList = arr
                SSIDSuspendTool.shared.update()
            }.disposed(by: disposeBag)

        LaunchAtLogin.shared.isEnableVirable
            .map { $0 ? .on : .off }
            .bind(to: launchAtLoginButton.rx.state)
            .disposed(by: disposeBag)
        launchAtLoginButton.rx.state.map { $0 == .on }.subscribe {
            LaunchAtLogin.shared.isEnabled = $0
        }.disposed(by: disposeBag)

        ICloudManager.shared.userEnableiCloudRelay
            .map { $0 ? .on : .off }
            .bind(to: useiCloudButton.rx.state)
            .disposed(by: disposeBag)
        useiCloudButton.rx.state.map { $0 == .on }.subscribe {
            ICloudManager.shared.userEnableiCloud = $0
        }.disposed(by: disposeBag)
        reduceNotificationsButton.toolTip = NSLocalizedString("Reduce alerts if notification permission is disabled", comment: "")
        reduceNotificationsButton.state = Settings.disableNoti ? .on : .off
        reduceNotificationsButton.rx.state.map { $0 == .on }.subscribe {
            Settings.disableNoti = $0
        }.disposed(by: disposeBag)

        ipv6Button.state = Settings.enableIPV6 ? .on : .off
        ipv6Button.rx.state.map { $0 == .on }.subscribe {
            Settings.enableIPV6 = $0
        }.disposed(by: disposeBag)

        if Settings.proxyPort > 0 {
            proxyPortTextField.stringValue = "\(Settings.proxyPort)"
        } else {
            proxyPortTextField.stringValue = "\(ConfigManager.shared.currentConfig?.mixedPort ?? 0)"
        }
        if Settings.apiPort > 0 {
            apiPortTextField.stringValue = "\(Settings.apiPort)"
        } else {
            apiPortTextField.stringValue = ConfigManager.shared.apiPort
        }

        apiSecretTextField.stringValue = Settings.apiSecret
        apiSecretTextField.rx.text.compactMap { $0 }.bind {
            Settings.apiSecret = $0
        }.disposed(by: disposeBag)

        apiSecretOverrideButton.state = Settings.overrideConfigSecret ? .on : .off
        apiSecretOverrideButton.rx.state.bind { state in
            Settings.overrideConfigSecret = state == .on
        }.disposed(by: disposeBag)

        proxyPortTextField.rx.text
            .compactMap { $0 }
            .compactMap { Int($0) }
            .bind {
                Settings.proxyPort = $0
            }.disposed(by: disposeBag)

        apiPortTextField.rx.text
            .compactMap { $0 }
            .compactMap { Int($0) }
            .bind {
                Settings.apiPort = $0
            }.disposed(by: disposeBag)
        allowApiLanUsageSwitcher.state = Settings.apiPortAllowLan ? .on : .off
        allowApiLanUsageSwitcher.rx.state.bind { state in
            Settings.apiPortAllowLan = state == .on
        }.disposed(by: disposeBag)
    }

    private func installDockIconToggle() {
        let title = NSTextField(labelWithString: NSLocalizedString("Hide Dock Icon", comment: ""))
        title.font = .systemFont(ofSize: 13)

        let toggle: NSView
        if #available(macOS 10.15, *) {
            let dockSwitch = NSSwitch()
            dockSwitch.controlSize = .small
            dockSwitch.state = Settings.hideDockIcon ? .on : .off
            dockSwitch.target = self
            dockSwitch.action = #selector(toggleDockIconVisibility(_:))
            toggle = dockSwitch
        } else {
            let dockCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleDockIconVisibility(_:)))
            dockCheckbox.state = Settings.hideDockIcon ? .on : .off
            toggle = dockCheckbox
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [title, spacer, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8

        let hint = NSTextField(labelWithString: NSLocalizedString("When enabled, ClashFX is available only from the menu bar.", comment: ""))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let container = NSStackView(views: [row, hint])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        applicationSettingsStack.addArrangedSubview(container)
    }

    @objc private func toggleDockIconVisibility(_ sender: Any) {
        let isEnabled: Bool
        if #available(macOS 10.15, *), let dockSwitch = sender as? NSSwitch {
            isEnabled = dockSwitch.state == .on
        } else if let dockCheckbox = sender as? NSButton {
            isEnabled = dockCheckbox.state == .on
        } else {
            return
        }
        Settings.hideDockIcon = isEnabled
        DockIconVisibility.refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        let url = speedTestUrlField.stringValue
        if url.isUrlVaild() || url.isEmpty {
            Settings.benchMarkUrl = url
        }
        SSIDSuspendTool.shared.showNoticeOnNotPermission = true
        SSIDSuspendTool.shared.requestPermissionIfNeed()
        SSIDSuspendTool.shared.update()
    }

    @IBAction func actionResetIgnoreList(_ sender: Any) {
        ignoreListTextView.string = Settings.proxyIgnoreListDefaultValue.joined(separator: ",")
        Settings.proxyIgnoreList = Settings.proxyIgnoreListDefaultValue
    }

    @IBAction func actionResetTunRouteExcludeList(_ sender: Any) {
        tunRouteExcludeTextView.string = ""
        Settings.tunRouteExcludeRawText = ""
        Settings.tunRouteExcludeList = []
    }
}

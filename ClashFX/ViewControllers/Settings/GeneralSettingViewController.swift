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
    @IBOutlet var benchmarkURLSaveButton: NSButton!
    @IBOutlet var benchmarkModeSegmentedControl: NSSegmentedControl!
    @IBOutlet var benchmarkSortOrderPopUp: NSPopUpButton!
    @IBOutlet var benchmarkURLPresetPopUp: NSPopUpButton!
    @IBOutlet var benchmarkMeasurementMethodPopUp: NSPopUpButton!
    @IBOutlet var benchmarkModeLabel: NSTextField!
    @IBOutlet var benchmarkSortOrderLabel: NSTextField!
    @IBOutlet var benchmarkURLPresetLabel: NSTextField!
    @IBOutlet var benchmarkMeasurementMethodLabel: NSTextField!

    var disposeBag = DisposeBag()
    override func viewDidLoad() {
        super.viewDidLoad()
        installDockIconToggle()
        speedTestUrlField.stringValue = Settings.benchMarkUrl
        speedTestUrlField.placeholderString = Settings.defaultBenchmarkUrl
        benchmarkURLSaveButton.title = NSLocalizedString("Save", comment: "")
        configureBenchmarkSettingsControls()
        speedTestUrlField.rx.text
            .compactMap { $0 }
            .distinctUntilChanged()
            .subscribe(onNext: { [weak self] _ in
                self?.persistBenchmarkURL()
            })
            .disposed(by: disposeBag)
        ignoreListTextView.string = Settings.proxyIgnoreList.joined(separator: ",")
        let tunRouteExcludes = Settings.normalizeAndPersistTunRouteExcludeList()
        tunRouteExcludeTextView.string = Settings.tunRouteExcludeRawText.isEmpty
            ? tunRouteExcludes.joined(separator: ",\n")
            : Settings.tunRouteExcludeRawText
        ignoreListTextView.rx
            .string
            .skip(1)
            .debounce(.milliseconds(500), scheduler: MainScheduler.instance)
            .map {
                $0.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            .distinctUntilChanged()
            .subscribe { arr in
                Settings.proxyIgnoreList = arr
                AppDelegate.shared.applyProxyBypassSettings()
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
                SSIDSuspendTool.shared.requestPermissionIfNeed()
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
        useiCloudButton.rx.state.map { $0 == .on }.subscribe { enabled in
            guard ICloudManager.shared.setUserEnableiCloud(enabled) || !enabled else {
                NSAlert.alert(with: NSLocalizedString("iCloud not available", comment: ""))
                return
            }
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
            proxyPortTextField.stringValue = PortPreferencePolicy.editableText(
                configuredPort: Settings.proxyPort
            )
            let runtimePort = ConfigManager.shared.currentConfig?.mixedPort ?? 0
            proxyPortTextField.toolTip = PortPreferencePolicy.runtimeFallback(
                configuredPort: Settings.proxyPort,
                runtimePort: runtimePort
            ).map {
                String(
                    format: NSLocalizedString(
                        "Configured port: %d; temporary runtime fallback: %d",
                        comment: ""
                    ),
                    $0.configured,
                    $0.runtime
                )
            }
        } else {
            proxyPortTextField.stringValue = ""
            proxyPortTextField.placeholderString = String(
                format: NSLocalizedString("Auto (runtime: %@)", comment: ""),
                "\(ConfigManager.shared.currentConfig?.mixedPort ?? 0)"
            )
        }
        if Settings.apiPort > 0 {
            apiPortTextField.stringValue = PortPreferencePolicy.editableText(
                configuredPort: Settings.apiPort
            )
            let runtimePort = Int(ConfigManager.shared.apiPort) ?? 0
            apiPortTextField.toolTip = PortPreferencePolicy.runtimeFallback(
                configuredPort: Settings.apiPort,
                runtimePort: runtimePort
            ).map {
                String(
                    format: NSLocalizedString(
                        "Configured port: %d; temporary runtime fallback: %d",
                        comment: ""
                    ),
                    $0.configured,
                    $0.runtime
                )
            }
        } else {
            apiPortTextField.stringValue = ""
            apiPortTextField.placeholderString = String(
                format: NSLocalizedString("Auto (runtime: %@)", comment: ""),
                ConfigManager.shared.apiPort
            )
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
            .compactMap(PortPreferencePolicy.configuredPort(from:))
            .distinctUntilChanged()
            .bind {
                Settings.proxyPort = $0
            }.disposed(by: disposeBag)

        apiPortTextField.rx.text
            .compactMap { $0 }
            .compactMap(PortPreferencePolicy.configuredPort(from:))
            .distinctUntilChanged()
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

    private func configureBenchmarkSettingsControls() {
        benchmarkModeLabel.stringValue = NSLocalizedString("Benchmark Mode:", comment: "")
        benchmarkSortOrderLabel.stringValue = NSLocalizedString("Display Order:", comment: "")
        benchmarkURLPresetLabel.stringValue = NSLocalizedString("Benchmark Target:", comment: "")
        benchmarkMeasurementMethodLabel.stringValue = NSLocalizedString("Measurement Method:", comment: "")
        let benchmarkLabels: [NSTextField] = [
            benchmarkModeLabel,
            benchmarkSortOrderLabel,
            benchmarkURLPresetLabel,
            benchmarkMeasurementMethodLabel
        ]
        let labelColumnWidth = max(
            82,
            benchmarkLabels.map { $0.intrinsicContentSize.width + 4 }.max() ?? 82
        )
        for benchmarkLabel in benchmarkLabels {
            benchmarkLabel.widthAnchor.constraint(equalToConstant: labelColumnWidth).isActive = true
        }

        benchmarkModeSegmentedControl.setLabel(NSLocalizedString("Quick", comment: ""), forSegment: 0)
        benchmarkModeSegmentedControl.setLabel(NSLocalizedString("Complete", comment: ""), forSegment: 1)
        benchmarkModeSegmentedControl.selectedSegment = Settings.benchmarkMode == .quick ? 0 : 1
        benchmarkModeSegmentedControl.setAccessibilityLabel(benchmarkModeLabel.stringValue)

        benchmarkSortOrderPopUp.removeAllItems()
        for order in [BenchmarkSortOrder.configuration, .latency] {
            let title = order == .configuration
                ? NSLocalizedString("Configuration Order", comment: "")
                : NSLocalizedString("Latency First", comment: "")
            benchmarkSortOrderPopUp.addItem(withTitle: title)
            benchmarkSortOrderPopUp.item(at: benchmarkSortOrderPopUp.numberOfItems - 1)?.representedObject = order.rawValue
        }
        benchmarkSortOrderPopUp.selectItem(
            at: Settings.benchmarkSortOrder == .configuration ? 0 : 1
        )

        benchmarkURLPresetPopUp.removeAllItems()
        for title in [
            NSLocalizedString("Cloudflare HTTPS", comment: ""),
            NSLocalizedString("Google HTTPS", comment: ""),
            NSLocalizedString("Custom", comment: "")
        ] {
            benchmarkURLPresetPopUp.addItem(withTitle: title)
        }
        benchmarkURLPresetPopUp.selectItem(
            at: BenchmarkURLSettings.presetIndex(for: Settings.benchMarkUrl)
        )

        benchmarkMeasurementMethodPopUp.removeAllItems()
        let measurementMethods: [(BenchmarkMeasurementMethod, String)] = [
            (.followConfiguration, NSLocalizedString("Follow Configuration", comment: "")),
            (.unified, NSLocalizedString("Unified", comment: "")),
            (.connection, NSLocalizedString("Connection", comment: ""))
        ]
        for (method, title) in measurementMethods {
            benchmarkMeasurementMethodPopUp.addItem(withTitle: title)
            benchmarkMeasurementMethodPopUp.item(
                at: benchmarkMeasurementMethodPopUp.numberOfItems - 1
            )?.representedObject = method.rawValue
        }
        let selectedMethodIndex = measurementMethods.firstIndex {
            $0.0 == Settings.benchmarkMeasurementMethod
        } ?? 0
        benchmarkMeasurementMethodPopUp.selectItem(at: selectedMethodIndex)
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
        persistBenchmarkURL()
        SSIDSuspendTool.shared.showNoticeOnNotPermission = true
        SSIDSuspendTool.shared.requestPermissionIfNeed()
        SSIDSuspendTool.shared.update()
    }

    @IBAction func actionSaveBenchmarkURL(_: Any) {
        guard persistBenchmarkURL() else {
            NSSound.beep()
            return
        }
        speedTestUrlField.stringValue = Settings.benchMarkUrl
        view.window?.makeFirstResponder(nil)
    }

    @IBAction func actionBenchmarkModeChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:
            Settings.benchmarkMode = .quick
        case 1:
            Settings.benchmarkMode = .complete
        default:
            return
        }
    }

    @IBAction func actionBenchmarkSortOrderChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let order = BenchmarkSortOrder(rawValue: rawValue) else { return }
        Settings.benchmarkSortOrder = order
    }

    @IBAction func actionBenchmarkURLPresetChanged(_ sender: NSPopUpButton) {
        guard let url = BenchmarkURLSettings.url(forPresetIndex: sender.indexOfSelectedItem) else {
            return
        }
        speedTestUrlField.stringValue = url
        guard persistBenchmarkURL() else { return }
        MenuItemFactory.refreshExistingMenuItems()
    }

    @IBAction func actionBenchmarkMeasurementMethodChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let method = BenchmarkMeasurementMethod(rawValue: rawValue),
              method != Settings.benchmarkMeasurementMethod else { return }
        let previousMethod = Settings.benchmarkMeasurementMethod
        AppDelegate.shared.cancelActiveSpeedTest(
            reason: "benchmark measurement method changed",
            refreshMenu: false
        )
        Settings.benchmarkMeasurementMethod = method
        BenchmarkMeasurementEpoch.invalidate()
        Self.clearBenchmarkMeasurementPresentations()
        sender.isEnabled = false
        AppDelegate.shared.updateConfig(showNotification: false) { [weak self] error in
            dispatchPrecondition(condition: .onQueue(.main))
            if error == nil {
                BenchmarkMeasurementEpoch.invalidate()
                Self.clearBenchmarkMeasurementPresentations()
                if Settings.benchmarkMeasurementMethod == method {
                    Settings.confirmRuntimeBenchmarkMeasurementMethod(method)
                }
                self?.benchmarkMeasurementMethodPopUp.isEnabled = true
                return
            }

            if Settings.benchmarkMeasurementMethod == method {
                Settings.benchmarkMeasurementMethod = previousMethod
            }
            guard let self = self else { return }
            self.benchmarkMeasurementMethodPopUp.isEnabled = true
            let methods: [BenchmarkMeasurementMethod] = [
                .followConfiguration, .unified, .connection
            ]
            self.benchmarkMeasurementMethodPopUp.selectItem(
                at: methods.firstIndex(of: Settings.benchmarkMeasurementMethod) ?? 0
            )
        }
    }

    private static func clearBenchmarkMeasurementPresentations() {
        GlobalLeafBenchmarkPresentationStore.clearAll()
        SelectorBenchmarkPresentationStore.clearAll()
        AutomaticChildBenchmarkStore.clearAll()
        AutomaticGroupBenchmarkPresentationStore.clearAll()
        ProxyGroupSpeedTestMenuItem.clearBenchmarkRetryHistory()
    }

    @discardableResult
    private func persistBenchmarkURL() -> Bool {
        guard let url = BenchmarkURLSettings.normalizedURL(
            speedTestUrlField.stringValue,
            defaultURL: Settings.defaultBenchmarkUrl
        ) else {
            speedTestUrlField.textColor = .systemRed
            benchmarkURLSaveButton.isEnabled = false
            return false
        }
        Settings.benchMarkUrl = url
        speedTestUrlField.textColor = .controlTextColor
        benchmarkURLSaveButton.isEnabled = true
        benchmarkURLPresetPopUp.selectItem(at: BenchmarkURLSettings.presetIndex(for: url))
        return true
    }

    @IBAction func actionResetIgnoreList(_: Any) {
        ignoreListTextView.string = Settings.proxyIgnoreListDefaultValue.joined(separator: ",")
        Settings.proxyIgnoreList = Settings.proxyIgnoreListDefaultValue
        AppDelegate.shared.applyProxyBypassSettings()
    }

    @IBAction func actionResetTunRouteExcludeList(_ sender: Any) {
        tunRouteExcludeTextView.string = ""
        Settings.tunRouteExcludeRawText = ""
        Settings.tunRouteExcludeList = []
    }
}

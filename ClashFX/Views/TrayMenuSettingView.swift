//
//  TrayMenuSettingView.swift
//  ClashFX
//

import Cocoa

class TrayMenuSettingView: NSView {

    // MARK: - Data model

    private struct ItemRow {
        let title: String
        let getter: () -> Bool
        let setter: (Bool) -> Void
    }

    private struct Group {
        let title: String
        let getter: () -> Bool
        let setter: (Bool) -> Void
        let children: [ItemRow]
    }

    private enum SectionEntry {
        case single(ItemRow)
        case group(Group)
    }

    private struct ChildView {
        let label: NSTextField
        let control: NSControl
    }

    // MARK: - State

    private var switchHandlers: [NSControl: (Bool) -> Void] = [:]
    private var parentControlToChildren: [NSControl: [ChildView]] = [:]
    private var uiSetupDone = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - Data

    private func sections() -> [SectionEntry] {
        return [
            .single(ItemRow(
                title: NSLocalizedString("Proxy Mode", comment: ""),
                getter: { Settings.trayMenuShowProxyMode },
                setter: { Settings.trayMenuShowProxyMode = $0 }
            )),
            .single(ItemRow(
                title: NSLocalizedString("Node Switch", comment: ""),
                getter: { Settings.trayMenuShowNodeSwitch },
                setter: { Settings.trayMenuShowNodeSwitch = $0 }
            )),
            .group(Group(
                title: NSLocalizedString("Proxy Actions", comment: ""),
                getter: { Settings.trayMenuShowProxyActions },
                setter: { Settings.trayMenuShowProxyActions = $0 },
                children: [
                    ItemRow(title: NSLocalizedString("System Proxy", comment: ""), getter: { Settings.trayMenuShowSystemProxy }, setter: { Settings.trayMenuShowSystemProxy = $0 }),
                    ItemRow(title: NSLocalizedString("Enhanced Mode", comment: ""), getter: { Settings.trayMenuShowEnhancedMode }, setter: { Settings.trayMenuShowEnhancedMode = $0 }),
                    ItemRow(title: NSLocalizedString("Copy Shell Command", comment: ""), getter: { Settings.trayMenuShowCopyShellCmd }, setter: { Settings.trayMenuShowCopyShellCmd = $0 }),
                ]
            )),
            .group(Group(
                title: NSLocalizedString("General Settings", comment: ""),
                getter: { Settings.trayMenuShowGeneralSettings },
                setter: { Settings.trayMenuShowGeneralSettings = $0 },
                children: [
                    ItemRow(title: NSLocalizedString("Start at Login", comment: ""), getter: { Settings.trayMenuShowStartAtLogin }, setter: { Settings.trayMenuShowStartAtLogin = $0 }),
                    ItemRow(title: NSLocalizedString("Show Net Speed", comment: ""), getter: { Settings.trayMenuShowNetSpeed }, setter: { Settings.trayMenuShowNetSpeed = $0 }),
                    ItemRow(title: NSLocalizedString("Allow from LAN", comment: ""), getter: { Settings.trayMenuShowAllowLan }, setter: { Settings.trayMenuShowAllowLan = $0 }),
                ]
            )),
            .group(Group(
                title: NSLocalizedString("Tools", comment: ""),
                getter: { Settings.trayMenuShowTools },
                setter: { Settings.trayMenuShowTools = $0 },
                children: [
                    ItemRow(title: NSLocalizedString("Benchmark", comment: ""), getter: { Settings.trayMenuShowBenchmark }, setter: { Settings.trayMenuShowBenchmark = $0 }),
                    ItemRow(title: NSLocalizedString("Dashboard", comment: ""), getter: { Settings.trayMenuShowDashboard }, setter: { Settings.trayMenuShowDashboard = $0 }),
                    ItemRow(title: NSLocalizedString("Connection Details", comment: ""), getter: { Settings.trayMenuShowConnections }, setter: { Settings.trayMenuShowConnections = $0 }),
                ]
            )),
            .group(Group(
                title: NSLocalizedString("Configs", comment: ""),
                getter: { Settings.trayMenuShowConfigs },
                setter: { Settings.trayMenuShowConfigs = $0 },
                children: [
                    ItemRow(title: NSLocalizedString("Config Switcher", comment: ""), getter: { Settings.trayMenuShowConfigSwitcher }, setter: { Settings.trayMenuShowConfigSwitcher = $0 }),
                    ItemRow(title: NSLocalizedString("Config Editor", comment: ""), getter: { Settings.trayMenuShowConfigEditor }, setter: { Settings.trayMenuShowConfigEditor = $0 }),
                    ItemRow(title: NSLocalizedString("Open Config Folder", comment: ""), getter: { Settings.trayMenuShowOpenConfigFolder }, setter: { Settings.trayMenuShowOpenConfigFolder = $0 }),
                    ItemRow(title: NSLocalizedString("Reload Config", comment: ""), getter: { Settings.trayMenuShowReloadConfig }, setter: { Settings.trayMenuShowReloadConfig = $0 }),
                    ItemRow(title: NSLocalizedString("Update External Resources", comment: ""), getter: { Settings.trayMenuShowUpdateExternal }, setter: { Settings.trayMenuShowUpdateExternal = $0 }),
                    ItemRow(title: NSLocalizedString("Remote Config", comment: ""), getter: { Settings.trayMenuShowRemoteConfig }, setter: { Settings.trayMenuShowRemoteConfig = $0 }),
                    ItemRow(title: NSLocalizedString("Remote Controller", comment: ""), getter: { Settings.trayMenuShowRemoteController }, setter: { Settings.trayMenuShowRemoteController = $0 }),
                ]
            )),
            .single(ItemRow(
                title: NSLocalizedString("Language", comment: ""),
                getter: { Settings.trayMenuShowLanguage },
                setter: { Settings.trayMenuShowLanguage = $0 }
            )),
            .group(Group(
                title: NSLocalizedString("Help", comment: ""),
                getter: { Settings.trayMenuShowHelp },
                setter: { Settings.trayMenuShowHelp = $0 },
                children: [
                    ItemRow(title: NSLocalizedString("About", comment: ""), getter: { Settings.trayMenuShowAbout }, setter: { Settings.trayMenuShowAbout = $0 }),
                    ItemRow(title: NSLocalizedString("Check for Update", comment: ""), getter: { Settings.trayMenuShowCheckUpdate }, setter: { Settings.trayMenuShowCheckUpdate = $0 }),
                    ItemRow(title: NSLocalizedString("Log Level", comment: ""), getter: { Settings.trayMenuShowLogLevel }, setter: { Settings.trayMenuShowLogLevel = $0 }),
                    ItemRow(title: NSLocalizedString("Show Log", comment: ""), getter: { Settings.trayMenuShowShowLog }, setter: { Settings.trayMenuShowShowLog = $0 }),
                    ItemRow(title: NSLocalizedString("Ports", comment: ""), getter: { Settings.trayMenuShowPorts }, setter: { Settings.trayMenuShowPorts = $0 }),
                ]
            )),
        ]
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard !uiSetupDone else { return }
        uiSetupDone = true
        translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        buildRows(into: stack)
    }

    private func addFullWidthSubview(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
        ).isActive = true
    }

    private func buildRows(into stack: NSStackView) {
        let allSections = sections()
        for (idx, entry) in allSections.enumerated() {
            switch entry {
            case .single(let row):
                let (rowView, control, _) = makeRow(title: row.title, isOn: row.getter())
                switchHandlers[control] = { [row] isOn in
                    row.setter(isOn)
                    NotificationCenter.default.post(name: .trayMenuSettingsChanged, object: nil)
                }
                addFullWidthSubview(rowView, to: stack)

            case .group(let group):
                let (parentRowView, parentControl, _) = makeRow(
                    title: group.title, isOn: group.getter(), bold: true
                )
                addFullWidthSubview(parentRowView, to: stack)

                let parentIsOn = group.getter()
                var childViews: [ChildView] = []

                for child in group.children {
                    let (childRowView, childControl, childLabel) = makeRow(
                        title: child.title, isOn: child.getter(),
                        indent: 16, parentOn: parentIsOn
                    )
                    switchHandlers[childControl] = { [child] isOn in
                        child.setter(isOn)
                        NotificationCenter.default.post(name: .trayMenuSettingsChanged, object: nil)
                    }
                    childViews.append(ChildView(label: childLabel, control: childControl))
                    addFullWidthSubview(childRowView, to: stack)
                }

                parentControlToChildren[parentControl] = childViews
                switchHandlers[parentControl] = { [group, childViews] isOn in
                    group.setter(isOn)
                    for child in childViews {
                        child.control.isEnabled = isOn
                        child.label.textColor = isOn ? NSColor.labelColor : NSColor.secondaryLabelColor
                    }
                    NotificationCenter.default.post(name: .trayMenuSettingsChanged, object: nil)
                }
            }

            // Thin separator between top-level sections
            if idx < allSections.count - 1 {
                let sep = NSBox()
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.boxType = .separator
                addFullWidthSubview(sep, to: stack)
            }
        }
    }

    // MARK: - Factories

    private func makeRow(
        title: String,
        isOn: Bool,
        bold: Bool = false,
        indent: CGFloat = 0,
        parentOn: Bool = true
    ) -> (row: NSView, control: NSControl, label: NSTextField) {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.spacing = 8
        container.alignment = .centerY
        container.edgeInsets = NSEdgeInsets(top: 6, left: 4 + indent, bottom: 6, right: 4)

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = bold
            ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if !parentOn {
            label.textColor = NSColor.secondaryLabelColor
        }

        let toggle = makeToggleControl(isOn: isOn, enabled: parentOn)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)

        container.addArrangedSubview(label)
        container.addArrangedSubview(spacer)
        container.addArrangedSubview(toggle)

        return (container, toggle, label)
    }

    private func makeToggleControl(isOn: Bool, enabled: Bool) -> NSControl {
        if #available(macOS 10.15, *) {
            let sw = NSSwitch()
            sw.translatesAutoresizingMaskIntoConstraints = false
            sw.target = self
            sw.action = #selector(onToggle(_:))
            sw.state = isOn ? .on : .off
            sw.isEnabled = enabled
            return sw
        } else {
            let btn = NSButton(checkboxWithTitle: "", target: self, action: #selector(onToggle(_:)))
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.state = isOn ? .on : .off
            btn.isEnabled = enabled
            return btn
        }
    }

    // MARK: - Actions

    @objc private func onToggle(_ sender: NSControl) {
        let isOn: Bool
        if #available(macOS 10.15, *), let sw = sender as? NSSwitch {
            isOn = sw.state == .on
        } else if let btn = sender as? NSButton {
            isOn = btn.state == .on
        } else {
            assertionFailure("Unexpected control type in onToggle: \(type(of: sender))")
            isOn = false
        }
        switchHandlers[sender]?(isOn)
    }
}


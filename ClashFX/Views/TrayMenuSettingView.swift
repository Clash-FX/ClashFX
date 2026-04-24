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

    // MARK: - State

    private var switchHandlers: [NSControl: (Bool) -> Void] = [:]
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
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)

        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        let hintLabel = NSTextField(labelWithString: NSLocalizedString("Show or hide items in the tray menu.", comment: ""))
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hintLabel)
        hintLabel.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
        ).isActive = true

        buildCards(into: stack)
    }

    // MARK: - Build

    private func addCard(_ card: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
        ).isActive = true
    }

    private func buildCards(into stack: NSStackView) {
        for entry in sections() {
            switch entry {
            case let .single(row):
                addCard(makeSingleCard(row: row), to: stack)
            case let .group(group):
                addCard(makeGroupCard(group: group), to: stack)
            }
        }
    }

    // MARK: - Card Builders

    private func makeSingleCard(row: ItemRow) -> NSView {
        let card = SectionCardView()
        let (rowView, control, _) = makeRow(title: row.title, isOn: row.getter())

        card.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.topAnchor.constraint(equalTo: card.topAnchor),
            rowView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        switchHandlers[control] = { [row] isOn in
            row.setter(isOn)
            NotificationCenter.default.post(name: .trayMenuSettingsChanged, object: nil)
        }
        return card
    }

    private func makeGroupCard(group: Group) -> NSView {
        let card = SectionCardView()

        let innerStack = NSStackView()
        innerStack.translatesAutoresizingMaskIntoConstraints = false
        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 0

        card.addSubview(innerStack)
        NSLayoutConstraint.activate([
            innerStack.topAnchor.constraint(equalTo: card.topAnchor),
            innerStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            innerStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            innerStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let parentIsOn = group.getter()
        let (groupHeader, parentControl, _) = makeRow(title: group.title, isOn: parentIsOn, bold: true)
        innerStack.addArrangedSubview(groupHeader)
        groupHeader.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true

        var childControls: [NSControl] = []
        var childLabels: [NSTextField] = []
        var childGetters: [() -> Bool] = []

        for child in group.children {
            let divider = makeInsetDivider()
            innerStack.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true

            let (childRowView, childControl, childLabel) = makeRow(title: child.title, isOn: child.getter(), indent: 12, parentOn: parentIsOn)
            childControls.append(childControl)
            childLabels.append(childLabel)
            childGetters.append(child.getter)
            switchHandlers[childControl] = { [child] isOn in
                child.setter(isOn)
                NotificationCenter.default.post(name: .trayMenuSettingsChanged, object: nil)
            }
            innerStack.addArrangedSubview(childRowView)
            childRowView.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        }

        switchHandlers[parentControl] = { [group, childControls, childLabels, childGetters] isOn in
            group.setter(isOn)
            for (idx, control) in childControls.enumerated() {
                control.isEnabled = isOn
                childLabels[idx].textColor = isOn ? .labelColor : .tertiaryLabelColor
                if isOn {
                    if #available(macOS 10.15, *), let sw = control as? NSSwitch {
                        sw.state = childGetters[idx]() ? .on : .off
                    } else if let btn = control as? NSButton {
                        btn.state = childGetters[idx]() ? .on : .off
                    }
                }
            }
            NotificationCenter.default.post(name: .trayMenuSettingsChanged, object: nil)
        }

        return card
    }

    // MARK: - Row Factory

    private func makeRow(
        title: String,
        isOn: Bool,
        bold: Bool = false,
        indent: CGFloat = 0,
        parentOn: Bool = true
    ) -> (row: NSView, control: NSControl, label: NSTextField) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = bold
            ? NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = parentOn ? .labelColor : .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toggle = makeToggleControl(isOn: isOn, enabled: parentOn)

        container.addSubview(label)
        container.addSubview(toggle)

        let leadingPad: CGFloat = 12 + indent
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingPad),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),

            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return (container, toggle, label)
    }

    private func makeInsetDivider() -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let line = DividerLineView()
        wrapper.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrapper.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    // MARK: - Toggle Control Factory

    private func makeToggleControl(isOn: Bool, enabled: Bool) -> NSControl {
        if #available(macOS 10.15, *) {
            let sw = NSSwitch()
            sw.translatesAutoresizingMaskIntoConstraints = false
            sw.controlSize = .mini
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

// MARK: - SectionCardView

private final class SectionCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        if #available(macOS 10.14, *) {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 0.5
        }
    }
}

// MARK: - DividerLineView

private final class DividerLineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

import Cocoa

enum ProxyFieldType {
    case text, number, bool, popup, secure, list
}

struct ProxyFieldDescriptor {
    let key: String
    let label: String
    let fieldType: ProxyFieldType
    var popupValues: [String]?
    var required: Bool = false
    var placeholder: String = ""
}

enum ProxyFieldRegistry {
    static func fields(for type: ProxyType) -> [ProxyFieldDescriptor] {
        var common: [ProxyFieldDescriptor] = [
            ProxyFieldDescriptor(key: "server", label: "Server", fieldType: .text, required: true, placeholder: "hostname or IP"),
            ProxyFieldDescriptor(key: "port", label: "Port", fieldType: .number, required: true, placeholder: "443"),
        ]

        switch type {
        case .vmess:
            common += [
                ProxyFieldDescriptor(key: "uuid", label: "UUID", fieldType: .text, required: true),
                ProxyFieldDescriptor(key: "alterId", label: "Alter ID", fieldType: .number, placeholder: "0"),
                ProxyFieldDescriptor(key: "cipher", label: "Cipher", fieldType: .popup, popupValues: ["auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305"]),
                ProxyFieldDescriptor(key: "network", label: "Network", fieldType: .popup, popupValues: ["tcp", "ws", "http", "h2", "grpc"]),
                ProxyFieldDescriptor(key: "tls", label: "TLS", fieldType: .bool),
                ProxyFieldDescriptor(key: "sni", label: "SNI", fieldType: .text),
                ProxyFieldDescriptor(key: "skip-cert-verify", label: "Skip Cert Verify", fieldType: .bool),
                ProxyFieldDescriptor(key: "udp", label: "UDP", fieldType: .bool),
            ]
        case .vless:
            common += [
                ProxyFieldDescriptor(key: "uuid", label: "UUID", fieldType: .text, required: true),
                ProxyFieldDescriptor(key: "flow", label: "Flow", fieldType: .popup, popupValues: ["", "xtls-rprx-vision"]),
                ProxyFieldDescriptor(key: "network", label: "Network", fieldType: .popup, popupValues: ["tcp", "ws", "http", "h2", "grpc"]),
                ProxyFieldDescriptor(key: "tls", label: "TLS", fieldType: .bool),
                ProxyFieldDescriptor(key: "sni", label: "SNI", fieldType: .text),
                ProxyFieldDescriptor(key: "skip-cert-verify", label: "Skip Cert Verify", fieldType: .bool),
                ProxyFieldDescriptor(key: "client-fingerprint", label: "Fingerprint", fieldType: .popup, popupValues: ["", "chrome", "firefox", "safari", "ios", "android", "edge", "random"]),
                ProxyFieldDescriptor(key: "udp", label: "UDP", fieldType: .bool),
            ]
        case .trojan:
            common += [
                ProxyFieldDescriptor(key: "password", label: "Password", fieldType: .secure, required: true),
                ProxyFieldDescriptor(key: "network", label: "Network", fieldType: .popup, popupValues: ["tcp", "ws", "grpc"]),
                ProxyFieldDescriptor(key: "sni", label: "SNI", fieldType: .text),
                ProxyFieldDescriptor(key: "skip-cert-verify", label: "Skip Cert Verify", fieldType: .bool),
                ProxyFieldDescriptor(key: "udp", label: "UDP", fieldType: .bool),
            ]
        case .ss:
            common += [
                ProxyFieldDescriptor(key: "cipher", label: "Cipher", fieldType: .popup, popupValues: [
                    "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
                    "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
                    "aes-128-cfb", "aes-256-cfb", "rc4-md5", "none",
                ], required: true),
                ProxyFieldDescriptor(key: "password", label: "Password", fieldType: .secure, required: true),
                ProxyFieldDescriptor(key: "udp", label: "UDP", fieldType: .bool),
                ProxyFieldDescriptor(key: "plugin", label: "Plugin", fieldType: .popup, popupValues: ["", "obfs", "v2ray-plugin", "shadow-tls"]),
            ]
        case .hysteria2:
            common += [
                ProxyFieldDescriptor(key: "password", label: "Password", fieldType: .secure, required: true),
                ProxyFieldDescriptor(key: "up", label: "Upload", fieldType: .text, placeholder: "30 Mbps"),
                ProxyFieldDescriptor(key: "down", label: "Download", fieldType: .text, placeholder: "200 Mbps"),
                ProxyFieldDescriptor(key: "obfs", label: "Obfs", fieldType: .popup, popupValues: ["", "salamander"]),
                ProxyFieldDescriptor(key: "obfs-password", label: "Obfs Password", fieldType: .secure),
                ProxyFieldDescriptor(key: "sni", label: "SNI", fieldType: .text),
                ProxyFieldDescriptor(key: "skip-cert-verify", label: "Skip Cert Verify", fieldType: .bool),
            ]
        case .wireguard:
            common += [
                ProxyFieldDescriptor(key: "private-key", label: "Private Key", fieldType: .secure, required: true),
                ProxyFieldDescriptor(key: "public-key", label: "Public Key", fieldType: .text, required: true),
                ProxyFieldDescriptor(key: "ip", label: "IP", fieldType: .text, required: true, placeholder: "172.16.0.2"),
                ProxyFieldDescriptor(key: "ipv6", label: "IPv6", fieldType: .text),
                ProxyFieldDescriptor(key: "pre-shared-key", label: "Pre-shared Key", fieldType: .secure),
                ProxyFieldDescriptor(key: "mtu", label: "MTU", fieldType: .number, placeholder: "1408"),
                ProxyFieldDescriptor(key: "remote-dns-resolve", label: "Remote DNS", fieldType: .bool),
            ]
        default:
            break
        }
        return common
    }
}

class ProxiesEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var document: ConfigDocument? {
        didSet { proxyTable.reloadData() }
    }

    private let proxyTable = NSTableView()
    private let formStack = NSStackView()
    private let formScroll = NSScrollView()
    private var selectedProxyIndex: Int = -1
    private var fieldControls: [(ProxyFieldDescriptor, NSView)] = []
    private let nameField = FormHelpers.makeTextField(placeholder: "Proxy Name")
    private let typePopup = FormHelpers.makePopup(items: ["vmess", "vless", "trojan", "ss", "hysteria2", "wireguard"])

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
    }

    private func setupLayout() {
        let leftPanel = NSView()
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        setupProxyList(in: leftPanel)
        view.addSubview(leftPanel)

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        view.addSubview(divider)

        let rightPanel = NSView()
        rightPanel.translatesAutoresizingMaskIntoConstraints = false
        setupFormPanel(in: rightPanel)
        view.addSubview(rightPanel)

        NSLayoutConstraint.activate([
            leftPanel.topAnchor.constraint(equalTo: view.topAnchor),
            leftPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftPanel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.45),

            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            rightPanel.topAnchor.constraint(equalTo: view.topAnchor),
            rightPanel.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupProxyList(in container: NSView) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Proxies"
        proxyTable.addTableColumn(nameCol)
        proxyTable.headerView = nil
        proxyTable.dataSource = self
        proxyTable.delegate = self
        proxyTable.rowHeight = 28
        proxyTable.target = self
        proxyTable.action = #selector(proxySelected)
        scrollView.documentView = proxyTable

        let buttonBar = NSView()
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(buttonBar)

        let addBtn = NSButton(title: "+", target: self, action: #selector(addProxy))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.bezelStyle = .smallSquare
        buttonBar.addSubview(addBtn)

        let removeBtn = NSButton(title: "-", target: self, action: #selector(removeProxy))
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.bezelStyle = .smallSquare
        buttonBar.addSubview(removeBtn)

        NSLayoutConstraint.activate([
            buttonBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            buttonBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            buttonBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            buttonBar.heightAnchor.constraint(equalToConstant: 24),

            addBtn.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor),
            addBtn.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            addBtn.widthAnchor.constraint(equalToConstant: 24),

            removeBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 2),
            removeBtn.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            removeBtn.widthAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -4),
        ])
    }

    private func setupFormPanel(in container: NSView) {
        formScroll.translatesAutoresizingMaskIntoConstraints = false
        formScroll.hasVerticalScroller = true
        formScroll.autohidesScrollers = true
        formScroll.borderType = .noBorder
        formScroll.drawsBackground = false
        container.addSubview(formScroll)

        let formContainer = FlippedView()
        formContainer.translatesAutoresizingMaskIntoConstraints = false
        formScroll.documentView = formContainer

        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 10
        formContainer.addSubview(formStack)

        NSLayoutConstraint.activate([
            formScroll.topAnchor.constraint(equalTo: container.topAnchor),
            formScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            formScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            formScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            formStack.topAnchor.constraint(equalTo: formContainer.topAnchor, constant: 12),
            formStack.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: 16),
            formStack.trailingAnchor.constraint(equalTo: formContainer.trailingAnchor, constant: -16),
            formStack.bottomAnchor.constraint(lessThanOrEqualTo: formContainer.bottomAnchor, constant: -12),
            formContainer.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
        ])
    }

    @objc private func proxySelected() {
        saveCurrentProxy()
        selectedProxyIndex = proxyTable.selectedRow
        loadProxyDetail()
    }

    @objc private func addProxy() {
        let proxy = ProxyDefinition(name: "New Proxy", type: .vmess, server: "", port: 443)
        document?.proxies.append(proxy)
        proxyTable.reloadData()
        let lastRow = (document?.proxies.count ?? 1) - 1
        proxyTable.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
        selectedProxyIndex = lastRow
        loadProxyDetail()
    }

    @objc private func removeProxy() {
        guard selectedProxyIndex >= 0, selectedProxyIndex < (document?.proxies.count ?? 0) else { return }
        document?.proxies.remove(at: selectedProxyIndex)
        proxyTable.reloadData()
        selectedProxyIndex = -1
        rebuildForm(for: .unknown)
    }

    @objc private func typeChanged(_ sender: NSPopUpButton) {
        saveCurrentProxy()
        if let title = sender.titleOfSelectedItem {
            document?.proxies[selectedProxyIndex].type = ProxyType(raw: title)
        }
        loadProxyDetail()
    }

    private func loadProxyDetail() {
        guard selectedProxyIndex >= 0,
              let proxy = document?.proxies[safe2: selectedProxyIndex] else {
            rebuildForm(for: .unknown)
            return
        }

        nameField.stringValue = proxy.name
        typePopup.selectItem(withTitle: proxy.type.rawValue)
        rebuildForm(for: proxy.type)

        for (desc, control) in fieldControls {
            let val = proxy.fields[desc.key]
            switch desc.fieldType {
            case .text, .secure:
                (control as? NSTextField)?.stringValue = val as? String ?? ""
            case .number:
                (control as? NSTextField)?.integerValue = val as? Int ?? 0
            case .bool:
                (control as? NSButton)?.state = (val as? Bool == true) ? .on : .off
            case .popup:
                (control as? NSPopUpButton)?.selectItem(withTitle: val as? String ?? "")
            case .list:
                break
            }
        }
    }

    private func saveCurrentProxy() {
        guard selectedProxyIndex >= 0,
              selectedProxyIndex < (document?.proxies.count ?? 0) else { return }

        document?.proxies[selectedProxyIndex].name = nameField.stringValue
        if let title = typePopup.titleOfSelectedItem {
            document?.proxies[selectedProxyIndex].type = ProxyType(raw: title)
        }

        for (desc, control) in fieldControls {
            switch desc.fieldType {
            case .text, .secure:
                let str = (control as? NSTextField)?.stringValue ?? ""
                if str.isEmpty {
                    document?.proxies[selectedProxyIndex].fields.removeValue(forKey: desc.key)
                } else {
                    document?.proxies[selectedProxyIndex].fields[desc.key] = str
                }
            case .number:
                let num = (control as? NSTextField)?.integerValue ?? 0
                if num == 0 {
                    document?.proxies[selectedProxyIndex].fields.removeValue(forKey: desc.key)
                } else {
                    document?.proxies[selectedProxyIndex].fields[desc.key] = num
                }
            case .bool:
                let on = (control as? NSButton)?.state == .on
                if on {
                    document?.proxies[selectedProxyIndex].fields[desc.key] = true
                } else {
                    document?.proxies[selectedProxyIndex].fields.removeValue(forKey: desc.key)
                }
            case .popup:
                let str = (control as? NSPopUpButton)?.titleOfSelectedItem ?? ""
                if str.isEmpty {
                    document?.proxies[selectedProxyIndex].fields.removeValue(forKey: desc.key)
                } else {
                    document?.proxies[selectedProxyIndex].fields[desc.key] = str
                }
            case .list:
                break
            }
        }
    }

    private func rebuildForm(for proxyType: ProxyType) {
        for sub in formStack.arrangedSubviews {
            sub.removeFromSuperview()
        }
        fieldControls = []

        let nameRow = FormHelpers.makeFormRow(label: NSLocalizedString("Name:", comment: ""), control: nameField)
        formStack.addArrangedSubview(nameRow)
        do { let c = nameRow.widthAnchor.constraint(equalTo: formStack.widthAnchor); c.priority = .defaultHigh; c.isActive = true }

        typePopup.target = self
        typePopup.action = #selector(typeChanged(_:))
        let typeRow = FormHelpers.makeFormRow(label: NSLocalizedString("Type:", comment: ""), control: typePopup)
        formStack.addArrangedSubview(typeRow)
        do { let c = typeRow.widthAnchor.constraint(equalTo: formStack.widthAnchor); c.priority = .defaultHigh; c.isActive = true }

        guard proxyType != .unknown else { return }

        formStack.addArrangedSubview(FormHelpers.makeSeparator())

        let descriptors = ProxyFieldRegistry.fields(for: proxyType)
        for desc in descriptors {
            let control: NSView
            switch desc.fieldType {
            case .text:
                control = FormHelpers.makeTextField(placeholder: desc.placeholder)
            case .number:
                control = FormHelpers.makeNumberField(placeholder: desc.placeholder)
            case .bool:
                control = FormHelpers.makeCheckbox()
            case .popup:
                control = FormHelpers.makePopup(items: desc.popupValues ?? [])
            case .secure:
                control = FormHelpers.makeSecureField(placeholder: desc.placeholder)
            case .list:
                control = StringListEditorView()
            }

            fieldControls.append((desc, control))
            let row = FormHelpers.makeFormRow(label: NSLocalizedString(desc.label + ":", comment: ""), control: control)
            formStack.addArrangedSubview(row)
            do { let c = row.widthAnchor.constraint(equalTo: formStack.widthAnchor); c.priority = .defaultHigh; c.isActive = true }
        }
    }

    func applyToDocument() {
        saveCurrentProxy()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        document?.proxies.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let proxy = document?.proxies[safe2: row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("ProxyCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = id
        cell.stringValue = "\(proxy.name) [\(proxy.type.rawValue)]"
        cell.font = .systemFont(ofSize: 13)
        return cell
    }
}

private extension Array {
    subscript(safe2 index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import Cocoa

class GeneralConfigViewController: NSViewController {
    var document: ConfigDocument? {
        didSet { populateFields() }
    }

    private let portField = FormHelpers.makeNumberField(placeholder: "7890")
    private let socksPortField = FormHelpers.makeNumberField(placeholder: "7891")
    private let mixedPortField = FormHelpers.makeNumberField(placeholder: "7890")
    private let allowLanCheck = FormHelpers.makeCheckbox()
    private let bindAddressField = FormHelpers.makeTextField(placeholder: "*")
    private let modePopup = FormHelpers.makePopup(items: ["rule", "global", "direct"])
    private let logLevelPopup = FormHelpers.makePopup(items: ["silent", "error", "warning", "info", "debug"])
    private let ipv6Check = FormHelpers.makeCheckbox()
    private let externalControllerField = FormHelpers.makeTextField(placeholder: "127.0.0.1:9090")
    private let secretField = FormHelpers.makeSecureField(placeholder: "optional")
    private let findProcessPopup = FormHelpers.makePopup(items: ["", "always", "strict", "off"])
    private let tcpConcurrentCheck = FormHelpers.makeCheckbox()
    private let unifiedDelayCheck = FormHelpers.makeCheckbox()
    private let interfaceField = FormHelpers.makeTextField()
    private let keepAliveField = FormHelpers.makeNumberField(placeholder: "15")
    private let geodataModeCheck = FormHelpers.makeCheckbox()
    private let fingerprintPopup = FormHelpers.makePopup(items: ["", "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random"])

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let (scrollView, stack) = FormHelpers.makeScrollableForm()
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let rows: [(String, NSView)] = [
            ("Port:", portField),
            ("SOCKS Port:", socksPortField),
            ("Mixed Port:", mixedPortField),
            ("Allow LAN:", allowLanCheck),
            ("Bind Address:", bindAddressField),
            ("Mode:", modePopup),
            ("Log Level:", logLevelPopup),
            ("IPv6:", ipv6Check),
            ("External Controller:", externalControllerField),
            ("Secret:", secretField),
            ("Find Process Mode:", findProcessPopup),
            ("TCP Concurrent:", tcpConcurrentCheck),
            ("Unified Delay:", unifiedDelayCheck),
            ("Interface Name:", interfaceField),
            ("Keep Alive Interval:", keepAliveField),
            ("Geodata Mode:", geodataModeCheck),
            ("Client Fingerprint:", fingerprintPopup),
        ]

        for (label, control) in rows {
            let row = FormHelpers.makeFormRow(label: NSLocalizedString(label, comment: ""), control: control)
            stack.addArrangedSubview(row)
            do { let c = row.widthAnchor.constraint(equalTo: stack.widthAnchor); c.priority = .defaultHigh; c.isActive = true }
        }
    }

    private func populateFields() {
        guard let g = document?.general else { return }
        portField.integerValue = g.port ?? 0
        socksPortField.integerValue = g.socksPort ?? 0
        mixedPortField.integerValue = g.mixedPort ?? 0
        allowLanCheck.state = (g.allowLan == true) ? .on : .off
        bindAddressField.stringValue = g.bindAddress ?? ""
        modePopup.selectItem(withTitle: g.mode.rawValue)
        logLevelPopup.selectItem(withTitle: g.logLevel.rawValue)
        ipv6Check.state = (g.ipv6 == true) ? .on : .off
        externalControllerField.stringValue = g.externalController ?? ""
        secretField.stringValue = g.secret ?? ""
        findProcessPopup.selectItem(withTitle: g.findProcessMode ?? "")
        tcpConcurrentCheck.state = (g.tcpConcurrent == true) ? .on : .off
        unifiedDelayCheck.state = (g.unifiedDelay == true) ? .on : .off
        interfaceField.stringValue = g.interfaceName ?? ""
        keepAliveField.integerValue = g.keepAliveInterval ?? 0
        geodataModeCheck.state = (g.geodataMode == true) ? .on : .off
        fingerprintPopup.selectItem(withTitle: g.globalClientFingerprint ?? "")
    }

    func applyToDocument() {
        guard let g = document?.general else { return }
        g.port = portField.integerValue > 0 ? portField.integerValue : nil
        g.socksPort = socksPortField.integerValue > 0 ? socksPortField.integerValue : nil
        g.mixedPort = mixedPortField.integerValue > 0 ? mixedPortField.integerValue : nil
        g.allowLan = allowLanCheck.state == .on
        g.bindAddress = bindAddressField.stringValue.isEmpty ? nil : bindAddressField.stringValue
        g.mode = ClashProxyMode(rawValue: modePopup.titleOfSelectedItem ?? "rule") ?? .rule
        g.logLevel = ClashLogLevel(rawValue: logLevelPopup.titleOfSelectedItem ?? "info") ?? .info
        g.ipv6 = ipv6Check.state == .on
        g.externalController = externalControllerField.stringValue.isEmpty ? nil : externalControllerField.stringValue
        g.secret = secretField.stringValue.isEmpty ? nil : secretField.stringValue
        let fpm = findProcessPopup.titleOfSelectedItem ?? ""
        g.findProcessMode = fpm.isEmpty ? nil : fpm
        g.tcpConcurrent = tcpConcurrentCheck.state == .on ? true : nil
        g.unifiedDelay = unifiedDelayCheck.state == .on ? true : nil
        g.interfaceName = interfaceField.stringValue.isEmpty ? nil : interfaceField.stringValue
        g.keepAliveInterval = keepAliveField.integerValue > 0 ? keepAliveField.integerValue : nil
        g.geodataMode = geodataModeCheck.state == .on ? true : nil
        let fp = fingerprintPopup.titleOfSelectedItem ?? ""
        g.globalClientFingerprint = fp.isEmpty ? nil : fp
    }
}

import Cocoa

class DNSConfigViewController: NSViewController {
    var document: ConfigDocument? {
        didSet { populateFields() }
    }

    private let enableCheck = FormHelpers.makeCheckbox()
    private let listenField = FormHelpers.makeTextField(placeholder: "0.0.0.0:1053")
    private let ipv6Check = FormHelpers.makeCheckbox()
    private let enhancedModePopup = FormHelpers.makePopup(items: ["", "fake-ip", "redir-host"])
    private let fakeIPRangeField = FormHelpers.makeTextField(placeholder: "198.18.0.1/16")
    private let filterModePopup = FormHelpers.makePopup(items: ["", "blacklist", "whitelist"])
    private let cacheAlgoPopup = FormHelpers.makePopup(items: ["", "arc", "lfu", "lru", "random"])
    private let preferH3Check = FormHelpers.makeCheckbox()
    private let useHostsCheck = FormHelpers.makeCheckbox()
    private let useSystemHostsCheck = FormHelpers.makeCheckbox()
    private let respectRulesCheck = FormHelpers.makeCheckbox()
    private let defaultNSList = StringListEditorView()
    private let nameserverList = StringListEditorView()
    private let fallbackList = StringListEditorView()
    private let proxyServerNSList = StringListEditorView()

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

        let scalarRows: [(String, NSView)] = [
            ("Enable:", enableCheck),
            ("Listen:", listenField),
            ("IPv6:", ipv6Check),
            ("Enhanced Mode:", enhancedModePopup),
            ("Fake-IP Range:", fakeIPRangeField),
            ("Filter Mode:", filterModePopup),
            ("Cache Algorithm:", cacheAlgoPopup),
            ("Prefer H3:", preferH3Check),
            ("Use Hosts:", useHostsCheck),
            ("Use System Hosts:", useSystemHostsCheck),
            ("Respect Rules:", respectRulesCheck),
        ]

        for (label, control) in scalarRows {
            let row = FormHelpers.makeFormRow(label: label, control: control)
            stack.addArrangedSubview(row)
            do { let c = row.widthAnchor.constraint(equalTo: stack.widthAnchor); c.priority = .defaultHigh; c.isActive = true }
        }

        let listSections: [(String, StringListEditorView)] = [
            ("Default Nameserver", defaultNSList),
            ("Nameserver", nameserverList),
            ("Fallback", fallbackList),
            ("Proxy Server NS", proxyServerNSList),
        ]

        for (title, listView) in listSections {
            stack.addArrangedSubview(FormHelpers.makeSeparator())
            stack.addArrangedSubview(FormHelpers.makeSectionHeader(title))
            stack.addArrangedSubview(listView)
            do { let c = listView.widthAnchor.constraint(equalTo: stack.widthAnchor); c.priority = .defaultHigh; c.isActive = true }
            listView.heightAnchor.constraint(equalToConstant: 120).isActive = true
        }
    }

    private func populateFields() {
        guard let d = document?.dns else { return }
        enableCheck.state = (d.enable == true) ? .on : .off
        listenField.stringValue = d.listen ?? ""
        ipv6Check.state = (d.ipv6 == true) ? .on : .off
        if let em = d.enhancedMode { enhancedModePopup.selectItem(withTitle: em.rawValue) }
        fakeIPRangeField.stringValue = d.fakeIPRange ?? ""
        if let fm = d.fakeIPFilterMode { filterModePopup.selectItem(withTitle: fm) }
        if let ca = d.cacheAlgorithm { cacheAlgoPopup.selectItem(withTitle: ca) }
        preferH3Check.state = (d.preferH3 == true) ? .on : .off
        useHostsCheck.state = (d.useHosts == true) ? .on : .off
        useSystemHostsCheck.state = (d.useSystemHosts == true) ? .on : .off
        respectRulesCheck.state = (d.respectRules == true) ? .on : .off
        defaultNSList.items = d.defaultNameserver ?? []
        nameserverList.items = d.nameserver ?? []
        fallbackList.items = d.fallback ?? []
        proxyServerNSList.items = d.proxyServerNameserver ?? []
    }

    func applyToDocument() {
        guard let d = document?.dns else { return }
        d.enable = enableCheck.state == .on ? true : nil
        d.listen = listenField.stringValue.isEmpty ? nil : listenField.stringValue
        d.ipv6 = ipv6Check.state == .on ? true : nil
        let em = enhancedModePopup.titleOfSelectedItem ?? ""
        d.enhancedMode = em.isEmpty ? nil : DNSEnhancedMode(rawValue: em)
        d.fakeIPRange = fakeIPRangeField.stringValue.isEmpty ? nil : fakeIPRangeField.stringValue
        let fm = filterModePopup.titleOfSelectedItem ?? ""
        d.fakeIPFilterMode = fm.isEmpty ? nil : fm
        let ca = cacheAlgoPopup.titleOfSelectedItem ?? ""
        d.cacheAlgorithm = ca.isEmpty ? nil : ca
        d.preferH3 = preferH3Check.state == .on ? true : nil
        d.useHosts = useHostsCheck.state == .on ? true : nil
        d.useSystemHosts = useSystemHostsCheck.state == .on ? true : nil
        d.respectRules = respectRulesCheck.state == .on ? true : nil
        d.defaultNameserver = defaultNSList.items.isEmpty ? nil : defaultNSList.items
        d.nameserver = nameserverList.items.isEmpty ? nil : nameserverList.items
        d.fallback = fallbackList.items.isEmpty ? nil : fallbackList.items
        d.proxyServerNameserver = proxyServerNSList.items.isEmpty ? nil : proxyServerNSList.items
    }
}

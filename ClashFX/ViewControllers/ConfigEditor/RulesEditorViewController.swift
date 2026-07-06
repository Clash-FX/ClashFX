import Cocoa

class RulesEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var allowsProfileRuleBuckets = false {
        didSet {
            configureRuleBucketPopup()
            selectPreferredRuleBucket()
            tableView.reloadData()
        }
    }

    var document: ConfigDocument? {
        didSet {
            selectPreferredRuleBucket()
            tableView.reloadData()
        }
    }

    private let tableView = NSTableView()
    private let ruleBucketPopup = NSPopUpButton()
    private enum RuleBucket: Int {
        case rules
        case profilePrependRules
        case profileAppendRules

        var fallbackRule: String {
            switch self {
            case .rules, .profilePrependRules: return "DOMAIN-SUFFIX,,DIRECT"
            case .profileAppendRules: return "MATCH,DIRECT"
            }
        }
    }

    private let ruleTypes = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX",
        "IP-CIDR", "IP-CIDR6", "GEOIP", "GEOSITE",
        "PROCESS-NAME", "PROCESS-PATH", "RULE-SET", "MATCH",
        "SRC-IP-CIDR", "SRC-PORT", "DST-PORT", "NETWORK",
    ]

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        view.addSubview(scrollView)

        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "Type"
        typeCol.width = 160
        tableView.addTableColumn(typeCol)

        let valueCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueCol.title = "Value"
        valueCol.width = 280
        tableView.addTableColumn(valueCol)

        let proxyCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("proxy"))
        proxyCol.title = "Proxy"
        proxyCol.width = 160
        tableView.addTableColumn(proxyCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true

        tableView.registerForDraggedTypes([.string])

        scrollView.documentView = tableView

        let buttonBar = NSView()
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonBar)

        ruleBucketPopup.translatesAutoresizingMaskIntoConstraints = false
        ruleBucketPopup.target = self
        ruleBucketPopup.action = #selector(ruleBucketChanged)
        buttonBar.addSubview(ruleBucketPopup)
        configureRuleBucketPopup()
        selectPreferredRuleBucket()

        let addBtn = NSButton(title: "+", target: self, action: #selector(addRule))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.bezelStyle = .smallSquare
        buttonBar.addSubview(addBtn)

        let removeBtn = NSButton(title: "-", target: self, action: #selector(removeRule))
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.bezelStyle = .smallSquare
        buttonBar.addSubview(removeBtn)

        let dupBtn = NSButton(title: "Dup", target: self, action: #selector(duplicateRule))
        dupBtn.translatesAutoresizingMaskIntoConstraints = false
        dupBtn.bezelStyle = .smallSquare
        buttonBar.addSubview(dupBtn)

        NSLayoutConstraint.activate([
            buttonBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            buttonBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            buttonBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            buttonBar.heightAnchor.constraint(equalToConstant: 24),

            ruleBucketPopup.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor),
            ruleBucketPopup.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            ruleBucketPopup.widthAnchor.constraint(equalToConstant: 220),

            addBtn.leadingAnchor.constraint(equalTo: ruleBucketPopup.trailingAnchor, constant: 8),
            addBtn.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            addBtn.widthAnchor.constraint(equalToConstant: 24),

            removeBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 2),
            removeBtn.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            removeBtn.widthAnchor.constraint(equalToConstant: 24),

            dupBtn.leadingAnchor.constraint(equalTo: removeBtn.trailingAnchor, constant: 2),
            dupBtn.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            dupBtn.widthAnchor.constraint(equalToConstant: 40),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -4),
        ])
    }

    @objc private func ruleBucketChanged() {
        tableView.deselectAll(nil)
        tableView.reloadData()
    }

    @objc private func addRule() {
        var rules = selectedRules()
        rules.append(selectedRuleBucket.fallbackRule)
        setSelectedRules(rules)
        tableView.reloadData()
        let lastRow = rules.count - 1
        tableView.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(lastRow)
    }

    @objc private func removeRule() {
        let rows = tableView.selectedRowIndexes.sorted().reversed()
        var rules = selectedRules()
        for row in rows {
            guard row >= 0, row < rules.count else { continue }
            rules.remove(at: row)
        }
        setSelectedRules(rules)
        tableView.reloadData()
    }

    @objc private func duplicateRule() {
        let row = tableView.selectedRow
        var rules = selectedRules()
        guard row >= 0, row < rules.count else { return }
        rules.insert(rules[row], at: row + 1)
        setSelectedRules(rules)
        tableView.reloadData()
    }

    func applyToDocument() {}

    private func parseRule(_ rule: String) -> (type: String, value: String, proxy: String) {
        let parts = rule.components(separatedBy: ",")
        let type = parts.first ?? ""
        if type == "MATCH" {
            return (type, "", parts.count > 1 ? parts[1] : "")
        }
        let value = parts.count > 1 ? parts[1] : ""
        let proxy = parts.count > 2 ? parts[2] : ""
        return (type, value, proxy)
    }

    private func buildRule(type: String, value: String, proxy: String) -> String {
        if type == "MATCH" { return "MATCH,\(proxy)" }
        return "\(type),\(value),\(proxy)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        selectedRules().count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let rules = selectedRules()
        guard row < rules.count else { return nil }
        let rule = rules[row]
        let parsed = parseRule(rule)
        switch tableColumn?.identifier.rawValue {
        case "type": return parsed.type
        case "value": return parsed.value
        case "proxy": return parsed.proxy
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        var rules = selectedRules()
        guard let str = object as? String, row < rules.count else { return }
        let rule = rules[row]
        var parsed = parseRule(rule)
        switch tableColumn?.identifier.rawValue {
        case "type": parsed.type = str
        case "value": parsed.value = str
        case "proxy": parsed.proxy = str
        default: break
        }
        rules[row] = buildRule(type: parsed.type, value: parsed.value, proxy: parsed.proxy)
        setSelectedRules(rules)
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: rowIndexes, requiringSecureCoding: false)
        pboard.declareTypes([.string], owner: self)
        pboard.setData(data, forType: .string)
        return true
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above { return .move }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let data = info.draggingPasteboard.data(forType: .string),
              let sourceIndexes = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSIndexSet.self, from: data) as IndexSet?
        else { return false }

        var rules = selectedRules()
        var items: [String] = []
        for idx in sourceIndexes.sorted().reversed() {
            items.insert(rules[idx], at: 0)
            rules.remove(at: idx)
        }

        var insertAt = row
        for idx in sourceIndexes where idx < row {
            insertAt -= 1
        }

        for (i, item) in items.enumerated() {
            rules.insert(item, at: insertAt + i)
        }

        setSelectedRules(rules)
        tableView.reloadData()
        return true
    }

    private var selectedRuleBucket: RuleBucket {
        RuleBucket(rawValue: ruleBucketPopup.indexOfSelectedItem) ?? .rules
    }

    private func configureRuleBucketPopup() {
        guard isViewLoaded else { return }
        let selectedIndex = max(0, ruleBucketPopup.indexOfSelectedItem)
        ruleBucketPopup.removeAllItems()
        if allowsProfileRuleBuckets {
            ruleBucketPopup.addItems(withTitles: ["rules", "profile.prepend-rules", "profile.append-rules"])
            ruleBucketPopup.selectItem(at: min(selectedIndex, ruleBucketPopup.numberOfItems - 1))
            ruleBucketPopup.isEnabled = true
        } else {
            ruleBucketPopup.addItem(withTitle: "rules")
            ruleBucketPopup.selectItem(at: RuleBucket.rules.rawValue)
            ruleBucketPopup.isEnabled = false
        }
    }

    private func selectPreferredRuleBucket() {
        guard ruleBucketPopup.numberOfItems > 0, let document = document else { return }
        if !allowsProfileRuleBuckets {
            ruleBucketPopup.selectItem(at: RuleBucket.rules.rawValue)
        } else if document.rules.isEmpty, !document.profilePrependRules.isEmpty {
            ruleBucketPopup.selectItem(at: RuleBucket.profilePrependRules.rawValue)
        } else if document.rules.isEmpty, !document.profileAppendRules.isEmpty {
            ruleBucketPopup.selectItem(at: RuleBucket.profileAppendRules.rawValue)
        } else {
            ruleBucketPopup.selectItem(at: RuleBucket.rules.rawValue)
        }
    }

    private func selectedRules() -> [String] {
        guard let document = document else { return [] }
        switch selectedRuleBucket {
        case .rules: return document.rules
        case .profilePrependRules: return document.profilePrependRules
        case .profileAppendRules: return document.profileAppendRules
        }
    }

    private func setSelectedRules(_ rules: [String]) {
        switch selectedRuleBucket {
        case .rules: document?.rules = rules
        case .profilePrependRules: document?.profilePrependRules = rules
        case .profileAppendRules: document?.profileAppendRules = rules
        }
    }
}

import Cocoa

class RulesEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var document: ConfigDocument? {
        didSet { tableView.reloadData() }
    }

    private let tableView = NSTableView()
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

            addBtn.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor),
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

    @objc private func addRule() {
        document?.rules.append("DOMAIN-SUFFIX,,DIRECT")
        tableView.reloadData()
        let lastRow = (document?.rules.count ?? 1) - 1
        tableView.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(lastRow)
    }

    @objc private func removeRule() {
        let rows = tableView.selectedRowIndexes.sorted().reversed()
        for row in rows {
            document?.rules.remove(at: row)
        }
        tableView.reloadData()
    }

    @objc private func duplicateRule() {
        let row = tableView.selectedRow
        guard row >= 0, let rules = document?.rules, row < rules.count else { return }
        document?.rules.insert(rules[row], at: row + 1)
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
        document?.rules.count ?? 0
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let rule = document?.rules[row] else { return nil }
        let parsed = parseRule(rule)
        switch tableColumn?.identifier.rawValue {
        case "type": return parsed.type
        case "value": return parsed.value
        case "proxy": return parsed.proxy
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let str = object as? String, let rule = document?.rules[row] else { return }
        var parsed = parseRule(rule)
        switch tableColumn?.identifier.rawValue {
        case "type": parsed.type = str
        case "value": parsed.value = str
        case "proxy": parsed.proxy = str
        default: break
        }
        document?.rules[row] = buildRule(type: parsed.type, value: parsed.value, proxy: parsed.proxy)
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

        guard var rules = document?.rules else { return false }
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

        document?.rules = rules
        tableView.reloadData()
        return true
    }
}

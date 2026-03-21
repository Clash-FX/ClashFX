import Cocoa

class ProxyGroupsEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var document: ConfigDocument? {
        didSet { groupTable.reloadData() }
    }

    private let groupTable = NSTableView()
    private let nameField = FormHelpers.makeTextField(placeholder: "Group Name")
    private let typePopup = FormHelpers.makePopup(items: ["select", "url-test", "fallback", "load-balance", "relay"])
    private let urlField = FormHelpers.makeTextField(placeholder: "https://www.gstatic.com/generate_204")
    private let intervalField = FormHelpers.makeNumberField(placeholder: "300")
    private let toleranceField = FormHelpers.makeNumberField(placeholder: "50")
    private let lazyCheck = FormHelpers.makeCheckbox()
    private let filterField = FormHelpers.makeTextField(placeholder: "regex filter")
    private let proxiesList = StringListEditorView()

    private var selectedGroupIndex: Int = -1

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
        setupGroupList(in: leftPanel)
        view.addSubview(leftPanel)

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        view.addSubview(divider)

        let rightPanel = NSView()
        rightPanel.translatesAutoresizingMaskIntoConstraints = false
        setupDetailPanel(in: rightPanel)
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

    private func setupGroupList(in container: NSView) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Groups"
        groupTable.addTableColumn(nameCol)
        groupTable.headerView = nil
        groupTable.dataSource = self
        groupTable.delegate = self
        groupTable.rowHeight = 28
        groupTable.target = self
        groupTable.action = #selector(groupSelected)
        scrollView.documentView = groupTable

        let buttonBar = NSView()
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(buttonBar)

        let addBtn = NSButton(title: "+", target: self, action: #selector(addGroup))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.bezelStyle = .smallSquare
        buttonBar.addSubview(addBtn)

        let removeBtn = NSButton(title: "-", target: self, action: #selector(removeGroup))
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

    private func setupDetailPanel(in container: NSView) {
        let (scrollView, stack) = FormHelpers.makeScrollableForm()
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let rows: [(String, NSView)] = [
            ("Name:", nameField),
            ("Type:", typePopup),
            ("URL:", urlField),
            ("Interval:", intervalField),
            ("Tolerance:", toleranceField),
            ("Lazy:", lazyCheck),
            ("Filter:", filterField),
        ]

        for (label, control) in rows {
            let row = FormHelpers.makeFormRow(label: NSLocalizedString(label, comment: ""), control: control)
            stack.addArrangedSubview(row)
            do { let c = row.widthAnchor.constraint(equalTo: stack.widthAnchor); c.priority = .defaultHigh; c.isActive = true }
        }

        stack.addArrangedSubview(FormHelpers.makeSeparator())
        stack.addArrangedSubview(FormHelpers.makeSectionHeader(NSLocalizedString("Proxies", comment: "")))
        stack.addArrangedSubview(proxiesList)
        do { let c = proxiesList.widthAnchor.constraint(equalTo: stack.widthAnchor); c.priority = .defaultHigh; c.isActive = true }
        proxiesList.heightAnchor.constraint(equalToConstant: 200).isActive = true
    }

    @objc private func groupSelected() {
        saveCurrentGroup()
        selectedGroupIndex = groupTable.selectedRow
        loadGroupDetail()
    }

    @objc private func addGroup() {
        let group = ProxyGroupDefinition(name: "New Group", type: .select)
        document?.proxyGroups.append(group)
        groupTable.reloadData()
        let lastRow = (document?.proxyGroups.count ?? 1) - 1
        groupTable.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
        selectedGroupIndex = lastRow
        loadGroupDetail()
    }

    @objc private func removeGroup() {
        guard selectedGroupIndex >= 0, selectedGroupIndex < (document?.proxyGroups.count ?? 0) else { return }
        document?.proxyGroups.remove(at: selectedGroupIndex)
        groupTable.reloadData()
        selectedGroupIndex = -1
        clearDetail()
    }

    private func loadGroupDetail() {
        guard selectedGroupIndex >= 0,
              let group = document?.proxyGroups[safe: selectedGroupIndex] else {
            clearDetail()
            return
        }
        nameField.stringValue = group.name
        typePopup.selectItem(withTitle: group.type.rawValue)
        urlField.stringValue = group.url ?? ""
        intervalField.integerValue = group.interval ?? 0
        toleranceField.integerValue = group.tolerance ?? 0
        lazyCheck.state = (group.lazy == true) ? .on : .off
        filterField.stringValue = group.filter ?? ""
        proxiesList.items = group.proxies
    }

    private func saveCurrentGroup() {
        guard selectedGroupIndex >= 0,
              selectedGroupIndex < (document?.proxyGroups.count ?? 0) else { return }
        document?.proxyGroups[selectedGroupIndex].name = nameField.stringValue
        document?.proxyGroups[selectedGroupIndex].type = ProxyGroupType(raw: typePopup.titleOfSelectedItem ?? "select")
        document?.proxyGroups[selectedGroupIndex].url = urlField.stringValue.isEmpty ? nil : urlField.stringValue
        document?.proxyGroups[selectedGroupIndex].interval = intervalField.integerValue > 0 ? intervalField.integerValue : nil
        document?.proxyGroups[selectedGroupIndex].tolerance = toleranceField.integerValue > 0 ? toleranceField.integerValue : nil
        document?.proxyGroups[selectedGroupIndex].lazy = lazyCheck.state == .on ? true : nil
        document?.proxyGroups[selectedGroupIndex].filter = filterField.stringValue.isEmpty ? nil : filterField.stringValue
        document?.proxyGroups[selectedGroupIndex].proxies = proxiesList.items
    }

    private func clearDetail() {
        nameField.stringValue = ""
        typePopup.selectItem(at: 0)
        urlField.stringValue = ""
        intervalField.stringValue = ""
        toleranceField.stringValue = ""
        lazyCheck.state = .off
        filterField.stringValue = ""
        proxiesList.items = []
    }

    func applyToDocument() {
        saveCurrentGroup()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        document?.proxyGroups.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let group = document?.proxyGroups[safe: row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("GroupCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = id
        cell.stringValue = "\(group.name) (\(group.type.rawValue))"
        cell.font = .systemFont(ofSize: 13)
        return cell
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

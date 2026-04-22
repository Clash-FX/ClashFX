import Cocoa

class VisualConfigEditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let sidebarTable = NSTableView()
    private let contentContainer = NSView()
    private var currentContentVC: NSViewController?
    private let sectionKeys = ["General", "DNS", "Proxies", "Proxy Groups", "Rules"]

    private lazy var generalVC = GeneralConfigViewController()
    private lazy var dnsVC = DNSConfigViewController()
    private lazy var proxiesVC = ProxiesEditorViewController()
    private lazy var proxyGroupsVC = ProxyGroupsEditorViewController()
    private lazy var rulesVC = RulesEditorViewController()

    private var sidebarBackgroundColor: NSColor {
        if #available(macOS 10.14, *) {
            return .underPageBackgroundColor
        }
        return .controlBackgroundColor
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showSection(0)
    }

    func loadDocument(_ doc: ConfigDocument) {
        generalVC.document = doc
        dnsVC.document = doc
        proxiesVC.document = doc
        proxyGroupsVC.document = doc
        rulesVC.document = doc
    }

    func applyToDocument(_ doc: ConfigDocument) {
        generalVC.applyToDocument()
        dnsVC.applyToDocument()
        proxiesVC.applyToDocument()
        proxyGroupsVC.applyToDocument()
        rulesVC.applyToDocument()
    }

    // MARK: - Layout (no NSSplitView — pure auto-layout)

    private func setupLayout() {
        // Sidebar scroll view
        let sidebarScroll = NSScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.borderType = .noBorder
        sidebarScroll.drawsBackground = true
        sidebarScroll.backgroundColor = sidebarBackgroundColor
        view.addSubview(sidebarScroll)

        // Divider line
        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        view.addSubview(divider)

        // Content container
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        // Setup sidebar table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.title = ""
        sidebarTable.addTableColumn(column)
        sidebarTable.headerView = nil
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        sidebarTable.rowHeight = 32
        sidebarTable.selectionHighlightStyle = .sourceList
        sidebarTable.target = self
        sidebarTable.action = #selector(sidebarClicked)
        sidebarTable.backgroundColor = sidebarBackgroundColor
        sidebarScroll.documentView = sidebarTable

        NSLayoutConstraint.activate([
            // Sidebar: fixed 160pt width on the left
            sidebarScroll.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 160),

            // Divider
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            // Content: fills the rest
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Section switching

    @objc private func sidebarClicked() {
        let row = sidebarTable.selectedRow
        guard row >= 0 else { return }
        showSection(row)
    }

    private func showSection(_ index: Int) {
        currentContentVC?.view.removeFromSuperview()

        let vc: NSViewController
        switch index {
        case 0: vc = generalVC
        case 1: vc = dnsVC
        case 2: vc = proxiesVC
        case 3: vc = proxyGroupsVC
        case 4: vc = rulesVC
        default: return
        }

        currentContentVC = vc
        let contentView = vc.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        sectionKeys.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SidebarCell")
        let wrapper: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            wrapper = existing
        } else {
            wrapper = NSTableCellView()
            wrapper.identifier = id
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 13)
            label.textColor = .labelColor
            wrapper.addSubview(label)
            wrapper.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            ])
        }
        wrapper.textField?.stringValue = NSLocalizedString(sectionKeys[row], comment: "")
        return wrapper
    }
}

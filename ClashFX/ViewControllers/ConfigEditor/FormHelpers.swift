import Cocoa

enum FormHelpers {
    static let labelWidth: CGFloat = 160

    static func makeFormRow(label text: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        row.addSubview(label)

        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)

        let labelW = label.widthAnchor.constraint(equalToConstant: labelWidth)
        labelW.priority = .defaultHigh
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labelW,
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    static func makeTextField(placeholder: String = "") -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func makeNumberField(placeholder: String = "0") -> NSTextField {
        return makeTextField(placeholder: placeholder)
    }

    static func makeCheckbox(title: String = "") -> NSButton {
        let btn = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        btn.font = .systemFont(ofSize: 13)
        return btn
    }

    static func makePopup(items: [String]) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: 13)
        for item in items {
            popup.addItem(withTitle: item)
        }
        return popup
    }

    static func makeSecureField(placeholder: String = "") -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        return field
    }

    static func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 14)
        label.textColor = .labelColor
        return label
    }

    static func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    static func makeScrollableForm() -> (NSScrollView, NSStackView) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        // Use a flipped container as documentView so content starts from top
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = container

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        container.addSubview(stack)

        // Pin stack to container (not clipView) so it scrolls properly
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
            // Container width must match clipView width for horizontal layout
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        return (scrollView, stack)
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

class StringListEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var items: [String] = [] {
        didSet { tableView.reloadData() }
    }

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        addSubview(scrollView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.title = ""
        column.isEditable = true
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        scrollView.documentView = tableView

        let addBtn = NSButton(title: "+", target: self, action: #selector(addItem))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.bezelStyle = .smallSquare
        addBtn.font = .systemFont(ofSize: 13)
        addSubview(addBtn)

        let removeBtn = NSButton(title: "-", target: self, action: #selector(removeItem))
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.bezelStyle = .smallSquare
        removeBtn.font = .systemFont(ofSize: 13)
        addSubview(removeBtn)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -4),

            addBtn.leadingAnchor.constraint(equalTo: leadingAnchor),
            addBtn.bottomAnchor.constraint(equalTo: bottomAnchor),
            addBtn.widthAnchor.constraint(equalToConstant: 24),

            removeBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 2),
            removeBtn.bottomAnchor.constraint(equalTo: bottomAnchor),
            removeBtn.widthAnchor.constraint(equalToConstant: 24),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }

    @objc private func addItem() {
        items.append("")
        tableView.reloadData()
        let lastRow = items.count - 1
        tableView.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
        tableView.editColumn(0, row: lastRow, with: nil, select: true)
    }

    @objc private func removeItem() {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        items.remove(at: row)
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        items[row]
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        if let str = object as? String, row < items.count {
            items[row] = str
        }
    }
}

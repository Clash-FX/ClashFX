//
//  ProxyGroupMenu.swift
//  ClashX
//
//  Created by yicheng on 2020/2/22.
//  Copyright © 2020 west2online. All rights reserved.
//
import AppKit

@objc protocol ProxyGroupMenuHighlightDelegate: AnyObject {
    func highlight(item: NSMenuItem?)
}

class ProxyGroupMenu: NSMenu {
    private static let displayOrderMenuMarker = "ClashFX.ProxyGroupMenu.DisplayOrder"

    var highlightDelegates = NSHashTable<ProxyGroupMenuHighlightDelegate>.weakObjects()
    private var preparationState = ProxyMenuPreparationState()
    private var prepareHandler: ((ProxyGroupMenu) -> Void)?
    private var hasCapturedConfigurationOrder = false
    private weak var displayOrderMenuItem: NSMenuItem?

    override init(title: String) {
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    convenience init(title: String, prepareHandler: @escaping (ProxyGroupMenu) -> Void) {
        self.init(title: title)
        self.prepareHandler = prepareHandler
        let placeholder = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        addItem(placeholder)
    }

    func prepareIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard preparationState.begin() else { return }
        guard let prepareHandler else { return }
        self.prepareHandler = nil
        removeAllItems()
        prepareHandler(self)
    }

    func add(delegate: ProxyGroupMenuHighlightDelegate) {
        highlightDelegates.add(delegate)
    }

    func remove(_ delegate: ProxyGroupMenuHighlightDelegate) {
        highlightDelegates.remove(delegate)
    }
}

extension ProxyGroupMenu: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        dispatchPrecondition(condition: .onQueue(.main))
        prepareIfNeeded()
        prepareDisplayOrderMenuIfNeeded()
        applyConfiguredRowOrder()
    }

    func menuDidClose(_ menu: NSMenu) {
        highlightDelegates.allObjects.forEach { $0.highlight(item: nil) }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlightDelegates.allObjects.forEach { $0.highlight(item: item) }
    }

    private func prepareDisplayOrderMenuIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        let sortableRows = items.compactMap { $0 as? ProxyMenuItem }.filter(\.isSortableProxyRow)
        guard !sortableRows.isEmpty else { return }

        if !hasCapturedConfigurationOrder {
            for (index, row) in sortableRows.enumerated() {
                row.captureConfigurationSortIndex(index)
            }
            hasCapturedConfigurationOrder = true
        }

        if let existingItem = items.first(where: {
            $0.representedObject as? String == Self.displayOrderMenuMarker
        }) {
            displayOrderMenuItem = existingItem
            updateDisplayOrderSelection()
            return
        }

        let menuItem = NSMenuItem(
            title: NSLocalizedString("Display Order", comment: "Proxy menu row-order submenu"),
            action: nil,
            keyEquivalent: ""
        )
        menuItem.representedObject = Self.displayOrderMenuMarker

        let submenu = NSMenu(title: menuItem.title)
        for order in [BenchmarkSortOrder.configuration, .latency] {
            let option = NSMenuItem(
                title: localizedTitle(for: order),
                action: #selector(changeDisplayOrder(_:)),
                keyEquivalent: ""
            )
            option.target = self
            option.representedObject = order.rawValue
            submenu.addItem(option)
        }
        menuItem.submenu = submenu

        let insertionIndex = items.firstIndex(where: {
            ($0 as? ProxyMenuItem)?.isSortableProxyRow == true
        }) ?? numberOfItems
        insertItem(menuItem, at: insertionIndex)
        displayOrderMenuItem = menuItem
        updateDisplayOrderSelection()
    }

    private func localizedTitle(for order: BenchmarkSortOrder) -> String {
        switch order {
        case .configuration:
            return NSLocalizedString("Configuration Order", comment: "Proxy menu sort option")
        case .latency:
            return NSLocalizedString("Latency First", comment: "Proxy menu sort option")
        }
    }

    @objc private func changeDisplayOrder(_ sender: NSMenuItem) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let rawValue = sender.representedObject as? String,
              let order = BenchmarkSortOrder(rawValue: rawValue) else { return }
        Settings.benchmarkSortOrder = order
        updateDisplayOrderSelection()
    }

    private func updateDisplayOrderSelection() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let submenu = displayOrderMenuItem?.submenu else { return }
        let selectedOrder = Settings.benchmarkSortOrder
        for item in submenu.items {
            item.state = (item.representedObject as? String) == selectedOrder.rawValue ? .on : .off
        }
    }

    private func applyConfiguredRowOrder() {
        dispatchPrecondition(condition: .onQueue(.main))
        let rowItems = items.compactMap { $0 as? ProxyMenuItem }.filter(\.isSortableProxyRow)
        guard rowItems.count > 1 else { return }

        let sortedRows = ProxyBenchmarkRowSorting.ordered(
            rowItems,
            by: Settings.benchmarkSortOrder,
            metadata: \.benchmarkSortMetadata
        )
        let orderChanged = zip(rowItems, sortedRows).contains { pair in
            pair.0 !== pair.1
        }
        guard orderChanged else { return }

        // Keep functional items attached: reattaching the benchmark view can
        // insert its options sibling while a whole-menu rebuild is in flight.
        let rowIndices = items.indices.filter { index in
            guard let row = items[index] as? ProxyMenuItem else { return false }
            return row.isSortableProxyRow
        }
        for index in rowIndices.reversed() {
            removeItem(at: index)
        }
        for (index, row) in zip(rowIndices, sortedRows) {
            insertItem(row, at: index)
        }
    }
}

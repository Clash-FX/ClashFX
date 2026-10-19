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
    var highlightDelegates = NSHashTable<ProxyGroupMenuHighlightDelegate>.weakObjects()
    var selectionController: ProxyGroupSelectionController?
    private var preparationState = ProxyMenuPreparationState()
    private var prepareHandler: ((ProxyGroupMenu) -> Void)?
    private var hasCapturedConfigurationOrder = false

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
        selectionController?.updateMenuPresentation()
        captureConfigurationOrderIfNeeded()
        applyConfiguredRowOrder()
    }

    func menuDidClose(_ menu: NSMenu) {
        highlightDelegates.allObjects.forEach { $0.highlight(item: nil) }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlightDelegates.allObjects.forEach { $0.highlight(item: item) }
    }

    private func captureConfigurationOrderIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        let sortableRows = items.compactMap { $0 as? ProxyMenuItem }.filter(\.isSortableProxyRow)
        guard !sortableRows.isEmpty else { return }
        guard !hasCapturedConfigurationOrder else { return }
        for (index, row) in sortableRows.enumerated() {
            row.captureConfigurationSortIndex(index)
        }
        hasCapturedConfigurationOrder = true
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

        // Keep functional items and separators in place while sorting only
        // the proxy rows.
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

//
//  ProxyMenuItem.swift
//  ClashX
//
//  Created by CYC on 2019/2/18.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa

enum SelectorBenchmarkPresentationStore {
    private struct Key: Hashable {
        let selectorName: ClashProxyName
        let rowName: ClashProxyName
    }

    private static var presentations = [Key: SelectorBenchmarkPresentation]()

    static func publish(_ presentation: SelectorBenchmarkPresentation) {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Key(
            selectorName: presentation.selectorName,
            rowName: presentation.rowName
        )
        presentations[key] = presentation
        NotificationCenter.default.post(
            name: .speedTestFinishForProxy,
            object: presentation
        )
    }

    static func presentation(
        selectorName: ClashProxyName,
        rowName: ClashProxyName,
        currentBenchmarkURL: String,
        snapshot: ClashProxyResp
    ) -> SelectorBenchmarkPresentation? {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Key(selectorName: selectorName, rowName: rowName)
        guard let current = presentations[key] else { return nil }
        let reconciled = current.reconciled(
            with: snapshot,
            currentBenchmarkURL: currentBenchmarkURL
        )
        presentations[key] = reconciled
        return reconciled
    }

    static func clear(selectorName: ClashProxyName) {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations = presentations.filter { $0.key.selectorName != selectorName }
    }

    static func prune(using snapshot: ClashProxyResp) {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations = presentations.filter { key, _ in
            guard let selector = snapshot.proxiesMap[key.selectorName],
                  selector.type == .select else { return false }
            return selector.all?.contains(key.rowName) == true
        }
    }

    static func clearAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations.removeAll()
    }
}

class ProxyMenuItem: NSMenuItem {
    let proxyName: String
    let maxProxyNameLength: CGFloat
    private let parentGroupName: ClashProxyName
    private let parentGroupType: ClashProxyType
    private let parentConfiguredBenchmarkURL: String?
    private var presentationName: String
    private var selectorBenchmarkPresentation: SelectorBenchmarkPresentation?

    private var parentBenchmarkURL: String {
        parentConfiguredBenchmarkURL ?? Settings.benchMarkUrl
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var enableShowUsingView: Bool {
        MenuItemFactory.useViewToRenderProxy
    }

    init(proxy: ClashProxy,
         group: ClashProxy,
         action selector: Selector?,
         simpleItem: Bool = false) {
        proxyName = proxy.name
        parentGroupName = group.name
        parentGroupType = group.type
        parentConfiguredBenchmarkURL = group.testUrl.flatMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        presentationName = proxy.name

        maxProxyNameLength = simpleItem ? 0 : group.maxProxyNameLength

        super.init(title: proxyName, action: selector, keyEquivalent: "")

        if !simpleItem && enableShowUsingView && group.isSpeedTestable {
            view = ProxyItemView(proxy: proxy)
        } else if !simpleItem {
            attributedTitle = getAttributedTitle(name: proxyName, delay: proxy.history.last?.delayDisplay)
        }
        let selected = group.now == proxy.name
        updateSelected(selected)

        if !simpleItem, group.type == .select {
            updateSelectorBenchmarkPresentation(from: proxy)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(proxyGroupInfoUpdate(note:)), name: .proxyUpdate(for: group.name), object: nil)

        if !simpleItem {
            NotificationCenter.default.addObserver(self, selector: #selector(updateDelayNotification(note:)), name: .speedTestFinishForProxy, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(proxyInfoUpdate(note:)), name: .proxyUpdate(for: proxy.name), object: nil)
        }
    }

    @available(*, unavailable)
    required init(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func didClick() {
        if let action = action {
            _ = target?.perform(action, with: self)
        }
        menu?.cancelTracking()
    }

    @objc private func updateDelayNotification(note: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateDelayNotification(note: note)
            }
            return
        }
        guard let presentation = note.object as? SelectorBenchmarkPresentation,
              presentation.selectorName == parentGroupName,
              presentation.rowName == proxyName else { return }
        applySelectorBenchmarkPresentation(presentation)
    }

    @objc private func proxyInfoUpdate(note: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.proxyInfoUpdate(note: note)
            }
            return
        }
        guard let info = note.object as? ClashProxy else {
            assertionFailure()
            return
        }
        if parentGroupType == .select {
            updateSelectorBenchmarkPresentation(from: info)
            return
        }
        if info.alive == false {
            updateDelay(NSLocalizedString("fail", comment: ""), rawValue: 0)
        } else {
            updateDelay(info.history.last?.delayDisplay, rawValue: info.history.last?.delay)
        }
    }

    @objc private func proxyGroupInfoUpdate(note: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.proxyGroupInfoUpdate(note: note)
            }
            return
        }
        guard let group = note.object as? ClashProxy else { return }
        guard ClashProxyType.isProxyGroup(group) else { return }
        let selected = group.now == proxyName
        updateSelected(selected)
    }

    private func updateSelected(_ selected: Bool) {
        if let v = view as? ProxyItemView {
            v.update(selected: selected)
        } else {
            state = selected ? .on : .off
        }
    }

    private func updateDelay(_ delay: String?, rawValue: Int?) {
        updatePresentation(name: presentationName, delay: delay, rawValue: rawValue)
    }

    private func applySelectorBenchmarkPresentation(
        _ presentation: SelectorBenchmarkPresentation
    ) {
        selectorBenchmarkPresentation = presentation
        presentationName = presentation.rowState.presentationName
        updatePresentation(
            name: presentationName,
            delay: presentation.rowState.delayDisplay,
            rawValue: presentation.rowState.rawDelay
        )
    }

    private func updateSelectorBenchmarkPresentation(from info: ClashProxy) {
        guard let snapshot = info.enclosingResp else {
            updatePresentation(name: proxyName, delay: nil, rawValue: nil)
            return
        }

        if let presentation = SelectorBenchmarkPresentationStore.presentation(
            selectorName: parentGroupName,
            rowName: proxyName,
            currentBenchmarkURL: parentBenchmarkURL,
            snapshot: snapshot
        ) {
            if selectorBenchmarkPresentation?.rowState.rawDelay != nil,
               presentation.rowState.rawDelay == nil {
                Logger.log(
                    "[Proxy Delay] Selector row '\(proxyName)' invalidated because its path or benchmark URL changed",
                    level: .warning
                )
            }
            applySelectorBenchmarkPresentation(presentation)
            return
        }

        selectorBenchmarkPresentation = nil
        presentationName = proxyName
        guard let leaf = finalLeaf(from: info),
              let state = leaf.testState(for: parentBenchmarkURL),
              let history = state.history.last else {
            updatePresentation(name: proxyName, delay: nil, rawValue: nil)
            return
        }
        if !state.alive || history.delay == 0 {
            updatePresentation(
                name: proxyName,
                delay: NSLocalizedString("fail", comment: ""),
                rawValue: 0
            )
        } else {
            updatePresentation(
                name: proxyName,
                delay: history.delayDisplay,
                rawValue: history.delay
            )
        }
    }

    private func finalLeaf(from root: ClashProxy) -> ClashProxy? {
        var current = root
        var visited = Set<ClashProxyName>()

        while ClashProxyType.isProxyGroup(current) {
            guard visited.insert(current.name).inserted,
                  let nextName = current.now,
                  !nextName.isEmpty,
                  let next = current.enclosingResp?.proxiesMap[nextName] else {
                return nil
            }
            current = next
        }

        return current.all == nil ? current : nil
    }

    private func updatePresentation(name: String, delay: String?, rawValue: Int?) {
        if enableShowUsingView {
            (view as? ProxyItemView)?.update(name: name)
            (view as? ProxyItemView)?.update(str: delay, value: rawValue)
        } else {
            attributedTitle = getAttributedTitle(name: name, delay: delay)
        }
    }
}

extension ProxyMenuItem: ProxyGroupMenuHighlightDelegate {
    func highlight(item: NSMenuItem?) {
        (view as? ProxyItemView)?.isHighlighted = item == self
    }
}

extension ProxyMenuItem {
    func getAttributedTitle(name: String, delay: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: 65 + maxProxyNameLength, options: [:])
        ]
        let proxyName = name.replacingOccurrences(of: "\t", with: " ")
        let str: String
        if let delay = delay {
            str = "\(proxyName)\t\(delay)"
        } else {
            str = proxyName.appending(" ")
        }

        let attributed = NSMutableAttributedString(
            string: str,
            attributes: [
                NSAttributedString.Key.paragraphStyle: paragraph,
                NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 14)
            ]
        )

        let hackAttr = [NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 15)]
        attributed.addAttributes(hackAttr, range: NSRange(name.utf16.count ..< name.utf16.count + 1))

        if delay != nil {
            let delayAttr = [NSAttributedString.Key.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
            attributed.addAttributes(delayAttr, range: NSRange(name.utf16.count + 1 ..< str.utf16.count))
        }
        return attributed
    }
}

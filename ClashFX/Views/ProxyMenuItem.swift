//
//  ProxyMenuItem.swift
//  ClashX
//
//  Created by CYC on 2019/2/18.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa

enum GlobalLeafBenchmarkPresentationStore {
    private static var presentations = [LeafProxyBenchmarkIdentity: GlobalLeafBenchmarkPresentation]()

    static func publish(_ presentation: GlobalLeafBenchmarkPresentation) {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations[presentation.identity] = presentation
        NotificationCenter.default.post(
            name: .speedTestFinishForProxy,
            object: presentation
        )
    }

    static func presentation(for proxy: ClashProxy) -> GlobalLeafBenchmarkPresentation? {
        dispatchPrecondition(condition: .onQueue(.main))
        let identity = LeafProxyBenchmarkIdentity(proxy: proxy)
        guard let current = presentations[identity] else { return nil }
        guard let reconciled = current.reconciled(with: proxy) else {
            presentations[identity] = nil
            return nil
        }
        return reconciled
    }

    static func prune(using snapshot: ClashProxyResp) {
        dispatchPrecondition(condition: .onQueue(.main))
        let validIdentities = Set(snapshot.proxies.compactMap { proxy -> LeafProxyBenchmarkIdentity? in
            proxy.all == nil ? LeafProxyBenchmarkIdentity(proxy: proxy) : nil
        })
        presentations = presentations.filter { validIdentities.contains($0.key) }
    }

    static func clearAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations.removeAll()
    }
}

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

enum AutomaticChildBenchmarkStore {
    private struct Key: Hashable {
        let groupName: ClashProxyName
        let rowName: ClashProxyName
    }

    private static var presentations = [Key: AutomaticGroupChildBenchmarkPresentation]()

    static func begin(group: ClashProxy, sessionIdentifier: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        let identity = AutomaticGroupBenchmarkIdentity(
            group: group,
            fallbackBenchmarkURL: Settings.benchMarkUrl
        )
        presentations = presentations.filter { $0.key.groupName != group.name }
        for rowName in identity.members {
            publish(AutomaticGroupChildBenchmarkPresentation(
                identity: identity,
                rowName: rowName,
                sessionIdentifier: sessionIdentifier,
                rowState: .testing(displayName: rowName)
            ))
        }
    }

    static func settle(group: ClashProxy,
                       candidateDelays: [ClashProxyName: Int],
                       sessionIdentifier: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard presentations.contains(where: {
            $0.key.groupName == group.name
                && $0.value.sessionIdentifier == sessionIdentifier
        }) else { return }
        let identity = AutomaticGroupBenchmarkIdentity(
            group: group,
            fallbackBenchmarkURL: Settings.benchMarkUrl
        )
        presentations = presentations.filter { key, presentation in
            key.groupName != group.name
                || (presentation.sessionIdentifier == sessionIdentifier
                    && identity.members.contains(key.rowName))
        }
        for rowName in identity.members {
            let state: ProxyBenchmarkRowState
            if let delay = candidateDelays[rowName] {
                state = delay > 0
                    ? .measured(displayName: rowName, delay: delay)
                    : .failed(displayName: rowName)
            } else {
                state = .unavailable(displayName: rowName)
            }
            publish(AutomaticGroupChildBenchmarkPresentation(
                identity: identity,
                rowName: rowName,
                sessionIdentifier: sessionIdentifier,
                rowState: state
            ))
        }
    }

    static func settleTestingAsUnavailable(groupName: ClashProxyName,
                                           sessionIdentifier: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        let current = presentations.filter {
            $0.key.groupName == groupName
                && $0.value.sessionIdentifier == sessionIdentifier
        }
        for (_, presentation) in current {
            guard case .testing = presentation.rowState else { continue }
            publish(AutomaticGroupChildBenchmarkPresentation(
                identity: presentation.identity,
                rowName: presentation.rowName,
                sessionIdentifier: presentation.sessionIdentifier,
                rowState: .unavailable(displayName: presentation.rowName)
            ))
        }
    }

    static func presentation(group: ClashProxy,
                             rowName: ClashProxyName) -> AutomaticGroupChildBenchmarkPresentation? {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Key(groupName: group.name, rowName: rowName)
        guard let current = presentations[key] else { return nil }
        guard let reconciled = current.reconciled(
            group: group,
            fallbackBenchmarkURL: Settings.benchMarkUrl
        ) else {
            presentations[key] = nil
            return nil
        }
        return reconciled
    }

    static func prune(using snapshot: ClashProxyResp) {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations = presentations.filter { key, presentation in
            guard let group = snapshot.proxiesMap[key.groupName],
                  group.type.isAutoGroup else { return false }
            return presentation.reconciled(
                group: group,
                fallbackBenchmarkURL: Settings.benchMarkUrl
            ) != nil
        }
    }

    static func clearAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations.removeAll()
    }

    private static func publish(_ presentation: AutomaticGroupChildBenchmarkPresentation) {
        let key = Key(
            groupName: presentation.identity.groupName,
            rowName: presentation.rowName
        )
        presentations[key] = presentation
        NotificationCenter.default.post(name: .speedTestFinishForProxy, object: presentation)
    }
}

class ProxyMenuItem: NSMenuItem {
    let proxyName: String
    let maxProxyNameLength: CGFloat
    private let parentGroupName: ClashProxyName
    private let parentGroupType: ClashProxyType
    private let parentConfiguredBenchmarkURL: String?
    private let benchmarkIdentity: LeafProxyBenchmarkIdentity
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
        benchmarkIdentity = LeafProxyBenchmarkIdentity(proxy: proxy)
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
        } else if !simpleItem, group.type.isAutoGroup {
            updateAutomaticChildBenchmarkPresentation(from: proxy)
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
              presentation.rowName == proxyName else {
            guard let presentation = note.object as? AutomaticGroupChildBenchmarkPresentation,
                  presentation.identity.groupName == parentGroupName,
                  presentation.rowName == proxyName else {
                guard let presentation = note.object as? GlobalLeafBenchmarkPresentation,
                      presentation.identity == benchmarkIdentity,
                      ProxyBenchmarkPresentationPolicy.allowsGlobalLeafFallback(
                          in: parentGroupType
                      ) else { return }
                applyGlobalLeafBenchmarkPresentation(presentation)
                return
            }
            applyAutomaticChildBenchmarkPresentation(presentation)
            return
        }
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
        if parentGroupType.isAutoGroup {
            updateAutomaticChildBenchmarkPresentation(from: info)
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
        toolTip = presentation.resolvedLeafName.flatMap {
            $0 == proxyName ? nil : $0
        }
        updatePresentation(
            name: presentationName,
            delay: presentation.rowState.delayDisplay,
            rawValue: presentation.rowState.rawDelay
        )
    }

    private func applyAutomaticChildBenchmarkPresentation(
        _ presentation: AutomaticGroupChildBenchmarkPresentation
    ) {
        presentationName = presentation.rowName
        updatePresentation(
            name: presentation.rowName,
            delay: presentation.rowState.delayDisplay,
            rawValue: presentation.rowState.rawDelay
        )
    }

    private func applyGlobalLeafBenchmarkPresentation(
        _ presentation: GlobalLeafBenchmarkPresentation
    ) {
        presentationName = proxyName
        toolTip = presentation.benchmarkURL == parentBenchmarkURL
            ? nil
            : presentation.benchmarkURL
        updatePresentation(
            name: proxyName,
            delay: presentation.rowState.delayDisplay,
            rawValue: presentation.rowState.rawDelay
        )
    }

    private func updateAutomaticChildBenchmarkPresentation(from info: ClashProxy) {
        guard let snapshot = info.enclosingResp,
              let group = snapshot.proxiesMap[parentGroupName] else {
            updatePresentation(name: proxyName, delay: nil, rawValue: nil)
            return
        }
        let globalPresentation = info.all == nil
            ? GlobalLeafBenchmarkPresentationStore.presentation(for: info)
            : nil
        if let presentation = AutomaticChildBenchmarkStore.presentation(
            group: group,
            rowName: proxyName
        ) {
            if let globalPresentation,
               ProxyBenchmarkPresentationPolicy.prefersGlobal(
                   publishedAt: globalPresentation.publishedAt,
                   over: presentation.publishedAt
               ) {
                applyGlobalLeafBenchmarkPresentation(globalPresentation)
            } else {
                applyAutomaticChildBenchmarkPresentation(presentation)
            }
            return
        }

        presentationName = proxyName
        let evidenceProxy = info.testState(for: parentBenchmarkURL) == nil
            ? (finalLeaf(from: info) ?? info)
            : info
        let state = evidenceProxy.testState(for: parentBenchmarkURL)
        if let globalPresentation,
           globalPresentation.isNewer(than: state) {
            applyGlobalLeafBenchmarkPresentation(globalPresentation)
            return
        }
        guard let state,
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

    private func updateSelectorBenchmarkPresentation(from info: ClashProxy) {
        guard let snapshot = info.enclosingResp else {
            updatePresentation(name: proxyName, delay: nil, rawValue: nil)
            return
        }
        let globalPresentation = info.all == nil
            ? GlobalLeafBenchmarkPresentationStore.presentation(for: info)
            : nil

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
            if case .unavailable = presentation.rowState {
                selectorBenchmarkPresentation = nil
            } else if let globalPresentation,
                      globalPresentation.publishedAt > presentation.publishedAt {
                selectorBenchmarkPresentation = nil
                applyGlobalLeafBenchmarkPresentation(globalPresentation)
                return
            } else {
                applySelectorBenchmarkPresentation(presentation)
                return
            }
        }

        selectorBenchmarkPresentation = nil
        presentationName = proxyName
        toolTip = nil
        guard let leaf = finalLeaf(from: info) else {
            updatePresentation(name: proxyName, delay: nil, rawValue: nil)
            return
        }
        let state = leaf.testState(for: parentBenchmarkURL)
        if let globalPresentation,
           globalPresentation.isNewer(than: state) {
            applyGlobalLeafBenchmarkPresentation(globalPresentation)
            return
        }
        guard let state,
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
        view?.alphaValue = 1
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

//
//  ProxyMenuItem.swift
//  ClashX
//
//  Created by CYC on 2019/2/18.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa

struct ProxyBenchmarkSortMetadata: Equatable {
    let configurationIndex: Int
    let freshDelay: Int?
}

enum ProxyBenchmarkRowSorting {
    static func ordered<Row>(
        _ rows: [Row],
        by order: BenchmarkSortOrder,
        metadata: (Row) -> ProxyBenchmarkSortMetadata
    ) -> [Row] {
        return rows.enumerated().sorted { left, right in
            let leftMetadata = metadata(left.element)
            let rightMetadata = metadata(right.element)

            if order == .latency {
                if let leftDelay = leftMetadata.freshDelay,
                   let rightDelay = rightMetadata.freshDelay,
                   leftDelay != rightDelay {
                    return leftDelay < rightDelay
                }
                if leftMetadata.freshDelay != nil, rightMetadata.freshDelay == nil {
                    return true
                }
                if leftMetadata.freshDelay == nil, rightMetadata.freshDelay != nil {
                    return false
                }
            }

            if leftMetadata.configurationIndex != rightMetadata.configurationIndex {
                return leftMetadata.configurationIndex < rightMetadata.configurationIndex
            }
            return left.offset < right.offset
        }.map { $0.element }
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
                       hasProbeEvidence: Bool,
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
            let proxy = group.enclosingResp?.proxiesMap[rowName]
            if rowName == "COMPATIBLE" || proxy.map(ClashProxyType.isCompatibilityFallback) == true {
                state = .unavailable(displayName: rowName)
            } else if let delay = candidateDelays[rowName] {
                state = delay > 0
                    ? .measured(displayName: rowName, delay: delay)
                    : .failed(displayName: rowName)
            } else {
                state = hasProbeEvidence ? .failed(displayName: rowName) : .unavailable(displayName: rowName)
            }
            if let proxy, proxy.all == nil, !ClashProxyType.isCompatibilityFallback(proxy) {
                GlobalLeafBenchmarkPresentationStore.publish(GlobalLeafBenchmarkPresentation(
                    identity: LeafProxyBenchmarkIdentity(proxy: proxy),
                    benchmarkURL: identity.benchmarkURL, expectedStatus: identity.expectedStatus,
                    sessionIdentifier: sessionIdentifier, rowState: state
                ))
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
    let isSortableProxyRow: Bool
    private let parentGroupName: ClashProxyName
    private let parentGroupType: ClashProxyType
    private var presentationName: String
    private var latestProxy: ClashProxy
    private var latestSnapshot: ClashProxyResp?
    private(set) var configurationSortIndex: Int?
    private var freshBenchmarkSortDelay: Int?

    var benchmarkSortMetadata: ProxyBenchmarkSortMetadata {
        ProxyBenchmarkSortMetadata(
            configurationIndex: configurationSortIndex ?? Int.max,
            freshDelay: freshBenchmarkSortDelay
        )
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
        isSortableProxyRow = !simpleItem && group.isSpeedTestable
        latestProxy = proxy
        latestSnapshot = proxy.enclosingResp
        presentationName = proxy.name

        maxProxyNameLength = simpleItem ? 0 : group.maxProxyNameLength

        super.init(title: proxyName, action: selector, keyEquivalent: "")

        if !simpleItem && enableShowUsingView && group.isSpeedTestable {
            view = ProxyItemView(proxy: proxy)
        } else if !simpleItem {
            attributedTitle = getAttributedTitle(
                name: proxyName,
                delay: proxy.history.last?.delayDisplay,
                rawValue: proxy.history.last?.delay
            )
        }
        let selected = group.now == proxy.name
        updateSelected(selected)

        if !simpleItem, group.type == .select {
            refreshBenchmark(from: proxy)
        } else if !simpleItem, group.type.isAutoGroup {
            refreshBenchmark(from: proxy)
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

    func captureConfigurationSortIndex(_ index: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard configurationSortIndex == nil else { return }
        configurationSortIndex = index
    }

    @objc private func updateDelayNotification(note: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateDelayNotification(note: note)
            }
            return
        }
        if let presentation = note.object as? SelectorBenchmarkPresentation {
            guard presentation.selectorName == parentGroupName, presentation.rowName == proxyName else { return }
        } else if let presentation = note.object as? AutomaticGroupChildBenchmarkPresentation {
            guard presentation.identity.groupName == parentGroupName, presentation.rowName == proxyName else { return }
        } else if let presentation = note.object as? GlobalLeafBenchmarkPresentation {
            guard let leaf = finalLeaf(from: latestProxy),
                  presentation.identity == LeafProxyBenchmarkIdentity(proxy: leaf),
                  ProxyBenchmarkPresentationPolicy.allowsGlobalLeafFallback(in: parentGroupType) else { return }
        } else {
            return
        }
        refreshBenchmark(from: latestProxy)
    }

    @objc private func proxyInfoUpdate(note: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.proxyInfoUpdate(note: note)
            }
            return
        }
        // Automatic-group progress shares this notification name with core
        // snapshots. A nested Selector row also observes that group: progress
        // is not a replacement ClashProxy and must not trigger an assertion.
        guard let info = note.object as? ClashProxy else { return }
        if parentGroupType == .select {
            refreshBenchmark(from: info)
            return
        }
        if parentGroupType.isAutoGroup {
            refreshBenchmark(from: info)
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
        if let snapshot = group.enclosingResp,
           let proxy = snapshot.proxiesMap[proxyName],
           parentGroupType == .select || parentGroupType.isAutoGroup {
            latestSnapshot = snapshot
            refreshBenchmark(from: proxy)
        }
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

    private func refreshBenchmark(from info: ClashProxy) {
        dispatchPrecondition(condition: .onQueue(.main))
        latestProxy = info
        if let snapshot = info.enclosingResp { latestSnapshot = snapshot }
        guard let snapshot = latestSnapshot,
              let group = snapshot.proxiesMap[parentGroupName] else { return }
        let conditions = BenchmarkConditions(
            url: group.effectiveBenchmarkURL(fallback: Settings.benchMarkUrl),
            expectedStatus: group.type.isAutoGroup ? group.expectedStatus : nil
        )
        let resolution = snapshot.resolveSelectedPath(from: proxyName)
        let isFallback: Bool
        if case .unavailable(_, .compatibilityFallback) = resolution { isFallback = true } else { isFallback = false }
        if isFallback || !snapshot.hasBenchmarkCandidates(in: proxyName) {
            // Never let old group/leaf history turn an empty regional group
            // into a successful proxy measurement through core direct fallback.
            presentationName = proxyName
            let message = NSLocalizedString(isFallback ? "Direct fallback (no proxy nodes)" : "No testable proxy nodes", comment: "")
            freshBenchmarkSortDelay = nil
            updateBenchmarkToolTip(nil)
            updatePresentation(name: proxyName, delay: message, rawValue: nil)
            return
        }
        var contextual: BenchmarkRowResolver.Evidence?
        var freshMeasurementDates = [Date]()
        if group.type == .select,
           let presentation = SelectorBenchmarkPresentationStore.presentation(
               selectorName: parentGroupName, rowName: proxyName,
               currentBenchmarkURL: conditions.url, snapshot: snapshot
           ) {
            contextual = .init(state: presentation.rowState, measuredAt: presentation.publishedAt)
            if !presentation.isStale, (presentation.rowState.rawDelay ?? 0) > 0 {
                freshMeasurementDates.append(presentation.publishedAt)
            }
        } else if group.type.isAutoGroup,
                  let presentation = AutomaticChildBenchmarkStore.presentation(group: group, rowName: proxyName) {
            contextual = .init(state: presentation.rowState, measuredAt: presentation.publishedAt)
            if !presentation.isStale, (presentation.rowState.rawDelay ?? 0) > 0 {
                freshMeasurementDates.append(presentation.publishedAt)
            }
        }

        let leaf = finalLeaf(from: info)
        let cached = leaf.flatMap {
            GlobalLeafBenchmarkPresentationStore.presentation(for: $0, conditions: conditions)
        }
        if let cached, !cached.isStale, (cached.rowState.rawDelay ?? 0) > 0 {
            freshMeasurementDates.append(cached.publishedAt)
        }
        let attempt = leaf.flatMap {
            GlobalLeafBenchmarkPresentationStore.attempt(for: $0, conditions: conditions)
        }
        let globalActivity = attempt.map {
            BenchmarkRowResolver.Evidence(state: $0.rowState, measuredAt: $0.publishedAt)
        }
        let activity = [contextual, globalActivity].compactMap { $0 }
            .max { $0.measuredAt < $1.measuredAt }
        // Core extra history is URL-scoped, but exposes no expected-status
        // provenance. Only our explicit retest evidence can certify that case.
        let core = conditions.expectedStatus == nil ? leaf?.testState(for: conditions.url) : nil
        let presentation = BenchmarkRowResolver.resolve(
            name: proxyName, core: core,
            cached: cached.map { .init(state: $0.rowState, measuredAt: $0.publishedAt) },
            contextual: contextual, activity: activity
        )
        if !presentation.isHistorical,
           !presentation.lastAttemptUnavailable,
           let measuredAt = presentation.measuredAt,
           freshMeasurementDates.contains(measuredAt),
           case let .measured(_, delay) = presentation.state,
           delay > 0 {
            freshBenchmarkSortDelay = delay
        } else {
            freshBenchmarkSortDelay = nil
        }
        presentationName = proxyName
        var tooltip = [String]()
        if let leaf, leaf.name != proxyName { tooltip.append(leaf.name) }
        tooltip.append(conditions.url)
        if let date = presentation.measuredAt {
            let timestamp = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
            tooltip.append(String(format: NSLocalizedString("Measured at: %@", comment: ""), timestamp))
        }
        if presentation.isHistorical {
            tooltip.append(NSLocalizedString("Historical benchmark result", comment: ""))
        }
        if presentation.lastAttemptUnavailable {
            tooltip.append(NSLocalizedString("Latest benchmark unavailable; showing the last measurement", comment: ""))
        }
        if case .testing = presentation.state {
            updateBenchmarkToolTip(nil)
        } else {
            updateBenchmarkToolTip(presentation.measuredAt == nil ? nil : tooltip.joined(separator: "\n"))
        }
        var delay = presentation.state.delayDisplay
        if presentation.measuredAt == nil, activity == nil {
            delay = NSLocalizedString("Not tested", comment: "")
        }
        delay = BenchmarkRowDelayPresentation.applyingHistoryMarker(
            to: delay,
            isHistorical: presentation.isHistorical,
            localizedFormat: NSLocalizedString(
                "Benchmark result with historical marker",
                value: "%@ (previous)",
                comment: "Format for a benchmark result that is historical"
            )
        )
        updatePresentation(name: proxyName, delay: delay, rawValue: presentation.state.rawDelay)
    }

    private func finalLeaf(from root: ClashProxy) -> ClashProxy? {
        guard let snapshot = root.enclosingResp ?? latestSnapshot,
              case let .resolved(_, leaf) = snapshot.resolveSelectedPath(from: root.name) else { return nil }
        return leaf
    }

    private func updateBenchmarkToolTip(_ details: String?) {
        // Native text-only menu items cannot restrict their tooltip to the
        // delay suffix. Do not fall back to a disruptive whole-row tooltip.
        toolTip = nil
        (view as? ProxyItemView)?.delayLabel.toolTip = details
    }

    private func updatePresentation(name: String, delay: String?, rawValue: Int?) {
        view?.alphaValue = 1
        if enableShowUsingView {
            (view as? ProxyItemView)?.update(name: name)
            (view as? ProxyItemView)?.update(str: delay, value: rawValue)
        } else {
            attributedTitle = getAttributedTitle(name: name, delay: delay, rawValue: rawValue)
        }
    }
}

extension ProxyMenuItem: ProxyGroupMenuHighlightDelegate {
    func highlight(item: NSMenuItem?) {
        (view as? ProxyItemView)?.isHighlighted = item == self
    }
}

extension ProxyMenuItem {
    func getAttributedTitle(name: String, delay: String?, rawValue: Int? = nil) -> NSAttributedString {
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
            let delayAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: ProxyBenchmarkDelayColorCategory.labelColor(for: rawValue)
            ]
            attributed.addAttributes(delayAttr, range: NSRange(name.utf16.count + 1 ..< str.utf16.count))
        }
        return attributed
    }
}

//
//  ProxyGroupMenuItemView.swift
//  ClashX
//

import Cocoa

struct AutomaticGroupBenchmarkPresentation {
    private static let freshCacheAge: TimeInterval = 30 * 60

    let identity: AutomaticGroupBenchmarkIdentity
    let selectedPath: [ClashProxyName]
    let finalLeaf: ClashProxyName?
    let finalLeafID: String?
    let sessionIdentifier: UUID
    let rowState: ProxyBenchmarkRowState
    let publishedAt: Date

    var groupName: ClashProxyName {
        return identity.groupName
    }

    var isStale: Bool {
        return Date().timeIntervalSince(publishedAt) > Self.freshCacheAge
    }

    init(identity: AutomaticGroupBenchmarkIdentity,
         selectedPath: [ClashProxyName],
         finalLeaf: ClashProxyName?,
         finalLeafID: String? = nil,
         sessionIdentifier: UUID,
         rowState: ProxyBenchmarkRowState,
         publishedAt: Date = .init()) {
        self.identity = identity
        self.selectedPath = selectedPath
        self.finalLeaf = finalLeaf
        self.finalLeafID = finalLeafID
        self.sessionIdentifier = sessionIdentifier
        self.rowState = rowState
        self.publishedAt = publishedAt
    }

    func isValid(for group: ClashProxy) -> Bool {
        return finalLeaf.flatMap { group.enclosingResp?.proxiesMap[$0]?.id } == finalLeafID
            && identity == AutomaticGroupBenchmarkIdentity(
                group: group,
                fallbackBenchmarkURL: Settings.benchMarkUrl
            )
    }
}

/// Retains a single automatic-group result across the terminal menu rebuild.
/// This store is deliberately main-queue-only because it is an AppKit presentation owner.
enum AutomaticGroupBenchmarkPresentationStore {
    private static var presentations = [ClashProxyName: AutomaticGroupBenchmarkPresentation]()

    static func begin(group: ClashProxy, sessionIdentifier: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        let path = selectedPath(for: group)
        let presentation = AutomaticGroupBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(
                group: group,
                fallbackBenchmarkURL: Settings.benchMarkUrl
            ),
            selectedPath: path,
            finalLeaf: path.last,
            finalLeafID: path.last.flatMap { group.enclosingResp?.proxiesMap[$0]?.id },
            sessionIdentifier: sessionIdentifier,
            rowState: .testing(displayName: displayName(groupName: group.name, finalLeaf: path.last))
        )
        publish(presentation)
    }

    static func publish(_ presentation: AutomaticGroupBenchmarkPresentation) {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations[presentation.groupName] = presentation
        NotificationCenter.default.post(
            name: .proxyUpdate(for: presentation.groupName),
            object: presentation
        )
    }

    static func settleTestingAsUnavailable(groupName: ClashProxyName,
                                           finalLeaf: ClashProxyName?,
                                           sessionIdentifier: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let presentation = presentations[groupName] else { return }
        guard presentation.sessionIdentifier == sessionIdentifier else { return }
        guard case .testing = presentation.rowState else { return }
        publish(AutomaticGroupBenchmarkPresentation(
            identity: presentation.identity,
            selectedPath: presentation.selectedPath,
            finalLeaf: finalLeaf ?? presentation.finalLeaf,
            finalLeafID: presentation.finalLeafID,
            sessionIdentifier: presentation.sessionIdentifier,
            rowState: .unavailable(displayName: displayName(
                groupName: groupName,
                finalLeaf: finalLeaf ?? presentation.finalLeaf
            ))
        ))
    }

    static func reconcile(group: ClashProxy) -> AutomaticGroupBenchmarkPresentation? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let current = presentations[group.name] else { return nil }
        guard current.isValid(for: group) else {
            presentations[group.name] = nil
            Logger.log(
                "[Proxy Delay] Automatic group '\(group.name)' discarded stale or mismatched benchmark evidence",
                level: .warning
            )
            return nil
        }
        let path = selectedPath(for: group)
        guard path == current.selectedPath else {
            let finalLeaf = path.last ?? current.finalLeaf
            let replacement: ProxyBenchmarkRowState
            switch current.rowState {
            case .testing:
                replacement = .testing(displayName: displayName(groupName: group.name, finalLeaf: finalLeaf))
            case .measured, .failed, .timedOut, .unavailable:
                Logger.log(
                    "[Proxy Delay] Automatic group '\(group.name)' changed its selected path without current-run evidence",
                    level: .warning
                )
                replacement = .unavailable(displayName: displayName(groupName: group.name, finalLeaf: finalLeaf))
            }
            let presentation = AutomaticGroupBenchmarkPresentation(
                identity: current.identity,
                selectedPath: path,
                finalLeaf: finalLeaf,
                finalLeafID: group.enclosingResp?.proxiesMap[finalLeaf ?? ""]?.id,
                sessionIdentifier: current.sessionIdentifier,
                rowState: replacement
            )
            presentations[group.name] = presentation
            return presentation
        }
        return current
    }

    static func prune(using snapshot: ClashProxyResp) {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations = presentations.filter { groupName, presentation in
            guard let group = snapshot.proxiesMap[groupName],
                  group.type.isAutoGroup else { return false }
            return presentation.isValid(for: group)
        }
    }

    static func clearAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        presentations.removeAll()
    }

    private static func selectedPath(for group: ClashProxy) -> [ClashProxyName] {
        guard let snapshot = group.enclosingResp else {
            return group.now.map { [group.name, $0] } ?? [group.name]
        }
        switch snapshot.resolveSelectedPath(from: group.name) {
        case let .resolved(path, _), let .unavailable(path, _):
            return path
        }
    }

    private static func displayName(groupName: ClashProxyName,
                                    finalLeaf: ClashProxyName?) -> String {
        guard let finalLeaf, finalLeaf != groupName else { return groupName }
        return "\(groupName) → \(finalLeaf)"
    }
}

class ProxyGroupMenuItemView: MenuItemBaseView {
    private let groupName: ClashProxyName
    private var latestGroup: ClashProxy
    private var latestSnapshot: ClashProxyResp?
    private let groupNameLabel: NSTextField
    private let selectProxyLabel: NSTextField
    let delayLabel = VibrancyTextField(labelWithString: "")
    private var delaySpacingConstraint: NSLayoutConstraint?
    private let arrowLabel: NSControl = {
        if #available(macOS 11, *) {
            let image = NSImage(named: NSImage.goForwardTemplateName)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .bold, scale: .small))!
            return NSImageView(image: image)
        } else {
            let label = NSTextField(labelWithString: "▶")
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.textColor = NSColor.labelColor
            return label
        }
    }()

    private var leftPaddingConstraint: NSLayoutConstraint?
    private let leftPadding: CGFloat = 20

    override var cells: [NSCell?] {
        return [groupNameLabel.cell, selectProxyLabel.cell, delayLabel.cell, arrowLabel.cell]
    }

    init(proxyGroup: ClashProxy, targetProxy: ClashProxyName, hasLeftPadding: Bool) {
        groupName = proxyGroup.name
        latestGroup = proxyGroup
        latestSnapshot = proxyGroup.enclosingResp
        groupNameLabel = VibrancyTextField(labelWithString: proxyGroup.name)
        selectProxyLabel = VibrancyTextField(labelWithString: targetProxy)
        super.init(autolayout: true)

        effectView.addSubview(arrowLabel)
        arrowLabel.translatesAutoresizingMaskIntoConstraints = false
        let rightConstraint: CGFloat = {
            if #available(macOS 11, *) { return -8 }
            return -10
        }()
        arrowLabel.rightAnchor.constraint(equalTo: effectView.rightAnchor, constant: rightConstraint).isActive = true
        arrowLabel.centerYAnchor.constraint(equalTo: effectView.centerYAnchor).isActive = true

        groupNameLabel.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(groupNameLabel)
        leftPaddingConstraint = groupNameLabel.leftAnchor.constraint(equalTo: effectView.leftAnchor, constant: leftPadding)
        leftPaddingConstraint?.isActive = true
        groupNameLabel.centerYAnchor.constraint(equalTo: effectView.centerYAnchor).isActive = true
        groupNameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        selectProxyLabel.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(selectProxyLabel)
        delayLabel.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(delayLabel)
        delayLabel.rightAnchor.constraint(equalTo: effectView.rightAnchor, constant: -30).isActive = true
        delayLabel.centerYAnchor.constraint(equalTo: effectView.centerYAnchor).isActive = true
        delayLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        delayLabel.setContentHuggingPriority(.required, for: .horizontal)
        delaySpacingConstraint = delayLabel.leftAnchor.constraint(equalTo: selectProxyLabel.rightAnchor)
        delaySpacingConstraint?.isActive = true
        selectProxyLabel.centerYAnchor.constraint(equalTo: effectView.centerYAnchor).isActive = true
        delayLabel.lineBreakMode = .byTruncatingTail
        selectProxyLabel.lineBreakMode = .byTruncatingMiddle
        selectProxyLabel.leftAnchor.constraint(greaterThanOrEqualTo: groupNameLabel.rightAnchor, constant: 20).isActive = true

        effectView.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        if #available(macOS 14, *) {
            delayLabel.rightAnchor.constraint(lessThanOrEqualTo: selectProxyLabel.leftAnchor, constant: 200).isActive = true
        } else {
            effectView.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        }
        groupNameLabel.font = type(of: self).labelFont
        selectProxyLabel.font = type(of: self).labelFont
        delayLabel.font = type(of: self).labelFont
        groupNameLabel.textColor = NSColor.labelColor
        selectProxyLabel.textColor = NSColor.secondaryLabelColor
        delayLabel.textColor = NSColor.secondaryLabelColor

        NotificationCenter.default.addObserver(self, selector: #selector(proxyInfoDidUpdate(note:)), name: .proxyUpdate(for: proxyGroup.name), object: nil)
        if !showMissingCandidates(proxyGroup) {
            if let selection = selectionPresentation(for: proxyGroup) {
                renderSelection(selection)
            }
            if proxyGroup.type.isAutoGroup,
               let presentation = AutomaticGroupBenchmarkPresentationStore.reconcile(group: proxyGroup) {
                render(presentation)
            }
        }
        if #available(macOS 11, *) {
            updateLeftMenuPadding(show: hasLeftPadding)
            NotificationCenter.default.addObserver(self, selector: #selector(showLeftPaddingUpdate(note:)), name: .proxyMeneViewShowLeftPadding, object: nil)
        }
    }

    private func updateLeftMenuPadding(show: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        leftPaddingConstraint?.constant = show ? leftPadding : 10
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func proxyInfoDidUpdate(note: NSNotification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.proxyInfoDidUpdate(note: note) }
            return
        }
        if let presentation = note.object as? AutomaticGroupBenchmarkPresentation {
            guard presentation.groupName == groupName else { return }
            render(presentation)
            return
        }
        guard let info = note.object as? ClashProxy, info.name == groupName else { return }
        latestGroup = info
        latestSnapshot = info.enclosingResp
        if showMissingCandidates(info) { return }
        if info.type.isAutoGroup,
           let presentation = AutomaticGroupBenchmarkPresentationStore.reconcile(group: info) {
            render(presentation)
            return
        }
        clearBenchmarkDetails()
        if let selection = selectionPresentation(for: info) {
            renderSelection(selection)
        } else {
            renderLegacySelection(info.now ?? "")
        }
    }

    private func render(_ presentation: AutomaticGroupBenchmarkPresentation) {
        dispatchPrecondition(condition: .onQueue(.main))
        clearBenchmarkDetails()
        effectView.alphaValue = 1
        let group = latestSnapshot?.proxiesMap[groupName] ?? latestGroup
        if showMissingCandidates(group) { return }

        let selection = selectionPresentation(for: group)
        let leaf: ClashProxyName
        if let selection {
            renderSelection(selection)
            guard selection.isResolved else { return }
            guard let resolvedLeaf = selection.leaf else { return }
            leaf = resolvedLeaf
        } else {
            guard let latestSnapshot,
                  case let .resolved(_, resolvedLeaf) = latestSnapshot.resolveSelectedPath(from: groupName) else { return }
            leaf = resolvedLeaf.name
            renderLegacySelection("\(leaf) ·")
        }
        let conditions = BenchmarkConditions(url: presentation.identity.benchmarkURL,
                                             expectedStatus: presentation.identity.expectedStatus)
        let proxy = latestSnapshot?.proxiesMap[leaf]
        let cached = proxy.flatMap { GlobalLeafBenchmarkPresentationStore.presentation(for: $0, conditions: conditions) }
        let benchmarkMatchesRoute = presentation.finalLeaf == leaf && presentation.isValid(for: group)
        let benchmarkEvidence: BenchmarkRowResolver.Evidence? = benchmarkMatchesRoute
            ? BenchmarkRowResolver.Evidence(state: presentation.rowState, measuredAt: presentation.publishedAt)
            : nil
        let resolved = BenchmarkRowResolver.resolve(
            name: leaf, core: conditions.expectedStatus == nil ? proxy?.testState(for: conditions.url) : nil,
            cached: cached.map { .init(state: $0.rowState, measuredAt: $0.publishedAt) },
            contextual: benchmarkEvidence,
            activity: benchmarkEvidence
        )
        delayLabel.stringValue = BenchmarkRowDelayPresentation.applyingHistoryMarker(
            to: resolved.state.delayDisplay,
            isHistorical: resolved.isHistorical,
            localizedFormat: NSLocalizedString(
                "Benchmark result with historical marker",
                value: "%@ · old",
                comment: "Format for a benchmark result that is historical"
            )
        ) ?? ""
        delayLabel.textColor = ProxyBenchmarkDelayColorCategory.labelColor(for: resolved.state.rawDelay)
        delaySpacingConstraint?.constant = 4
        let details = BenchmarkFailurePresentation.details(for: resolved, conditions: conditions, proxy: proxy)
        if case .testing = resolved.state { return }
        delayLabel.toolTip = resolved.measuredAt == nil ? nil : details
    }

    private func clearBenchmarkDetails() {
        dispatchPrecondition(condition: .onQueue(.main))
        toolTip = nil
        delayLabel.toolTip = nil
        delayLabel.stringValue = ""
        delaySpacingConstraint?.constant = 0
    }

    private func showMissingCandidates(_ group: ClashProxy) -> Bool {
        guard let snapshot = group.enclosingResp ?? latestSnapshot else { return false }
        let isFallback: Bool
        if case .unavailable(_, .compatibilityFallback) = snapshot.resolveSelectedPath(from: group.name) {
            isFallback = true
        } else {
            isFallback = false
        }
        guard isFallback || !snapshot.hasBenchmarkCandidates(in: group.name) else { return false }
        renderLegacySelection(NSLocalizedString(isFallback ? "Direct fallback (no proxy nodes)" : "No testable proxy nodes", comment: ""))
        clearBenchmarkDetails()
        return true
    }

    private func selectionPresentation(for group: ClashProxy) -> ProxyGroupSelectionPresentation? {
        return ProxyGroupSelectionPresentation(group: group, snapshot: latestSnapshot)
    }

    private func renderSelection(_ presentation: ProxyGroupSelectionPresentation) {
        dispatchPrecondition(condition: .onQueue(.main))
        let modeTitle: String
        switch presentation.mode {
        case .manual:
            modeTitle = ""
        case .automatic:
            modeTitle = NSLocalizedString("Automatic Selection", value: "Auto", comment: "Short menu label for automatic selection")
        case .manualPriority:
            modeTitle = NSLocalizedString("Manual Priority", value: "Priority", comment: "Short menu label for manual priority")
        case .unknownAutomatic:
            modeTitle = NSLocalizedString("Core-managed Selection", value: "Core choice", comment: "Short menu label when selection mode is unknown")
        }
        let label = presentation.leaf.map { modeTitle.isEmpty ? $0 : "\(modeTitle) · \($0)" } ?? modeTitle
        selectProxyLabel.stringValue = label
        selectProxyLabel.setAccessibilityLabel(label)

        var details = [String]()
        if presentation.isResolved, !presentation.path.isEmpty {
            details.append(String(
                format: NSLocalizedString(
                    "Actual route: %@",
                    value: "Actual route: %@",
                    comment: "Tooltip and accessibility route for a proxy group"
                ),
                presentation.path.joined(separator: " → ")
            ))
        }
        if let preferredTarget = presentation.preferredTarget {
            details.append(String(
                format: NSLocalizedString(
                    "Preferred node: %@",
                    value: "Preferred node: %@",
                    comment: "Configured preferred node for a proxy group"
                ),
                preferredTarget
            ))
        }
        if !presentation.isResolved {
            details.append(NSLocalizedString(
                "Actual route could not be fully resolved",
                value: "Actual route could not be fully resolved",
                comment: "Accessibility status when the core route is incomplete"
            ))
        }
        let help = details.isEmpty ? nil : details.joined(separator: "\n")
        selectProxyLabel.toolTip = help
        selectProxyLabel.setAccessibilityHelp(help)
    }

    private func renderLegacySelection(_ title: String) {
        selectProxyLabel.stringValue = title
        selectProxyLabel.toolTip = nil
        selectProxyLabel.setAccessibilityLabel(title)
        selectProxyLabel.setAccessibilityHelp(nil)
    }

    @objc private func showLeftPaddingUpdate(note: NSNotification) {
        guard let show = note.userInfo?["show"] as? Bool else { assertionFailure(); return }
        updateLeftMenuPadding(show: show)
    }
}

extension ProxyGroupMenuItemView: ProxyGroupMenuHighlightDelegate {
    func highlight(item: NSMenuItem?) {
        isHighlighted = item == enclosingMenuItem
    }
}

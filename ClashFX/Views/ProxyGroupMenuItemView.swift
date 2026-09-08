//
//  ProxyGroupMenuItemView.swift
//  ClashX
//

import Cocoa

struct AutomaticGroupBenchmarkPresentation {
    private static let freshCacheAge: TimeInterval = 30 * 60
    private static let maximumCacheAge: TimeInterval = 24 * 60 * 60

    let identity: AutomaticGroupBenchmarkIdentity
    let selectedPath: [ClashProxyName]
    let finalLeaf: ClashProxyName?
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
         sessionIdentifier: UUID,
         rowState: ProxyBenchmarkRowState,
         publishedAt: Date = .init()) {
        self.identity = identity
        self.selectedPath = selectedPath
        self.finalLeaf = finalLeaf
        self.sessionIdentifier = sessionIdentifier
        self.rowState = rowState
        self.publishedAt = publishedAt
    }

    func isValid(for group: ClashProxy) -> Bool {
        return Date().timeIntervalSince(publishedAt) <= Self.maximumCacheAge
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
            case .measured, .failed, .unavailable:
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
    private let groupNameLabel: NSTextField
    private let selectProxyLabel: NSTextField
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
        return [groupNameLabel.cell, selectProxyLabel.cell, arrowLabel.cell]
    }

    init(proxyGroup: ClashProxy, targetProxy: ClashProxyName, hasLeftPadding: Bool) {
        groupName = proxyGroup.name
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
        selectProxyLabel.rightAnchor.constraint(equalTo: effectView.rightAnchor, constant: -30).isActive = true
        selectProxyLabel.centerYAnchor.constraint(equalTo: effectView.centerYAnchor).isActive = true
        selectProxyLabel.lineBreakMode = .byTruncatingHead
        selectProxyLabel.leftAnchor.constraint(greaterThanOrEqualTo: groupNameLabel.rightAnchor, constant: 20).isActive = true

        effectView.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        if #available(macOS 14, *) {
            selectProxyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        } else {
            effectView.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        }
        groupNameLabel.font = type(of: self).labelFont
        selectProxyLabel.font = type(of: self).labelFont
        groupNameLabel.textColor = NSColor.labelColor
        selectProxyLabel.textColor = NSColor.secondaryLabelColor

        NotificationCenter.default.addObserver(self, selector: #selector(proxyInfoDidUpdate(note:)), name: .proxyUpdate(for: proxyGroup.name), object: nil)
        if proxyGroup.type.isAutoGroup,
           let presentation = AutomaticGroupBenchmarkPresentationStore.reconcile(group: proxyGroup) {
            render(presentation)
        }
        if #available(macOS 11, *) {
            updateLeftMenuPadding(show: hasLeftPadding)
            NotificationCenter.default.addObserver(self, selector: #selector(showLeftPaddingUpdate(note:)), name: .proxyMeneViewShowLeftPadding, object: nil)
        }
    }

    private func updateLeftMenuPadding(show: Bool) {
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
        if info.type.isAutoGroup,
           let presentation = AutomaticGroupBenchmarkPresentationStore.reconcile(group: info) {
            render(presentation)
            return
        }
        selectProxyLabel.stringValue = info.now ?? ""
    }

    private func render(_ presentation: AutomaticGroupBenchmarkPresentation) {
        effectView.alphaValue = 1
        let leaf = presentation.finalLeaf ?? presentation.rowState.presentationName
        if let result = presentation.rowState.delayDisplay {
            selectProxyLabel.stringValue = "\(leaf) · \(result)"
        } else {
            selectProxyLabel.stringValue = leaf
        }
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

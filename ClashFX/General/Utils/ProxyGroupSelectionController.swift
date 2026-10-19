import AppKit

/// Owns the user initiated selection flow for one proxy group. Core snapshots
/// remain the only source of checkmark state.
final class ProxyGroupSelectionController: NSObject, NSMenuItemValidation {
    private static let registry = NSHashTable<ProxyGroupSelectionController>.weakObjects()
    /// A menu rebuild can release the old submenu while its PUT is still in
    /// flight. Keep that controller alive until its callback or timeout settles
    /// so another interaction cannot overlap the physical mutation.
    private static var activeOperationOwners = [UUID: ProxyGroupSelectionController]()

    static var isAnyOperationInProgress: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return !activeOperationOwners.isEmpty
    }

    /// Invalidates every currently displayed selection menu. An active API
    /// mutation keeps its global operation lease until its callback or timeout.
    static func invalidateAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        registry.allObjects.forEach { $0.invalidate() }
    }

    struct Dependencies {
        let isCurrent: () -> Bool
        let isCoreChanging: () -> Bool
        let isBusyBenchmark: () -> Bool
        let isInteractionReserved: () -> Bool
        let select: (_ group: String, _ name: String, _ completion: @escaping (Bool) -> Void) -> Void
        let reset: (_ group: String, _ completion: @escaping (Bool) -> Void) -> Void
        let refresh: (_ completion: @escaping (ClashProxyResp?) -> Void) -> Void
        let publish: (_ snapshot: ClashProxyResp) -> Void
        let rememberSelection: (_ group: String, _ name: String) -> Void
        let closeConnections: () -> Void
        let showError: (_ message: String) -> Void
        let stageTimeout: TimeInterval

        init(
            isCurrent: @escaping () -> Bool,
            isCoreChanging: @escaping () -> Bool,
            isBusyBenchmark: @escaping () -> Bool,
            isInteractionReserved: @escaping () -> Bool = { false },
            select: @escaping (_ group: String, _ name: String, _ completion: @escaping (Bool) -> Void) -> Void,
            reset: @escaping (_ group: String, _ completion: @escaping (Bool) -> Void) -> Void,
            refresh: @escaping (_ completion: @escaping (ClashProxyResp?) -> Void) -> Void,
            publish: @escaping (_ snapshot: ClashProxyResp) -> Void,
            rememberSelection: @escaping (_ group: String, _ name: String) -> Void,
            closeConnections: @escaping () -> Void,
            showError: @escaping (_ message: String) -> Void,
            stageTimeout: TimeInterval = 10
        ) {
            self.isCurrent = isCurrent
            self.isCoreChanging = isCoreChanging
            self.isBusyBenchmark = isBusyBenchmark
            self.isInteractionReserved = isInteractionReserved
            self.select = select
            self.reset = reset
            self.refresh = refresh
            self.publish = publish
            self.rememberSelection = rememberSelection
            self.closeConnections = closeConnections
            self.showError = showError
            self.stageTimeout = stageTimeout
        }
    }

    private enum Intent {
        case select(String)
        case reset
    }

    private enum StageOutcome: Equatable {
        case success
        case failure
        case timedOut
    }

    private enum ReadbackOutcome {
        case snapshot(ClashProxyResp)
        case unavailable
        case timedOut
    }

    private enum Stage: Equatable {
        case mutating
        case readback
    }

    private struct Operation {
        let id: UUID
        let controllerGeneration: UInt64
        let intent: Intent
        var stage: Stage
    }

    private let groupName: String
    private let groupType: ClashProxyType
    private let groupID: String?
    private let members: Set<String>
    private let dependencies: Dependencies
    private var controllerGeneration: UInt64 = 0
    private var isInvalidated = false
    private var activeOperation: Operation?
    private var activeStageID: UUID?
    private var activeStageSettlement: ManagedOperationSettlement<StageOutcome>?
    private var candidateItems = [String: ProxyMenuItem]()
    private(set) var proxyGroup: ClashProxy
    private(set) var proxySnapshot: ClashProxyResp
    private(set) var restoreAutomaticItem: NSMenuItem?

    var isOperationInProgress: Bool {
        activeOperation != nil
    }

    init(group: ClashProxy, snapshot: ClashProxyResp, dependencies: Dependencies) {
        groupName = group.name
        groupType = group.type
        groupID = group.id
        members = Set(group.all ?? [])
        proxyGroup = group
        proxySnapshot = snapshot
        self.dependencies = dependencies
        super.init()

        if group.supportsManualPriority {
            let item = NSMenuItem(
                title: NSLocalizedString("Restore Automatic Selection", comment: ""),
                action: #selector(restoreAutomaticSelection(sender:)),
                keyEquivalent: ""
            )
            item.target = self
            restoreAutomaticItem = item
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(proxyGroupUpdated(_:)),
            name: .proxyUpdate(for: group.name),
            object: nil
        )
        dispatchPrecondition(condition: .onQueue(.main))
        Self.registry.add(self)
        updateMenuPresentation()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        activeStageSettlement?.cancelTimeout()
        readbackSettlement?.cancelTimeout()
        if Thread.isMainThread {
            Self.registry.remove(self)
            Self.refreshSharedInteractionState()
        } else {
            DispatchQueue.main.async {
                Self.refreshSharedInteractionState()
            }
        }
    }

    @objc func selectProxy(sender: ProxyMenuItem) {
        select(group: groupName, name: sender.proxyName)
    }

    func select(group requestedGroup: String, name: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.select(group: requestedGroup, name: name) }
            return
        }
        guard requestedGroup == groupName else {
            reportError("Selected path unavailable")
            return
        }
        guard canBeginOperation() else { return }

        switch groupType {
        case .select:
            guard members.contains(name), proxyGroup.type == .select, isSelectableCandidate(name) else {
                reportError("Selected path unavailable")
                return
            }
        case .urltest, .fallback:
            guard proxyGroup.supportsManualPriority,
                  proxyGroup.fixed != nil,
                  members.contains(name),
                  isSelectableCandidate(name) else {
                reportError(manualPriorityUnavailableMessage)
                return
            }
        default:
            reportError("Selected path unavailable")
            return
        }

        begin(.select(name))
    }

    @objc func restoreAutomaticSelection(sender: NSMenuItem) {
        restoreAutomaticSelection()
    }

    func restoreAutomaticSelection() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.restoreAutomaticSelection() }
            return
        }
        guard canBeginOperation() else { return }
        guard proxyGroup.supportsManualPriority,
              proxyGroup.fixed != nil,
              let fixed = proxyGroup.fixed,
              !fixed.isEmpty else {
            reportError(manualPriorityUnavailableMessage)
            return
        }
        begin(.reset)
    }

    func register(candidateItem: ProxyMenuItem) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard members.contains(candidateItem.proxyName) else { return }
        candidateItems[candidateItem.proxyName] = candidateItem
        updateMenuPresentation()
    }

    func attachHeaderItem(_ item: NSMenuItem) {
        dispatchPrecondition(condition: .onQueue(.main))
        headerItem = item
        updateMenuPresentation()
    }

    /// Called when a lazy submenu is populated from the factory's current
    /// snapshot. A changed identity or member set makes this menu controller
    /// stale; a state-only update is safe to apply.
    @discardableResult
    func update(group: ClashProxy, snapshot: ClashProxyResp) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard validate(group: group, snapshot: snapshot) else {
            invalidate()
            return false
        }
        proxyGroup = group
        proxySnapshot = snapshot
        updateMenuPresentation()
        return true
    }

    func updateMenuPresentation() {
        dispatchPrecondition(condition: .onQueue(.main))
        for (name, item) in candidateItems {
            item.state = proxyGroup.now == name ? .on : .off
            if !isSelectableCandidate(name) {
                item.selectionHelp = NSLocalizedString("Selected path unavailable", comment: "")
            } else if groupType == .select {
                item.selectionHelp = NSLocalizedString("Manual Selection", comment: "")
            } else if proxyGroup.supportsManualPriority {
                if let fixed = proxyGroup.fixed, !fixed.isEmpty {
                    item.selectionHelp = fixed == name
                        ? NSLocalizedString("Preferred node", comment: "")
                        : NSLocalizedString("Manual Priority", comment: "")
                } else if proxyGroup.fixed == "" {
                    item.selectionHelp = NSLocalizedString("Manual Priority", comment: "")
                } else {
                    item.selectionHelp = manualPriorityUnavailableMessage
                }
            }

            item.isEnabled = canSelect(name)
        }

        if groupType == .urltest || groupType == .fallback {
            let help: String
            if let fixed = proxyGroup.fixed, !fixed.isEmpty {
                help = "\(NSLocalizedString("Manual Priority", comment: "")): \(fixed)"
            } else if proxyGroup.fixed == "" {
                help = NSLocalizedString("Automatic Selection", comment: "")
            } else {
                help = manualPriorityUnavailableMessage
            }
            headerItem?.toolTip = help
            headerItem?.view?.toolTip = help
        }

        if let restoreAutomaticItem {
            let target = proxyGroup.manualPriorityTarget
            restoreAutomaticItem.isHidden = target == nil
            restoreAutomaticItem.isEnabled = target != nil && canRunRequest()
            restoreAutomaticItem.toolTip = target == nil
                ? manualPriorityUnavailableMessage
                : NSLocalizedString("Automatic Selection", comment: "")
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let item = menuItem as? ProxyMenuItem, candidateItems[item.proxyName] === item {
            return canSelect(item.proxyName)
        }
        if menuItem === restoreAutomaticItem {
            return proxyGroup.manualPriorityTarget != nil && canRunRequest()
        }
        return true
    }

    @objc private func proxyGroupUpdated(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.proxyGroupUpdated(notification) }
            return
        }
        guard let group = notification.object as? ClashProxy,
              group.name == groupName,
              let snapshot = group.enclosingResp,
              snapshot.proxiesMap[groupName] === group else { return }
        _ = update(group: group, snapshot: snapshot)
    }

    private var manualPriorityUnavailableMessage: String {
        "\(NSLocalizedString("Selected path unavailable", comment: ""))\n\(NSLocalizedString("This core did not report fixed state.", comment: ""))"
    }

    private func begin(_ intent: Intent) {
        dispatchPrecondition(condition: .onQueue(.main))
        let operation = Operation(
            id: UUID(),
            controllerGeneration: controllerGeneration,
            intent: intent,
            stage: .mutating
        )
        activeOperation = operation
        Self.activeOperationOwners[operation.id] = self
        Self.refreshSharedInteractionState()

        startStage(operation: operation) { [dependencies, groupName] complete in
            switch intent {
            case let .select(name): dependencies.select(groupName, name, complete)
            case .reset: dependencies.reset(groupName, complete)
            }
        }
    }

    private func startStage(
        operation: Operation,
        request: (@escaping (Bool) -> Void) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let stageID = UUID()
        activeStageID = stageID
        let settlement = ManagedOperationSettlement<StageOutcome> { [weak self] outcome in
            DispatchQueue.main.async { [weak self] in
                self?.stageDidSettle(outcome, operationID: operation.id, stageID: stageID)
            }
        }
        activeStageSettlement = settlement
        settlement.scheduleTimeout(after: max(0.01, dependencies.stageTimeout), queue: .main) { .timedOut }
        request { accepted in
            _ = settlement.finish(accepted ? .success : .failure)
        }
    }

    private func stageDidSettle(_ outcome: StageOutcome, operationID: UUID, stageID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeStageID == stageID,
              var operation = activeOperation,
              operation.id == operationID else { return }
        activeStageID = nil
        activeStageSettlement = nil

        guard isOperationCurrent(operation) else {
            finishFailure(operationID: operationID, message: "Selected path unavailable")
            return
        }
        guard outcome == .success else {
            finishFailure(
                operationID: operationID,
                message: outcome == .timedOut
                    ? NSLocalizedString("Proxy selection timed out.", comment: "")
                    : NSLocalizedString("Proxy selection failed.", comment: "")
            )
            return
        }

        switch operation.stage {
        case .mutating:
            operation.stage = .readback
            activeOperation = operation
            startReadback(operation: operation)
        case .readback:
            assertionFailure("Readback stages are settled through readbackDidSettle")
        }
    }

    private func startReadback(operation: Operation) {
        dispatchPrecondition(condition: .onQueue(.main))
        let stageID = UUID()
        activeStageID = stageID
        let settlement = ManagedOperationSettlement<ReadbackOutcome> { [weak self] outcome in
            DispatchQueue.main.async { [weak self] in
                self?.readbackDidSettle(outcome, operationID: operation.id, stageID: stageID)
            }
        }
        activeStageSettlement = nil
        readbackSettlement = settlement
        settlement.scheduleTimeout(after: max(0.01, dependencies.stageTimeout), queue: .main) { .timedOut }
        dependencies.refresh { snapshot in
            _ = settlement.finish(snapshot.map(ReadbackOutcome.snapshot) ?? .unavailable)
        }
    }

    private var readbackSettlement: ManagedOperationSettlement<ReadbackOutcome>?
    private weak var headerItem: NSMenuItem?

    private func readbackDidSettle(_ outcome: ReadbackOutcome, operationID: UUID, stageID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeStageID == stageID,
              let operation = activeOperation,
              operation.id == operationID,
              operation.stage == .readback else { return }
        activeStageID = nil
        readbackSettlement = nil

        guard isOperationCurrent(operation) else {
            finishFailure(operationID: operationID, message: "Selected path unavailable")
            return
        }
        guard case let .snapshot(snapshot) = outcome else {
            let message: String
            if case .timedOut = outcome {
                message = NSLocalizedString("Proxy selection timed out.", comment: "")
            } else {
                message = NSLocalizedString("Selected path unavailable", comment: "")
            }
            finishFailure(operationID: operationID, message: message)
            return
        }
        guard let refreshedGroup = snapshot.proxiesMap[groupName],
              validate(group: refreshedGroup, snapshot: snapshot) else {
            // The GET belongs to the still-current config/core scope, but this
            // controller no longer owns that group identity. Publish the live
            // topology so the replacement menu can render its authority.
            dependencies.publish(snapshot)
            if activeOperation?.id == operationID {
                invalidate()
                finishFailure(operationID: operationID, message: "Selected path unavailable")
            }
            return
        }

        // Every valid current-scope GET is published, even when Mihomo did not
        // retain the requested fixed target. This keeps now/fixed display tied
        // to the core's actual state, including Fallback clearing a dead target.
        proxySnapshot = snapshot
        proxyGroup = refreshedGroup
        dependencies.publish(snapshot)
        updateMenuPresentation()

        guard isOperationCurrent(operation) else {
            finishFailure(operationID: operationID, message: "Selected path unavailable")
            return
        }

        guard intentMatches(operation.intent, group: refreshedGroup) else {
            finishFailure(
                operationID: operationID,
                message: NSLocalizedString("The core did not retain the requested selection.", comment: "")
            )
            return
        }

        activeOperation = nil
        Self.activeOperationOwners.removeValue(forKey: operation.id)
        updateMenuPresentation()
        Self.refreshSharedInteractionState()
        if case let .select(name) = operation.intent, groupType == .select {
            dependencies.rememberSelection(groupName, name)
        }
        dependencies.closeConnections()
    }

    private func intentMatches(_ intent: Intent, group: ClashProxy) -> Bool {
        switch intent {
        case let .select(name):
            if groupType == .select { return group.now == name }
            return group.supportsManualPriority && group.fixed == name
        case .reset:
            return group.supportsManualPriority && group.fixed == ""
        }
    }

    private func canBeginOperation() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeOperation == nil else {
            reportError(NSLocalizedString("A proxy selection is already in progress.", comment: ""))
            return false
        }
        guard !Self.activeOperationOwners.values.contains(where: { $0 !== self }) else {
            reportError(NSLocalizedString("A proxy selection is already in progress.", comment: ""))
            return false
        }
        guard !isInvalidated, dependencies.isCurrent() else {
            reportError("Selected path unavailable")
            return false
        }
        guard !dependencies.isCoreChanging() else {
            reportError(NSLocalizedString("Proxy core is changing.", comment: ""))
            return false
        }
        guard !dependencies.isBusyBenchmark() else {
            reportError(NSLocalizedString("Selection is unavailable during a benchmark.", comment: ""))
            return false
        }
        guard !dependencies.isInteractionReserved() else {
            reportError(NSLocalizedString(
                "Configuration update is queued.",
                value: "Configuration update is queued.",
                comment: ""
            ))
            return false
        }
        return true
    }

    private func canRunRequest() -> Bool {
        !isInvalidated
            && activeOperation == nil
            && !Self.activeOperationOwners.values.contains(where: { $0 !== self })
            && dependencies.isCurrent()
            && !dependencies.isCoreChanging()
            && !dependencies.isBusyBenchmark()
            && !dependencies.isInteractionReserved()
    }

    private func canSelect(_ name: String) -> Bool {
        guard members.contains(name), isSelectableCandidate(name), canRunRequest() else { return false }
        if groupType == .select { return proxyGroup.type == .select }
        return proxyGroup.supportsManualPriority && proxyGroup.fixed != nil
    }

    private func isSelectableCandidate(_ name: String) -> Bool {
        guard let candidate = proxySnapshot.proxiesMap[name] else { return false }
        return !ClashProxyType.isCompatibilityFallback(candidate)
    }

    private func isOperationCurrent(_ operation: Operation) -> Bool {
        !isInvalidated
            && activeOperation?.id == operation.id
            && operation.controllerGeneration == controllerGeneration
            && dependencies.isCurrent()
            && !dependencies.isCoreChanging()
    }

    private func finishFailure(operationID: UUID, message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeOperation?.id == operationID else { return }
        activeStageID = nil
        activeStageSettlement?.cancelTimeout()
        activeStageSettlement = nil
        readbackSettlement?.cancelTimeout()
        readbackSettlement = nil
        activeOperation = nil
        Self.activeOperationOwners.removeValue(forKey: operationID)
        updateMenuPresentation()
        Self.refreshSharedInteractionState()
        reportError(message)
    }

    private func validate(group: ClashProxy, snapshot: ClashProxyResp) -> Bool {
        group.name == groupName
            && group.type == groupType
            && group.id == groupID
            && Set(group.all ?? []) == members
            && snapshot.proxiesMap[groupName] === group
    }

    private func invalidate() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isInvalidated else { return }
        isInvalidated = true
        controllerGeneration &+= 1
        // Do not release the shared interaction guard here. A topology or menu
        // rebuild can invalidate this controller while the PUT is still being
        // processed by Mihomo. Its stage settlement releases the guard.
        Self.refreshSharedInteractionState()
    }

    private func reportError(_ message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard dependencies.isCurrent() else { return }
        dependencies.showError(message)
    }

    private static func refreshSharedInteractionState() {
        dispatchPrecondition(condition: .onQueue(.main))
        registry.allObjects.forEach { $0.updateMenuPresentation() }
        ProxyGroupSpeedTestMenuItem.refreshSelectionInteractionState()
    }
}

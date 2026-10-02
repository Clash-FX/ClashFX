//
//  ProxyGroupSpeedTestMenuItem.swift
//  ClashX
//
//  Created by yicheng on 2019/10/15.
//  Copyright © 2019 west2online. All rights reserved.
//

import Carbon
import Cocoa

private final class SelectorBenchmarkPresentationCoalescer {
    private struct Key: Hashable {
        let selectorName: ClashProxyName
        let rowName: ClashProxyName
    }

    private var pending = [Key: SelectorBenchmarkPresentation]()
    private var flushWorkItem: DispatchWorkItem?
    private let delay: TimeInterval = 0.15

    func enqueue(_ presentation: SelectorBenchmarkPresentation) {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Key(
            selectorName: presentation.selectorName,
            rowName: presentation.rowName
        )
        pending[key] = presentation
        guard flushWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        flushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func flush() {
        dispatchPrecondition(condition: .onQueue(.main))
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let presentations = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        presentations.forEach(SelectorBenchmarkPresentationStore.publish)
    }
}

private func isAggregateTimeout(_ outcome: ProxyGroupDelayOutcome) -> Bool {
    if case .allFailed = outcome { return true }
    return false
}

class ProxyGroupSpeedTestMenuItem: NSMenuItem {
    private static let benchmarkOptionsIdentifier = NSUserInterfaceItemIdentifier(
        "com.clashfx.benchmark-options"
    )
    private struct BenchmarkFeedback {
        let identifier: UUID
        let title: String
        let message: String
    }

    private static let interactionItems = NSHashTable<ProxyGroupSpeedTestMenuItem>.weakObjects()
    private static var cancellationFeedback: BenchmarkFeedback?
    private static var cancellationFeedbackResetWorkItem: DispatchWorkItem?
    private static var interactionSession: ApiRequest.BenchmarkSession?
    private static var finishingInteractionSession: ApiRequest.BenchmarkSession?

    private(set) var proxyGroup: ClashProxy
    // ClashProxy.enclosingResp is weak. Retain and refresh the action's own
    // topology just as the visible rows do, so begin/settle use matching IDs
    // after another group's benchmark has replaced the menu snapshot.
    private var proxySnapshot: ClashProxyResp?
    let testType: TestType
    private var isTesting = false
    private var benchmarkActionSession: ApiRequest.BenchmarkSession?
    private var benchmarkFeedback: BenchmarkFeedback?
    private var benchmarkFeedbackResetWorkItem: DispatchWorkItem?
    private var explicitBenchmarkMode: BenchmarkMode?
    private weak var benchmarkOptionsMenuItem: NSMenuItem?
    private var benchmarkProgressSnapshot: BenchmarkProgressSnapshot?
    private var benchmarkProgressMode: BenchmarkMode = .quick
    private var benchmarkProgressPhase: String?
    private var benchmarkProgressWasCancelled = false
    private var benchmarkAdditionalSummary: String?
    private var benchmarkAdditionalTitle: String?
    private var benchmarkAdditionalTimeouts = 0
    private var selectorAttemptOutcomes = [SelectorBenchmarkMeasurementKey: ProxyDelayOutcome]()

    var effectiveBenchmarkMode: BenchmarkMode {
        explicitBenchmarkMode ?? Settings.benchmarkMode
    }

    init(group: ClashProxy) {
        proxyGroup = group
        proxySnapshot = group.enclosingResp
        if group.type.isAutoGroup {
            testType = .reTest
        } else if group.type == .select {
            testType = .benchmark
        } else {
            testType = .unknown
        }

        super.init(title: NSLocalizedString("Benchmark", comment: ""), action: nil, keyEquivalent: "")
        Self.interactionItems.add(self)
        NotificationCenter.default.addObserver(self, selector: #selector(proxyGroupUpdated(_:)),
                                               name: .proxyUpdate(for: group.name), object: nil)
        target = self
        action = #selector(healthCheck)

        switch testType {
        case .benchmark:
            view = ProxyGroupSpeedTestMenuItemView(testType.title)
        case .reTest:
            view = ProxyGroupSpeedTestMenuItemView(testType.title)
        case .unknown:
            assertionFailure()
        }
        updateBenchmarkInteractionPresentation()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        Self.interactionItems.remove(self)
    }

    @objc private func proxyGroupUpdated(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.proxyGroupUpdated(notification) }
            return
        }
        guard let group = notification.object as? ClashProxy,
              group.name == proxyGroup.name, group.type == proxyGroup.type,
              let snapshot = group.enclosingResp,
              snapshot.proxiesMap[group.name] === group else { return }
        proxyGroup = group
        proxySnapshot = snapshot
    }

    @objc func healthCheck() {
        ensureBenchmarkOptionsMenuItemAttached()
        updateBenchmarkInteractionPresentation()
        guard !isBenchmarkInteractionBusy, isEnabled else { return }
        (view as? ProxyGroupSpeedTestMenuItemView)?.didClickView()
    }

    func retestAutoGroup() {
        guard testType == .reTest else { return }
        ensureBenchmarkOptionsMenuItemAttached()
        updateBenchmarkInteractionPresentation()
        guard !isBenchmarkInteractionBusy else { return }
        guard !AppDelegate.shared.isEnhancedModeTransitionInProgress else { return }
        if (proxyGroup.all ?? []).allSatisfy({ $0 == "COMPATIBLE" })
            || proxyGroup.enclosingResp.map({ !$0.hasBenchmarkCandidates(in: proxyGroup.name) }) == true {
            updateViewTitle(NSLocalizedString("No testable proxy nodes", comment: ""))
            return
        }
        let benchmarkMode = effectiveBenchmarkMode
        guard let session = AppDelegate.shared.beginSpeedTest(showNotifications: false) else {
            showBenchmarkFeedback(
                title: NSLocalizedString("Benchmark unavailable", comment: ""),
                message: NSLocalizedString("Proxy core is changing. Please try again shortly.", comment: "")
            )
            return
        }

        beginBenchmarkAction(
            session: session,
            mode: benchmarkMode,
            phase: NSLocalizedString("Testing automatic group", comment: "")
        )
        let presentationSessionIdentifier = UUID()
        AutomaticGroupBenchmarkPresentationStore.begin(
            group: proxyGroup,
            sessionIdentifier: presentationSessionIdentifier
        )
        AutomaticChildBenchmarkStore.begin(
            group: proxyGroup,
            sessionIdentifier: presentationSessionIdentifier
        )

        var didFinish = false
        var bestKnownLeaf = proxyGroup.now
        let didFinishAction: () -> Void = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !didFinish else { return }
                didFinish = true
                if session.isCancelled {
                    AutomaticGroupBenchmarkPresentationStore.settleTestingAsUnavailable(
                        groupName: self.proxyGroup.name,
                        finalLeaf: bestKnownLeaf,
                        sessionIdentifier: presentationSessionIdentifier
                    )
                    AutomaticChildBenchmarkStore.settleTestingAsUnavailable(
                        groupName: self.proxyGroup.name,
                        sessionIdentifier: presentationSessionIdentifier
                    )
                }
                if AppDelegate.shared.isActiveBenchmarkSession(session) {
                    AppDelegate.shared.finishSpeedTest(session: session, showNotifications: false)
                }
            }
        }

        session.onTermination { [weak self] in
            guard let self else { return }
            AutomaticGroupBenchmarkPresentationStore.settleTestingAsUnavailable(
                groupName: self.proxyGroup.name,
                finalLeaf: bestKnownLeaf,
                sessionIdentifier: presentationSessionIdentifier
            )
            AutomaticChildBenchmarkStore.settleTestingAsUnavailable(
                groupName: self.proxyGroup.name,
                sessionIdentifier: presentationSessionIdentifier
            )
        }

        let benchmarkURL = proxyGroup.testUrl
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? Settings.benchMarkUrl

        ApiRequest.getProxyGroupDelay(
            groupName: proxyGroup.name,
            benchmarkURL: benchmarkURL,
            expectedStatus: proxyGroup.expectedStatus,
            timeout: benchmarkMode.timeoutMilliseconds,
            session: session
        ) { result in
            DispatchQueue.main.async {
                guard !session.isCancelled,
                      AppDelegate.shared.isActiveBenchmarkSession(session) else {
                    didFinishAction()
                    return
                }

                self.recordAutomaticGroupProgress(result, session: session)

                let candidateDelays = result.candidateDelays

                ApiRequest.getMergedProxyData(session: session, timeout: 10) { snapshot in
                    DispatchQueue.main.async {
                        guard !session.isCancelled,
                              AppDelegate.shared.isActiveBenchmarkSession(session) else {
                            didFinishAction()
                            return
                        }
                        guard let snapshot else {
                            Logger.log(
                                "[Proxy Delay] Automatic group '\(self.proxyGroup.name)' has no fresh topology after \(result.diagnostic)",
                                level: .warning
                            )
                            AutomaticGroupBenchmarkPresentationStore.settleTestingAsUnavailable(
                                groupName: self.proxyGroup.name,
                                finalLeaf: bestKnownLeaf,
                                sessionIdentifier: presentationSessionIdentifier
                            )
                            AutomaticChildBenchmarkStore.settleTestingAsUnavailable(
                                groupName: self.proxyGroup.name,
                                sessionIdentifier: presentationSessionIdentifier
                            )
                            self.showBenchmarkFeedback(
                                title: NSLocalizedString("Benchmark unavailable", comment: ""),
                                message: NSLocalizedString("Proxy core unavailable. Please try again shortly.", comment: ""),
                                session: session
                            )
                            didFinishAction()
                            return
                        }

                        guard let freshGroup = snapshot.proxiesMap[self.proxyGroup.name],
                              freshGroup.type.isAutoGroup else {
                            AutomaticGroupBenchmarkPresentationStore.settleTestingAsUnavailable(
                                groupName: self.proxyGroup.name,
                                finalLeaf: bestKnownLeaf,
                                sessionIdentifier: presentationSessionIdentifier
                            )
                            AutomaticChildBenchmarkStore.settleTestingAsUnavailable(
                                groupName: self.proxyGroup.name,
                                sessionIdentifier: presentationSessionIdentifier
                            )
                            self.showBenchmarkFeedback(
                                title: NSLocalizedString("Benchmark unavailable", comment: ""),
                                message: NSLocalizedString("Proxy group is no longer available. Refresh and try again.", comment: ""),
                                session: session
                            )
                            didFinishAction()
                            return
                        }

                        AutomaticChildBenchmarkStore.settle(
                            group: freshGroup,
                            candidateDelays: candidateDelays,
                            hasProbeEvidence: !isAggregateTimeout(result) && result.hasProbeEvidence,
                            sessionIdentifier: presentationSessionIdentifier
                        )

                        let retestSnapshot = AutomaticGroupRetestSnapshot.make(
                            groupName: self.proxyGroup.name,
                            candidateDelays: candidateDelays,
                            snapshot: snapshot
                        )
                        bestKnownLeaf = retestSnapshot.finalLeaf ?? bestKnownLeaf
                        let displayName: String = {
                            guard let leaf = retestSnapshot.finalLeaf,
                                  leaf != self.proxyGroup.name else { return self.proxyGroup.name }
                            return "\(self.proxyGroup.name) → \(leaf)"
                        }()
                        let state: ProxyBenchmarkRowState
                        switch retestSnapshot.evidence {
                        case let .measured(delay):
                            state = .measured(displayName: displayName, delay: delay)
                        case .zeroDelay:
                            state = .failed(displayName: displayName)
                        case let .unavailable(reason):
                            Logger.log(
                                "[Proxy Delay] Automatic group '\(self.proxyGroup.name)' path unavailable after \(result.diagnostic): \(reason)",
                                level: .warning
                            )
                            state = .unavailable(displayName: displayName)
                        case .noMatchingCandidate:
                            Logger.log(
                                "[Proxy Delay] Automatic group '\(self.proxyGroup.name)' has no current-run evidence on fresh path '\(retestSnapshot.selectedPath.joined(separator: " → "))' after \(result.diagnostic)",
                                level: .warning
                            )
                            state = !isAggregateTimeout(result) && result.hasProbeEvidence
                                ? .failed(displayName: displayName) : .unavailable(displayName: displayName)
                        }
                        AutomaticGroupBenchmarkPresentationStore.publish(
                            AutomaticGroupBenchmarkPresentation(
                                identity: AutomaticGroupBenchmarkIdentity(
                                    group: freshGroup,
                                    fallbackBenchmarkURL: Settings.benchMarkUrl
                                ),
                                selectedPath: retestSnapshot.selectedPath,
                                finalLeaf: retestSnapshot.finalLeaf ?? bestKnownLeaf,
                                finalLeafID: (retestSnapshot.finalLeaf ?? bestKnownLeaf).flatMap { snapshot.proxiesMap[$0]?.id },
                                sessionIdentifier: presentationSessionIdentifier,
                                rowState: state
                            )
                        )
                        didFinishAction()
                    }
                }
            }
        }
    }

    private func updateViewTitle(_ title: String) {
        self.title = title
        (view as? ProxyGroupSpeedTestMenuItemView)?.updateTitle(title)
    }

    /// The menu item is created before it belongs to its containing NSMenu.
    /// Attach its sibling options row once AppKit establishes that relationship.
    func ensureBenchmarkOptionsMenuItemAttached() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let menu, menu.index(of: self) != NSNotFound else { return }
        if let existing = menu.items.first(where: { $0.identifier == Self.benchmarkOptionsIdentifier }) {
            benchmarkOptionsMenuItem = existing
            return
        }

        let optionsItem = NSMenuItem(
            title: NSLocalizedString("Benchmark options", comment: ""),
            action: nil,
            keyEquivalent: ""
        )
        optionsItem.identifier = Self.benchmarkOptionsIdentifier
        let optionsMenu = NSMenu(title: optionsItem.title)
        let canChangeMode = !isBenchmarkInteractionBusy

        let quickItem = NSMenuItem(
            title: NSLocalizedString("Quick (2.5 s)", comment: ""),
            action: #selector(selectBenchmarkMode(_:)),
            keyEquivalent: ""
        )
        quickItem.target = self
        quickItem.tag = 0
        quickItem.isEnabled = canChangeMode
        optionsMenu.addItem(quickItem)

        let completeItem = NSMenuItem(
            title: NSLocalizedString("Complete (5 s)", comment: ""),
            action: #selector(selectBenchmarkMode(_:)),
            keyEquivalent: ""
        )
        completeItem.target = self
        completeItem.tag = 1
        completeItem.isEnabled = canChangeMode
        optionsMenu.addItem(completeItem)

        if testType == .benchmark {
            optionsMenu.addItem(.separator())
            let retryItem = NSMenuItem(
                title: NSLocalizedString("Retry failed nodes", comment: ""),
                action: #selector(retryFailedBenchmarks),
                keyEquivalent: ""
            )
            retryItem.target = self
            retryItem.isEnabled = !isBenchmarkInteractionBusy
            optionsMenu.addItem(retryItem)
        }

        optionsItem.submenu = optionsMenu
        let speedTestIndex = menu.index(of: self)
        guard speedTestIndex != NSNotFound else { return }
        let displayOrderItem = menu.items.first {
            $0.representedObject as? String == "ClashFX.ProxyGroupMenu.DisplayOrder"
                || $0.title == NSLocalizedString("Display Order", comment: "Proxy menu row-order submenu")
        }
        let displayOrderIndex = displayOrderItem.map { menu.index(of: $0) }
        let index: Int
        if let displayOrderIndex, displayOrderIndex == speedTestIndex + 1 {
            index = displayOrderIndex
        } else {
            index = speedTestIndex + 1
        }
        menu.insertItem(optionsItem, at: min(index, menu.numberOfItems))
        benchmarkOptionsMenuItem = optionsItem
        updateBenchmarkOptionsSelectionState()
    }

    @objc private func selectBenchmarkMode(_ sender: NSMenuItem) {
        explicitBenchmarkMode = sender.tag == 0 ? .quick : .complete
        updateBenchmarkOptionsSelectionState()
    }

    private func updateBenchmarkOptionsSelectionState() {
        guard let optionsMenu = benchmarkOptionsMenuItem?.submenu else { return }
        for item in optionsMenu.items where item.action == #selector(selectBenchmarkMode(_:)) {
            let mode: BenchmarkMode = item.tag == 0 ? .quick : .complete
            item.state = mode == effectiveBenchmarkMode ? .on : .off
            item.isEnabled = !isBenchmarkInteractionBusy
        }
        if let retryItem = optionsMenu.items.first(where: { $0.action == #selector(retryFailedBenchmarks) }) {
            retryItem.isEnabled = !isBenchmarkInteractionBusy && hasRetryableSelectorOutcomes
        }
    }

    private var hasRetryableSelectorOutcomes: Bool {
        selectorAttemptOutcomes.values.contains { $0 == .failed || $0 == .timedOut }
    }

    @objc private func retryFailedBenchmarks() {
        guard testType == .benchmark, !isBenchmarkInteractionBusy,
              !AppDelegate.shared.isEnhancedModeTransitionInProgress else { return }
        (view as? ProxyGroupSpeedTestMenuItemView)?.startBenchmark(retryingFailures: true)
    }

    fileprivate var isBenchmarkInteractionBusy: Bool {
        isTesting
            || benchmarkActionSession != nil
            || Self.interactionSession != nil
            || (AppDelegate.shared.isSpeedTesting && Self.finishingInteractionSession == nil)
    }

    fileprivate func updateBenchmarkInteractionPresentation() {
        let isCoreChanging = AppDelegate.shared.isEnhancedModeTransitionInProgress
        isEnabled = !isCoreChanging

        let title: String
        let feedbackMessage: String?
        if isCoreChanging, let cancellation = Self.cancellationFeedback {
            title = cancellation.title
            feedbackMessage = cancellation.message + "\n" +
                NSLocalizedString("Proxy core is changing. Please try again shortly.", comment: "")
        } else if isCoreChanging {
            title = NSLocalizedString("Core switching…", comment: "")
            feedbackMessage = NSLocalizedString("Proxy core is changing. Please try again shortly.", comment: "")
        } else if let benchmarkFeedback {
            title = benchmarkFeedback.title
            feedbackMessage = benchmarkFeedback.message
        } else if benchmarkActionSession != nil {
            if let benchmarkProgressPhase {
                title = benchmarkProgressPhase
                feedbackMessage = nil
            } else if let benchmarkProgressSnapshot {
                title = String(
                    format: NSLocalizedString("Benchmarking %d/%d", comment: ""),
                    benchmarkProgressSnapshot.completed,
                    benchmarkProgressSnapshot.total
                )
                feedbackMessage = benchmarkProgressSummary(benchmarkProgressSnapshot)
            } else {
                title = NSLocalizedString("Testing", comment: "")
                feedbackMessage = nil
            }
        } else if let cancellation = Self.cancellationFeedback {
            title = cancellation.title
            feedbackMessage = cancellation.message
        } else if let benchmarkProgressSnapshot, !benchmarkProgressWasCancelled {
            title = benchmarkProgressTitle(benchmarkProgressSnapshot)
            feedbackMessage = benchmarkProgressSummary(benchmarkProgressSnapshot)
        } else {
            title = testType.title
            feedbackMessage = nil
        }

        updateViewTitle(title)
        toolTip = feedbackMessage
        let menuView = view as? ProxyGroupSpeedTestMenuItemView
        menuView?.isBusy = isBenchmarkInteractionBusy
        menuView?.isCoreChanging = isCoreChanging
        menuView?.updateFeedbackHelp(feedbackMessage)
        // Start the readable feedback window only after the switch settles.
        // Defer this check because cancellation happens before beginLaunch().
        if Self.cancellationFeedback != nil {
            DispatchQueue.main.async { Self.armCancellationFeedbackExpiryIfStable() }
        }
        updateBenchmarkOptionsSelectionState()
    }

    static func showBenchmarkCancellation(session: ApiRequest.BenchmarkSession, reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard AppDelegate.shared.isActiveBenchmarkSession(session), reason != "application quit" else { return }
        let configChanged = reason == "configuration reload"
        cancellationFeedbackResetWorkItem?.cancel()
        cancellationFeedbackResetWorkItem = nil
        cancellationFeedback = BenchmarkFeedback(
            identifier: UUID(),
            title: NSLocalizedString(
                configChanged ? "Benchmark cancelled: configuration changed" : "Benchmark cancelled: core changed",
                comment: ""
            ),
            message: NSLocalizedString(
                configChanged
                    ? "The configuration changed, so unfinished benchmark requests were cancelled. Completed results are kept. Run the benchmark again after reload."
                    : "The proxy core is switching, so unfinished benchmark requests were cancelled. Completed results are kept. Run the benchmark again after the switch.",
                comment: ""
            )
        )
        updateAllBenchmarkInteractionPresentations()
    }

    static func clearBenchmarkCancellationFeedback() {
        dispatchPrecondition(condition: .onQueue(.main))
        cancellationFeedbackResetWorkItem?.cancel()
        cancellationFeedbackResetWorkItem = nil
        cancellationFeedback = nil
        updateAllBenchmarkInteractionPresentations()
    }

    static func clearBenchmarkRetryHistory() {
        dispatchPrecondition(condition: .onQueue(.main))
        interactionItems.allObjects.forEach { item in
            item.selectorAttemptOutcomes.removeAll()
            item.updateBenchmarkOptionsSelectionState()
        }
    }

    static func clearRetryableBenchmarkOutcomes() {
        clearBenchmarkRetryHistory()
    }

    private static func armCancellationFeedbackExpiryIfStable() {
        guard let feedback = cancellationFeedback else { return }
        if AppDelegate.shared.isEnhancedModeTransitionInProgress {
            cancellationFeedbackResetWorkItem?.cancel()
            cancellationFeedbackResetWorkItem = nil
            return
        }
        guard cancellationFeedbackResetWorkItem == nil else { return }
        let reset = DispatchWorkItem {
            guard cancellationFeedback?.identifier == feedback.identifier else { return }
            clearBenchmarkCancellationFeedback()
        }
        cancellationFeedbackResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: reset)
    }

    private static func updateAllBenchmarkInteractionPresentations() {
        interactionItems.allObjects.forEach { $0.updateBenchmarkInteractionPresentation() }
    }

    func beginBenchmarkAction(
        session: ApiRequest.BenchmarkSession,
        mode: BenchmarkMode? = nil,
        phase: String? = nil
    ) {
        clearBenchmarkFeedback()
        benchmarkActionSession = session
        isTesting = true
        benchmarkProgressSnapshot = nil
        benchmarkProgressMode = mode ?? effectiveBenchmarkMode
        benchmarkProgressPhase = phase
        benchmarkProgressWasCancelled = false
        benchmarkAdditionalSummary = nil
        benchmarkAdditionalTitle = nil
        benchmarkAdditionalTimeouts = 0
        Self.interactionSession = session
        Self.updateAllBenchmarkInteractionPresentations()
        updateBenchmarkOptionsSelectionState()
        // Disabling the active custom-view item can end AppKit menu tracking.
        // Keep it enabled and let the benchmark session reject repeat clicks.
        session.onTermination { [weak self] in
            let finish = {
                self?.finishBenchmarkActionIfOwned(session: session)
                Self.finishInteractionIfOwned(session: session)
            }
            if Thread.isMainThread {
                finish()
            } else {
                DispatchQueue.main.async(execute: finish)
            }
        }
    }

    private static func finishInteractionIfOwned(session: ApiRequest.BenchmarkSession) {
        guard interactionSession === session else { return }
        finishingInteractionSession = session
        interactionSession = nil
        updateAllBenchmarkInteractionPresentations()

        // AppDelegate clears its global speed-test flag immediately after a
        // cancellation observer returns. Clear the session-specific override
        // after that state transition and refresh once more for external work.
        DispatchQueue.main.async {
            if finishingInteractionSession === session {
                finishingInteractionSession = nil
            }
            updateAllBenchmarkInteractionPresentations()
        }
    }

    @discardableResult
    func finishBenchmarkActionIfOwned(session: ApiRequest.BenchmarkSession) -> Bool {
        guard benchmarkActionSession === session else { return false }
        benchmarkProgressWasCancelled = session.isCancelled
        benchmarkProgressPhase = nil
        benchmarkActionSession = nil
        isTesting = false
        updateBenchmarkInteractionPresentation()
        updateBenchmarkOptionsSelectionState()
        Self.finishInteractionIfOwned(session: session)
        return true
    }

    func receiveBenchmarkProgress(_ progress: BenchmarkProgressSnapshot, session: ApiRequest.BenchmarkSession) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard benchmarkActionSession === session,
              !session.isCancelled,
              AppDelegate.shared.isActiveBenchmarkSession(session) else { return }
        benchmarkProgressSnapshot = progress
        benchmarkProgressPhase = nil
        updateBenchmarkInteractionPresentation()
    }

    func setBenchmarkProgressPhase(_ phase: String?, session: ApiRequest.BenchmarkSession) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard benchmarkActionSession === session,
              !session.isCancelled,
              AppDelegate.shared.isActiveBenchmarkSession(session) else { return }
        benchmarkProgressPhase = phase
        updateBenchmarkInteractionPresentation()
    }

    func recordAutomaticGroupProgress(_ result: ProxyGroupDelayOutcome, session: ApiRequest.BenchmarkSession) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard benchmarkActionSession === session,
              !session.isCancelled,
              AppDelegate.shared.isActiveBenchmarkSession(session) else { return }
        let progress: BenchmarkProgressSnapshot
        switch result {
        case let .success(candidateDelays):
            let values = Array(candidateDelays.values)
            progress = BenchmarkProgressSnapshot(
                total: values.count,
                completed: values.count,
                succeeded: values.filter { $0 > 0 }.count,
                failed: values.filter { $0 == 0 }.count
            )
        case .allFailed:
            // The group endpoint reports one completed group request, not
            // per-node outcomes when Mihomo returns its aggregate timeout.
            progress = BenchmarkProgressSnapshot(total: 1, completed: 1, timedOut: 1)
        case .empty, .httpFailure:
            progress = BenchmarkProgressSnapshot(total: 1, completed: 1, unavailable: 1)
        case .cancelled:
            return
        }
        benchmarkProgressSnapshot = progress
        benchmarkProgressPhase = nil
        updateBenchmarkInteractionPresentation()
    }

    func recordSelectorAutomaticGroupOutcome(_ result: ProxyGroupDelayOutcome, session: ApiRequest.BenchmarkSession) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard benchmarkActionSession === session,
              !session.isCancelled,
              AppDelegate.shared.isActiveBenchmarkSession(session) else { return }
        switch result {
        case let .success(candidateDelays):
            let values = Array(candidateDelays.values)
            benchmarkAdditionalTitle = String(
                format: NSLocalizedString("Group %d succeeded · %d failed", comment: ""),
                values.filter { $0 > 0 }.count,
                values.filter { $0 == 0 }.count
            )
            benchmarkAdditionalSummary = String(
                format: NSLocalizedString("Selected automatic group response: %d succeeded, %d failed", comment: ""),
                values.filter { $0 > 0 }.count,
                values.filter { $0 == 0 }.count
            )
        case .allFailed:
            benchmarkAdditionalTimeouts = 1
            benchmarkAdditionalTitle = NSLocalizedString("Group timed out", comment: "")
            benchmarkAdditionalSummary = NSLocalizedString("Selected automatic group request timed out", comment: "")
        case .empty:
            benchmarkAdditionalTitle = NSLocalizedString("Group unavailable", comment: "")
            benchmarkAdditionalSummary = NSLocalizedString("Selected automatic group returned no results", comment: "")
        case .httpFailure:
            benchmarkAdditionalTitle = NSLocalizedString("Group unavailable", comment: "")
            benchmarkAdditionalSummary = NSLocalizedString("Selected automatic group was unavailable", comment: "")
        case .cancelled:
            return
        }
        if benchmarkProgressSnapshot == nil {
            benchmarkProgressSnapshot = BenchmarkProgressSnapshot()
        }
        updateBenchmarkInteractionPresentation()
    }

    func recordSelectorAttemptOutcome(
        _ outcome: ProxyDelayOutcome,
        for key: SelectorBenchmarkMeasurementKey,
        session: ApiRequest.BenchmarkSession
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard benchmarkActionSession === session,
              !session.isCancelled,
              AppDelegate.shared.isActiveBenchmarkSession(session),
              outcome != .cancelled else { return }
        selectorAttemptOutcomes = selectorAttemptOutcomes.filter {
            !key.matchesRetryConditions(of: $0.key)
        }
        selectorAttemptOutcomes[key] = outcome
        updateBenchmarkOptionsSelectionState()
    }

    fileprivate func clearSelectorAttemptOutcomes() {
        dispatchPrecondition(condition: .onQueue(.main))
        selectorAttemptOutcomes.removeAll()
        updateBenchmarkOptionsSelectionState()
    }

    func retryingFailures(from plan: SelectorBenchmarkPlan) -> SelectorBenchmarkPlan? {
        plan.retryingFailures(from: selectorAttemptOutcomes)
    }

    private func benchmarkProgressTitle(_ progress: BenchmarkProgressSnapshot) -> String {
        let isQuickTimeout = benchmarkProgressMode == .quick
            && progress.timedOut + benchmarkAdditionalTimeouts > 0
        let key = isQuickTimeout
            ? "Quick: %d succeeded, %d timed out, %d failed, %d unavailable, %d reused"
            : "Done: %d succeeded, %d timed out, %d failed, %d unavailable, %d reused"
        var title = String(
            format: NSLocalizedString(key, comment: "Completed benchmark summary"),
            progress.succeeded,
            progress.timedOut + benchmarkAdditionalTimeouts,
            progress.failed,
            progress.unavailable,
            progress.reused
        )
        if let benchmarkAdditionalTitle {
            title += " · " + benchmarkAdditionalTitle
        }
        return title
    }

    private func benchmarkProgressSummary(_ progress: BenchmarkProgressSnapshot) -> String {
        var summary: String
        if benchmarkProgressMode == .quick, progress.timedOut + benchmarkAdditionalTimeouts > 0 {
            summary = String(
                format: NSLocalizedString(
                    "Quick benchmark timed out after %d ms. %d succeeded, %d timed out, %d failed, %d unavailable, %d reused. Select Complete mode for nodes that need more time.",
                    comment: ""
                ),
                benchmarkProgressMode.timeoutMilliseconds,
                progress.succeeded,
                progress.timedOut + benchmarkAdditionalTimeouts,
                progress.failed,
                progress.unavailable,
                progress.reused
            )
        } else {
            summary = String(
                format: NSLocalizedString(
                    "Benchmark summary: %d succeeded, %d timed out, %d failed, %d unavailable, %d reused",
                    comment: ""
                ),
                progress.succeeded,
                progress.timedOut + benchmarkAdditionalTimeouts,
                progress.failed,
                progress.unavailable,
                progress.reused
            )
        }
        if let benchmarkAdditionalSummary {
            summary += "\n" + benchmarkAdditionalSummary
        }
        return summary
    }

    fileprivate func showBenchmarkFeedback(
        title: String,
        message: String,
        session: ApiRequest.BenchmarkSession? = nil
    ) {
        let show = { [weak self] in
            guard let self else { return }
            if let session {
                guard !session.isCancelled,
                      AppDelegate.shared.isActiveBenchmarkSession(session) else { return }
            }

            self.benchmarkFeedbackResetWorkItem?.cancel()
            let feedback = BenchmarkFeedback(identifier: UUID(), title: title, message: message)
            self.benchmarkFeedback = feedback
            self.updateBenchmarkInteractionPresentation()

            let reset = DispatchWorkItem { [weak self] in
                guard let self,
                      self.benchmarkFeedback?.identifier == feedback.identifier else { return }
                self.benchmarkFeedback = nil
                self.benchmarkFeedbackResetWorkItem = nil
                self.updateBenchmarkInteractionPresentation()
            }
            self.benchmarkFeedbackResetWorkItem = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: reset)
        }

        if Thread.isMainThread {
            show()
        } else {
            DispatchQueue.main.async(execute: show)
        }
    }

    private func clearBenchmarkFeedback() {
        benchmarkFeedbackResetWorkItem?.cancel()
        benchmarkFeedbackResetWorkItem = nil
        benchmarkFeedback = nil
    }
}

extension ProxyGroupSpeedTestMenuItem: ProxyGroupMenuHighlightDelegate {
    func highlight(item: NSMenuItem?) {
        updateBenchmarkInteractionPresentation()
        (view as? ProxyGroupSpeedTestMenuItemView)?.isHighlighted =
            !isBenchmarkInteractionBusy
                && !AppDelegate.shared.isEnhancedModeTransitionInProgress
                && item == self
    }
}

private class ProxyGroupSpeedTestMenuItemView: MenuItemBaseView {
    private let label: NSTextField
    private var interactionRefreshTimer: Timer?

    fileprivate var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            updateInteractionVisualState()
        }
    }

    fileprivate var isCoreChanging = false {
        didSet {
            guard isCoreChanging != oldValue else { return }
            updateInteractionVisualState()
            refreshInteractionTimer()
        }
    }

    init(_ title: String) {
        label = NSTextField(labelWithString: title)
        label.font = type(of: self).labelFont
        label.sizeToFit()
        let rect = NSRect(x: 0, y: 0, width: label.bounds.width + 40, height: 20)
        super.init(frame: rect, autolayout: false)
        addSubview(label)
        label.frame = NSRect(x: 20, y: 0, width: label.bounds.width, height: 20)
        label.textColor = NSColor.labelColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        interactionRefreshTimer?.invalidate()
    }

    override var cells: [NSCell?] {
        return [label.cell]
    }

    override var labels: [NSTextField] {
        return [label]
    }

    func updateTitle(_ title: String) {
        guard label.stringValue != title else { return }
        label.stringValue = title
        label.sizeToFit()
        label.frame = NSRect(x: 20, y: 0, width: label.frame.width, height: 20)
        let requiredWidth = label.frame.maxX + 20
        if requiredWidth > bounds.width {
            setFrameSize(NSSize(width: requiredWidth, height: 20))
        }
        setNeedsDisplay()
    }

    func updateFeedbackHelp(_ message: String?) {
        toolTip = message
        label.toolTip = message
        setAccessibilityHelp(message ?? (isBusy
            ? NSLocalizedString("Wait for the current benchmark to finish.", comment: "")
            : nil))
    }

    private func updateInteractionVisualState() {
        alphaValue = (isBusy || isCoreChanging) ? 0.5 : 1
        let accessibilityValue: String?
        if isCoreChanging {
            accessibilityValue = NSLocalizedString("Core switching…", comment: "")
        } else if isBusy {
            accessibilityValue = NSLocalizedString("Testing", comment: "")
        } else {
            accessibilityValue = nil
        }
        setAccessibilityValue(accessibilityValue)
        if isBusy || isCoreChanging {
            isHighlighted = false
        } else {
            isHighlighted = enclosingMenuItem?.menu?.highlightedItem == enclosingMenuItem
        }
        setNeedsDisplay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let speedTestItem = enclosingMenuItem as? ProxyGroupSpeedTestMenuItem {
            speedTestItem.ensureBenchmarkOptionsMenuItemAttached()
            speedTestItem.updateBenchmarkInteractionPresentation()
        }
        refreshInteractionTimer()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        (enclosingMenuItem as? ProxyGroupSpeedTestMenuItem)?.ensureBenchmarkOptionsMenuItemAttached()
    }

    private func refreshInteractionTimer() {
        interactionRefreshTimer?.invalidate()
        interactionRefreshTimer = nil
        // Only a switching core needs polling to re-enable an open menu.
        // Benchmark sessions already publish their own begin/finish updates.
        guard window != nil, isCoreChanging else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self,
                  let item = self.enclosingMenuItem as? ProxyGroupSpeedTestMenuItem else { return }
            item.updateBenchmarkInteractionPresentation()
        }
        RunLoop.main.add(timer, forMode: .common)
        interactionRefreshTimer = timer
    }

    override func didClickView() {
        guard let speedTestItem = enclosingMenuItem as? ProxyGroupSpeedTestMenuItem else { return }
        speedTestItem.updateBenchmarkInteractionPresentation()
        guard !speedTestItem.isBenchmarkInteractionBusy,
              !AppDelegate.shared.isEnhancedModeTransitionInProgress else { return }
        switch speedTestItem.testType {
        case .benchmark:
            startBenchmark()
        case .reTest:
            speedTestItem.retestAutoGroup()
        case .unknown:
            break
        }
    }

    fileprivate func startBenchmark(retryingFailures: Bool = false) {
        guard let speedTestItem = enclosingMenuItem as? ProxyGroupSpeedTestMenuItem else {
            return
        }
        guard !speedTestItem.isBenchmarkInteractionBusy else { return }
        speedTestItem.updateBenchmarkInteractionPresentation()
        guard !AppDelegate.shared.isEnhancedModeTransitionInProgress else { return }
        let group = speedTestItem.proxyGroup
        let benchmarkMode = speedTestItem.effectiveBenchmarkMode
        guard let session = AppDelegate.shared.beginSpeedTest(showNotifications: false) else {
            speedTestItem.showBenchmarkFeedback(
                title: NSLocalizedString("Benchmark unavailable", comment: ""),
                message: NSLocalizedString("Proxy core is changing. Please try again shortly.", comment: "")
            )
            return
        }

        speedTestItem.beginBenchmarkAction(session: session, mode: benchmarkMode)

        var plan: SelectorBenchmarkPlan?
        var reusableMeasurements = [SelectorBenchmarkMeasurementKey: Int]()
        var pendingRows = Set<ClashProxyName>()
        var selectorBenchmarkURL = Settings.benchMarkUrl
        let sessionIdentifier = UUID()
        let presentationCoalescer = SelectorBenchmarkPresentationCoalescer()
        let publishState: (SelectorBenchmarkRow, ProxyBenchmarkRowState) -> Void = { row, state in
            SelectorBenchmarkPresentationStore.publish(
                SelectorBenchmarkPresentation(
                    selectorName: group.name,
                    rowName: row.rowName,
                    resolvedLeafName: row.measurementKey?.proxyName,
                    resolvedCoreID: row.measurementKey?.coreID,
                    benchmarkURL: row.measurementKey?.benchmarkURL ?? selectorBenchmarkURL,
                    sessionIdentifier: sessionIdentifier,
                    rowState: state
                )
            )
        }
        let publishAutomaticState: (
            SelectorBenchmarkRow,
            SelectorBenchmarkAutomaticRetestTarget,
            ClashProxy?,
            ProxyBenchmarkRowState
        ) -> Void = { row, target, finalLeaf, state in
            SelectorBenchmarkPresentationStore.publish(
                SelectorBenchmarkPresentation(
                    selectorName: group.name,
                    rowName: row.rowName,
                    resolvedLeafName: finalLeaf?.name,
                    resolvedCoreID: finalLeaf?.id,
                    benchmarkURL: target.benchmarkURL,
                    sessionIdentifier: sessionIdentifier,
                    rowState: state
                )
            )
        }
        let publishResult: (SelectorBenchmarkPlan.Target, ProxyDelayOutcome) -> Void = { target, outcome in
            DispatchQueue.main.async {
                guard !session.isCancelled,
                      AppDelegate.shared.isActiveBenchmarkSession(session) else {
                    return
                }
                guard outcome != .cancelled else { return }
                speedTestItem.recordSelectorAttemptOutcome(outcome, for: target.key, session: session)
                for row in target.aliases {
                    guard pendingRows.remove(row.rowName) != nil else { continue }
                    let state = outcome.rowState(name: row.displayName)
                    presentationCoalescer.enqueue(
                        SelectorBenchmarkPresentation(
                            selectorName: group.name,
                            rowName: row.rowName,
                            resolvedLeafName: row.measurementKey?.proxyName,
                            resolvedCoreID: row.measurementKey?.coreID,
                            benchmarkURL: row.measurementKey?.benchmarkURL ?? selectorBenchmarkURL,
                            sessionIdentifier: sessionIdentifier,
                            rowState: state
                        )
                    )
                }
                let identity = LeafProxyBenchmarkIdentity(
                    endpoint: target.key.endpoint,
                    providerName: target.key.providerName,
                    proxyName: target.key.proxyName,
                    coreID: target.key.coreID
                )
                let state = outcome.rowState(name: target.key.proxyName)
                GlobalLeafBenchmarkPresentationStore.publish(
                    GlobalLeafBenchmarkPresentation(
                        identity: identity,
                        benchmarkURL: target.key.benchmarkURL,
                        sessionIdentifier: sessionIdentifier,
                        rowState: state
                    )
                )
            }
        }

        var didFinish = false
        let finish = { [weak speedTestItem] in
            DispatchQueue.main.async {
                guard !didFinish else { return }
                didFinish = true
                presentationCoalescer.flush()
                if AppDelegate.shared.isActiveBenchmarkSession(session) {
                    AppDelegate.shared.finishSpeedTest(
                        session: session,
                        showNotifications: false
                    )
                }
                speedTestItem?.finishBenchmarkActionIfOwned(session: session)
            }
        }
        let retestSelectedAutomaticGroup: (@escaping () -> Void) -> Void = { continuation in
            guard !session.isCancelled,
                  AppDelegate.shared.isActiveBenchmarkSession(session),
                  let plan,
                  let target = plan.selectedAutomaticRetest else {
                continuation()
                return
            }
            let deferredRows = plan.orderedRows.filter(\.isDeferredAutomaticRetest)
            guard !deferredRows.isEmpty else {
                continuation()
                return
            }

            let automaticRetestStartedAt = Date()
            speedTestItem.setBenchmarkProgressPhase(
                NSLocalizedString("Testing selected automatic group", comment: ""),
                session: session
            )
            Logger.log(
                "[Proxy Delay] Refreshing selected automatic group '\(target.groupName)' with the Selector benchmark URL before other rows"
            )

            ApiRequest.getProxyGroupDelay(
                groupName: target.groupName,
                benchmarkURL: target.benchmarkURL,
                expectedStatus: target.expectedStatus,
                timeout: benchmarkMode.timeoutMilliseconds,
                session: session
            ) { result in
                DispatchQueue.main.async {
                    guard !session.isCancelled,
                          AppDelegate.shared.isActiveBenchmarkSession(session) else {
                        finish()
                        return
                    }

                    speedTestItem.recordSelectorAutomaticGroupOutcome(result, session: session)

                    ApiRequest.getMergedProxyData(session: session, timeout: 10) { snapshot in
                        DispatchQueue.main.async {
                            guard !session.isCancelled,
                                  AppDelegate.shared.isActiveBenchmarkSession(session) else {
                                finish()
                                return
                            }
                            guard let snapshot else {
                                Logger.log(
                                    "[Proxy Delay] Selected automatic group '\(target.groupName)' has no fresh topology after \(result.diagnostic)",
                                    level: .warning
                                )
                                for row in deferredRows where pendingRows.remove(row.rowName) != nil {
                                    publishAutomaticState(
                                        row,
                                        target,
                                        nil,
                                        .unavailable(displayName: row.displayName)
                                    )
                                }
                                speedTestItem.showBenchmarkFeedback(
                                    title: NSLocalizedString("Benchmark unavailable", comment: ""),
                                    message: NSLocalizedString("Proxy core unavailable. Please try again shortly.", comment: ""),
                                    session: session
                                )
                                speedTestItem.setBenchmarkProgressPhase(nil, session: session)
                                continuation()
                                return
                            }

                            guard let freshGroup = snapshot.proxiesMap[target.groupName],
                                  freshGroup.type.isAutoGroup else {
                                for row in deferredRows where pendingRows.remove(row.rowName) != nil {
                                    publishAutomaticState(
                                        row,
                                        target,
                                        nil,
                                        .unavailable(displayName: row.displayName)
                                    )
                                }
                                speedTestItem.showBenchmarkFeedback(
                                    title: NSLocalizedString("Benchmark unavailable", comment: ""),
                                    message: NSLocalizedString("Proxy group is no longer available. Refresh and try again.", comment: ""),
                                    session: session
                                )
                                speedTestItem.setBenchmarkProgressPhase(nil, session: session)
                                continuation()
                                return
                            }

                            for memberName in freshGroup.all ?? [] {
                                guard let leaf = snapshot.proxiesMap[memberName],
                                      leaf.all == nil,
                                      !ClashProxyType.isCompatibilityFallback(leaf),
                                      !ClashProxyType.isProxyGroup(leaf),
                                      let delay = result.candidateDelays[memberName] else { continue }
                                let state: ProxyBenchmarkRowState = delay > 0
                                    ? .measured(displayName: memberName, delay: delay)
                                    : .failed(displayName: memberName)
                                GlobalLeafBenchmarkPresentationStore.publish(
                                    GlobalLeafBenchmarkPresentation(
                                        identity: LeafProxyBenchmarkIdentity(proxy: leaf),
                                        benchmarkURL: target.benchmarkURL,
                                        sessionIdentifier: sessionIdentifier,
                                        rowState: state
                                    )
                                )
                            }
                            reusableMeasurements = plan.reusableMeasurements(
                                group: freshGroup,
                                candidateDelays: result.candidateDelays,
                                timeout: benchmarkMode.timeoutMilliseconds
                            )

                            let retestSnapshot = AutomaticGroupRetestSnapshot.make(
                                groupName: target.groupName,
                                candidateDelays: result.candidateDelays,
                                snapshot: snapshot
                            )
                            // Keep the menu row width and identity stable. The
                            // authoritative final leaf is retained separately in
                            // the presentation and exposed as the item's tooltip.
                            let displayName = target.groupName
                            let state: ProxyBenchmarkRowState
                            switch retestSnapshot.evidence {
                            case let .measured(delay):
                                state = .measured(displayName: displayName, delay: delay)
                            case .zeroDelay:
                                state = .failed(displayName: displayName)
                            case let .unavailable(reason):
                                Logger.log(
                                    "[Proxy Delay] Selected automatic group '\(target.groupName)' path unavailable after \(result.diagnostic): \(reason)",
                                    level: .warning
                                )
                                state = .unavailable(displayName: displayName)
                            case .noMatchingCandidate:
                                Logger.log(
                                    "[Proxy Delay] Selected automatic group '\(target.groupName)' has no current-run evidence on fresh path '\(retestSnapshot.selectedPath.joined(separator: " → "))' after \(result.diagnostic)",
                                    level: .warning
                                )
                                state = !isAggregateTimeout(result) && result.hasProbeEvidence
                                    ? .failed(displayName: displayName) : .unavailable(displayName: displayName)
                            }
                            for row in deferredRows where pendingRows.remove(row.rowName) != nil {
                                publishAutomaticState(
                                    row,
                                    target,
                                    retestSnapshot.finalLeaf.flatMap { snapshot.proxiesMap[$0] },
                                    state
                                )
                            }
                            Logger.log(
                                "[Proxy Delay] Selected automatic group '\(target.groupName)' completed in "
                                    + String(format: "%.2f", Date().timeIntervalSince(automaticRetestStartedAt))
                                    + "s; starting Selector rows"
                            )
                            speedTestItem.setBenchmarkProgressPhase(nil, session: session)
                            continuation()
                        }
                    }
                }
            }
        }

        ApiRequest.getMergedProxyData(session: session, timeout: 10) { response in
            guard !session.isCancelled,
                  AppDelegate.shared.isActiveBenchmarkSession(session) else {
                finish()
                return
            }
            guard let response else {
                speedTestItem.showBenchmarkFeedback(
                    title: NSLocalizedString("Benchmark unavailable", comment: ""),
                    message: NSLocalizedString("Proxy core unavailable. Please try again shortly.", comment: ""),
                    session: session
                )
                finish()
                return
            }
            guard let selector = response.proxiesMap[group.name] else {
                speedTestItem.showBenchmarkFeedback(
                    title: NSLocalizedString("Benchmark unavailable", comment: ""),
                    message: NSLocalizedString("Proxy group is no longer available. Refresh and try again.", comment: ""),
                    session: session
                )
                finish()
                return
            }
            selectorBenchmarkURL = selector.effectiveBenchmarkURL(
                fallback: Settings.benchMarkUrl
            )
            let freshPlan = SelectorBenchmarkPlan.make(
                selector: selector,
                snapshot: response,
                benchmarkURL: selectorBenchmarkURL,
                timeout: benchmarkMode.timeoutMilliseconds
            )
            if !retryingFailures {
                speedTestItem.clearSelectorAttemptOutcomes()
            }
            if freshPlan.targets.isEmpty, freshPlan.selectedAutomaticRetest == nil {
                speedTestItem.showBenchmarkFeedback(
                    title: NSLocalizedString("Benchmark unavailable", comment: ""),
                    message: NSLocalizedString("No testable proxy nodes", comment: ""),
                    session: session
                )
                finish()
                return
            }
            var selectedPlan = freshPlan
            if retryingFailures {
                guard let retryPlan = speedTestItem.retryingFailures(from: freshPlan) else {
                    speedTestItem.showBenchmarkFeedback(
                        title: NSLocalizedString("No failed nodes to retry", comment: ""),
                        message: NSLocalizedString("Only failed or timed-out nodes from the latest benchmark can be retried.", comment: ""),
                        session: session
                    )
                    finish()
                    return
                }
                selectedPlan = retryPlan
            }
            plan = selectedPlan
            DispatchQueue.main.async {
                guard !session.isCancelled,
                      AppDelegate.shared.isActiveBenchmarkSession(session) else {
                    finish()
                    return
                }
                if !retryingFailures {
                    SelectorBenchmarkPresentationStore.clear(selectorName: group.name)
                }
                pendingRows = Set(selectedPlan.orderedRows.compactMap { row in
                    row.measurementKey == nil && !row.isDeferredAutomaticRetest
                        ? nil
                        : row.rowName
                })
                session.onTermination {
                    // terminate() delivers on main. Settle synchronously before
                    // a subsequent session can own these rows; the old session
                    // has already lost AppDelegate ownership at this point.
                    guard session.isCancelled else { return }
                    presentationCoalescer.flush()
                    for row in selectedPlan.orderedRows where pendingRows.remove(row.rowName) != nil {
                        publishState(row, .unavailable(displayName: row.displayName))
                    }
                }
                for row in selectedPlan.orderedRows {
                    if row.measurementKey == nil && !row.isDeferredAutomaticRetest {
                        publishState(row, .unavailable(displayName: row.displayName))
                    } else {
                        publishState(row, .testing(displayName: row.displayName))
                    }
                }
                retestSelectedAutomaticGroup {
                    ApiRequest.benchmarkSelectorPlan(
                        selectedPlan,
                        reusing: reusableMeasurements,
                        session: session,
                        progress: { progress in
                            DispatchQueue.main.async {
                                speedTestItem.receiveBenchmarkProgress(progress, session: session)
                            }
                        },
                        result: publishResult,
                        completion: finish
                    )
                }
            }
        }
    }
}

extension ProxyGroupSpeedTestMenuItem {
    enum TestType {
        case benchmark
        case reTest
        case unknown

        var title: String {
            switch self {
            case .benchmark: return NSLocalizedString("Benchmark", comment: "")
            case .reTest: return NSLocalizedString("ReTest", comment: "")
            case .unknown: return ""
            }
        }
    }
}

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

class ProxyGroupSpeedTestMenuItem: NSMenuItem {
    let proxyGroup: ClashProxy
    let testType: TestType
    private var isTesting = false
    private var benchmarkActionSession: ApiRequest.BenchmarkSession?

    init(group: ClashProxy) {
        proxyGroup = group
        if group.type.isAutoGroup {
            testType = .reTest
        } else if group.type == .select {
            testType = .benchmark
        } else {
            testType = .unknown
        }

        super.init(title: NSLocalizedString("Benchmark", comment: ""), action: nil, keyEquivalent: "")
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
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func healthCheck() {
        guard testType == .reTest else { return }
        retestAutoGroup()
    }

    func retestAutoGroup() {
        guard testType == .reTest else { return }
        guard !isTesting else { return }
        guard let session = AppDelegate.shared.beginSpeedTest(showNotifications: false) else {
            return
        }

        beginBenchmarkAction(session: session)
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
            timeout: 5000,
            session: session
        ) { result in
            DispatchQueue.main.async {
                guard !session.isCancelled,
                      AppDelegate.shared.isActiveBenchmarkSession(session) else {
                    didFinishAction()
                    return
                }

                let candidateDelays = result.candidateDelays

                ApiRequest.getFreshProxyGroupList(session: session) { snapshot in
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
                            didFinishAction()
                            return
                        }

                        AutomaticChildBenchmarkStore.settle(
                            group: freshGroup,
                            candidateDelays: candidateDelays,
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
                            state = .unavailable(displayName: displayName)
                        }
                        AutomaticGroupBenchmarkPresentationStore.publish(
                            AutomaticGroupBenchmarkPresentation(
                                identity: AutomaticGroupBenchmarkIdentity(
                                    group: freshGroup,
                                    fallbackBenchmarkURL: Settings.benchMarkUrl
                                ),
                                selectedPath: retestSnapshot.selectedPath,
                                finalLeaf: retestSnapshot.finalLeaf ?? bestKnownLeaf,
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

    func beginBenchmarkAction(session: ApiRequest.BenchmarkSession) {
        benchmarkActionSession = session
        isTesting = true
        // Disabling the active custom-view item can end AppKit menu tracking.
        // Keep it enabled and let the benchmark session reject repeat clicks.
        updateViewTitle(NSLocalizedString("Testing", comment: ""))
        session.onTermination { [weak self] in
            self?.finishBenchmarkActionIfOwned(session: session)
        }
    }

    @discardableResult
    func finishBenchmarkActionIfOwned(session: ApiRequest.BenchmarkSession) -> Bool {
        guard benchmarkActionSession === session else { return false }
        benchmarkActionSession = nil
        isTesting = false
        updateViewTitle(testType.title)
        return true
    }
}

extension ProxyGroupSpeedTestMenuItem: ProxyGroupMenuHighlightDelegate {
    func highlight(item: NSMenuItem?) {
        (view as? ProxyGroupSpeedTestMenuItemView)?.isHighlighted = item == self
    }
}

private class ProxyGroupSpeedTestMenuItemView: MenuItemBaseView {
    private let label: NSTextField

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

    override var cells: [NSCell?] {
        return [label.cell]
    }

    override var labels: [NSTextField] {
        return [label]
    }

    func updateTitle(_ title: String) {
        label.stringValue = title
        setNeedsDisplay()
    }

    override func didClickView() {
        guard let speedTestItem = enclosingMenuItem as? ProxyGroupSpeedTestMenuItem else { return }
        switch speedTestItem.testType {
        case .benchmark:
            startBenchmark()
        case .reTest:
            speedTestItem.retestAutoGroup()
        case .unknown:
            break
        }
    }

    private func startBenchmark() {
        guard let speedTestItem = enclosingMenuItem as? ProxyGroupSpeedTestMenuItem else {
            return
        }
        let group = speedTestItem.proxyGroup
        guard let session = AppDelegate.shared.beginSpeedTest(showNotifications: false) else {
            return
        }

        speedTestItem.beginBenchmarkAction(session: session)

        var plan: SelectorBenchmarkPlan?
        var preflightSnapshot: ClashProxyResp?
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
                    benchmarkURL: row.measurementKey?.benchmarkURL ?? selectorBenchmarkURL,
                    sessionIdentifier: sessionIdentifier,
                    rowState: state
                )
            )
        }
        let publishAutomaticState: (
            SelectorBenchmarkRow,
            SelectorBenchmarkAutomaticRetestTarget,
            ClashProxyName?,
            ProxyBenchmarkRowState
        ) -> Void = { row, target, finalLeaf, state in
            SelectorBenchmarkPresentationStore.publish(
                SelectorBenchmarkPresentation(
                    selectorName: group.name,
                    rowName: row.rowName,
                    resolvedLeafName: finalLeaf,
                    benchmarkURL: target.benchmarkURL,
                    sessionIdentifier: sessionIdentifier,
                    rowState: state
                )
            )
        }
        let publishResult: (SelectorBenchmarkPlan.Target, Int) -> Void = { target, delay in
            DispatchQueue.main.async {
                guard !session.isCancelled,
                      AppDelegate.shared.isActiveBenchmarkSession(session) else {
                    return
                }
                for row in target.aliases {
                    guard pendingRows.remove(row.rowName) != nil else { continue }
                    let state: ProxyBenchmarkRowState = delay == 0
                        ? .failed(displayName: row.displayName)
                        : .measured(displayName: row.displayName, delay: delay)
                    presentationCoalescer.enqueue(
                        SelectorBenchmarkPresentation(
                            selectorName: group.name,
                            rowName: row.rowName,
                            resolvedLeafName: row.measurementKey?.proxyName,
                            benchmarkURL: row.measurementKey?.benchmarkURL ?? selectorBenchmarkURL,
                            sessionIdentifier: sessionIdentifier,
                            rowState: state
                        )
                    )
                }
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
            Logger.log(
                "[Proxy Delay] Prioritizing selected automatic group '\(target.groupName)' before Selector rows"
            )

            ApiRequest.getProxyGroupDelay(
                groupName: target.groupName,
                benchmarkURL: target.benchmarkURL,
                expectedStatus: target.expectedStatus,
                timeout: 5000,
                session: session
            ) { result in
                DispatchQueue.main.async {
                    guard !session.isCancelled,
                          AppDelegate.shared.isActiveBenchmarkSession(session) else {
                        finish()
                        return
                    }

                    ApiRequest.getFreshProxyGroupList(session: session) { snapshot in
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
                                AutomaticGroupBenchmarkPresentationStore.settleTestingAsUnavailable(
                                    groupName: target.groupName,
                                    finalLeaf: nil,
                                    sessionIdentifier: sessionIdentifier
                                )
                                AutomaticChildBenchmarkStore.settleTestingAsUnavailable(
                                    groupName: target.groupName,
                                    sessionIdentifier: sessionIdentifier
                                )
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
                                AutomaticGroupBenchmarkPresentationStore.settleTestingAsUnavailable(
                                    groupName: target.groupName,
                                    finalLeaf: nil,
                                    sessionIdentifier: sessionIdentifier
                                )
                                AutomaticChildBenchmarkStore.settleTestingAsUnavailable(
                                    groupName: target.groupName,
                                    sessionIdentifier: sessionIdentifier
                                )
                                continuation()
                                return
                            }

                            // Restore Provider ownership on the fresh topology
                            // before matching direct candidates to Selector targets.
                            if let providers = preflightSnapshot?.enclosingProviderResp {
                                snapshot.updateProvider(providers)
                            }
                            AutomaticChildBenchmarkStore.settle(
                                group: freshGroup,
                                candidateDelays: result.candidateDelays,
                                sessionIdentifier: sessionIdentifier
                            )
                            reusableMeasurements = plan.reusableMeasurements(
                                group: freshGroup,
                                candidateDelays: result.candidateDelays,
                                timeout: 5000
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
                                state = .unavailable(displayName: displayName)
                            }
                            for row in deferredRows where pendingRows.remove(row.rowName) != nil {
                                publishAutomaticState(
                                    row,
                                    target,
                                    retestSnapshot.finalLeaf,
                                    state
                                )
                            }
                            AutomaticGroupBenchmarkPresentationStore.publish(
                                AutomaticGroupBenchmarkPresentation(
                                    identity: AutomaticGroupBenchmarkIdentity(
                                        group: freshGroup,
                                        fallbackBenchmarkURL: Settings.benchMarkUrl
                                    ),
                                    selectedPath: retestSnapshot.selectedPath,
                                    finalLeaf: retestSnapshot.finalLeaf,
                                    sessionIdentifier: sessionIdentifier,
                                    rowState: state
                                )
                            )
                            Logger.log(
                                "[Proxy Delay] Selected automatic group '\(target.groupName)' completed in "
                                    + String(format: "%.2f", Date().timeIntervalSince(automaticRetestStartedAt))
                                    + "s; starting Selector rows"
                            )
                            continuation()
                        }
                    }
                }
            }
        }

        ApiRequest.getMergedProxyData(session: session, timeout: 10) { response in
            guard let response, let selector = response.proxiesMap[group.name] else {
                finish()
                return
            }
            selectorBenchmarkURL = selector.effectiveBenchmarkURL(
                fallback: Settings.benchMarkUrl
            )
            preflightSnapshot = response
            plan = SelectorBenchmarkPlan.make(
                selector: selector,
                snapshot: response,
                benchmarkURL: selectorBenchmarkURL,
                timeout: 5000
            )
            guard let plan else {
                finish()
                return
            }
            DispatchQueue.main.async {
                guard !session.isCancelled,
                      AppDelegate.shared.isActiveBenchmarkSession(session) else {
                    finish()
                    return
                }
                SelectorBenchmarkPresentationStore.clear(selectorName: group.name)
                pendingRows = Set(plan.orderedRows.compactMap { row in
                    row.measurementKey == nil && !row.isDeferredAutomaticRetest
                        ? nil
                        : row.rowName
                })
                session.onTermination {
                    DispatchQueue.main.async {
                        guard session.isCancelled,
                              AppDelegate.shared.isActiveBenchmarkSession(session) else {
                            return
                        }
                        for row in plan.orderedRows where pendingRows.remove(row.rowName) != nil {
                            publishState(row, .unavailable(displayName: row.displayName))
                        }
                        if let target = plan.selectedAutomaticRetest {
                            AutomaticGroupBenchmarkPresentationStore.settleTestingAsUnavailable(
                                groupName: target.groupName,
                                finalLeaf: nil,
                                sessionIdentifier: sessionIdentifier
                            )
                            AutomaticChildBenchmarkStore.settleTestingAsUnavailable(
                                groupName: target.groupName,
                                sessionIdentifier: sessionIdentifier
                            )
                        }
                        presentationCoalescer.flush()
                    }
                }
                for row in plan.orderedRows {
                    if row.measurementKey == nil && !row.isDeferredAutomaticRetest {
                        publishState(row, .unavailable(displayName: row.displayName))
                    } else {
                        publishState(row, .testing(displayName: row.displayName))
                    }
                }
                if let target = plan.selectedAutomaticRetest,
                   let automaticGroup = response.proxiesMap[target.groupName] {
                    AutomaticGroupBenchmarkPresentationStore.begin(
                        group: automaticGroup,
                        sessionIdentifier: sessionIdentifier
                    )
                    AutomaticChildBenchmarkStore.begin(
                        group: automaticGroup,
                        sessionIdentifier: sessionIdentifier
                    )
                }
                retestSelectedAutomaticGroup {
                    ApiRequest.benchmarkSelectorPlan(
                        plan,
                        reusing: reusableMeasurements,
                        session: session,
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

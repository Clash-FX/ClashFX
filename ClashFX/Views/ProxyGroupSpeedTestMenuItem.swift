//
//  ProxyGroupSpeedTestMenuItem.swift
//  ClashX
//
//  Created by yicheng on 2019/10/15.
//  Copyright © 2019 west2online. All rights reserved.
//

import Carbon
import Cocoa

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
        AutomaticGroupBenchmarkPresentationStore.begin(group: proxyGroup)

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
                        finalLeaf: bestKnownLeaf
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
                finalLeaf: bestKnownLeaf
            )
        }

        let benchmarkURL: String
        if let testURL = proxyGroup.testUrl, !testURL.isEmpty {
            benchmarkURL = testURL
        } else {
            benchmarkURL = Settings.benchMarkUrl
        }

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
                var publishedCandidates = Set<ClashProxyName>()
                for candidateName in self.proxyGroup.all ?? [] where publishedCandidates.insert(candidateName).inserted {
                    guard let delay = candidateDelays[candidateName] else { continue }
                    let state: ProxyBenchmarkRowState = delay > 0
                        ? .measured(displayName: candidateName, delay: delay)
                        : .failed(displayName: candidateName)
                    NotificationCenter.default.post(
                        name: .speedTestFinishForProxy,
                        object: nil,
                        userInfo: ["proxyName": candidateName, "benchmarkRowState": state]
                    )
                }

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
                                finalLeaf: bestKnownLeaf
                            )
                            didFinishAction()
                            return
                        }

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
                                groupName: self.proxyGroup.name,
                                selectedPath: retestSnapshot.selectedPath,
                                finalLeaf: retestSnapshot.finalLeaf ?? bestKnownLeaf,
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
        isEnabled = false
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
        isEnabled = true
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
        let publishState: (SelectorBenchmarkRow, ProxyBenchmarkRowState) -> Void = { row, state in
            NotificationCenter.default.post(
                name: .speedTestFinishForProxy,
                object: nil,
                userInfo: ["proxyName": row.rowName, "benchmarkRowState": state]
            )
        }
        let publishResult: (SelectorBenchmarkPlan.Target, Int) -> Void = { target, delay in
            DispatchQueue.main.async {
                guard !session.isCancelled,
                      AppDelegate.shared.isActiveBenchmarkSession(session) else {
                    return
                }
                for row in target.aliases {
                    let state: ProxyBenchmarkRowState = delay == 0
                        ? .failed(displayName: row.displayName)
                        : .measured(displayName: row.displayName, delay: delay)
                    publishState(row, state)
                }
            }
        }

        var didFinish = false
        let finish = { [weak speedTestItem] in
            DispatchQueue.main.async {
                guard !didFinish else { return }
                didFinish = true
                if AppDelegate.shared.isActiveBenchmarkSession(session) {
                    AppDelegate.shared.finishSpeedTest(
                        session: session,
                        showNotifications: false
                    )
                }
                speedTestItem?.finishBenchmarkActionIfOwned(session: session)
            }
        }

        ApiRequest.getMergedProxyData { response in
            guard let response, let selector = response.proxiesMap[group.name] else {
                finish()
                return
            }
            plan = SelectorBenchmarkPlan.make(
                selector: selector,
                snapshot: response,
                benchmarkURL: selector.testUrl ?? Settings.benchMarkUrl,
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
                for row in plan.orderedRows {
                    if row.measurementKey == nil {
                        publishState(row, .unavailable(displayName: row.displayName))
                    } else {
                        publishState(row, .testing(displayName: row.displayName))
                    }
                }
                ApiRequest.benchmarkSelectorPlan(
                    plan,
                    session: session,
                    result: publishResult,
                    completion: finish
                )
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

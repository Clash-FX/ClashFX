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
    private var refreshTimer: Timer?

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

        isTesting = true
        isEnabled = false
        updateViewTitle(NSLocalizedString("Testing", comment: ""))

        ApiRequest.getProxyGroupDelay(
            groupName: proxyGroup.name,
            benchmarkURL: proxyGroup.testUrl ?? Settings.benchMarkUrl,
            expectedStatus: proxyGroup.expectedStatus,
            session: session
        ) { _ in
            DispatchQueue.main.async {
                AppDelegate.shared.finishSpeedTest(
                    session: session,
                    showNotifications: false
                )
                self.isTesting = false
                self.isEnabled = true
                self.updateViewTitle(self.testType.title)
                self.scheduleMenuRefresh()
            }
        }
    }

    private func scheduleMenuRefresh() {
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
            MenuItemFactory.refreshExistingMenuItems()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateViewTitle(_ title: String) {
        self.title = title
        (view as? ProxyGroupSpeedTestMenuItemView)?.updateTitle(title)
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

        var proxies = [ClashProxyName]()
        var providerProxies = [ApiRequest.ProviderProxyBenchmarkTarget]()
        for testable in group.speedtestAble {
            switch testable {
            case let .provider(name, provider):
                providerProxies.append(
                    .init(providerName: provider, proxyName: name)
                )
            case let .proxy(name):
                proxies.append(name)
            }
        }

        label.stringValue = NSLocalizedString("Testing", comment: "")
        speedTestItem.isEnabled = false
        setNeedsDisplay()

        let finish = { [weak self, weak speedTestItem] in
            AppDelegate.shared.finishSpeedTest(
                session: session,
                showNotifications: false
            )
            guard let self, let menu = speedTestItem else { return }
            self.label.stringValue = menu.title
            menu.isEnabled = true
            self.setNeedsDisplay()
            MenuItemFactory.refreshExistingMenuItems()
        }

        ApiRequest.benchmarkProxySelection(
            proxyNames: proxies,
            providerProxies: providerProxies,
            benchmarkURL: Settings.benchMarkUrl,
            timeout: 5000,
            session: session,
            proxyResult: { proxyName, delay in
                let delayStr = delay == 0 ? NSLocalizedString("fail", comment: "") : "\(delay) ms"
                NotificationCenter.default.post(name: .speedTestFinishForProxy,
                                                object: nil,
                                                userInfo: ["proxyName": proxyName, "delay": delayStr, "rawValue": delay])
            },
            completion: {
                guard !session.isCancelled else {
                    finish()
                    return
                }
                guard let response = group.enclosingResp else {
                    finish()
                    return
                }
                ApiRequest.retestURLTestGroups(
                    in: response,
                    limitedTo: Set(group.all ?? []),
                    timeout: 5000,
                    session: session,
                    completion: finish
                )
            }
        )
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

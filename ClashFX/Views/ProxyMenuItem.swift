//
//  ProxyMenuItem.swift
//  ClashX
//
//  Created by CYC on 2019/2/18.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa

enum ProxyBenchmarkRowState {
    case testing(displayName: String)
    case measured(displayName: String, delay: Int)
    case failed(displayName: String)
    case unavailable(displayName: String)

    var presentationName: String {
        switch self {
        case let .testing(displayName),
             let .measured(displayName, _),
             let .failed(displayName),
             let .unavailable(displayName):
            return displayName
        }
    }

    var delayDisplay: String? {
        switch self {
        case .testing:
            return NSLocalizedString("Testing", comment: "")
        case let .measured(_, delay):
            return "\(delay) ms"
        case .failed:
            return NSLocalizedString("fail", comment: "")
        case .unavailable:
            return NSLocalizedString("Benchmark unavailable", comment: "")
        }
    }

    var rawDelay: Int? {
        switch self {
        case let .measured(_, delay):
            return delay
        case .failed:
            return 0
        case .testing, .unavailable:
            return nil
        }
    }
}

class ProxyMenuItem: NSMenuItem {
    let proxyName: String
    let maxProxyNameLength: CGFloat
    private var presentationName: String

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
        guard let name = note.userInfo?["proxyName"] as? String, name == proxyName else {
            return
        }
        if let state = note.userInfo?["benchmarkRowState"] as? ProxyBenchmarkRowState {
            applyBenchmarkRowState(state)
            return
        }
        if let delay = note.userInfo?["delay"] as? String {
            updateDelay(delay, rawValue: note.userInfo?["rawValue"] as? Int)
        }
    }

    @objc private func proxyInfoUpdate(note: Notification) {
        guard let info = note.object as? ClashProxy else {
            assertionFailure()
            return
        }
        if info.alive == false {
            updateDelay(NSLocalizedString("fail", comment: ""), rawValue: 0)
        } else {
            updateDelay(info.history.last?.delayDisplay, rawValue: info.history.last?.delay)
        }
    }

    @objc private func proxyGroupInfoUpdate(note: Notification) {
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

    func applyBenchmarkRowState(_ state: ProxyBenchmarkRowState) {
        presentationName = state.presentationName
        updatePresentation(name: presentationName, delay: state.delayDisplay, rawValue: state.rawDelay)
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

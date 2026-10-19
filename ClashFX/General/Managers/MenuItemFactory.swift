//
//  MenuItemFactory.swift
//  ClashX
//
//  Created by CYC on 2018/8/4.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import Cocoa
import RxCocoa
import SwiftyJSON

class MenuItemFactory {
    private static var cachedProxyData: ClashProxyResp?
    private static var cachedStructureSignature: ProxyMenuStructureSignature?
    private static var refreshCoordinator = ProxyMenuRefreshCoordinator()
    private static var benchmarkScope: String?
    private static var displayedBenchmarkURL: String?
    private static var selectionControllerGeneration: UInt64 = 0

    static let useViewToRenderProxy: Bool = AppDelegate.isAboveMacOS152

    // MARK: - Public

    static func refreshExistingMenuItems() {
        scheduleRefresh(.incremental)
    }

    static func recreateProxyMenuItems(coreReloaded: Bool = false) {
        let recreate = {
            advanceSelectionControllerGeneration()
            if coreReloaded { BenchmarkProbeDiagnosticsStore.clearAll() }
            // A mode change or reload of the same profile is not a new
            // benchmark scope. Validate retained evidence against the snapshot
            // below; changing profiles/controllers must clear every store.
            reconcileBenchmarkScope()
            if coreReloaded,
               cachedProxyData?.proxiesMap.values.contains(where: {
                   $0.all == nil && !ClashProxyType.isBuiltInProxy($0) && $0.id == nil
               }) == true {
                // Older remote cores cannot certify same-name node identity
                // across config reloads. Fail closed for their retained data.
                GlobalLeafBenchmarkPresentationStore.clearAll()
                AutomaticGroupBenchmarkPresentationStore.clearAll()
                AutomaticChildBenchmarkStore.clearAll()
                SelectorBenchmarkPresentationStore.clearAll()
            }
            scheduleRefresh(.rebuild)
        }
        if Thread.isMainThread { recreate() } else { DispatchQueue.main.async(execute: recreate) }
    }

    private static func scheduleRefresh(_ mode: ProxyMenuRefreshCoordinator.Mode) {
        let schedule = {
            guard let ticket = refreshCoordinator.request(mode) else { return }
            executeRefresh(ticket)
        }
        if Thread.isMainThread { schedule() } else { DispatchQueue.main.async(execute: schedule) }
    }

    private static func executeRefresh(_ ticket: ProxyMenuRefreshCoordinator.Ticket) {
        dispatchPrecondition(condition: .onQueue(.main))
        ApiRequest.getMergedProxyData { info in
            let completion = refreshCoordinator.complete(ticket)
            if completion.shouldApply {
                applyRefreshResult(info, mode: ticket.mode)
            }
            if let nextTicket = completion.nextTicket {
                executeRefresh(nextTicket)
            }
        }
    }

    private static func applyRefreshResult(
        _ info: ClashProxyResp?,
        mode: ProxyMenuRefreshCoordinator.Mode
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let info, !info.proxiesMap.isEmpty else {
            Logger.log(
                mode == .rebuild
                    ? "Kept existing proxy menu because the refreshed snapshot is empty"
                    : "Skipped proxy-menu refresh because no valid proxy snapshot is available",
                level: .warning
            )
            return
        }

        reconcileBenchmarkScope()
        GlobalLeafBenchmarkPresentationStore.prune(using: info)
        AutomaticGroupBenchmarkPresentationStore.prune(using: info)
        AutomaticChildBenchmarkStore.prune(using: info)
        SelectorBenchmarkPresentationStore.prune(using: info)
        let structure = ProxyMenuStructureSignature(snapshot: info)
        let previous = cachedProxyData
        let requiresRebuild = mode == .rebuild
            || previous == nil
            || structure != cachedStructureSignature
            || displayedBenchmarkURL != Settings.benchMarkUrl

        cachedProxyData = info
        cachedStructureSignature = structure
        displayedBenchmarkURL = Settings.benchMarkUrl
        guard !requiresRebuild, let previous else {
            refreshMenuItems(mergedData: info)
            return
        }

        for name in ProxyMenuSnapshotDelta.affectedNames(previous: previous, current: info).sorted() {
            guard let proxy = info.proxiesMap[name] else { continue }
            NotificationCenter.default.post(name: .proxyUpdate(for: name), object: proxy, userInfo: nil)
        }
    }

    static func refreshMenuItems(mergedData proxyInfo: ClashProxyResp?) {
        dispatchPrecondition(condition: .onQueue(.main))
        let leftPadding = AppDelegate.shared.hasMenuSelected()
        guard let proxyInfo = proxyInfo else { return }
        advanceSelectionControllerGeneration()
        var menuItems = [NSMenuItem]()
        let visibleGroups = proxyInfo.proxyGroups.filter { !($0.hidden ?? false) }
        for proxy in sortedProxyGroupsForMenu(visibleGroups) {
            var menu: NSMenuItem?
            switch proxy.type {
            case .select: menu = generateSelectorMenuItem(proxyGroup: proxy, proxyInfo: proxyInfo, leftPadding: leftPadding)
            case .urltest, .fallback: menu = generateUrlTestFallBackMenuItem(proxyGroup: proxy, proxyInfo: proxyInfo, leftPadding: leftPadding)
            case .loadBalance:
                menu = generateLoadBalanceMenuItem(proxyGroup: proxy, proxyInfo: proxyInfo, leftPadding: leftPadding)
            case .relay:
                menu = generateListOnlyMenuItem(proxyGroup: proxy, proxyInfo: proxyInfo)
            default: continue
            }

            if let menu = menu {
                menuItems.append(menu)
                menu.isEnabled = true
            }
        }
        updateProxyList(withMenus: Array(menuItems.reversed()))
    }

    private static func reconcileBenchmarkScope() {
        let scope = "\(RemoteControlManager.selectConfig?.uuid ?? ConfigManager.selectConfigName)\n\(ConfigManager.apiUrl)"
        guard benchmarkScope != scope else { return }
        BenchmarkProbeDiagnosticsStore.clearAll()
        benchmarkScope = scope
        GlobalLeafBenchmarkPresentationStore.clearAll()
        AutomaticGroupBenchmarkPresentationStore.clearAll()
        AutomaticChildBenchmarkStore.clearAll()
        SelectorBenchmarkPresentationStore.clearAll()
    }

    private static func advanceSelectionControllerGeneration() {
        dispatchPrecondition(condition: .onQueue(.main))
        selectionControllerGeneration &+= 1
        ProxyGroupSelectionController.invalidateAll()
    }

    private static func sortedProxyGroupsForMenu(_ groups: [ClashProxy]) -> [ClashProxy] {
        groups.enumerated().sorted { lhs, rhs in
            let lhsPriority = proxyGroupMenuPriority(lhs.element)
            let rhsPriority = proxyGroupMenuPriority(rhs.element)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func proxyGroupMenuPriority(_ group: ClashProxy) -> Int {
        switch group.type {
        case .select:
            return 0
        case .urltest, .fallback, .loadBalance:
            return 1
        case .relay:
            return 2
        default:
            return 3
        }
    }

    static func generateSwitchConfigMenuItems(complete: @escaping (([NSMenuItem]) -> Void)) {
        let generateMenuItem: ((String) -> NSMenuItem) = {
            config in
            let item = NSMenuItem(title: config, action: #selector(MenuItemFactory.actionSelectConfig(sender:)), keyEquivalent: "")
            item.target = MenuItemFactory.self
            item.state = ConfigManager.selectConfigName == config ? .on : .off
            return item
        }

        if RemoteControlManager.selectConfig != nil {
            complete([])
            return
        }

        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getConfigFilesList {
                complete($0.map { generateMenuItem($0) })
            }
        } else {
            complete(ConfigManager.getConfigFilesList().map { generateMenuItem($0) })
        }
    }

    // MARK: - Private

    // MARK: Updaters

    static func updateProxyList(withMenus menus: [NSMenuItem]) {
        let app = AppDelegate.shared
        let startIndex = app.statusMenu.items.firstIndex(of: app.separatorLineTop)! + 1
        let endIndex = app.statusMenu.items.firstIndex(of: app.sepatatorLineEndProxySelect)!
        let nodeHidden = !Settings.trayMenuShowNodeSwitch
        app.sepatatorLineEndProxySelect.isHidden = menus.isEmpty || nodeHidden
        for _ in 0 ..< endIndex - startIndex {
            app.statusMenu.removeItem(at: startIndex)
        }
        for each in menus {
            app.statusMenu.insertItem(each, at: startIndex)
            each.isHidden = nodeHidden
        }
    }

    // MARK: Generators

    private static func generateSelectorMenuItem(proxyGroup: ClashProxy,
                                                 proxyInfo: ClashProxyResp,
                                                 leftPadding: Bool) -> NSMenuItem? {
        let isGlobalMode = ConfigManager.shared.currentConfig?.mode == .global
        if !isGlobalMode {
            if proxyGroup.name == "GLOBAL" { return nil }
        }

        let menu = NSMenuItem(title: proxyGroup.name, action: nil, keyEquivalent: "")
        let selectedName = proxyGroup.now ?? ""
        if !Settings.disableShowCurrentProxyInMenu {
            menu.view = ProxyGroupMenuItemView(proxyGroup: proxyGroup, targetProxy: selectedName, hasLeftPadding: leftPadding)
        }
        let groupName = proxyGroup.name
        let controller = makeSelectionController(group: proxyGroup, snapshot: proxyInfo)
        let submenu = ProxyGroupMenu(title: groupName) { submenu in
            guard let snapshot = cachedProxyData,
                  let currentGroup = snapshot.proxiesMap[groupName],
                  currentGroup.type == .select,
                  controller.update(group: currentGroup, snapshot: snapshot) else { return }
            populateSelectorSubmenu(submenu, proxyGroup: currentGroup, proxyInfo: snapshot, controller: controller)
        }
        submenu.selectionController = controller
        menu.submenu = submenu
        return menu
    }

    private static func populateSelectorSubmenu(
        _ submenu: ProxyGroupMenu,
        proxyGroup: ClashProxy,
        proxyInfo: ClashProxyResp,
        controller: ProxyGroupSelectionController
    ) {
        for proxy in proxyGroup.all ?? [] {
            guard let proxyModel = proxyInfo.proxiesMap[proxy] else { continue }
            let proxyItem = ProxyMenuItem(
                proxy: proxyModel,
                group: proxyGroup,
                action: #selector(ProxyGroupSelectionController.selectProxy(sender:))
            )
            proxyItem.target = controller
            submenu.add(delegate: proxyItem)
            submenu.addItem(proxyItem)
            controller.register(candidateItem: proxyItem)
        }

        if proxyGroup.isSpeedTestable && useViewToRenderProxy {
            submenu.minimumWidth = proxyGroup.maxProxyNameLength + ProxyItemView.fixedPlaceHolderWidth
        }
        addSpeedTestMenuItem(submenu, proxyGroup: proxyGroup)
    }

    private static func generateUrlTestFallBackMenuItem(proxyGroup: ClashProxy,
                                                        proxyInfo: ClashProxyResp,
                                                        leftPadding: Bool) -> NSMenuItem? {
        let selectedName = proxyGroup.now ?? ""
        let menu = NSMenuItem(title: proxyGroup.name, action: nil, keyEquivalent: "")
        if !Settings.disableShowCurrentProxyInMenu {
            menu.view = ProxyGroupMenuItemView(proxyGroup: proxyGroup, targetProxy: selectedName, hasLeftPadding: leftPadding)
        }
        let groupName = proxyGroup.name
        let controller = makeSelectionController(group: proxyGroup, snapshot: proxyInfo)
        controller.attachHeaderItem(menu)
        let submenu = ProxyGroupMenu(title: groupName) { submenu in
            guard let snapshot = cachedProxyData,
                  let currentGroup = snapshot.proxiesMap[groupName],
                  currentGroup.supportsManualPriority,
                  controller.update(group: currentGroup, snapshot: snapshot) else { return }
            populateAutomaticSubmenu(submenu, proxyGroup: currentGroup, proxyInfo: snapshot, controller: controller)
        }
        submenu.selectionController = controller
        menu.submenu = submenu
        return menu
    }

    private static func populateAutomaticSubmenu(
        _ submenu: ProxyGroupMenu,
        proxyGroup: ClashProxy,
        proxyInfo: ClashProxyResp,
        controller: ProxyGroupSelectionController
    ) {
        for proxyName in proxyGroup.all ?? [] {
            guard let proxy = proxyInfo.proxiesMap[proxyName] else { continue }
            let proxyMenuItem = ProxyMenuItem(
                proxy: proxy,
                group: proxyGroup,
                action: #selector(ProxyGroupSelectionController.selectProxy(sender:))
            )
            proxyMenuItem.target = controller

            submenu.add(delegate: proxyMenuItem)
            submenu.addItem(proxyMenuItem)
            controller.register(candidateItem: proxyMenuItem)
        }
        if proxyGroup.isSpeedTestable && useViewToRenderProxy {
            submenu.minimumWidth = proxyGroup.maxProxyNameLength + ProxyItemView.fixedPlaceHolderWidth
        }
        let hasBenchmarkActions = addSpeedTestMenuItem(submenu, proxyGroup: proxyGroup)
        if let restoreItem = controller.restoreAutomaticItem {
            if hasBenchmarkActions {
                submenu.insertItem(restoreItem, at: min(2, submenu.numberOfItems))
            } else {
                submenu.addItem(restoreItem)
            }
        }
    }

    private static func makeSelectionController(
        group: ClashProxy,
        snapshot: ClashProxyResp
    ) -> ProxyGroupSelectionController {
        let configName = ConfigManager.selectConfigName
        let remoteControlID = RemoteControlManager.selectConfig?.uuid
        let apiURL = ConfigManager.apiUrl
        let coreGeneration = AppDelegate.shared.proxySelectionGeneration
        let controllerGeneration = selectionControllerGeneration
        let app = AppDelegate.shared

        return ProxyGroupSelectionController(
            group: group,
            snapshot: snapshot,
            dependencies: .init(
                isCurrent: {
                    ConfigManager.selectConfigName == configName
                        && RemoteControlManager.selectConfig?.uuid == remoteControlID
                        && ConfigManager.apiUrl == apiURL
                        && AppDelegate.shared.proxySelectionGeneration == coreGeneration
                        && selectionControllerGeneration == controllerGeneration
                },
                isCoreChanging: {
                    app.isConfigUpdating
                        || app.isEnhancedModeTransitionInProgress
                        || app.isRestoringProxySelection
                        || (RemoteControlManager.selectConfig == nil && !ConfigManager.shared.isRunning)
                },
                isBusyBenchmark: { app.isSpeedTesting },
                isInteractionReserved: { app.isConfigUpdateQueued },
                select: { groupName, name, complete in
                    ApiRequest.updateProxyGroup(group: groupName, selectProxy: name, callback: complete)
                },
                reset: { groupName, complete in
                    ApiRequest.resetProxyGroup(group: groupName, callback: complete)
                },
                refresh: { complete in
                    let session = ApiRequest.BenchmarkSession()
                    ApiRequest.getMergedProxyData(session: session, timeout: 10) { freshSnapshot in
                        session.terminate()
                        complete(freshSnapshot)
                    }
                },
                publish: { freshSnapshot in
                    applyRefreshResult(freshSnapshot, mode: .incremental)
                },
                rememberSelection: { groupName, name in
                    let model = SavedProxyModel(group: groupName, selected: name, config: configName)
                    ConfigManager.selectedProxyRecords.removeAll { $0.key == model.key }
                    ConfigManager.selectedProxyRecords.append(model)
                },
                closeConnections: {
                    ConnectionManager.closeAllConnection()
                },
                showError: { message in
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = NSLocalizedString("Proxy Selection Failed", comment: "")
                    alert.informativeText = message
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.runModal()
                },
                stageTimeout: 10
            )
        )
    }

    @discardableResult
    private static func addSpeedTestMenuItem(_ menu: NSMenu, proxyGroup: ClashProxy) -> Bool {
        guard !proxyGroup.speedtestAble.isEmpty else { return false }
        let speedTestItem = ProxyGroupSpeedTestMenuItem(group: proxyGroup)
        let separator = NSMenuItem.separator()
        menu.insertItem(separator, at: 0)
        menu.insertItem(speedTestItem.retryFailedNodesMenuItem, at: 0)
        menu.insertItem(speedTestItem, at: 0)
        (menu as? ProxyGroupMenu)?.add(delegate: speedTestItem)
        return true
    }

    private static func generateLoadBalanceMenuItem(proxyGroup: ClashProxy, proxyInfo: ClashProxyResp, leftPadding: Bool) -> NSMenuItem? {
        let menu = NSMenuItem(title: proxyGroup.name, action: nil, keyEquivalent: "")
        if !Settings.disableShowCurrentProxyInMenu {
            menu.view = ProxyGroupMenuItemView(proxyGroup: proxyGroup, targetProxy: NSLocalizedString("Load Balance", comment: ""), hasLeftPadding: leftPadding)
        }
        let groupName = proxyGroup.name
        let submenu = ProxyGroupMenu(title: groupName) { submenu in
            guard let snapshot = cachedProxyData,
                  let currentGroup = snapshot.proxiesMap[groupName],
                  currentGroup.type == .loadBalance else { return }
            populateLoadBalanceSubmenu(submenu, proxyGroup: currentGroup, proxyInfo: snapshot)
        }
        menu.submenu = submenu
        return menu
    }

    private static func populateLoadBalanceSubmenu(
        _ submenu: ProxyGroupMenu,
        proxyGroup: ClashProxy,
        proxyInfo: ClashProxyResp
    ) {
        for proxy in proxyGroup.all ?? [] {
            guard let proxyModel = proxyInfo.proxiesMap[proxy] else { continue }
            let proxyItem = ProxyMenuItem(proxy: proxyModel,
                                          group: proxyGroup,
                                          action: #selector(empty))
            proxyItem.target = MenuItemFactory.self
            submenu.add(delegate: proxyItem)
            submenu.addItem(proxyItem)
        }
        if proxyGroup.isSpeedTestable && useViewToRenderProxy {
            submenu.minimumWidth = proxyGroup.maxProxyNameLength + ProxyItemView.fixedPlaceHolderWidth
        }
        addSpeedTestMenuItem(submenu, proxyGroup: proxyGroup)
    }

    private static func generateListOnlyMenuItem(proxyGroup: ClashProxy, proxyInfo: ClashProxyResp) -> NSMenuItem? {
        let menu = NSMenuItem(title: proxyGroup.name, action: nil, keyEquivalent: "")
        let groupName = proxyGroup.name
        let submenu = ProxyGroupMenu(title: groupName) { submenu in
            guard let snapshot = cachedProxyData,
                  let currentGroup = snapshot.proxiesMap[groupName],
                  currentGroup.type == .relay else { return }
            populateListOnlySubmenu(submenu, proxyGroup: currentGroup, proxyInfo: snapshot)
        }
        menu.submenu = submenu
        return menu
    }

    private static func populateListOnlySubmenu(
        _ submenu: ProxyGroupMenu,
        proxyGroup: ClashProxy,
        proxyInfo: ClashProxyResp
    ) {
        for proxy in proxyGroup.all ?? [] {
            guard let proxyModel = proxyInfo.proxiesMap[proxy] else { continue }
            let proxyItem = ProxyMenuItem(proxy: proxyModel,
                                          group: proxyGroup,
                                          action: #selector(empty),
                                          simpleItem: true)
            proxyItem.target = MenuItemFactory.self
            submenu.add(delegate: proxyItem)
            submenu.addItem(proxyItem)
        }
    }
}

// MARK: - Action

extension MenuItemFactory {
    @objc static func actionSelectProxy(sender: ProxyMenuItem) {
        guard let menu = sender.menu as? ProxyGroupMenu else { return }
        if let controller = menu.selectionController {
            controller.selectProxy(sender: sender)
            return
        }
        guard let snapshot = cachedProxyData,
              let group = snapshot.proxiesMap[menu.title] else { return }
        let controller = makeSelectionController(group: group, snapshot: snapshot)
        menu.selectionController = controller
        controller.register(candidateItem: sender)
        controller.selectProxy(sender: sender)
    }

    @objc static func actionSelectConfig(sender: NSMenuItem) {
        let config = sender.title
        AppDelegate.shared.updateConfig(configName: config, showNotification: false) {
            err in
            if err == nil {
                ConnectionManager.closeAllConnection()
            }
        }
    }

    @objc static func empty() {}
}

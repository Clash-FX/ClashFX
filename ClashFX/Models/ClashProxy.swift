//
//  ClashProxy.swift
//  ClashX
//
//  Created by CYC on 2019/3/17.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa
import SwiftyJSON

enum ClashProxyType: String, Codable {
    case urltest = "URLTest"
    case fallback = "Fallback"
    case loadBalance = "LoadBalance"
    case select = "Selector"
    case direct = "Direct"
    case reject = "Reject"
    case shadowsocks = "Shadowsocks"
    case shadowsocksR = "ShadowsocksR"
    case socks5 = "Socks5"
    case http = "Http"
    case vmess = "Vmess"
    case snell = "Snell"
    case trojan = "Trojan"
    case relay = "Relay"
    case unknown = "Unknown"
    case wireguard = "Wireguard"
    case vless = "Vless"
    case hysteria = "Hysteria"
    case hysteria2 = "Hysteria2"
    case tuic = "Tuic"
    case ssh = "Ssh"
    case anytls = "Anytls"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ClashProxyType(rawValue: rawValue) ?? .unknown
    }

    static let proxyGroups: [ClashProxyType] = [.select, .urltest, .fallback, .loadBalance]

    var isAutoGroup: Bool {
        switch self {
        case .urltest, .fallback, .loadBalance:
            return true
        default:
            return false
        }
    }

    static func isProxyGroup(_ proxy: ClashProxy) -> Bool {
        switch proxy.type {
        case .select, .urltest, .fallback, .loadBalance, .relay: return true
        default: return false
        }
    }

    static func isBuiltInProxy(_ proxy: ClashProxy) -> Bool {
        switch proxy.name {
        case "DIRECT", "REJECT": return true
        default: return false
        }
    }
}

typealias ClashProxyName = String
typealias ClashProviderName = String

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

struct SelectorBenchmarkPresentation {
    let selectorName: ClashProxyName
    let rowName: ClashProxyName
    let resolvedLeafName: ClashProxyName?
    let benchmarkURL: String
    let sessionIdentifier: UUID
    let rowState: ProxyBenchmarkRowState

    func reconciled(
        with snapshot: ClashProxyResp,
        currentBenchmarkURL: String
    ) -> SelectorBenchmarkPresentation {
        guard benchmarkURL == currentBenchmarkURL else {
            return unavailable()
        }
        guard let resolvedLeafName else {
            return self
        }
        guard case let .resolved(_, leaf) = snapshot.resolveSelectedPath(from: rowName),
              leaf.name == resolvedLeafName else {
            return unavailable()
        }
        return self
    }

    private func unavailable() -> SelectorBenchmarkPresentation {
        switch rowState {
        case .unavailable:
            return self
        case .testing, .measured, .failed:
            return SelectorBenchmarkPresentation(
                selectorName: selectorName,
                rowName: rowName,
                resolvedLeafName: resolvedLeafName,
                benchmarkURL: benchmarkURL,
                sessionIdentifier: sessionIdentifier,
                rowState: .unavailable(displayName: rowName)
            )
        }
    }
}

enum SelectorBenchmarkEndpoint: Hashable {
    case inline
    case provider
}

struct SelectorBenchmarkMeasurementKey: Hashable {
    let endpoint: SelectorBenchmarkEndpoint
    let providerName: ClashProviderName?
    let proxyName: ClashProxyName
    let benchmarkURL: String
    let timeout: Int
}

enum SelectorBenchmarkUnavailableReason: Hashable {
    case cycle(ClashProxyName)
    case missingNode(ClashProxyName)
    case missingSelection(ClashProxyName)
    case unknownTarget(ClashProxyName)
    case nonLeafTerminal(ClashProxyName)
}

enum SelectedProxyPathResolution {
    case resolved(path: [ClashProxyName], leaf: ClashProxy)
    case unavailable(path: [ClashProxyName], reason: SelectorBenchmarkUnavailableReason)
}

struct AutomaticGroupRetestSnapshot {
    enum Evidence {
        case measured(delay: Int)
        case zeroDelay(node: ClashProxyName)
        case unavailable(SelectorBenchmarkUnavailableReason)
        case noMatchingCandidate
    }

    let groupName: ClashProxyName
    let selectedPath: [ClashProxyName]
    let finalLeaf: ClashProxyName?
    let evidence: Evidence

    static func make(groupName: ClashProxyName,
                     candidateDelays: [ClashProxyName: Int],
                     snapshot: ClashProxyResp) -> AutomaticGroupRetestSnapshot {
        switch snapshot.resolveSelectedPath(from: groupName) {
        case let .unavailable(path, reason):
            return AutomaticGroupRetestSnapshot(
                groupName: groupName,
                selectedPath: path,
                finalLeaf: path.last,
                evidence: .unavailable(reason)
            )
        case let .resolved(path, leaf):
            // Mihomo's fresh path is the only authority. Candidate values are display
            // evidence, never a policy input; the final leaf wins over its ancestors.
            let candidatePath = Array(path.dropFirst().reversed())
            for node in candidatePath {
                guard let delay = candidateDelays[node] else { continue }
                if delay > 0 {
                    return AutomaticGroupRetestSnapshot(
                        groupName: groupName,
                        selectedPath: path,
                        finalLeaf: leaf.name,
                        evidence: .measured(delay: delay)
                    )
                }
                return AutomaticGroupRetestSnapshot(
                    groupName: groupName,
                    selectedPath: path,
                    finalLeaf: leaf.name,
                    evidence: .zeroDelay(node: node)
                )
            }
            return AutomaticGroupRetestSnapshot(
                groupName: groupName,
                selectedPath: path,
                finalLeaf: leaf.name,
                evidence: .noMatchingCandidate
            )
        }
    }
}

struct SelectorBenchmarkRow {
    let rowName: ClashProxyName
    let displayName: String
    let measurementKey: SelectorBenchmarkMeasurementKey?
    let unavailableReason: SelectorBenchmarkUnavailableReason?
}

struct SelectorBenchmarkPlan {
    private static let smallPlanConcurrency = 6
    private static let largePlanConcurrency = 4
    private static let largePlanThreshold = 24

    struct Target {
        let key: SelectorBenchmarkMeasurementKey
        let aliases: [SelectorBenchmarkRow]
    }

    let orderedRows: [SelectorBenchmarkRow]
    let targets: [Target]

    /// Large menus can otherwise saturate the benchmark destination or the
    /// local connection pool and inflate every measured delay. Small plans
    /// keep a little more parallelism so their total completion time stays low.
    var maxConcurrentRequests: Int {
        guard !targets.isEmpty else { return 1 }
        let limit = targets.count > Self.largePlanThreshold
            ? Self.largePlanConcurrency
            : Self.smallPlanConcurrency
        return min(targets.count, limit)
    }

    static func make(selector: ClashProxy,
                     snapshot: ClashProxyResp,
                     benchmarkURL: String,
                     timeout: Int) -> SelectorBenchmarkPlan {
        let visibleNames = selector.all ?? []
        var orderedRows = [SelectorBenchmarkRow]()
        var aliases = [SelectorBenchmarkMeasurementKey: [SelectorBenchmarkRow]]()
        var targetOrder = [SelectorBenchmarkMeasurementKey]()

        for visibleName in visibleNames {
            let row = makeRow(
                visibleName: visibleName,
                snapshot: snapshot,
                benchmarkURL: benchmarkURL,
                timeout: timeout
            )
            orderedRows.append(row)
            guard let key = row.measurementKey else { continue }
            if aliases[key] == nil {
                aliases[key] = []
                targetOrder.append(key)
            }
            aliases[key]?.append(row)
        }

        let targets = targetOrder.compactMap { key -> Target? in
            guard let rows = aliases[key], !rows.isEmpty else { return nil }
            return Target(key: key, aliases: rows)
        }
        return SelectorBenchmarkPlan(orderedRows: orderedRows, targets: targets)
    }

    private static func makeRow(visibleName: ClashProxyName,
                                snapshot: ClashProxyResp,
                                benchmarkURL: String,
                                timeout: Int) -> SelectorBenchmarkRow {
        switch snapshot.resolveSelectedPath(from: visibleName) {
        case let .resolved(_, proxy):
            let endpoint: SelectorBenchmarkEndpoint
            let providerName: ClashProviderName?
            if let provider = proxy.enclosingProvider {
                endpoint = .provider
                providerName = provider.name
            } else {
                endpoint = .inline
                providerName = nil
            }
            return SelectorBenchmarkRow(
                rowName: visibleName,
                // Keep the visible Selector row stable. Expanding a nested
                // policy path here makes AppKit resize the open menu and can
                // overlap the delay badge on long node names.
                displayName: visibleName,
                measurementKey: SelectorBenchmarkMeasurementKey(
                    endpoint: endpoint,
                    providerName: providerName,
                    proxyName: proxy.name,
                    benchmarkURL: benchmarkURL,
                    timeout: timeout
                ),
                unavailableReason: nil
            )
        case let .unavailable(_, reason):
            Logger.log(
                "[Proxy Delay] Selector row '\(visibleName)' is unavailable: \(reason)",
                level: .warning
            )
            return SelectorBenchmarkRow(
                rowName: visibleName,
                displayName: visibleName,
                measurementKey: nil,
                unavailableReason: reason
            )
        }
    }
}

class ClashProxySpeedHistory: Codable {
    let time: Date
    let delay: Int
    let meanDelay: Int?

    class HisDateFormaterInstance {
        static let shared = HisDateFormaterInstance()
        lazy var formater: DateFormatter = {
            var f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
    }

    lazy var delayDisplay: String = {
        if let meanDelay, meanDelay > 0 {
            switch meanDelay {
            case 0: return NSLocalizedString("fail", comment: "")
            default: return "\(meanDelay) ms"
            }
        } else {
            switch delay {
            case 0: return NSLocalizedString("fail", comment: "")
            default: return "\(delay) ms"
            }
        }
    }()

    lazy var dateDisplay: String = HisDateFormaterInstance.shared.formater.string(from: time)

    lazy var displayString: String = "\(dateDisplay) \(delayDisplay)"
}

struct ClashProxyTestState: Codable {
    let alive: Bool
    let history: [ClashProxySpeedHistory]
}

class ClashProxy: Codable {
    let name: ClashProxyName
    let type: ClashProxyType
    let all: [ClashProxyName]?
    let history: [ClashProxySpeedHistory]
    let now: ClashProxyName?
    let alive: Bool?
    let extra: [String: ClashProxyTestState]?
    let hidden: Bool?
    let testUrl: String?
    let expectedStatus: String?
    weak var enclosingResp: ClashProxyResp?
    weak var enclosingProvider: ClashProvider?

    enum SpeedtestAbleItem {
        case proxy(name: ClashProxyName)
        case provider(name: ClashProxyName, provider: ClashProviderName)
    }

    private static var nameLengthCachedMap = [ClashProxyName: CGFloat]()
    static func cleanCache() {
        nameLengthCachedMap.removeAll()
    }

    lazy var speedtestAble: [SpeedtestAbleItem] = {
        guard let resp = enclosingResp, let allProxys = all else { return [] }
        var proxys = [SpeedtestAbleItem]()
        for proxy in allProxys {
            if let p = resp.proxiesMap[proxy] {
                if let provider = p.enclosingProvider {
                    proxys.append(.provider(name: p.name, provider: provider.name))
                } else {
                    proxys.append(.proxy(name: p.name))
                }
            }
        }
        return proxys
    }()

    lazy var isSpeedTestable: Bool = !speedtestAble.isEmpty

    private enum CodingKeys: String, CodingKey {
        case type, all, history, now, name, alive, extra, hidden, testUrl, expectedStatus
    }

    func testState(for benchmarkURL: String) -> ClashProxyTestState? {
        let normalizedURL = benchmarkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return nil }
        return extra?[normalizedURL]
    }

    func effectiveBenchmarkURL(fallback: String) -> String {
        testUrl
            .flatMap {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            ?? fallback
    }

    lazy var maxProxyNameLength: CGFloat = {
        let rect = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)

        let lengths = all?.compactMap { name -> CGFloat in
            if let length = ClashProxy.nameLengthCachedMap[name] {
                return length
            }

            let rects = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)
            let attr = [NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 14)]
            let length = (name as NSString)
                .boundingRect(with: rect,
                              options: .usesLineFragmentOrigin,
                              attributes: attr).width
            ClashProxy.nameLengthCachedMap[name] = length
            return length
        }
        return lengths?.max() ?? 0
    }()
}

class ClashProxyResp {
    var proxies: [ClashProxy]

    var proxiesMap: [ClashProxyName: ClashProxy]

    var enclosingProviderResp: ClashProviderResp?

    init(_ data: Data?) {
        guard let data
        else {
            self.proxiesMap = [:]
            self.proxies = []
            return
        }
        let proxies = JSON(data)["proxies"]
        var proxiesModel = [ClashProxy]()

        var proxiesMap = [ClashProxyName: ClashProxy]()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(DateFormatter.js)
        for value in proxies.dictionaryValue.values {
            guard let data = try? value.rawData() else {
                continue
            }
            guard let proxy = try? decoder.decode(ClashProxy.self, from: data) else {
                continue
            }
            proxiesModel.append(proxy)
            proxiesMap[proxy.name] = proxy
        }
        self.proxiesMap = proxiesMap
        self.proxies = proxiesModel

        for proxy in self.proxies {
            proxy.enclosingResp = self
        }
    }

    func resolveSelectedPath(from name: ClashProxyName) -> SelectedProxyPathResolution {
        var path = [ClashProxyName]()
        var visited = Set<ClashProxyName>()
        var currentName = name

        while true {
            guard let proxy = proxiesMap[currentName] else {
                let reason: SelectorBenchmarkUnavailableReason = path.isEmpty
                    ? .missingNode(currentName)
                    : .unknownTarget(currentName)
                return .unavailable(path: path, reason: reason)
            }
            guard !visited.contains(proxy.name) else {
                return .unavailable(path: path, reason: .cycle(proxy.name))
            }

            visited.insert(proxy.name)
            path.append(proxy.name)
            guard ClashProxyType.isProxyGroup(proxy) else {
                guard proxy.all == nil else {
                    return .unavailable(path: path, reason: .nonLeafTerminal(proxy.name))
                }
                return .resolved(path: path, leaf: proxy)
            }

            guard let selectedName = proxy.now, !selectedName.isEmpty else {
                return .unavailable(path: path, reason: .missingSelection(proxy.name))
            }
            currentName = selectedName
        }
    }

    func updateProvider(_ providerResp: ClashProviderResp) {
        enclosingProviderResp = providerResp
        for provider in providerResp.providers.values {
            for proxy in provider.proxies {
                proxy.enclosingProvider = provider
                proxiesMap[proxy.name] = proxy
                proxies.append(proxy)
            }
        }
    }

    lazy var proxiesSortMap: [ClashProxyName: Int] = {
        var map = [ClashProxyName: Int]()
        for (idx, proxy) in (self.proxiesMap["GLOBAL"]?.all ?? []).enumerated() {
            map[proxy] = idx
        }
        return map
    }()

    lazy var proxyGroups: [ClashProxy] = proxies.filter {
        ClashProxyType.isProxyGroup($0)
    }.sorted(by: { proxiesSortMap[$0.name] ?? -1 < proxiesSortMap[$1.name] ?? -1 })

    lazy var longestProxyGroupName = proxyGroups.max { $1.name.count > $0.name.count }?.name ?? ""

    lazy var maxProxyNameLength: CGFloat = {
        let rect = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)
        let attr = [NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 0)]
        return (self.longestProxyGroupName as NSString)
            .boundingRect(with: rect,
                          options: .usesLineFragmentOrigin,
                          attributes: attr).width
    }()
}

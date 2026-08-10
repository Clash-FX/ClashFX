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

struct SelectorBenchmarkRow {
    let rowName: ClashProxyName
    let displayName: String
    let measurementKey: SelectorBenchmarkMeasurementKey?
    let unavailableReason: SelectorBenchmarkUnavailableReason?
}

struct SelectorBenchmarkPlan {
    struct Target {
        let key: SelectorBenchmarkMeasurementKey
        let aliases: [SelectorBenchmarkRow]
    }

    let orderedRows: [SelectorBenchmarkRow]
    let targets: [Target]

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
        switch resolve(name: visibleName, snapshot: snapshot, visited: []) {
        case let .leaf(proxy, path):
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
                displayName: path.joined(separator: " → "),
                measurementKey: SelectorBenchmarkMeasurementKey(
                    endpoint: endpoint,
                    providerName: providerName,
                    proxyName: proxy.name,
                    benchmarkURL: benchmarkURL,
                    timeout: timeout
                ),
                unavailableReason: nil
            )
        case let .unavailable(reason):
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

    private enum Resolution {
        case leaf(ClashProxy, [ClashProxyName])
        case unavailable(SelectorBenchmarkUnavailableReason)
    }

    private static func resolve(name: ClashProxyName,
                                snapshot: ClashProxyResp,
                                visited: Set<ClashProxyName>) -> Resolution {
        guard let proxy = snapshot.proxiesMap[name] else {
            return .unavailable(.missingNode(name))
        }
        guard !visited.contains(proxy.name) else {
            return .unavailable(.cycle(proxy.name))
        }
        guard ClashProxyType.isProxyGroup(proxy) else {
            guard proxy.all == nil else {
                return .unavailable(.nonLeafTerminal(proxy.name))
            }
            return .leaf(proxy, [proxy.name])
        }
        guard let selectedName = proxy.now, !selectedName.isEmpty else {
            return .unavailable(.missingSelection(proxy.name))
        }
        guard snapshot.proxiesMap[selectedName] != nil else {
            return .unavailable(.unknownTarget(selectedName))
        }

        switch resolve(name: selectedName,
                       snapshot: snapshot,
                       visited: visited.union([proxy.name])) {
        case let .leaf(leaf, path):
            return .leaf(leaf, [proxy.name] + path)
        case let .unavailable(reason):
            return .unavailable(reason)
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

class ClashProxy: Codable {
    let name: ClashProxyName
    let type: ClashProxyType
    let all: [ClashProxyName]?
    let history: [ClashProxySpeedHistory]
    let now: ClashProxyName?
    let alive: Bool?
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
        case type, all, history, now, name, alive, hidden, testUrl, expectedStatus
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

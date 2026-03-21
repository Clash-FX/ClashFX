import Foundation
import Yams

// MARK: - OrderedDictionary

struct OrderedDictionary<Key: Hashable, Value>: Sequence {
    private(set) var orderedKeys: [Key] = []
    private var dict: [Key: Value] = [:]

    var isEmpty: Bool {
        orderedKeys.isEmpty
    }

    var count: Int {
        orderedKeys.count
    }

    init() {}

    init(_ elements: [(Key, Value)]) {
        for (k, v) in elements {
            orderedKeys.append(k)
            dict[k] = v
        }
    }

    subscript(key: Key) -> Value? {
        get { dict[key] }
        set {
            if let val = newValue {
                if dict[key] == nil {
                    orderedKeys.append(key)
                }
                dict[key] = val
            } else {
                removeValue(forKey: key)
            }
        }
    }

    mutating func removeValue(forKey key: Key) {
        dict.removeValue(forKey: key)
        orderedKeys.removeAll { $0 == key }
    }

    func makeIterator() -> IndexingIterator<[(Key, Value)]> {
        orderedKeys.compactMap { key in
            dict[key].map { (key, $0) }
        }.makeIterator()
    }
}

// MARK: - Enums

enum DNSEnhancedMode: String {
    case fakeIP = "fake-ip"
    case redirHost = "redir-host"
    case normal
}

enum ProxyType: String {
    case vmess, vless, trojan, ss, hysteria2, wireguard
    case http, socks5, ssh, ssr, snell, tuic
    case hysteria, direct, reject, dns
    case anytls, mieru, masque, sudoku, trusttunnel
    case unknown

    init(raw: String) {
        self = ProxyType(rawValue: raw) ?? .unknown
    }
}

enum ProxyGroupType: String {
    case select
    case urlTest = "url-test"
    case fallback
    case loadBalance = "load-balance"
    case relay
    case unknown

    init(raw: String) {
        self = ProxyGroupType(rawValue: raw) ?? .unknown
    }
}

// MARK: - GeneralConfig

class GeneralConfig {
    var port: Int?
    var socksPort: Int?
    var mixedPort: Int?
    var redirPort: Int?
    var tproxyPort: Int?
    var allowLan: Bool?
    var bindAddress: String?
    var mode: ClashProxyMode = .rule
    var logLevel: ClashLogLevel = .info
    var ipv6: Bool?
    var externalController: String?
    var externalControllerTls: String?
    var secret: String?
    var externalUI: String?
    var externalUIName: String?
    var externalUIUrl: String?
    var findProcessMode: String?
    var tcpConcurrent: Bool?
    var unifiedDelay: Bool?
    var keepAliveInterval: Int?
    var keepAliveIdle: Int?
    var disableKeepAlive: Bool?
    var interfaceName: String?
    var routingMark: Int?
    var geodataMode: Bool?
    var geodataLoader: String?
    var geoAutoUpdate: Bool?
    var geoUpdateInterval: Int?
    var globalClientFingerprint: String?
    var globalUA: String?
    var etagSupport: Bool?
    var profile: [String: Any]?
    var tls: [String: Any]?
    var authentication: [String]?
    var skipAuthPrefixes: [String]?
    var lanAllowedIps: [String]?
    var lanDisallowedIps: [String]?
    var geoxUrl: [String: Any]?
    var unknownFields = OrderedDictionary<String, Any>()

    static let knownKeys: Set<String> = [
        "port", "socks-port", "mixed-port", "redir-port", "tproxy-port",
        "allow-lan", "bind-address", "mode", "log-level", "ipv6",
        "external-controller", "external-controller-tls", "secret",
        "external-ui", "external-ui-name", "external-ui-url",
        "find-process-mode", "tcp-concurrent", "unified-delay",
        "keep-alive-interval", "keep-alive-idle", "disable-keep-alive",
        "interface-name", "routing-mark", "geodata-mode", "geodata-loader",
        "geo-auto-update", "geo-update-interval", "global-client-fingerprint",
        "global-ua", "etag-support", "profile", "tls", "authentication",
        "skip-auth-prefixes", "lan-allowed-ips", "lan-disallowed-ips", "geox-url",
    ]

    func load(from dict: [String: Any]) {
        port = dict["port"] as? Int
        socksPort = dict["socks-port"] as? Int
        mixedPort = dict["mixed-port"] as? Int
        redirPort = dict["redir-port"] as? Int
        tproxyPort = dict["tproxy-port"] as? Int
        allowLan = dict["allow-lan"] as? Bool
        bindAddress = dict["bind-address"] as? String
        if let m = dict["mode"] as? String { mode = ClashProxyMode(rawValue: m) ?? .rule }
        if let l = dict["log-level"] as? String { logLevel = ClashLogLevel(rawValue: l) ?? .info }
        ipv6 = dict["ipv6"] as? Bool
        externalController = dict["external-controller"] as? String
        externalControllerTls = dict["external-controller-tls"] as? String
        secret = dict["secret"] as? String
        externalUI = dict["external-ui"] as? String
        externalUIName = dict["external-ui-name"] as? String
        externalUIUrl = dict["external-ui-url"] as? String
        findProcessMode = dict["find-process-mode"] as? String
        tcpConcurrent = dict["tcp-concurrent"] as? Bool
        unifiedDelay = dict["unified-delay"] as? Bool
        keepAliveInterval = dict["keep-alive-interval"] as? Int
        keepAliveIdle = dict["keep-alive-idle"] as? Int
        disableKeepAlive = dict["disable-keep-alive"] as? Bool
        interfaceName = dict["interface-name"] as? String
        routingMark = dict["routing-mark"] as? Int
        geodataMode = dict["geodata-mode"] as? Bool
        geodataLoader = dict["geodata-loader"] as? String
        geoAutoUpdate = dict["geo-auto-update"] as? Bool
        geoUpdateInterval = dict["geo-update-interval"] as? Int
        globalClientFingerprint = dict["global-client-fingerprint"] as? String
        globalUA = dict["global-ua"] as? String
        etagSupport = dict["etag-support"] as? Bool
        profile = dict["profile"] as? [String: Any]
        tls = dict["tls"] as? [String: Any]
        authentication = dict["authentication"] as? [String]
        skipAuthPrefixes = dict["skip-auth-prefixes"] as? [String]
        lanAllowedIps = dict["lan-allowed-ips"] as? [String]
        lanDisallowedIps = dict["lan-disallowed-ips"] as? [String]
        geoxUrl = dict["geox-url"] as? [String: Any]
    }

    func toOrderedDict() -> OrderedDictionary<String, Any> {
        var d = OrderedDictionary<String, Any>()
        if let v = port { d["port"] = v }
        if let v = socksPort { d["socks-port"] = v }
        if let v = mixedPort { d["mixed-port"] = v }
        if let v = redirPort { d["redir-port"] = v }
        if let v = tproxyPort { d["tproxy-port"] = v }
        if let v = allowLan { d["allow-lan"] = v }
        if let v = bindAddress { d["bind-address"] = v }
        d["mode"] = mode.rawValue
        d["log-level"] = logLevel.rawValue
        if let v = ipv6 { d["ipv6"] = v }
        if let v = externalController { d["external-controller"] = v }
        if let v = externalControllerTls { d["external-controller-tls"] = v }
        if let v = secret { d["secret"] = v }
        if let v = externalUI { d["external-ui"] = v }
        if let v = externalUIName { d["external-ui-name"] = v }
        if let v = externalUIUrl { d["external-ui-url"] = v }
        if let v = findProcessMode { d["find-process-mode"] = v }
        if let v = tcpConcurrent { d["tcp-concurrent"] = v }
        if let v = unifiedDelay { d["unified-delay"] = v }
        if let v = keepAliveInterval { d["keep-alive-interval"] = v }
        if let v = keepAliveIdle { d["keep-alive-idle"] = v }
        if let v = disableKeepAlive { d["disable-keep-alive"] = v }
        if let v = interfaceName { d["interface-name"] = v }
        if let v = routingMark { d["routing-mark"] = v }
        if let v = geodataMode { d["geodata-mode"] = v }
        if let v = geodataLoader { d["geodata-loader"] = v }
        if let v = geoAutoUpdate { d["geo-auto-update"] = v }
        if let v = geoUpdateInterval { d["geo-update-interval"] = v }
        if let v = globalClientFingerprint { d["global-client-fingerprint"] = v }
        if let v = globalUA { d["global-ua"] = v }
        if let v = etagSupport { d["etag-support"] = v }
        if let v = profile { d["profile"] = v }
        if let v = tls { d["tls"] = v }
        if let v = authentication { d["authentication"] = v }
        if let v = skipAuthPrefixes { d["skip-auth-prefixes"] = v }
        if let v = lanAllowedIps { d["lan-allowed-ips"] = v }
        if let v = lanDisallowedIps { d["lan-disallowed-ips"] = v }
        if let v = geoxUrl { d["geox-url"] = v }
        for (k, v) in unknownFields {
            d[k] = v
        }
        return d
    }
}

// MARK: - DNSConfig

class DNSConfig {
    var enable: Bool?
    var listen: String?
    var ipv6: Bool?
    var enhancedMode: DNSEnhancedMode?
    var fakeIPRange: String?
    var fakeIPFilterMode: String?
    var fakeIPFilter: [String]?
    var fakeIPTTL: Int?
    var cacheAlgorithm: String?
    var preferH3: Bool?
    var useHosts: Bool?
    var useSystemHosts: Bool?
    var respectRules: Bool?
    var defaultNameserver: [String]?
    var nameserver: [String]?
    var fallback: [String]?
    var proxyServerNameserver: [String]?
    var nameserverPolicy: [String: Any]?
    var fallbackFilter: [String: Any]?
    var unknownFields = OrderedDictionary<String, Any>()

    static let knownKeys: Set<String> = [
        "enable", "listen", "ipv6", "enhanced-mode", "fake-ip-range",
        "fake-ip-filter-mode", "fake-ip-filter", "fake-ip-ttl",
        "cache-algorithm", "prefer-h3", "use-hosts", "use-system-hosts",
        "respect-rules", "default-nameserver", "nameserver", "fallback",
        "proxy-server-nameserver", "nameserver-policy", "fallback-filter",
    ]

    func load(from dict: [String: Any]) {
        enable = dict["enable"] as? Bool
        listen = dict["listen"] as? String
        ipv6 = dict["ipv6"] as? Bool
        if let m = dict["enhanced-mode"] as? String { enhancedMode = DNSEnhancedMode(rawValue: m) }
        fakeIPRange = dict["fake-ip-range"] as? String
        fakeIPFilterMode = dict["fake-ip-filter-mode"] as? String
        fakeIPFilter = dict["fake-ip-filter"] as? [String]
        fakeIPTTL = dict["fake-ip-ttl"] as? Int
        cacheAlgorithm = dict["cache-algorithm"] as? String
        preferH3 = dict["prefer-h3"] as? Bool
        useHosts = dict["use-hosts"] as? Bool
        useSystemHosts = dict["use-system-hosts"] as? Bool
        respectRules = dict["respect-rules"] as? Bool
        defaultNameserver = dict["default-nameserver"] as? [String]
        nameserver = dict["nameserver"] as? [String]
        fallback = dict["fallback"] as? [String]
        proxyServerNameserver = dict["proxy-server-nameserver"] as? [String]
        nameserverPolicy = dict["nameserver-policy"] as? [String: Any]
        fallbackFilter = dict["fallback-filter"] as? [String: Any]
        for (k, v) in dict where !DNSConfig.knownKeys.contains(k) {
            unknownFields[k] = v
        }
    }

    func toDict() -> [String: Any]? {
        var d = OrderedDictionary<String, Any>()
        if let v = enable { d["enable"] = v }
        if let v = listen { d["listen"] = v }
        if let v = ipv6 { d["ipv6"] = v }
        if let v = enhancedMode { d["enhanced-mode"] = v.rawValue }
        if let v = fakeIPRange { d["fake-ip-range"] = v }
        if let v = fakeIPFilterMode { d["fake-ip-filter-mode"] = v }
        if let v = fakeIPFilter { d["fake-ip-filter"] = v }
        if let v = fakeIPTTL { d["fake-ip-ttl"] = v }
        if let v = cacheAlgorithm { d["cache-algorithm"] = v }
        if let v = preferH3 { d["prefer-h3"] = v }
        if let v = useHosts { d["use-hosts"] = v }
        if let v = useSystemHosts { d["use-system-hosts"] = v }
        if let v = respectRules { d["respect-rules"] = v }
        if let v = defaultNameserver { d["default-nameserver"] = v }
        if let v = nameserver { d["nameserver"] = v }
        if let v = fallback { d["fallback"] = v }
        if let v = proxyServerNameserver { d["proxy-server-nameserver"] = v }
        if let v = nameserverPolicy { d["nameserver-policy"] = v }
        if let v = fallbackFilter { d["fallback-filter"] = v }
        for (k, v) in unknownFields {
            d[k] = v
        }
        guard !d.isEmpty else { return nil }
        var result: [String: Any] = [:]
        for (k, v) in d {
            result[k] = v
        }
        return result
    }

    var hasContent: Bool {
        enable != nil || listen != nil || nameserver != nil || enhancedMode != nil
    }
}

// MARK: - ProxyDefinition

struct ProxyDefinition {
    var name: String
    var type: ProxyType
    var server: String
    var port: Int
    var fields: OrderedDictionary<String, Any>

    static let coreKeys: Set<String> = ["name", "type", "server", "port"]

    init(from dict: [String: Any]) {
        name = dict["name"] as? String ?? ""
        type = ProxyType(raw: dict["type"] as? String ?? "unknown")
        server = dict["server"] as? String ?? ""
        port = dict["port"] as? Int ?? 0
        var f = OrderedDictionary<String, Any>()
        for (k, v) in dict where !ProxyDefinition.coreKeys.contains(k) {
            f[k] = v
        }
        fields = f
    }

    init(name: String, type: ProxyType, server: String = "", port: Int = 0) {
        self.name = name
        self.type = type
        self.server = server
        self.port = port
        fields = OrderedDictionary<String, Any>()
    }

    func toDict() -> OrderedDictionary<String, Any> {
        var d = OrderedDictionary<String, Any>()
        d["name"] = name
        d["type"] = type == .unknown ? "unknown" : type.rawValue
        if !server.isEmpty { d["server"] = server }
        if port > 0 { d["port"] = port }
        for (k, v) in fields {
            d[k] = v
        }
        return d
    }
}

// MARK: - ProxyGroupDefinition

struct ProxyGroupDefinition {
    var name: String
    var type: ProxyGroupType
    var proxies: [String]
    var use: [String]
    var url: String?
    var interval: Int?
    var tolerance: Int?
    var lazy: Bool?
    var filter: String?
    var excludeFilter: String?
    var fields: OrderedDictionary<String, Any>

    static let coreKeys: Set<String> = [
        "name", "type", "proxies", "use", "url", "interval",
        "tolerance", "lazy", "filter", "exclude-filter",
    ]

    init(from dict: [String: Any]) {
        name = dict["name"] as? String ?? ""
        type = ProxyGroupType(raw: dict["type"] as? String ?? "unknown")
        proxies = dict["proxies"] as? [String] ?? []
        use = dict["use"] as? [String] ?? []
        url = dict["url"] as? String
        interval = dict["interval"] as? Int
        tolerance = dict["tolerance"] as? Int
        lazy = dict["lazy"] as? Bool
        filter = dict["filter"] as? String
        excludeFilter = dict["exclude-filter"] as? String
        var f = OrderedDictionary<String, Any>()
        for (k, v) in dict where !ProxyGroupDefinition.coreKeys.contains(k) {
            f[k] = v
        }
        fields = f
    }

    init(name: String, type: ProxyGroupType) {
        self.name = name
        self.type = type
        proxies = []
        use = []
        fields = OrderedDictionary<String, Any>()
    }

    func toDict() -> OrderedDictionary<String, Any> {
        var d = OrderedDictionary<String, Any>()
        d["name"] = name
        d["type"] = type == .unknown ? "unknown" : type.rawValue
        if !proxies.isEmpty { d["proxies"] = proxies }
        if !use.isEmpty { d["use"] = use }
        if let v = url { d["url"] = v }
        if let v = interval { d["interval"] = v }
        if let v = tolerance { d["tolerance"] = v }
        if let v = lazy { d["lazy"] = v }
        if let v = filter { d["filter"] = v }
        if let v = excludeFilter { d["exclude-filter"] = v }
        for (k, v) in fields {
            d[k] = v
        }
        return d
    }
}

// MARK: - ConfigDocument

class ConfigDocument {
    var rawYAML: String = ""
    let general = GeneralConfig()
    let dns = DNSConfig()
    var proxies: [ProxyDefinition] = []
    var proxyGroups: [ProxyGroupDefinition] = []
    var rules: [String] = []
    var ruleProviders = OrderedDictionary<String, Any>()
    var proxyProviders = OrderedDictionary<String, Any>()
    var unknownSections = OrderedDictionary<String, Any>()

    static let sectionKeys: Set<String> = [
        "dns", "proxies", "proxy-groups", "rules",
        "rule-providers", "proxy-providers",
        "tun", "listeners", "sniffer", "hosts",
        "tunnels", "sub-rules", "ntp",
    ]

    static func loadFromYAML(_ yaml: String) throws -> ConfigDocument {
        let doc = ConfigDocument()
        doc.rawYAML = yaml

        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            return doc
        }

        var generalDict: [String: Any] = [:]
        for (key, value) in root {
            if ConfigDocument.sectionKeys.contains(key) {
                continue
            }
            generalDict[key] = value
        }
        doc.general.load(from: generalDict)

        for (key, value) in generalDict {
            if !GeneralConfig.knownKeys.contains(key), !ConfigDocument.sectionKeys.contains(key) {
                doc.general.unknownFields[key] = value
            }
        }

        if let dnsDict = root["dns"] as? [String: Any] {
            doc.dns.load(from: dnsDict)
        }

        if let proxyList = root["proxies"] as? [[String: Any]] {
            doc.proxies = proxyList.map { ProxyDefinition(from: $0) }
        }

        if let groupList = root["proxy-groups"] as? [[String: Any]] {
            doc.proxyGroups = groupList.map { ProxyGroupDefinition(from: $0) }
        }

        if let ruleList = root["rules"] as? [String] {
            doc.rules = ruleList
        }

        if let providers = root["rule-providers"] as? [String: Any] {
            for (k, v) in providers {
                doc.ruleProviders[k] = v
            }
        }

        if let providers = root["proxy-providers"] as? [String: Any] {
            for (k, v) in providers {
                doc.proxyProviders[k] = v
            }
        }

        let allKnownKeys = GeneralConfig.knownKeys.union(ConfigDocument.sectionKeys)
        for (key, value) in root {
            if !allKnownKeys.contains(key) {
                doc.unknownSections[key] = value
            }
        }

        return doc
    }

    func toYAMLDictionary() -> OrderedDictionary<String, Any> {
        var root = general.toOrderedDict()

        if dns.hasContent, let dnsDict = dns.toDict() {
            root["dns"] = dnsDict
        }

        if !proxies.isEmpty {
            root["proxies"] = proxies.map { proxy -> [String: Any] in
                var d: [String: Any] = [:]
                let ordered = proxy.toDict()
                for (k, v) in ordered {
                    d[k] = v
                }
                return d
            }
        }

        if !proxyGroups.isEmpty {
            root["proxy-groups"] = proxyGroups.map { group -> [String: Any] in
                var d: [String: Any] = [:]
                let ordered = group.toDict()
                for (k, v) in ordered {
                    d[k] = v
                }
                return d
            }
        }

        if !rules.isEmpty {
            root["rules"] = rules
        }

        if !ruleProviders.isEmpty {
            var d: [String: Any] = [:]
            for (k, v) in ruleProviders {
                d[k] = v
            }
            root["rule-providers"] = d
        }

        if !proxyProviders.isEmpty {
            var d: [String: Any] = [:]
            for (k, v) in proxyProviders {
                d[k] = v
            }
            root["proxy-providers"] = d
        }

        for (k, v) in unknownSections {
            root[k] = v
        }

        return root
    }

    func serializeToYAML() -> String {
        YAMLSerializer.serialize(self)
    }
}

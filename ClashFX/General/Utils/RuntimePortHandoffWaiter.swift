import Darwin
import Foundation

/// Process exit does not guarantee Darwin will let a different UID rebind
/// the proxy's TCP endpoints. Check the requested bind domains before apply.
enum RuntimePortHandoffWaiter {
    static let defaultTimeout: TimeInterval = 45

    enum Transport: String {
        case tcp
        case udp

        var socketType: Int32 { self == .tcp ? SOCK_STREAM : SOCK_DGRAM }
        var socketProtocol: Int32 { self == .tcp ? IPPROTO_TCP : IPPROTO_UDP }
    }

    struct Endpoint: Hashable {
        let host: String
        let port: Int
        let transport: Transport

        init(host: String, port: Int, transport: Transport = .tcp) {
            self.host = RuntimePortHandoffWaiter.canonicalHost(host) ?? host
            self.port = port
            self.transport = transport
        }

        fileprivate var isWildcard: Bool { host == "*" || host == "0.0.0.0" }
        fileprivate var isIPv4: Bool { !host.contains(":") && !host.contains("*") }

        fileprivate func covers(_ candidate: Endpoint) -> Bool {
            guard port == candidate.port, transport == candidate.transport else { return false }
            return host == candidate.host || host == "*" || (host == "0.0.0.0" && candidate.isIPv4)
        }
    }

    /// Only the five global proxy listeners are projected here. The core
    /// validates custom listeners, DNS and the controller on its normal path.
    static func endpoints(in root: [String: Any], excluding owned: [String: Any]? = nil) -> [Endpoint] {
        let candidates = globalEndpoints(root)
        let requestedPorts = Set(candidates.map(\.port))
        let baseline = owned.map { globalEndpoints($0) + namedBaselineEndpoints($0, ports: requestedPorts) } ?? []
        var requested = Set<Endpoint>()
        for endpoint in candidates {
            if baseline.contains(where: { owner in
                guard owner.covers(endpoint) else { return false }
                // A distinct TCP socket can own a specific address inside an
                // existing wildcard. Probe the exact address with SO_REUSEADDR.
                return owner.host == endpoint.host || endpoint.isWildcard || endpoint.transport == .udp
            }) { continue }
            let overlapping = baseline.filter { endpoint.covers($0) }
            if endpoint.isWildcard, !overlapping.isEmpty {
                // A wildcard probe can conflict with our narrower baseline.
                // Check the local address claims it does not already cover.
                let local = concreteLocalHosts()
                if local.error == 0 {
                    let probeIPv4Wildcard = endpoint.host == "*" && !overlapping.contains { $0.isIPv4 }
                    if probeIPv4Wildcard {
                        requested.insert(Endpoint(host: "0.0.0.0", port: endpoint.port, transport: endpoint.transport))
                    }
                    for host in local.hosts {
                        let concrete = Endpoint(host: host, port: endpoint.port, transport: endpoint.transport)
                        if probeIPv4Wildcard, concrete.isIPv4 { continue }
                        if endpoint.covers(concrete), !overlapping.contains(where: { $0.covers(concrete) }) {
                            requested.insert(concrete)
                        }
                    }
                    continue
                }
            }
            requested.insert(endpoint)
        }
        return sortedEndpoints(requested)
    }

    /// Mirrors the global proxy overrides applied before Go starts config.yaml.
    static func bootstrapEndpoints(in root: [String: Any], proxyPortOverride: Int, allowLANOverride: Bool?) -> [Endpoint] {
        var effective = root
        var mixed = port(root["mixed-port"])
        if (1 ... 65_535).contains(proxyPortOverride) {
            mixed = proxyPortOverride
        } else if mixed == 0 {
            let http = port(root["port"])
            let socks = port(root["socks-port"])
            mixed = http > 0 ? http : socks > 0 ? socks : 7890
        }
        effective["mixed-port"] = mixed
        for key in ["port", "socks-port"] where port(root[key]) == mixed {
            effective[key] = 0
        }
        if let allowLANOverride { effective["allow-lan"] = allowLANOverride }
        return endpoints(in: effective)
    }

    static func sortedEndpoints(_ endpoints: Set<Endpoint>) -> [Endpoint] {
        return endpoints.sorted {
            ($0.port, $0.transport.rawValue, $0.host) < ($1.port, $1.transport.rawValue, $1.host)
        }
    }

    /// All identity checks and callbacks run on main. Socket operations never do.
    /// Retry only EADDRINUSE. Permission and address errors fail promptly.
    static func wait(
        for endpoints: [Endpoint],
        timeout: TimeInterval = defaultTimeout,
        interval: TimeInterval = 0.25,
        isCurrent: @escaping () -> Bool,
        onWaiting: @escaping ([Int]) -> Void = { _ in },
        completion: @escaping (String?) -> Void
    ) {
        wait(for: endpoints, deadline: ProcessInfo.processInfo.systemUptime + max(0, timeout),
             interval: interval, isCurrent: isCurrent, onWaiting: onWaiting, completion: completion)
    }

    static func wait(
        for endpoints: [Endpoint],
        deadline: TimeInterval,
        interval: TimeInterval = 0.25,
        isCurrent: @escaping () -> Bool,
        onWaiting: @escaping ([Int]) -> Void = { _ in },
        completion: @escaping (String?) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        func timeoutError(_ busy: [Endpoint]) -> String {
            let labels = Set(busy.map { "\($0.port)/\($0.transport.rawValue)" }).sorted()
            return "Proxy port handoff timed out before bind readiness was confirmed for \(labels.joined(separator: ", "))."
        }
        func attempt(_ lastBusy: [Endpoint]) {
            guard isCurrent() else { completion("Port handoff cancelled: runtime scope changed"); return }
            guard !endpoints.isEmpty else { completion(nil); return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                completion(timeoutError(lastBusy.isEmpty ? endpoints : lastBusy))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let failures = endpoints.compactMap { endpoint -> (Endpoint, Int32)? in
                    let error = bindError(endpoint)
                    return error == 0 ? nil : (endpoint, error)
                }
                DispatchQueue.main.async {
                    guard isCurrent() else { completion("Port handoff cancelled: runtime scope changed"); return }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    let busy = failures.map { $0.0 }
                    guard remaining > 0 else {
                        completion(timeoutError(busy.isEmpty ? endpoints : busy))
                        return
                    }
                    guard !failures.isEmpty else { completion(nil); return }
                    if let fatal = failures.first(where: { $0.1 != EADDRINUSE }) {
                        completion("Proxy port \(fatal.0.port)/\(fatal.0.transport.rawValue) cannot be prepared (socket errno \(fatal.1))")
                        return
                    }
                    if lastBusy.isEmpty { onWaiting(Set(busy.map { $0.port }).sorted()) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + min(max(0.01, interval), remaining)) { attempt(busy) }
                }
            }
        }
        attempt([])
    }

    static func bindError(_ endpoint: Endpoint) -> Int32 {
        let error = bindSocket(endpoint)
        guard error == 0, endpoint.isWildcard else { return error }
        if endpoint.host == "*", endpoint.transport == .tcp {
            // Darwin can give a native IPv4 wildcard the same port as a
            // mapped IPv6 wildcard. Check the native IPv4 bind separately.
            let ipv4 = Endpoint(host: "0.0.0.0", port: endpoint.port)
            let ipv4Error = bindSocket(ipv4)
            if ipv4Error != 0, ipv4Error != EAFNOSUPPORT, ipv4Error != EPROTONOSUPPORT { return ipv4Error }
        }
        // Darwin can let a wildcard listener coexist with a concrete claim.
        // Check the concrete addresses that would otherwise receive traffic.
        let local = concreteLocalHosts()
        guard local.error == 0 else { return local.error }
        for host in local.hosts {
            let concrete = Endpoint(host: host, port: endpoint.port, transport: endpoint.transport)
            guard endpoint.covers(concrete) else { continue }
            let error = bindSocket(concrete)
            if error == EADDRNOTAVAIL || error == EAFNOSUPPORT || error == EPROTONOSUPPORT {
                // The interface may have disappeared since the snapshot.
                continue
            }
            if error != 0 { return error }
        }
        return 0
    }

    private static func globalEndpoints(_ root: [String: Any]) -> [Endpoint] {
        let allowLAN = root["allow-lan"] as? Bool ?? false
        let address = allowLAN ? root["bind-address"] as? String ?? "*" : "127.0.0.1"
        // Use only numeric addresses. Core validation handles other names.
        guard let host = canonicalHost(address) else { return [] }
        let listeners: [(String, [Transport])] = [
            ("port", [.tcp]), ("socks-port", [.tcp, .udp]), ("mixed-port", [.tcp, .udp]),
            ("redir-port", [.tcp]), ("tproxy-port", [.tcp, .udp])
        ]
        return listeners.flatMap { key, transports -> [Endpoint] in
            let number = port(root[key])
            guard number > 0 else { return [] }
            return transports.map { proxyEndpoint(host: host, port: number, transport: $0) }
        }
    }

    /// The verified baseline can hold a requested global endpoint through a
    /// named listener. Mirror the core's last-entry-wins name lookup and
    /// include only addresses and transports of recognized listener types.
    private static func namedBaselineEndpoints(_ root: [String: Any], ports: Set<Int>) -> [Endpoint] {
        guard let listeners = root["listeners"] as? [[String: Any]], !ports.isEmpty else { return [] }
        var seen = Set<String>()
        var endpoints: [Endpoint] = []
        for listener in listeners.reversed() {
            let name = (listener["name"] as? String) ?? (listener["name"] as? NSNumber)?.stringValue ?? ""
            let address = listener["listen"] as? String ?? ""
            guard seen.insert(name).inserted, let host = canonicalHost(address.isEmpty ? "0.0.0.0" : address) else { continue }
            let transports = namedTransports(listener)
            for port in ports where namedPortSpec(listener["port"], includes: port) {
                endpoints.append(contentsOf: transports.map { proxyEndpoint(host: host, port: port, transport: $0) })
            }
        }
        return endpoints
    }

    private static func namedTransports(_ listener: [String: Any]) -> [Transport] {
        let udp = boolean(listener["udp"]) ?? true
        switch listener["type"] as? String {
        case "http", "redir", "vmess", "vless", "trojan", "anytls", "sudoku":
            return [.tcp]
        case "socks", "mixed", "tproxy":
            return udp ? [.tcp, .udp] : [.tcp]
        case "shadowsocks":
            let kcp = listener["kcp-tun"] as? [String: Any]
            return boolean(kcp?["enable"]) == true ? [.udp] : (udp ? [.tcp, .udp] : [.tcp])
        case "tuic", "hysteria2":
            return [.udp]
        case "mieru":
            return Transport(rawValue: (listener["transport"] as? String ?? "").lowercased()).map { [$0] } ?? []
        case "tunnel":
            return (listener["network"] as? [String] ?? []).compactMap(Transport.init(rawValue:))
        case "trusttunnel":
            let networks = listener["network"] as? [String] ?? []
            if networks.isEmpty { return [.tcp] }
            return [.tcp, .udp].filter { transport in
                networks.contains { $0.lowercased().hasPrefix(transport.rawValue) }
            }
        default:
            return []
        }
    }

    private static func namedPortSpec(_ value: Any?, includes candidate: Int) -> Bool {
        guard let text = value as? String else { return port(value) == candidate }
        return text.split(whereSeparator: { $0 == "/" || $0 == "," }).contains { item in
            let bounds = item.split(separator: "-", omittingEmptySubsequences: false)
            let numbers = bounds.compactMap { UInt16($0.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) }
            guard numbers.count == bounds.count, let first = numbers.first, let last = numbers.last,
                  numbers.count <= 2 else { return false }
            return Int(first) <= candidate && candidate <= Int(last)
        }
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "t", "1": return true
            case "false", "f", "0": return false
            default: return nil
            }
        }
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw.rounded(.towardZero) == raw else { return nil }
        return number.boolValue
    }

    private static func proxyEndpoint(host: String, port: Int, transport: Transport) -> Endpoint {
        // Generic Go UDP binds 0.0.0.0 as a dual-stack wildcard.
        let bindHost = host == "0.0.0.0" && transport == .udp ? "*" : host
        return Endpoint(host: bindHost, port: port, transport: transport)
    }

    private static func port(_ value: Any?) -> Int {
        if let text = value as? String, let port = Int(text), (1 ... 65_535).contains(port) { return port }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let port = number.doubleValue
        guard port.isFinite, port.rounded(.towardZero) == port, (1 ... 65_535).contains(port) else { return 0 }
        return number.intValue
    }

    private static func canonicalHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "*" || host.isEmpty { return "*" }
        if host == "localhost" { return "127.0.0.1" }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return host }

        let parts = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = parts.first else { return nil }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, String(address), &ipv6) == 1 else { return nil }
        var name = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &ipv6, &name, socklen_t(name.count)) != nil else { return nil }
        let numeric = String(cString: name)
        if numeric == "::" { return "*" }
        if numeric.hasPrefix("::ffff:"), numeric.dropFirst("::ffff:".count).contains(".") {
            return String(numeric.dropFirst("::ffff:".count))
        }
        if parts.count == 2 { return numeric + "%" + parts[1] }
        return numeric
    }

    private static func concreteLocalHosts() -> (hosts: [String], error: Int32) {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return ([], errno) }
        defer { freeifaddrs(first) }
        var hosts = Set(["127.0.0.1", "::1"])
        var cursor = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0,
               let host = canonicalHost(String(cString: name)) {
                hosts.insert(host)
            }
        }
        return (hosts.sorted(), 0)
    }

    private static func bindSocket(_ endpoint: Endpoint) -> Int32 {
        let dualStack = endpoint.host == "*"
        let host = dualStack ? "::" : endpoint.host
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = dualStack ? AF_INET6 : AF_UNSPEC
        hints.ai_socktype = endpoint.transport.socketType
        hints.ai_protocol = endpoint.transport.socketProtocol
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(endpoint.port), &hints, &addresses) == 0, let first = addresses else { return EADDRNOTAVAIL }
        defer { freeaddrinfo(first) }
        let address = first.pointee
        let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard fd >= 0 else {
            let error = errno
            if dualStack, error == EAFNOSUPPORT || error == EPROTONOSUPPORT {
                return bindSocket(Endpoint(host: "0.0.0.0", port: endpoint.port, transport: endpoint.transport))
            }
            return error
        }
        defer { close(fd) }
        if endpoint.transport == .tcp {
            var reuse: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else { return errno }
        }
        if address.ai_family == AF_INET6 {
            var only: Int32 = dualStack ? 0 : 1
            guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout.size(ofValue: only))) == 0 else { return errno }
        }
        guard bind(fd, address.ai_addr, address.ai_addrlen) == 0 else { return errno }
        if endpoint.transport == .tcp, listen(fd, 1) != 0 { return errno }
        return 0
    }
}

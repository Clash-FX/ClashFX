import Darwin
import Foundation

/// Process exit is not proof that Darwin permits a different UID to rebind its
/// TCP endpoints. Probe the requested endpoints before mutating a staging core.
/// Never changes configured ports, enables port sharing, or stops other owners.
enum RuntimePortHandoffWaiter {
    struct Endpoint: Hashable {
        let host: String
        let port: Int
    }

    static func endpoints(in root: [String: Any], excluding owned: [String: Any]? = nil) -> [Endpoint] {
        func ports(_ root: [String: Any]) -> Set<Int> {
            return Set(["port", "socks-port", "mixed-port", "redir-port", "tproxy-port"].compactMap { key in
                if let text = root[key] as? String, let port = Int(text), (1 ... 65_535).contains(port) { return port }
                guard let number = root[key] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                let value = number.doubleValue
                guard value.isFinite, value.rounded(.towardZero) == value, (1 ... 65_535).contains(value) else { return nil }
                return number.intValue
            })
        }
        var ownedPorts = owned.map(ports) ?? []
        // Custom inbounds are also owned by the confirmed embedded baseline.
        // Mihomo releases/replaces them before rebuilding global listeners.
        for listener in owned?["listeners"] as? [[String: Any]] ?? [] {
            if let port = listener["port"] { ownedPorts.formUnion(ports(["port": port])) }
        }
        let allowLAN = root["allow-lan"] as? Bool ?? false
        let address = allowLAN ? (root["bind-address"] as? String ?? "*") : "127.0.0.1"
        let host = address == "localhost" ? "127.0.0.1" : address
        return ports(root).subtracting(ownedPorts).sorted().map { Endpoint(host: host, port: $0) }
    }

    /// All identity checks and callbacks run on main; socket operations never do.
    /// Retry only EADDRINUSE. Permission/address errors fail promptly.
    static func wait(
        for endpoints: [Endpoint],
        timeout: TimeInterval = 45,
        interval: TimeInterval = 0.25,
        isCurrent: @escaping () -> Bool,
        onWaiting: @escaping ([Int]) -> Void = { _ in },
        completion: @escaping (String?) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        func attempt(_ reported: Bool) {
            guard isCurrent() else { completion("Port handoff cancelled: runtime scope changed"); return }
            DispatchQueue.global(qos: .utility).async {
                let failures = endpoints.compactMap { endpoint -> (Endpoint, Int32)? in
                    let error = bindError(endpoint)
                    return error == 0 ? nil : (endpoint, error)
                }
                DispatchQueue.main.async {
                    guard isCurrent() else { completion("Port handoff cancelled: runtime scope changed"); return }
                    guard !failures.isEmpty else { completion(nil); return }
                    let ports = failures.map { $0.0.port }.sorted()
                    if let fatal = failures.first(where: { $0.1 != EADDRINUSE }) {
                        completion("Proxy port \(fatal.0.port) cannot be prepared (socket errno \(fatal.1))")
                        return
                    }
                    if !reported { onWaiting(ports) }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        completion("Proxy port handoff timed out; ports \(ports.map(String.init).joined(separator: ", ")) remain unavailable. No ports were changed and no other process was stopped.")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, interval)) { attempt(true) }
                }
            }
        }
        attempt(false)
    }

    static func bindError(_ endpoint: Endpoint) -> Int32 {
        let error = bindError(endpoint, ipv4Only: false)
        guard error == 0, isWildcard(endpoint.host) else { return error }
        // An IPv4 wildcard can coexist with an IPv6 wildcard on Darwin even
        // with mapped IPv4 enabled. Probe the native IPv4 wildcard separately.
        let ipv4Error = bindError(endpoint, ipv4Only: true)
        if ipv4Error != 0, ipv4Error != EAFNOSUPPORT, ipv4Error != EPROTONOSUPPORT { return ipv4Error }
        // Darwin may let a wildcard SO_REUSEADDR listener coexist with a
        // concrete listener, which would still receive traffic to its address.
        // Check the concrete local bind claims as well as the wildcard socket.
        let local = concreteLocalHosts()
        guard local.error == 0 else { return local.error }
        for host in local.hosts {
            let error = bindError(Endpoint(host: host, port: endpoint.port), ipv4Only: false)
            if error == EADDRNOTAVAIL || error == EAFNOSUPPORT || error == EPROTONOSUPPORT {
                // An interface can disappear after the snapshot. The wildcard
                // listener can still bind on the interfaces that remain.
                continue
            }
            if error != 0 { return error }
        }
        return 0
    }

    private static func isWildcard(_ host: String) -> Bool {
        return ["*", "", "0.0.0.0", "::", "[::]"].contains(host)
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
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                hosts.insert(String(cString: name))
            }
        }
        return (hosts.sorted(), 0)
    }

    private static func bindError(_ endpoint: Endpoint, ipv4Only: Bool) -> Int32 {
        // Go's wildcard TCP listener prefers dual-stack IPv6. Match that bind
        // domain; use IPv4 only on systems where IPv6 sockets are unavailable.
        let wildcard = isWildcard(endpoint.host)
        let host = wildcard ? (ipv4Only ? "0.0.0.0" : "::") : endpoint.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = wildcard ? (ipv4Only ? AF_INET : AF_INET6) : AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(endpoint.port), &hints, &addresses) == 0, let first = addresses else { return EADDRNOTAVAIL }
        defer { freeaddrinfo(first) }
        let address = first.pointee
        let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard fd >= 0 else {
            let error = errno
            if wildcard, !ipv4Only, error == EAFNOSUPPORT || error == EPROTONOSUPPORT {
                return bindError(endpoint, ipv4Only: true)
            }
            return error
        }
        defer { close(fd) }
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else { return errno }
        if address.ai_family == AF_INET6 {
            var only: Int32 = 0
            guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout.size(ofValue: only))) == 0 else { return errno }
        }
        guard bind(fd, address.ai_addr, address.ai_addrlen) == 0 else { return errno }
        guard listen(fd, 1) == 0 else { return errno }
        return 0
    }
}

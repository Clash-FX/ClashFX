import Darwin
import Foundation
import Yams

/// Maps node names to their server hostnames from a profile, so a failing node
/// can be told apart as "hostname does not resolve" or "resolves but unreachable".
enum ProxyServerIndex {
    static func servers(inYAML text: String) -> [String: String] {
        guard let root = (try? Yams.load(yaml: text)) as? [String: Any],
              let proxies = root["proxies"] as? [[String: Any]] else { return [:] }
        var servers: [String: String] = [:]
        for proxy in proxies {
            if let name = proxy["name"] as? String, let server = proxy["server"] as? String, !server.isEmpty {
                servers[name] = server
            }
        }
        return servers
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}

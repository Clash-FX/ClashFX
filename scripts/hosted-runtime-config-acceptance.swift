import Darwin
import Foundation

private struct Manifest: Decodable {
    let controllerURL: String
    let secret: String
    let coreBinary: String
    let configPath: String
    let homeDir: String
    let artifactDirectory: String
}

private enum Failure: Error { case check(String) }

private final class Acceptance {
    let manifest: Manifest
    let output: URL
    let session: URLSession
    var assertions = [[String: Any]]()
    var applyCount = 0
    let scope = "hosted-runtime-acceptance-\(UUID().uuidString)"
    var controller: RuntimeConfigTransactionController!
    var validator: RuntimeConfigValidationRunner!
    var originFD: Int32 = -1
    var originPort = 0
    let originStopped = DispatchGroup()

    init(_ manifest: Manifest) throws {
        self.manifest = manifest
        output = URL(fileURLWithPath: manifest.artifactDirectory)
        let environment = ProcessInfo.processInfo.environment
        guard getuid() == 0, environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted", environment["RUNNER_OS"] == "macOS",
              let workspace = environment["GITHUB_WORKSPACE"], workspace.hasPrefix("/Users/runner/work/"),
              let temporary = environment["RUNNER_TEMP"], temporary.hasPrefix("/Users/runner/work/") else {
            throw Failure.check("Refused: disposable hosted macOS guest required")
        }
        for path in [manifest.configPath, manifest.coreBinary, manifest.artifactDirectory, manifest.homeDir] {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard resolved.hasPrefix(temporary + "/") || resolved.hasPrefix(workspace + "/") else {
                throw Failure.check("Refused: fixture path outside hosted checkout/temp")
            }
        }
        guard let endpoint = URLComponents(string: manifest.controllerURL), endpoint.scheme == "http",
              endpoint.host == "127.0.0.1", endpoint.port != nil else { throw Failure.check("non-loopback controller") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        controller = RuntimeConfigTransactionController(directory: URL(fileURLWithPath: manifest.homeDir).appendingPathComponent("runtime-acceptance-snapshots"), timeout: 20)
        validator = RuntimeConfigValidationRunner(binary: URL(fileURLWithPath: manifest.coreBinary),
                resourceDirectory: URL(fileURLWithPath: manifest.configPath).deletingLastPathComponent(), timeout: 8)
    }

    func check(_ value: Bool, _ name: String) throws {
        assertions.append(["name": name, "passed": value])
        if !value { throw Failure.check(name) }
    }

    func wait<T>(_ begin: (@escaping (T) -> Void) -> Void) throws -> T {
        var result: T?
        begin { result = $0 }
        let deadline = Date().addingTimeInterval(35)
        while result == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard let value = result else { throw Failure.check("fixture callback deadline") }
        return value
    }

    func request(_ method: String, _ path: String, _ body: [String: Any]? = nil,
                 completion: @escaping (Data?, Int, Error?) -> Void) {
        var request = URLRequest(url: URL(string: manifest.controllerURL + path)!)
        request.httpMethod = method
        request.setValue("Bearer " + manifest.secret, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async { completion(data, (response as? HTTPURLResponse)?.statusCode ?? 0, error) }
        }.resume()
    }

    func readback() throws -> [String: Any] {
        let result: (Data?, Int, Error?) = try wait { done in request("GET", "/configs") { done(($0, $1, $2)) } }
        guard result.1 == 200, result.2 == nil, let data = result.0,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.check("core readback failed")
        }
        return root
    }

    func dnsAAnswerMatchesRange(_ packet: [UInt8], range: String) -> Bool {
        let cidr = range.split(separator: "/", omittingEmptySubsequences: false)
        guard cidr.count == 2, let prefix = Int(cidr[1]), (0 ... 32).contains(prefix) else { return false }
        let components = cidr[0].split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { UInt32($0) }
        guard components.count == 4, octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
        let network = octets.reduce(UInt32(0)) { ($0 << 8) | $1 }
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - prefix)
        guard packet.count >= 12, packet[2] & 0x80 != 0, packet[2] & 0x02 == 0,
              packet[3] & 0x0f == 0 else { return false }
        func word(_ offset: Int) -> Int { Int(packet[offset]) * 256 + Int(packet[offset + 1]) }
        func skipName(_ offset: inout Int) -> Bool {
            while offset < packet.count {
                let length = Int(packet[offset]); offset += 1
                if length == 0 { return true }
                if length & 0xc0 == 0xc0 {
                    guard offset < packet.count else { return false }
                    let target = ((length & 0x3f) << 8) | Int(packet[offset])
                    offset += 1
                    return target < packet.count
                }
                guard length <= 63, offset + length <= packet.count else { return false }
                offset += length
            }
            return false
        }
        var offset = 12
        for _ in 0 ..< word(4) {
            guard skipName(&offset), offset + 4 <= packet.count else { return false }
            offset += 4
        }
        for _ in 0 ..< word(6) {
            guard skipName(&offset), offset + 10 <= packet.count else { return false }
            let kind = word(offset), recordClass = word(offset + 2), length = word(offset + 8)
            offset += 10
            guard offset + length <= packet.count else { return false }
            if kind == 1, recordClass == 1, length == 4 {
                let address = packet[offset ..< offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                if (address & mask) == (network & mask) { return true }
            }
            offset += length
        }
        return false
    }

    func probeDNS(_ expected: [String: Any]) -> Bool {
        guard let dns = expected["dns"] as? [String: Any], let listen = dns["listen"] as? String,
              let address = URLComponents(string: "udp://" + listen), let port = address.port,
              let host = EnhancedDNSProbeTargetPolicy.host(from: listen),
              let range = dns["fake-ip-range"] as? String else { return false }
        let transaction: [UInt8] = [0xca, 0xfe]
        var question = transaction + [0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        let domain = "hosted-" + UUID().uuidString.lowercased() + ".example.com"
        for label in domain.split(separator: ".") { question.append(UInt8(label.utf8.count)); question += label.utf8 }
        question += [0, 0, 1, 0, 1]
        for transport in [SOCK_DGRAM, SOCK_STREAM] {
            guard let response = BoundedDNSProbe.query(host: host, port: port, type: transport,
                                                       payload: question, timeout: 2) else { return false }
            let bytes = Array(response)
            guard Array(bytes.prefix(2)) == transaction, dnsAAnswerMatchesRange(bytes, range: range) else { return false }
        }
        return true
    }

    func startOrigin() throws {
        (originFD, originPort) = try reserve(SOCK_STREAM)
        let listener = originFD
        originStopped.enter()
        DispatchQueue.global().async {
            defer { self.originStopped.leave() }
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 { break }
                var noSignal: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var buffer = [UInt8](repeating: 0, count: 4096)
                if recv(connection, &buffer, buffer.count, 0) > 0 {
                    let reply = Array("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)
                    _ = reply.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
                }
                close(connection)
            }
        }
    }

    func proxyServes(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard connected else { return false }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let payload = Array("GET http://127.0.0.1:\(originPort)/probe HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nConnection: close\r\n\r\n".utf8)
        guard payload.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == payload.count else { return false }
        var response = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &response, response.count, 0)
        return received > 0 && String(decoding: response.prefix(received), as: UTF8.self).hasPrefix("HTTP/1.1 204 ")
    }

    func client() -> RuntimeConfigTransactionController.Client {
        RuntimeConfigTransactionController.Client(validate: { file, done in
            _ = self.validator.validate(file: file, completion: done)
        }, apply: { file, done in
            self.applyCount += 1
            self.request("PUT", "/configs?force=true", ["path": file.path]) { _, status, error in
                if error != nil { done(.uncertain("transport did not settle")) }
                else if status == 204 { done(.accepted) }
                else if (400 ... 499).contains(status) { done(.rejected("listener/config rejected")) }
                else { done(.uncertain("unexpected apply status \(status)")) }
            }
        }, verify: { file, done in
            guard let data = try? Data(contentsOf: file),
                  let expected = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                done(.failed("snapshot unavailable")); return
            }
            self.request("GET", "/configs") { data, status, error in
                guard error == nil, status == 200, let data,
                      let actual = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      RuntimeConfigReadbackPolicy.readbackError(expected: expected, actual: actual) == nil,
                      actual["log-level"] as? String == expected["log-level"] as? String else {
                    done(.failed("runtime metadata mismatch")); return
                }
                DispatchQueue.global().async {
                    let usable = self.probeDNS(expected) && self.proxyServes(RuntimeConfigReadbackPolicy.port(expected["mixed-port"]))
                    DispatchQueue.main.async { done(usable ? .verified(.healthy) : .failed("DNS/proxy listener unavailable")) }
                }
            }
        })
    }

    func submit(_ data: Data) throws -> RuntimeConfigTransactionController.Outcome {
        try wait { done in controller.submit(data: data, scope: scope, isCurrent: { true }, client: client(), completion: done) }
    }

    func reserve(_ transport: Int32) throws -> (Int32, Int) {
        for _ in 0 ..< 64 {
            let fd = socket(AF_INET, transport, 0)
            guard fd >= 0 else { throw Failure.check("socket allocation") }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
            }
            guard bound, transport != SOCK_STREAM || listen(fd, 4) == 0 else { close(fd); throw Failure.check("reserve socket") }
            if transport == SOCK_DGRAM {
                // This negative case must be UDP-only, not an unrelated TCP/API collision.
                let tcp = socket(AF_INET, SOCK_STREAM, 0)
                guard tcp >= 0 else { close(fd); throw Failure.check("TCP availability probe") }
                let available = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(tcp, $0, length) == 0 }
                }
                close(tcp)
                if !available { close(fd); continue }
            }
            return (fd, Int(UInt16(bigEndian: address.sin_port)))
        }
        throw Failure.check("could not reserve isolated conflict port")
    }

    func run() throws {
        try startOrigin()
        let initial = try Data(contentsOf: URL(fileURLWithPath: manifest.configPath))
        guard var root = try JSONSerialization.jsonObject(with: initial) as? [String: Any] else { throw Failure.check("initial JSON") }
        let actual = try readback()
        guard let baseline = RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(root, actual: actual) else { throw Failure.check("baseline readback") }
        root = baseline
        try check(probeDNS(root), "initial real TUN core serves UDP and TCP fake-IP DNS")
        let baselineData = try JSONSerialization.data(withJSONObject: root)
        _ = try controller.adoptConfirmed(data: baselineData, scope: scope)
        let initialPort = RuntimeConfigReadbackPolicy.port(root["mixed-port"])
        for index in 0 ..< 6 {
            root["mode"] = index % 2 == 0 ? "direct" : "rule"
            root["log-level"] = index % 2 == 0 ? "warning" : "info"
            let outcome = try submit(JSONSerialization.data(withJSONObject: root))
            guard case let .applied(receipt) = outcome else { throw Failure.check("continuous configuration switch \(index)") }
            try check(receipt.dataPlane == .healthy, "switch \(index): mode/log-level/ports, TUN enable, proxy forwarding and UDP/TCP DNS confirmed")
            try check(RuntimeConfigReadbackPolicy.port(try readback()["mixed-port"]) == initialPort, "switch \(index): confirmed proxy port reused")
        }
        var invalidSemantic = root
        invalidSemantic["rules"] = ["MATCH,clashfx-missing-policy-for-semantic-validation"]
        let invalidInputs: [(String, Data)] = [
            ("syntax", Data("tun: [\n".utf8)),
            ("semantic missing rule target", try JSONSerialization.data(withJSONObject: invalidSemantic)),
        ]
        for (kind, input) in invalidInputs {
            let beforeInvalid = applyCount
            let invalid = try submit(input)
            guard case .rejected = invalid else { throw Failure.check("\(kind) config was not rejected") }
            try check(applyCount == beforeInvalid, "\(kind) rejected before runtime mutation")
        }
        for transport in [SOCK_STREAM, SOCK_DGRAM] {
            let (blocker, port) = try reserve(transport)
            defer { close(blocker) }
            let oldID = controller.confirmed!.id
            var conflict = root
            conflict["mixed-port"] = port
            let outcome = try submit(JSONSerialization.data(withJSONObject: conflict))
            guard case let .rolledBack(receipt, _) = outcome else { throw Failure.check("actual port failure did not rollback") }
            try check(receipt.id == oldID && receipt.dataPlane == .healthy, "\(transport): rollback confirms old receipt and live DNS/listener")
            try check(RuntimeConfigReadbackPolicy.port(try readback()["mixed-port"]) == initialPort, "\(transport): old port restored")
        }
        let (udpBlocker, occupied) = try reserve(SOCK_DGRAM)
        defer { close(udpBlocker) }
        let beforePatch = try readback()
        let patch: (Data?, Int, Error?) = try wait { done in
            request("PATCH", "/configs", ["mixed-port": occupied, "mode": "direct",
                    "tun": ["enable": false, "mtu": 1421, "device": "must-not-commit"],
                    "lan-allowed-ips": ["192.0.2.0/24"]]) { done(($0, $1, $2)) }
        }
        try check(patch.1 == 400 && patch.2 == nil, "PATCH listener failure returns settled 400")
        let afterPatch = try readback()
        for field in ["mixed-port", "mode", "tun", "lan-allowed-ips"] {
            let before = try JSONSerialization.data(withJSONObject: ["value": beforePatch[field] ?? NSNull()], options: [.sortedKeys])
            let after = try JSONSerialization.data(withJSONObject: ["value": afterPatch[field] ?? NSNull()], options: [.sortedKeys])
            try check(before == after, "rejected PATCH preserves \(field)")
        }
        try check(probeDNS(root), "rejected PATCH leaves real TUN DNS serving over UDP and TCP")
    }

    func finish(_ error: Error?) {
        let report: [String: Any] = ["status": error == nil ? "passed" : "failed",
            "execution": "automated backend acceptance in disposable hosted macOS; GUI not exercised",
            "coverage": ["continuousRuntimeSwitches": error == nil, "runtimeConfigRollback": error == nil,
                         "patchFailureRollback": error == nil, "stableRuntimeEndpoints": error == nil],
            "assertions": assertions, "applyCount": applyCount,
            "error": error.map { String(describing: $0) } ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("report.json"))
        }
        session.invalidateAndCancel()
        if originFD >= 0 {
            shutdown(originFD, SHUT_RDWR)
            close(originFD)
            originFD = -1
            _ = originStopped.wait(timeout: .now() + 3)
        }
    }
}

@main
private enum HostedRuntimeAcceptance {
    static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--manifest" else {
            fputs("Usage: hosted-runtime-config-acceptance --manifest fixture.json\n", stderr); exit(2)
        }
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let acceptance = try Acceptance(manifest)
            do { try acceptance.run(); acceptance.finish(nil) }
            catch { acceptance.finish(error); throw error }
        } catch {
            fputs("Hosted runtime configuration acceptance failed: \(error)\n", stderr); exit(1)
        }
    }
}

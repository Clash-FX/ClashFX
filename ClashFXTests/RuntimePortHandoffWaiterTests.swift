import Darwin
import XCTest

/// Uses only an ephemeral loopback port chosen by the kernel, never a
/// configured proxy port, so it cannot disturb a running ClashFX.
final class RuntimePortHandoffWaiterTests: XCTestCase {
    private func listener(type: Int32 = SOCK_STREAM) -> (fd: Int32, port: Int)? {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, type != SOCK_STREAM || Darwin.listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        guard named == 0, port > 0, ![7088, 7890, 7891, 19090].contains(port) else {
            close(fd)
            return nil
        }
        return (fd, port)
    }

    func testOwnedTCPDoesNotExcludeProfileUDPOrDifferentBindAddress() {
        let owned: [String: Any] = ["port": 35101, "mixed-port": 35102, "allow-lan": false]
        let candidate: [String: Any] = ["mixed-port": 35101, "socks-port": "35102", "port": true]
        XCTAssertEqual(
            Set(RuntimePortHandoffWaiter.endpoints(in: candidate, excluding: owned)),
            [.init(host: "127.0.0.1", port: 35101, transport: .udp)]
        )
        var lanCandidate = candidate
        lanCandidate["allow-lan"] = true
        lanCandidate["bind-address"] = "::1"
        XCTAssertEqual(
            Set(RuntimePortHandoffWaiter.endpoints(in: lanCandidate, excluding: owned)),
            [
                .init(host: "::1", port: 35101, transport: .tcp),
                .init(host: "::1", port: 35101, transport: .udp),
                .init(host: "::1", port: 35102, transport: .tcp),
                .init(host: "::1", port: 35102, transport: .udp),
            ]
        )
    }

    func testBootstrapProjectionAppliesMixedPortAndLANOverrides() {
        let root: [String: Any] = [
            "port": 35101, "socks-port": 35102, "mixed-port": 35103,
            "redir-port": 35104, "tproxy-port": 35105,
            "allow-lan": true, "bind-address": "[::1]",
        ]
        XCTAssertEqual(
            RuntimePortHandoffWaiter.bootstrapEndpoints(in: root, proxyPortOverride: 35102, allowLANOverride: false),
            [
                .init(host: "127.0.0.1", port: 35101, transport: .tcp),
                .init(host: "127.0.0.1", port: 35102, transport: .tcp),
                .init(host: "127.0.0.1", port: 35102, transport: .udp),
                .init(host: "127.0.0.1", port: 35104, transport: .tcp),
                .init(host: "127.0.0.1", port: 35105, transport: .tcp),
                .init(host: "127.0.0.1", port: 35105, transport: .udp),
            ]
        )
    }

    func testNamedBaselineExcludesOnlyItsEffectiveAddressPortAndTransport() {
        let candidate = ["mixed-port": 35101]
        let original = ["name": "legacy", "type": "http", "listen": "localhost", "port": "35101-35102"]
        let replacement = ["name": "legacy", "type": "http", "listen": "localhost", "port": "35103"]
        let tcp = RuntimePortHandoffWaiter.Endpoint(host: "127.0.0.1", port: 35101, transport: .tcp)
        let udp = RuntimePortHandoffWaiter.Endpoint(host: "127.0.0.1", port: 35101, transport: .udp)
        XCTAssertEqual(
            RuntimePortHandoffWaiter.endpoints(in: candidate, excluding: ["listeners": [original]]),
            [udp]
        )
        XCTAssertEqual(
            RuntimePortHandoffWaiter.endpoints(in: candidate, excluding: ["listeners": [original, replacement]]),
            [tcp, udp]
        )
    }

    func testOwnedWildcardTCPDoesNotMaskAConcreteTCPClaim() {
        let candidate: [String: Any] = ["mixed-port": 35101]
        let owned: [String: Any] = ["mixed-port": 35101, "allow-lan": true, "bind-address": "*"]
        XCTAssertEqual(
            RuntimePortHandoffWaiter.endpoints(in: candidate, excluding: owned),
            [.init(host: "127.0.0.1", port: 35101, transport: .tcp)]
        )
    }

    func testFreePortCompletesImmediately() throws {
        let held = try XCTUnwrap(listener())
        close(held.fd)
        let done = expectation(description: "free port")
        RuntimePortHandoffWaiter.wait(
            for: [.init(host: "127.0.0.1", port: held.port)], timeout: 2, isCurrent: { true }
        ) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    func testBusyPortTimesOutWithoutStoppingOwner() throws {
        let held = try XCTUnwrap(listener())
        defer { close(held.fd) }
        let waiting = expectation(description: "reported waiting")
        let done = expectation(description: "timed out")
        RuntimePortHandoffWaiter.wait(
            for: [.init(host: "127.0.0.1", port: held.port)], timeout: 0.6, interval: 0.1,
            isCurrent: { true }, onWaiting: { ports in
                XCTAssertEqual(ports, [held.port])
                waiting.fulfill()
            }
        ) { error in
            XCTAssertTrue(error?.contains("timed out") == true, "\(error ?? "nil")")
            done.fulfill()
        }
        wait(for: [waiting, done], timeout: 3)
        // The owner's listener must be untouched.
        XCTAssertEqual(fcntl(held.fd, F_GETFD) >= 0, true)
    }

    func testDistinctProfileEndpointWaitsUntilReleased() throws {
        let bootstrap = try XCTUnwrap(listener())
        defer { close(bootstrap.fd) }
        let profile = try XCTUnwrap(listener())
        var profileFD: Int32? = profile.fd
        defer { if let profileFD { close(profileFD) } }
        let endpoints = RuntimePortHandoffWaiter.endpoints(
            in: ["port": profile.port, "mixed-port": bootstrap.port],
            excluding: ["mixed-port": bootstrap.port]
        )
        XCTAssertEqual(endpoints, [.init(host: "127.0.0.1", port: profile.port)])
        let waiting = expectation(description: "waiting for profile port")
        let done = expectation(description: "released")
        RuntimePortHandoffWaiter.wait(
            for: endpoints, timeout: 2, interval: 0.05,
            isCurrent: { true }, onWaiting: { ports in
                XCTAssertEqual(ports, [profile.port])
                if let fd = profileFD {
                    profileFD = nil
                    close(fd)
                }
                waiting.fulfill()
            }
        ) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [waiting, done], timeout: 3, enforceOrder: true)
        XCTAssertGreaterThanOrEqual(fcntl(bootstrap.fd, F_GETFD), 0)
    }

    func testUDPConflictIsDetectedWithoutStoppingOwner() throws {
        let held = try XCTUnwrap(listener(type: SOCK_DGRAM))
        defer { close(held.fd) }
        let endpoint = RuntimePortHandoffWaiter.Endpoint(host: "127.0.0.1", port: held.port, transport: .udp)
        XCTAssertEqual(RuntimePortHandoffWaiter.bindError(endpoint), EADDRINUSE)
        XCTAssertGreaterThanOrEqual(fcntl(held.fd, F_GETFD), 0)
    }

    func testStaleScopeCancelsWait() throws {
        let held = try XCTUnwrap(listener())
        defer { close(held.fd) }
        let done = expectation(description: "cancelled")
        RuntimePortHandoffWaiter.wait(
            for: [.init(host: "127.0.0.1", port: held.port)], timeout: 3, interval: 0.1, isCurrent: { false }
        ) { error in
            XCTAssertTrue(error?.contains("cancelled") == true)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testScopeChangeAfterBusyProbeCancelsRetry() throws {
        let held = try XCTUnwrap(listener())
        defer { close(held.fd) }
        var current = true
        let waiting = expectation(description: "initial busy probe")
        let done = expectation(description: "stale retry cancelled")
        RuntimePortHandoffWaiter.wait(
            for: [.init(host: "127.0.0.1", port: held.port)], timeout: 2, interval: 0.05,
            isCurrent: { current }, onWaiting: { ports in
                XCTAssertEqual(ports, [held.port])
                current = false
                waiting.fulfill()
            }
        ) { error in
            XCTAssertTrue(error?.contains("cancelled") == true)
            done.fulfill()
        }
        wait(for: [waiting, done], timeout: 3, enforceOrder: true)
        XCTAssertGreaterThanOrEqual(fcntl(held.fd, F_GETFD), 0)
    }
}

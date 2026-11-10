import Darwin
import XCTest

/// Uses only an ephemeral loopback port chosen by the kernel, never a
/// configured proxy port, so it cannot disturb a running ClashFX.
final class RuntimePortHandoffWaiterTests: XCTestCase {
    private func listener() -> (fd: Int32, port: Int)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
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
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { close(fd); return nil }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
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

    func testPortReleasedDuringWaitSucceeds() throws {
        let held = try XCTUnwrap(listener())
        let done = expectation(description: "released")
        RuntimePortHandoffWaiter.wait(
            for: [.init(host: "127.0.0.1", port: held.port)], timeout: 3, interval: 0.1, isCurrent: { true }
        ) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { close(held.fd) }
        wait(for: [done], timeout: 5)
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
}

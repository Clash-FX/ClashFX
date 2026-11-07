import Darwin
import XCTest

final class PortOwnerProbeTests: XCTestCase {
    private func boundSocket(type: Int32, address: String) throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, type, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, address, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        if type == SOCK_STREAM { XCTAssertEqual(listen(fd, 1), 0) }
        var out = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: out.sin_port)))
    }

    func testIdentifiesOwnTCPListener() throws {
        let tcp = try boundSocket(type: SOCK_STREAM, address: "127.0.0.1")
        defer { close(tcp.fd) }
        let result = PortOwnerProbe.owners(ofLocalPort: tcp.port)
        XCTAssertTrue(result.owners.contains { $0.pid == getpid() && $0.proto == "tcp" }, result.summary)
    }

    func testIdentifiesOwnUDPSocket() throws {
        let udp = try boundSocket(type: SOCK_DGRAM, address: "127.0.0.1")
        defer { close(udp.fd) }
        let result = PortOwnerProbe.owners(ofLocalPort: udp.port)
        XCTAssertTrue(result.owners.contains { $0.pid == getpid() && $0.proto == "udp" }, result.summary)
    }

    func testReportsNoOwnerAfterTheSocketCloses() throws {
        let tcp = try boundSocket(type: SOCK_STREAM, address: "127.0.0.1")
        close(tcp.fd)
        let result = PortOwnerProbe.owners(ofLocalPort: tcp.port)
        XCTAssertFalse(result.owners.contains { $0.pid == getpid() }, result.summary)
    }

    func testRejectsInvalidPorts() {
        XCTAssertTrue(PortOwnerProbe.owners(ofLocalPort: 0).owners.isEmpty)
        XCTAssertTrue(PortOwnerProbe.owners(ofLocalPort: 70000).owners.isEmpty)
    }

    func testSummaryExplainsUninspectableProcesses() {
        let result = PortOwnerProbe.Result(owners: [], unreadableProcessCount: 3)
        XCTAssertTrue(result.summary.contains("not inspectable"))
    }
}

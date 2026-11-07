import Darwin
import XCTest

final class HandoffDiagnosticsTests: XCTestCase {
    func testTimelineReportsElapsedMillisecondsPerStage() {
        var clock: UInt64 = 5_000_000_000
        var lines: [String] = []
        let timeline = HandoffTimeline(transactionID: "tx1", now: { clock }, emit: { lines.append($0) })
        clock += 120_000_000
        timeline.mark("stop_requested")
        clock += 1_500_000_000
        timeline.mark("stop_replied", detail: "error=none")
        XCTAssertEqual(lines, [
            "timeline transaction=tx1 stage=stop_requested t+120ms",
            "timeline transaction=tx1 stage=stop_replied t+1620ms error=none"
        ])
    }

    func testParserFindsEveryDistinctBindFailurePort() {
        let error = "listen tcp 127.0.0.1:7890: bind: address already in use; " +
            "listen tcp 127.0.0.1:7891: bind: address already in use; " +
            "retry 127.0.0.1:7890: bind: address already in use"
        XCTAssertEqual(PortConflictParser.ports(in: error), [7890, 7891])
    }

    func testParserReadsClassifiedConflictPort() {
        XCTAssertEqual(PortConflictParser.ports(in: "error:[port_conflict] service=dns_listener port=7874"), [7874])
    }

    func testParserIgnoresUnrelatedErrors() {
        XCTAssertTrue(PortConflictParser.ports(in: "Helper XPC request failed").isEmpty)
        XCTAssertTrue(PortConflictParser.ports(in: "port=7874 without the classified prefix").isEmpty)
    }

    private func listener() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 4), 0)
        var out = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: out.sin_port)))
    }

    func testProbeSeesALiveListenerAndThenNothing() throws {
        let live = try listener()
        XCTAssertTrue(PortListenProbe.isAccepting(port: live.port))
        close(live.fd)
        XCTAssertFalse(PortListenProbe.isAccepting(port: live.port))
    }

    func testProbeRejectsInvalidPorts() {
        XCTAssertFalse(PortListenProbe.isAccepting(port: 0))
        XCTAssertFalse(PortListenProbe.isAccepting(port: 70000))
    }

    func testSampleReportsEachPortAtEachOffset() throws {
        let live = try listener()
        defer { close(live.fd) }
        var lines: [String] = []
        PortListenProbe.sample(ports: [live.port], offsets: [0, 0.05]) { lines.append($0) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.contains("port=\(live.port)") && $0.hasSuffix("accepting=true") })
    }
}

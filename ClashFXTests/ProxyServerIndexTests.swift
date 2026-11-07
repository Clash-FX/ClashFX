import XCTest

final class ProxyServerIndexTests: XCTestCase {
    func testReadsFlowAndBlockStyleProxyEntries() {
        let yaml = """
        proxies:
          - {name: "Tokyo 1", type: vmess, server: node1.example.net, port: 443}
          - name: Sydney 2
            type: trojan
            server: 203.0.113.9
            port: 443
        """
        XCTAssertEqual(ProxyServerIndex.servers(inYAML: yaml),
                       ["Tokyo 1": "node1.example.net", "Sydney 2": "203.0.113.9"])
    }

    func testProfilesWithoutInlineProxiesYieldNothing() {
        XCTAssertTrue(ProxyServerIndex.servers(inYAML: "proxy-providers:\n  p: {type: http}\n").isEmpty)
        XCTAssertTrue(ProxyServerIndex.servers(inYAML: "not: [valid").isEmpty)
    }

    func testRecognisesIPLiterals() {
        XCTAssertTrue(ProxyServerIndex.isIPLiteral("203.0.113.9"))
        XCTAssertTrue(ProxyServerIndex.isIPLiteral("2001:db8::1"))
        XCTAssertFalse(ProxyServerIndex.isIPLiteral("node1.example.net"))
    }
}

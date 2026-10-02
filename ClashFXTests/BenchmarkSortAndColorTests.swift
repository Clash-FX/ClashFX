import XCTest

final class BenchmarkSortAndColorTests: XCTestCase {
    private struct Row {
        let name: String
        let metadata: ProxyBenchmarkSortMetadata
    }

    func testLatencyOrderRanksFreshSuccessesAndKeepsOtherRowsInConfigurationOrder() {
        let rows = [
            Row(name: "Untested", metadata: ProxyBenchmarkSortMetadata(configurationIndex: 0, freshDelay: nil)),
            Row(name: "Slow", metadata: ProxyBenchmarkSortMetadata(configurationIndex: 1, freshDelay: 801)),
            Row(name: "Fast-B", metadata: ProxyBenchmarkSortMetadata(configurationIndex: 2, freshDelay: 120)),
            Row(name: "Failed", metadata: ProxyBenchmarkSortMetadata(configurationIndex: 3, freshDelay: nil)),
            Row(name: "Fast-A", metadata: ProxyBenchmarkSortMetadata(configurationIndex: 4, freshDelay: 120))
        ]

        let result = ProxyBenchmarkRowSorting.ordered(rows, by: .latency) { $0.metadata }

        XCTAssertEqual(result.map(\.name), ["Fast-B", "Fast-A", "Slow", "Untested", "Failed"])
    }

    func testConfigurationOrderRestoresOriginalRows() {
        let rows = [
            Row(name: "Third", metadata: ProxyBenchmarkSortMetadata(configurationIndex: 2, freshDelay: 20)),
            Row(name: "First", metadata: ProxyBenchmarkSortMetadata(configurationIndex: 0, freshDelay: 800)),
            Row(name: "Second", metadata: ProxyBenchmarkSortMetadata(configurationIndex: 1, freshDelay: 300))
        ]

        let result = ProxyBenchmarkRowSorting.ordered(rows, by: .configuration) { $0.metadata }

        XCTAssertEqual(result.map(\.name), ["First", "Second", "Third"])
    }

    func testDelayColorThresholdsUseRawMilliseconds() {
        XCTAssertEqual(ProxyBenchmarkDelayColorCategory.category(for: 299), .fast)
        XCTAssertEqual(ProxyBenchmarkDelayColorCategory.category(for: 300), .moderate)
        XCTAssertEqual(ProxyBenchmarkDelayColorCategory.category(for: 799), .moderate)
        XCTAssertEqual(ProxyBenchmarkDelayColorCategory.category(for: 800), .slow)
        XCTAssertEqual(ProxyBenchmarkDelayColorCategory.category(for: 0), .failed)
        XCTAssertEqual(ProxyBenchmarkDelayColorCategory.category(for: nil), .unknown)
    }
}

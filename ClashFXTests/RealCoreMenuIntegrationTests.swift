import Cocoa
import CoreFoundation
import XCTest

private enum ExpectedDelayColor {
    static let green = CGColor(red: CGFloat(30) / 255, green: CGFloat(181) / 255,
                               blue: CGFloat(30) / 255, alpha: 1)
    static let orange = CGColor(red: 1, green: CGFloat(116) / 255, blue: 0, alpha: 1)
}

/// Opt-in: scripts/run-real-core-menu-validation.py owns the separate core and
/// local HTTP proxy/origin processes. Ordinary unit-test runs skip this class.
final class RealCoreMenuIntegrationTests: XCTestCase {
    private var endpoint: URL!
    private var origin: URL!
    private var secret = ""
    private var snapshot: ClashProxyResp!
    private var menus = [ProxyGroupMenu]()
    private var refreshing = false

    private func waitUntil(_ description: String, _ predicate: @escaping () -> Bool) {
        let done = expectation(description: description)
        var stopped = false
        func poll() {
            guard !stopped else { return }
            if predicate() { done.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
        }
        poll()
        wait(for: [done], timeout: 20)
        stopped = true
    }

    @discardableResult
    private func call(_ base: URL, _ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> [String: Any] {
        XCTAssertEqual(base.host, "127.0.0.1")
        guard base.host == "127.0.0.1", base.scheme == "http", (base.port ?? 0) > 1024 else {
            throw URLError(.badURL)
        }
        let done = expectation(description: "isolated real HTTP \(path)")
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var payload: [String: Any] = [:]
        var failure: Error?
        ApiRequest.loopbackTransport.dataTask(with: request) { data, response, error in
            failure = error
            if let response = response as? HTTPURLResponse {
                XCTAssertTrue((200 ..< 300).contains(response.statusCode), "\(path): \(response.statusCode)")
            }
            if let data, !data.isEmpty { payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        if let failure { throw failure }
        return payload
    }

    private func fetch(completion: @escaping () -> Void) {
        refreshing = true
        ApiRequest.getMergedProxyData(session: .init(), timeout: 10) { response in
            defer { self.refreshing = false; completion() }
            guard let response else { XCTFail("Real core snapshot unavailable"); return }
            let previous = self.snapshot
            self.snapshot = response
            GlobalLeafBenchmarkPresentationStore.prune(using: response)
            SelectorBenchmarkPresentationStore.prune(using: response)
            AutomaticChildBenchmarkStore.prune(using: response)
            AutomaticGroupBenchmarkPresentationStore.prune(using: response)
            if let previous {
                for name in ProxyMenuSnapshotDelta.affectedNames(previous: previous, current: response) {
                    NotificationCenter.default.post(name: .proxyUpdate(for: name), object: response.proxiesMap[name])
                }
            }
        }
    }

    private func refresh() {
        fetch {}
        waitUntil("real core snapshot loaded") { !self.refreshing }
    }

    private func menu(_ name: String) throws -> ProxyGroupMenu {
        let group = try XCTUnwrap(snapshot.proxiesMap[name])
        let menu = ProxyGroupMenu(title: name)
        menu.addItem(ProxyGroupSpeedTestMenuItem(group: group))
        for member in group.all ?? [] {
            if let proxy = snapshot.proxiesMap[member] {
                menu.addItem(ProxyMenuItem(proxy: proxy, group: group, action: nil))
            }
        }
        menus.append(menu)
        return menu
    }

    private func row(_ menu: NSMenu, _ name: String) throws -> ProxyMenuItem {
        try XCTUnwrap(menu.items.compactMap { $0 as? ProxyMenuItem }.first { $0.proxyName == name })
    }

    private func text(_ menu: NSMenu, _ name: String) throws -> String {
        try XCTUnwrap(row(menu, name).view as? ProxyItemView).delayLabel.stringValue
    }

    private func resetCapturedResponses() throws {
        _ = try call(endpoint, "__fixture/clear-captures", method: "POST")
    }

    private func capturedResponses() throws -> [[String: Any]] {
        try XCTUnwrap(call(endpoint, "__fixture/captures")["captures"] as? [[String: Any]])
    }

    private func capturedResponse(path: String, url: String,
                                  from captures: [[String: Any]]) throws -> [String: Any] {
        let matches = captures.filter {
            $0["path"] as? String == path
                && ($0["query"] as? [String: String])?["url"] == url
        }
        XCTAssertEqual(matches.count, 1, "Expected one production response for \(path) at \(url)")
        let response = try XCTUnwrap(matches.first)
        XCTAssertEqual(response["status"] as? Int, 200)
        XCTAssertEqual((response["query"] as? [String: String])?["timeout"], "5000")
        let body = try XCTUnwrap(response["body"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func capturedLeafDelay(_ name: String, url: String,
                                  from captures: [[String: Any]]) throws -> Int {
        let body = try capturedResponse(path: "/proxies/\(name)/delay", url: url, from: captures)
        return try XCTUnwrap(body["delay"] as? Int)
    }

    private func capturedGroupDelay(_ group: String, node: String, url: String,
                                    from captures: [[String: Any]]) throws -> Int {
        let body = try capturedResponse(path: "/group/\(group)/delay", url: url, from: captures)
        return try XCTUnwrap(body[node] as? Int)
    }

    private func numericDelay(_ label: String) throws -> Int {
        let range = label.range(of: "[0-9]+(?=\\s*ms)", options: .regularExpression)
        return try XCTUnwrap(range.flatMap { Int(String(label[$0])) },
                             "No numeric millisecond value in '\(label)'")
    }

    private func assertDelay(_ menu: NSMenu, node: String, equals expected: Int,
                             color: CGColor, file: StaticString = #file, line: UInt = #line) throws {
        let view = try XCTUnwrap(row(menu, node).view as? ProxyItemView)
        XCTAssertEqual(try numericDelay(view.delayLabel.stringValue), expected,
                       "Menu value for \(node) must match the captured core response",
                       file: file, line: line)
        let actualColor = view.delayLabel.layer?.backgroundColor
        XCTAssertTrue(actualColor.map { CFEqual($0, color) } ?? false,
                      "Unexpected delay color for \(node) at \(expected) ms",
                      file: file, line: line)
    }

    private func benchmark(_ menu: NSMenu) throws {
        let action = try XCTUnwrap(menu.items.first as? ProxyGroupSpeedTestMenuItem)
        try XCTUnwrap(action.view as? MenuItemBaseView).didClickView()
        waitUntil("real core benchmark and menu refresh settled") {
            AppDelegate.shared.active == nil && !self.refreshing && action.title != NSLocalizedString("Testing", comment: "")
        }
    }

    func testSchedulingStrategiesWithIsolatedCore() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let file = environment["CLASHFX_REAL_CORE_MANIFEST"] ?? environment["TEST_RUNNER_CLASHFX_REAL_CORE_MANIFEST"] else {
            throw XCTSkip("Opt-in real core fixture is not running")
        }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        endpoint = try XCTUnwrap(URL(string: try XCTUnwrap(manifest["endpoint"] as? String)))
        origin = try XCTUnwrap(URL(string: try XCTUnwrap(manifest["origin"] as? String)))
        secret = try XCTUnwrap(manifest["secret"] as? String)
        let homeURL = origin.appendingPathComponent("probe-a").absoluteString
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        ApiRequest.loopbackFixture = .init(endpoint: endpoint, secret: secret)
        defer { ApiRequest.loopbackFixture = nil }
        var reports = [[String: Any]]()
        for (scenario, slowDelay) in [("healthy", 0.18), ("slow-tail", 0.75), ("timeout-tail", 2.6)] {
            _ = try call(origin, "fixture-delays", method: "POST", body: ["Local-A": 0.04, "Local-B": slowDelay])
            for strategy in SelectorBenchmarkConcurrencyStrategy.allCases {
                refresh()
                let group = try XCTUnwrap(snapshot.proxiesMap["Scheduling"])
                let plan = SelectorBenchmarkPlan.make(selector: group, snapshot: snapshot, benchmarkURL: homeURL,
                                                     timeout: BenchmarkMode.quick.timeoutMilliseconds)
                XCTAssertEqual(plan.targets.count, 40)
                let finished = expectation(description: "isolated scheduler \(scenario) \(strategy.rawValue)")
                let lock = NSLock()
                let started = Date()
                var firstResult: TimeInterval?
                var requests = 0
                var active = 0
                var peak = 0
                var outcomes = [SelectorBenchmarkMeasurementKey: ProxyDelayOutcome]()
                SelectorBenchmarkExecutor.runOutcomes(
                    plan: plan,
                    executionPolicy: SelectorBenchmarkConcurrencyPolicy(targetCount: plan.targets.count, strategy: strategy),
                    isCancelled: { false },
                    request: { target, done in
                        lock.lock()
                        requests += 1
                        active += 1
                        peak = max(peak, active)
                        lock.unlock()
                        var components = URLComponents(url: self.endpoint.appendingPathComponent("proxies/" + target.key.proxyName + "/delay"),
                                                       resolvingAgainstBaseURL: false)!
                        components.queryItems = [URLQueryItem(name: "url", value: homeURL),
                                                URLQueryItem(name: "timeout", value: String(target.key.timeout))]
                        var request = URLRequest(url: components.url!)
                        request.setValue("Bearer " + self.secret, forHTTPHeaderField: "Authorization")
                        ApiRequest.loopbackTransport.dataTask(with: request) { data, response, error in
                            let outcome = ProxyDelayOutcome.decode(statusCode: (response as? HTTPURLResponse)?.statusCode,
                                                                   data: data, transportFailed: error != nil)
                            lock.lock()
                            active -= 1
                            lock.unlock()
                            done(outcome)
                        }.resume()
                    },
                    result: { target, outcome in
                        lock.lock()
                        if firstResult == nil { firstResult = Date().timeIntervalSince(started) }
                        outcomes[target.key] = outcome
                        lock.unlock()
                    },
                    completion: { finished.fulfill() }
                )
                wait(for: [finished], timeout: 20)
                XCTAssertEqual(requests, 40)
                XCTAssertEqual(outcomes.count, 40)
                XCTAssertLessThanOrEqual(peak, strategy.rawValue)
                let successful = outcomes.values.filter { if case .measured = $0 { return true }; return false }.count
                let timeouts = outcomes.values.filter { $0 == .timedOut }.count
                let unavailable = outcomes.values.filter { $0 == .unavailable }.count
                XCTAssertEqual(unavailable, 0)
                XCTAssertGreaterThanOrEqual(successful, 32)
                if scenario == "timeout-tail" {
                    XCTAssertEqual(timeouts, 8)
                    XCTAssertEqual(successful, 32)
                } else {
                    XCTAssertEqual(timeouts, 0)
                    XCTAssertEqual(successful, 40)
                }
                reports.append(["scenario": scenario, "concurrency": strategy.rawValue, "targets": requests,
                                "peak": peak, "firstSeconds": firstResult ?? -1,
                                "totalSeconds": Date().timeIntervalSince(started),
                                "success": successful, "timeout": timeouts, "unavailable": unavailable])
            }
        }
        let json = try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys])
        print("BENCHMARK_SCHEDULER_COMPARISON:" + String(decoding: json, as: UTF8.self))
    }

    func testActualMihomoAndProductionMenusWithLocalNodes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let file = environment["CLASHFX_REAL_CORE_MANIFEST"] ?? environment["TEST_RUNNER_CLASHFX_REAL_CORE_MANIFEST"] else {
            throw XCTSkip("Opt-in real core fixture is not running")
        }
        XCTAssertTrue(Thread.isMainThread)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        endpoint = try XCTUnwrap(try URL(string: XCTUnwrap(manifest["endpoint"] as? String)))
        origin = try XCTUnwrap(try URL(string: XCTUnwrap(manifest["origin"] as? String)))
        secret = try XCTUnwrap(manifest["secret"] as? String)
        guard endpoint.host == "127.0.0.1", origin.host == "127.0.0.1" else { throw URLError(.badURL) }
        _ = NSApplication.shared
        AppDelegate.shared.cancel()
        let oldURL = Settings.benchMarkUrl
        let oldMode = Settings.benchmarkMode
        Settings.benchmarkMode = .complete
        Settings.benchMarkUrl = origin.appendingPathComponent("probe-a").absoluteString
        ApiRequest.loopbackFixture = .init(endpoint: endpoint, secret: secret)
        ApiRequest.loopbackPaths = []
        MenuItemFactory.useViewToRenderProxy = true
        GlobalLeafBenchmarkPresentationStore.clearAll()
        SelectorBenchmarkPresentationStore.clearAll()
        AutomaticChildBenchmarkStore.clearAll()
        AutomaticGroupBenchmarkPresentationStore.clearAll()
        defer {
            AppDelegate.shared.onFinish = nil
            AppDelegate.shared.cancel()
            ApiRequest.loopbackFixture = nil
            Settings.benchMarkUrl = oldURL
            Settings.benchmarkMode = oldMode
            menus.removeAll()
        }

        let version = try call(endpoint, "version")
        XCTAssertEqual(version["version"] as? String, "1.19.24")
        let configs = try call(endpoint, "configs")
        XCTAssertEqual((configs["tun"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertEqual(configs["allow-lan"] as? Bool, false)
        XCTAssertEqual(configs["mixed-port"] as? Int, 0)
        refresh()
        AppDelegate.shared.onFinish = { [weak self] in self?.fetch {} }

        // These are actual parsed config groups, including the core-generated
        // COMPATIBLE fallback — no synthesized /proxies payloads in this test.
        for name in ["Empty-SG", "Empty-TW", "Nested-Empty"] {
            guard case .unavailable(_, .compatibilityFallback) = snapshot.resolveSelectedPath(from: name) else {
                return XCTFail("Expected real core direct fallback for \(name)")
            }
        }
        let selector = try menu("Selector")
        let probeURL = origin.appendingPathComponent("probe-a").absoluteString
        try resetCapturedResponses()
        try benchmark(selector)
        for name in ["Empty-SG", "Empty-TW", "Nested-Empty"] {
            XCTAssertEqual(try text(selector, name), NSLocalizedString("Direct fallback (no proxy nodes)", comment: ""))
        }
        for name in ["Local-A", "Local-B", "DIRECT"] {
            XCTAssertTrue(try text(selector, name).contains(" ms"), name)
        }
        XCTAssertEqual(try text(selector, "Local-Broken"), NSLocalizedString("fail", comment: ""))
        let selectorCaptures = try capturedResponses()
        let selectorA = try capturedLeafDelay("Local-A", url: probeURL, from: selectorCaptures)
        let selectorB = try capturedLeafDelay("Local-B", url: probeURL, from: selectorCaptures)
        XCTAssertLessThan(selectorA, 300)
        XCTAssertGreaterThanOrEqual(selectorB, 1177)
        try assertDelay(selector, node: "Local-A", equals: selectorA, color: ExpectedDelayColor.green)
        try assertDelay(selector, node: "Local-B", equals: selectorB, color: ExpectedDelayColor.orange)
        XCTAssertFalse(ApiRequest.loopbackPaths.contains { $0.contains("COMPATIBLE") || $0.hasPrefix("/group/Empty-") })
        print("REAL_CORE_SELECTOR: \(probeURL), raw/menu A=\(selectorA), B=\(selectorB); threshold colors agree")

        let empty = try menu("Empty-SG")
        let requestCount = ApiRequest.loopbackPaths.count
        try benchmark(empty)
        XCTAssertEqual(ApiRequest.loopbackPaths.count, requestCount)
        XCTAssertNil(AppDelegate.shared.active)

        let automatic = try menu("Automatic")
        try call(origin, "fixture-delays", method: "POST", body: ["Local-A": 1.177, "Local-B": 2.383])
        try resetCapturedResponses()
        try benchmark(automatic)
        XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Local-A")
        let firstAutomaticCaptures = try capturedResponses()
        let firstAutomaticA = try capturedGroupDelay("Automatic", node: "Local-A", url: probeURL,
                                                     from: firstAutomaticCaptures)
        let firstAutomaticB = try capturedGroupDelay("Automatic", node: "Local-B", url: probeURL,
                                                     from: firstAutomaticCaptures)
        XCTAssertGreaterThanOrEqual(firstAutomaticA, 1177)
        XCTAssertGreaterThanOrEqual(firstAutomaticB, 2383)
        XCTAssertNotNil(try (row(automatic, "Local-A").view as? ProxyItemView)?.imageView)
        XCTAssertNil(try (row(automatic, "Local-B").view as? ProxyItemView)?.imageView)
        try assertDelay(automatic, node: "Local-A", equals: firstAutomaticA, color: ExpectedDelayColor.orange)
        try assertDelay(automatic, node: "Local-B", equals: firstAutomaticB, color: ExpectedDelayColor.orange)

        try call(origin, "fixture-delays", method: "POST", body: ["Local-A": 2.383, "Local-B": 0.04])
        try resetCapturedResponses()
        try benchmark(automatic)
        XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Local-B")
        let switchedAutomaticCaptures = try capturedResponses()
        let switchedAutomaticA = try capturedGroupDelay("Automatic", node: "Local-A", url: probeURL,
                                                        from: switchedAutomaticCaptures)
        let switchedAutomaticB = try capturedGroupDelay("Automatic", node: "Local-B", url: probeURL,
                                                        from: switchedAutomaticCaptures)
        XCTAssertGreaterThanOrEqual(switchedAutomaticA, 2383)
        XCTAssertLessThan(switchedAutomaticB, 300)
        XCTAssertNotNil(try (row(automatic, "Local-B").view as? ProxyItemView)?.imageView)
        XCTAssertNil(try (row(automatic, "Local-A").view as? ProxyItemView)?.imageView)
        try assertDelay(automatic, node: "Local-A", equals: switchedAutomaticA, color: ExpectedDelayColor.orange)
        try assertDelay(automatic, node: "Local-B", equals: switchedAutomaticB, color: ExpectedDelayColor.green)
        print("REAL_CORE_AUTOMATIC: \(probeURL), selected path A then B; captured group raw values match child rows and colors")

        let first = try menu("URL-A")
        let second = try menu("URL-B")
        try benchmark(first)
        let firstValue = try text(first, "Local-A")
        try benchmark(second)
        let secondValue = try text(second, "Local-A")
        XCTAssertTrue(firstValue.contains(" ms"))
        XCTAssertTrue(secondValue.contains(" ms"))
        XCTAssertNotEqual(firstValue, secondValue)
        XCTAssertEqual(try text(first, "Local-A"), firstValue)
        XCTAssertEqual(try text(menu("URL-A"), "Local-A"), firstValue)
        XCTAssertEqual(try text(menu("URL-B"), "Local-A"), secondValue)
        print("REAL_CORE_URL_ISOLATION: A=\(firstValue), B=\(secondValue); both retained on reopen")
        print("REAL_CORE_MENU_VALIDATION_COMPLETE")
    }
}

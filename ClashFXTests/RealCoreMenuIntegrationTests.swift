import Cocoa
import XCTest

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
                XCTAssertTrue((200..<300).contains(response.statusCode), "\(path): \(response.statusCode)")
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

    private func benchmark(_ menu: NSMenu) throws {
        let action = try XCTUnwrap(menu.items.first as? ProxyGroupSpeedTestMenuItem)
        try XCTUnwrap(action.view as? MenuItemBaseView).didClickView()
        waitUntil("real core benchmark and menu refresh settled") {
            AppDelegate.shared.active == nil && !self.refreshing && action.title != NSLocalizedString("Testing", comment: "")
        }
    }

    func testActualMihomoAndProductionMenusWithLocalNodes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let file = environment["CLASHFX_REAL_CORE_MANIFEST"] ?? environment["TEST_RUNNER_CLASHFX_REAL_CORE_MANIFEST"] else {
            throw XCTSkip("Opt-in real core fixture is not running")
        }
        XCTAssertTrue(Thread.isMainThread)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        endpoint = try XCTUnwrap(URL(string: try XCTUnwrap(manifest["endpoint"] as? String)))
        origin = try XCTUnwrap(URL(string: try XCTUnwrap(manifest["origin"] as? String)))
        secret = try XCTUnwrap(manifest["secret"] as? String)
        guard endpoint.host == "127.0.0.1", origin.host == "127.0.0.1" else { throw URLError(.badURL) }
        _ = NSApplication.shared
        AppDelegate.shared.cancel()
        let oldURL = Settings.benchMarkUrl
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
        try benchmark(selector)
        for name in ["Empty-SG", "Empty-TW", "Nested-Empty"] {
            XCTAssertEqual(try text(selector, name), NSLocalizedString("Direct fallback (no proxy nodes)", comment: ""))
        }
        for name in ["Local-A", "Local-B", "DIRECT"] {
            XCTAssertTrue(try text(selector, name).contains(" ms"), name)
        }
        XCTAssertEqual(try text(selector, "Local-Broken"), NSLocalizedString("fail", comment: ""))
        XCTAssertFalse(ApiRequest.loopbackPaths.contains { $0.contains("COMPATIBLE") || $0.hasPrefix("/group/Empty-") })
        print("REAL_CORE_SELECTOR: A=\(try text(selector, "Local-A")), B=\(try text(selector, "Local-B")), DIRECT=\(try text(selector, "DIRECT")), broken=\(try text(selector, "Local-Broken")); empty groups rejected")

        let empty = try menu("Empty-SG")
        let requestCount = ApiRequest.loopbackPaths.count
        try benchmark(empty)
        XCTAssertEqual(ApiRequest.loopbackPaths.count, requestCount)
        XCTAssertNil(AppDelegate.shared.active)

        let automatic = try menu("Automatic")
        try benchmark(automatic)
        XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Local-A")
        try call(origin, "fixture-delays", method: "POST", body: ["Local-A": 0.25, "Local-B": 0.03])
        try benchmark(automatic)
        XCTAssertEqual(snapshot.proxiesMap["Automatic"]?.now, "Local-B")
        XCTAssertNotNil((try row(automatic, "Local-B").view as? ProxyItemView)?.imageView)
        XCTAssertNil((try row(automatic, "Local-A").view as? ProxyItemView)?.imageView)
        print("REAL_CORE_AUTOMATIC: now changed Local-A -> Local-B, native checkmark agrees")

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

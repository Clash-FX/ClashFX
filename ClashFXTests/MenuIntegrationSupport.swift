import Cocoa
import XCTest

// Test-target-only boundaries. Production AppDelegate/Settings/ApiRequest are
// deliberately not linked: no production core, helper, preferences or system
// proxy. An explicitly provided manifest can opt into a separate fixture core.
enum Settings {
    static var benchMarkUrl = "https://test-a.invalid/204"
    static var menuBarSpeedAlignment: MenuBarSpeedAlignment = .right
    static var selectedMenuIconID = "default"
}

enum MenuItemFactory {
    static var useViewToRenderProxy = true
}

final class AppDelegate {
    static let shared = AppDelegate()
    private(set) var active: ApiRequest.BenchmarkSession?
    var onFinish: (() -> Void)?

    func beginSpeedTest(showNotifications: Bool) -> ApiRequest.BenchmarkSession? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard active == nil else { return nil }
        let session = ApiRequest.BenchmarkSession()
        active = session
        return session
    }

    func isActiveBenchmarkSession(_ session: ApiRequest.BenchmarkSession) -> Bool { active === session }

    func finishSpeedTest(session: ApiRequest.BenchmarkSession, showNotifications: Bool) {
        guard active === session else { return }
        active = nil
        session.terminate()
        onFinish?()
    }

    func cancel() {
        guard let session = active else { return }
        active = nil
        session.cancel()
    }
}

/// All URLSession requests are intercepted, including accidental off-fixture
/// URLs (which fail closed). No listener, real socket or system configuration.
final class MihomoMenuURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body: [String: Any]
    }

    static var topology: [String: Any] = [:]
    static var replies = [String: Reply]()
    static var groupReply = Reply(body: [:])
    static var groupDidRespond: (() -> Void)?
    static var requests = [URLRequest]()
    static var hold = false
    static var held = [() -> Void]()
    static var delivered = 0

    static func key(_ name: String, _ url: String) -> String { name + "\n" + url }

    static func reset() {
        topology = [:]
        replies = [:]
        groupReply = Reply(body: [:])
        groupDidRespond = nil
        requests = []
        hold = false
        held = []
        delivered = 0
    }

    static func releaseHeld() {
        let pending = held
        held.removeAll()
        pending.forEach { $0() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        DispatchQueue.main.async { [self] in
            guard request.url?.host == "mihomo-menu-fixture.invalid" else {
                XCTFail("Attempted non-fixture request")
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            Self.requests.append(request)
            let url = request.url!
            let path = url.path
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let testURL = query.first { $0.name == "url" }?.value ?? ""
            let reply: Reply
            if path == "/proxies" {
                reply = Reply(body: ["proxies": Self.topology])
            } else if path == "/providers/proxies" {
                reply = Reply(body: ["providers": [:]])
            } else if path.hasPrefix("/group/") && path.hasSuffix("/delay") {
                reply = Self.groupReply
            } else if path.hasSuffix("/delay") || path.hasSuffix("/healthcheck") {
                let name = url.pathComponents.dropLast().last ?? ""
                reply = Self.replies[Self.key(name, testURL)] ?? Reply(body: ["delay": 83])
            } else {
                XCTFail("Unexpected fixture route: \(path)")
                reply = Reply(status: 404, body: ["message": "unexpected route"])
            }
            let deliver = { [self] in
                if path.hasPrefix("/group/") { Self.groupDidRespond?() }
                let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.body))
                client?.urlProtocolDidFinishLoading(self)
                Self.delivered += 1
            }
            if Self.hold && (path.hasSuffix("/delay") || path.hasSuffix("/healthcheck")) {
                Self.held.append(deliver)
            } else {
                deliver()
            }
        }
    }

    override func stopLoading() {}
}

/// HTTP facade for the compiled production menu actions. Only I/O and app
/// lifetime are substituted; decoding, planning, executor, stores and views
/// are the real production sources. Late responses intentionally still arrive.
enum ApiRequest {
    struct LoopbackFixture {
        let endpoint: URL
        let secret: String
    }
    // Opt-in for the separate real-core test only. Ordinary tests continue to
    // intercept every request through MihomoMenuURLProtocol.
    static var loopbackFixture: LoopbackFixture?
    static var loopbackPaths = [String]()

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    static let loopbackTransport: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    final class BenchmarkSession {
        private let lock = NSLock()
        private var cancelled = false
        private var terminated = false
        private var observers = [() -> Void]()
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func onTermination(_ action: @escaping () -> Void) {
            lock.lock()
            let invoke = terminated
            if !invoke { observers.append(action) }
            lock.unlock()
            if invoke { action() }
        }
        func cancel() { lock.lock(); cancelled = true; lock.unlock(); terminate() }
        func terminate() {
            lock.lock()
            guard !terminated else { lock.unlock(); return }
            terminated = true
            let actions = observers
            observers.removeAll()
            lock.unlock()
            actions.forEach { $0() }
        }
    }

    static let transport: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MihomoMenuURLProtocol.self]
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    private static func request(_ path: String, query: [String: String] = [:],
                                completion: @escaping (Int, Data?, Bool) -> Void) {
        var url = URLComponents()
        url.scheme = "http"
        url.host = "mihomo-menu-fixture.invalid"
        let fixture = loopbackFixture
        if let fixture {
            guard fixture.endpoint.scheme == "http", fixture.endpoint.host == "127.0.0.1",
                  let port = fixture.endpoint.port, port > 1024 else {
                XCTFail("Rejected non-loopback real-core fixture")
                DispatchQueue.main.async { completion(-1, nil, true) }
                return
            }
            url.host = "127.0.0.1"
            url.port = port
            DispatchQueue.main.async { loopbackPaths.append(path) }
        }
        url.path = path
        url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        if let fixture { request.setValue("Bearer " + fixture.secret, forHTTPHeaderField: "Authorization") }
        let session = fixture == nil ? transport : loopbackTransport
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async { completion((response as? HTTPURLResponse)?.statusCode ?? -1, data, error != nil) }
        }.resume()
    }

    static func getMergedProxyData(session: BenchmarkSession, timeout: TimeInterval,
                                   complete: @escaping (ClashProxyResp?) -> Void) {
        request("/proxies") { status, data, failed in
            guard !session.isCancelled, status == 200, !failed else { complete(nil); return }
            let snapshot = ClashProxyResp(data)
            request("/providers/proxies") { status, data, failed in
                guard !session.isCancelled, status == 200, !failed, let data,
                      let providers = try? ClashProviderResp.decoder.decode(ClashProviderResp.self, from: data) else {
                    complete(nil); return
                }
                snapshot.updateProvider(providers)
                complete(snapshot)
            }
        }
    }

    static func getProxyGroupDelay(groupName: String, benchmarkURL: String, expectedStatus: String?,
                                   timeout: Int, session: BenchmarkSession,
                                   callback: @escaping (ProxyGroupDelayOutcome) -> Void) {
        var query = ["url": benchmarkURL, "timeout": String(timeout)]
        if let expectedStatus { query["expected"] = expectedStatus }
        request("/group/\(groupName)/delay", query: query) { status, data, failed in
            callback(session.isCancelled ? .cancelled : .decode(statusCode: status, data: data, transportFailed: failed))
        }
    }

    static func benchmarkSelectorPlan(_ plan: SelectorBenchmarkPlan,
                                     reusing measurements: [SelectorBenchmarkMeasurementKey: Int],
                                     session: BenchmarkSession,
                                     result: @escaping (SelectorBenchmarkPlan.Target, ProxyDelayOutcome) -> Void,
                                     completion: @escaping () -> Void) {
        SelectorBenchmarkExecutor.runOutcomes(plan: plan, reusing: measurements,
            isCancelled: { session.isCancelled }, request: { target, done in
                let path = target.key.providerName.map {
                    "/providers/proxies/\($0)/\(target.key.proxyName)/healthcheck"
                } ?? "/proxies/\(target.key.proxyName)/delay"
                request(path, query: ["url": target.key.benchmarkURL, "timeout": String(target.key.timeout)]) { status, data, failed in
                    done(.decode(statusCode: status, data: data, transportFailed: failed, cancelled: session.isCancelled))
                }
            }, result: result, completion: completion)
    }
}

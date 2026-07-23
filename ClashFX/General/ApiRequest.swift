//
//  ApiRequest.swift
//  ClashX
//
//  Created by CYC on 2018/7/30.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import Alamofire
import Cocoa
import Starscream
import SwiftyJSON

protocol ApiRequestStreamDelegate: AnyObject {
    func didUpdateTraffic(up: Int, down: Int)
    func didGetLog(log: String, level: String)
}

typealias ErrorString = String

private final class LimitedAsyncTaskRunner {
    typealias Task = (@escaping () -> Void) -> Void

    private let tasks: [Task]
    private let maxConcurrent: Int
    private let stateQueue = DispatchQueue(label: "com.clashfx.proxyDelayTaskRunner")
    private var nextTaskIndex = 0
    private var activeTaskCount = 0
    private var completion: (() -> Void)?

    init(tasks: [Task], maxConcurrent: Int) {
        self.tasks = tasks
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func start(completion: @escaping () -> Void) {
        stateQueue.async {
            self.completion = completion
            self.scheduleAvailableTasks()
        }
    }

    private func scheduleAvailableTasks() {
        while activeTaskCount < maxConcurrent, nextTaskIndex < tasks.count {
            let task = tasks[nextTaskIndex]
            nextTaskIndex += 1
            activeTaskCount += 1

            task {
                self.stateQueue.async {
                    self.activeTaskCount -= 1
                    self.scheduleAvailableTasks()
                }
            }
        }

        guard nextTaskIndex == tasks.count, activeTaskCount == 0 else { return }
        let completion = completion
        self.completion = nil
        DispatchQueue.main.async {
            completion?()
        }
    }
}

class ApiRequest {
    static let shared = ApiRequest()

    private var proxyRespCache: ClashProxyResp?

    static let clashRequestQueue = DispatchQueue(label: "com.clashfx.clashRequestQueue")

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 604800
        configuration.timeoutIntervalForResource = 604800
        configuration.httpMaximumConnectionsPerHost = 100
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        alamoFireManager = Session(configuration: configuration)
    }

    static func authHeader() -> HTTPHeaders {
        let secret = ConfigManager.shared.overrideSecret ?? ConfigManager.shared.apiSecret
        return (!secret.isEmpty) ? ["Authorization": "Bearer \(secret)"] : [:]
    }

    @discardableResult
    private static func req(
        _ url: String,
        method: HTTPMethod = .get,
        parameters: Parameters? = nil,
        encoding: ParameterEncoding = URLEncoding.default
    )
        -> DataRequest {
        guard ConfigManager.shared.isRunning else {
            return AF.request("")
        }

        return shared.alamoFireManager
            .request(ConfigManager.apiUrl + url,
                     method: method,
                     parameters: parameters,
                     encoding: encoding,
                     headers: authHeader())
    }

    weak var delegate: ApiRequestStreamDelegate?

    private var trafficWebSocket: WebSocket?
    private var loggingWebSocket: WebSocket?
    private var trafficWebSocketIsConnected = false
    private var loggingWebSocketIsConnected = false

    private var trafficWebSocketRetryDelay: TimeInterval = 1
    private var loggingWebSocketRetryDelay: TimeInterval = 1
    private var trafficWebSocketRetryTimer: Timer?
    private var loggingWebSocketRetryTimer: Timer?
    private var trafficWatchdogTimer: Timer?
    private static let maxRetryDelaySeconds: TimeInterval = 64
    private static let trafficWatchdogTimeoutSeconds: TimeInterval = 10

    private var alamoFireManager: Session

    static func useDirectApi() -> Bool {
        if ConfigManager.shared.isEnhancedModeActive {
            return false
        }
        if ConfigManager.shared.overrideApiURL != nil {
            return false
        }
        return Settings.builtInApiMode
    }

    static func requestConfig(completeHandler: @escaping ((ClashConfig) -> Void)) {
        requestConfigWithRetry(
            context: RequestConfigContext.current,
            retriesLeft: 5,
            delay: 0.2,
            completeHandler: completeHandler
        )
    }

    private struct RequestConfigContext: Equatable {
        let directApi: Bool
        let apiUrl: String
        let selectedConfig: String

        static var current: RequestConfigContext {
            RequestConfigContext(
                directApi: ApiRequest.useDirectApi(),
                apiUrl: ConfigManager.apiUrl,
                selectedConfig: ConfigManager.selectConfigName
            )
        }
    }

    private static func requestConfigWithRetry(
        context: RequestConfigContext,
        retriesLeft: Int,
        delay: TimeInterval,
        completeHandler: @escaping ((ClashConfig) -> Void)
    ) {
        let retry: (String) -> Void = { reason in
            guard context == RequestConfigContext.current else {
                Logger.log("requestConfig: context changed during retry, reissuing", level: .warning)
                requestConfig(completeHandler: completeHandler)
                return
            }
            guard retriesLeft > 0 else {
                Logger.log("requestConfig: gave up after retries, \(reason)", level: .warning)
                return
            }
            Logger.log("requestConfig: \(reason), retrying in \(delay)s (\(retriesLeft) left)", level: .warning)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                requestConfigWithRetry(
                    context: context,
                    retriesLeft: retriesLeft - 1,
                    delay: min(delay * 1.8, 2.0),
                    completeHandler: completeHandler
                )
            }
        }

        let dispatch: (ClashConfig) -> Void = { config in
            guard context == RequestConfigContext.current else {
                Logger.log("requestConfig: context changed before completion, reissuing", level: .warning)
                requestConfig(completeHandler: completeHandler)
                return
            }
            if config.usedHttpPort > 0 || retriesLeft <= 0 {
                if config.usedHttpPort == 0 {
                    Logger.log("requestConfig: gave up after retries, port still 0", level: .warning)
                }
                completeHandler(config)
                return
            }
            retry("port=0 transient")
        }

        if !context.directApi {
            req("/configs").responseDecodable(of: ClashConfig.self) {
                resp in
                switch resp.result {
                case let .success(config):
                    dispatch(config)
                case let .failure(err):
                    Logger.log("requestConfig: \(err.localizedDescription)")
                    if ConfigManager.shared.isRunning, !ConfigManager.shared.isEnhancedModeActive, retriesLeft <= 0 {
                        NSUserNotificationCenter.default.post(title: "Error", info: err.localizedDescription)
                    }
                    retry(err.localizedDescription)
                }
            }
            return
        }

        clashRequestQueue.async {
            let data = clashGetConfigs()?.toString().data(using: .utf8) ?? Data()
            DispatchQueue.main.async {
                guard let config = ClashConfig.fromData(data) else {
                    NSUserNotificationCenter.default.post(title: "Error", info: "Get clash config failed. Try fixing your config file, then reload the config or restart ClashFX.")
                    (NSApplication.shared.delegate as? AppDelegate)?.startProxy()
                    return
                }
                dispatch(config)
            }
        }
    }

    static func requestConfigUpdate(configName: String, callback: @escaping ((ErrorString?) -> Void)) {
        ConfigManager.getConfigPath(configName: configName) {
            requestConfigUpdate(configPath: $0, callback: callback)
        }
    }

    static func requestConfigUpdate(configPath: String, callback: @escaping ((ErrorString?) -> Void)) {
        let placeHolderErrorDesp = "Error occurred. Please try to fix it by restarting ClashFX. "

        // DEV MODE: Use API
        if !useDirectApi() {
            req("/configs", method: .put, parameters: ["Path": configPath], encoding: JSONEncoding.default).responseData { res in
                if res.response?.statusCode == 204 {
                    ConfigManager.shared.isRunning = true
                    callback(nil)
                } else {
                    let errorJson = try? res.result.get()
                    let err = JSON(errorJson ?? "")["message"].string ?? placeHolderErrorDesp
                    Logger.log(err)
                    callback(err)
                }
            }
            return
        }

        // NORMAL MODE: Use internal api
        clashRequestQueue.async {
            let res = clashUpdateConfig(configPath.goStringBuffer())?.toString() ?? placeHolderErrorDesp
            DispatchQueue.main.async {
                if res == "success" {
                    callback(nil)
                } else {
                    Logger.log(res)
                    callback(res)
                }
            }
        }
    }

    static func updateOutBoundMode(mode: ClashProxyMode, callback: ((Bool) -> Void)? = nil) {
        req("/configs", method: .patch, parameters: ["mode": mode.rawValue], encoding: JSONEncoding.default)
            .validate(statusCode: 200 ..< 300)
            .responseData { response in
                switch response.result {
                case .success:
                    callback?(true)
                case let .failure(error):
                    let status = response.response
                        .map { String($0.statusCode) } ?? "none"
                    Logger.log(
                        "Failed to update outbound mode to \(mode.rawValue): " +
                            "status=\(status) error=\(error.localizedDescription)",
                        level: .error
                    )
                    callback?(false)
                }
            }
    }

    static func updateLogLevel(level: ClashLogLevel, callback: ((Bool) -> Void)? = nil) {
        req("/configs", method: .patch, parameters: ["log-level": level.rawValue], encoding: JSONEncoding.default).responseData(completionHandler: { response in
            switch response.result {
            case .success:
                callback?(true)
            case .failure:
                callback?(false)
            }
        })
    }

    static func requestProxyGroupList(completeHandler: ((ClashProxyResp) -> Void)? = nil) {
        req("/proxies").responseData {
            res in
            let proxies = ClashProxyResp(try? res.result.get())
            ApiRequest.shared.proxyRespCache = proxies
            completeHandler?(proxies)
        }
    }

    static func requestProxyProviderList(completeHandler: ((ClashProviderResp) -> Void)? = nil) {
        req("/providers/proxies")
            .responseDecodable(of: ClashProviderResp.self, decoder: ClashProviderResp.decoder) { resp in
                switch resp.result {
                case let .success(providerResp):
                    completeHandler?(providerResp)
                case let .failure(err):
                    Logger.log("\(err)")
                    completeHandler?(ClashProviderResp())
                }
            }
    }

    static func updateAllowLan(allow: Bool, completeHandler: (() -> Void)? = nil) {
        Logger.log("update allow lan:\(allow)", level: .debug)
        req("/configs",
            method: .patch,
            parameters: ["allow-lan": allow],
            encoding: JSONEncoding.default).response {
            _ in
            completeHandler?()
        }
    }

    static func updateProxyGroup(group: String, selectProxy: String, callback: @escaping ((Bool) -> Void)) {
        req("/proxies/\(group.encoded)",
            method: .put,
            parameters: ["name": selectProxy],
            encoding: JSONEncoding.default)
            .responseData { response in
                let statusCode = response.response?.statusCode ?? -1
                let success = statusCode == 204
                if success {
                    Logger.log("[Proxy Select] Selected '\(selectProxy)' for group '\(group)'")
                } else {
                    let body = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<empty body>"
                    Logger.log("[Proxy Select] Failed selecting '\(selectProxy)' for group '\(group)', status: \(statusCode), error: \(response.error?.localizedDescription ?? "unknown error"), body: \(body)", level: .warning)
                }
                callback(success)
            }
    }

    static func getAllProxyList(callback: @escaping (([ClashProxyName]) -> Void)) {
        requestProxyGroupList {
            proxyInfo in
            let lists: [ClashProxyName] = proxyInfo.proxiesMap["GLOBAL"]?.all ?? []
            callback(lists)
        }
    }

    static func getMergedProxyData(complete: ((ClashProxyResp?) -> Void)? = nil) {
        let group = DispatchGroup()
        group.enter()
        group.enter()

        var provider: ClashProviderResp?
        var proxyInfo: ClashProxyResp?

        group.notify(queue: .main) {
            guard let proxyInfo = proxyInfo, let proxyprovider = provider else {
                complete?(nil)
                return
            }
            proxyInfo.updateProvider(proxyprovider)
            complete?(proxyInfo)
        }

        ApiRequest.requestProxyProviderList {
            proxyprovider in
            provider = proxyprovider
            group.leave()
        }

        ApiRequest.requestProxyGroupList {
            proxy in
            proxyInfo = proxy
            group.leave()
        }
    }

    static func getProxyDelay(proxyName: String,
                              benchmarkURL: String = Settings.benchMarkUrl,
                              timeout: Int = 5000,
                              callback: @escaping ((Int) -> Void)) {
        requestProxyDelay(
            path: "/proxies/\(proxyName.encoded)/delay",
            description: "proxy '\(proxyName)'",
            benchmarkURL: benchmarkURL,
            timeout: timeout,
            callback: callback
        )
    }

    static func getProviderProxyDelay(providerName: ClashProviderName,
                                      proxyName: ClashProxyName,
                                      benchmarkURL: String = Settings.benchMarkUrl,
                                      timeout: Int = 5000,
                                      callback: @escaping ((Int) -> Void)) {
        requestProxyDelay(
            path: "/providers/proxies/\(providerName.encoded)/\(proxyName.encoded)/healthcheck",
            description: "provider '\(providerName)' proxy '\(proxyName)'",
            benchmarkURL: benchmarkURL,
            timeout: timeout,
            callback: callback
        )
    }

    static func benchmarkLeafProxies(in response: ClashProxyResp,
                                     benchmarkURL: String,
                                     timeout: Int,
                                     maxConcurrent: Int = 10,
                                     completion: @escaping () -> Void) {
        typealias DelayTask = LimitedAsyncTaskRunner.Task
        var tasks = [DelayTask]()

        // GLOBAL.all also contains policy groups. Testing a group recursively
        // tests its members, often more than once when providers are shared.
        // Build one task per actual leaf proxy instead.
        let builtInNames: Set = [
            "GLOBAL", "DIRECT", "REJECT", "REJECT-DROP",
            "PASS", "PASS-RULE", "COMPATIBLE"
        ]
        var inlineProxyNames = Set<String>()
        let inlineProxies = response.proxies
            .filter { proxy in
                proxy.enclosingProvider == nil
                    && proxy.all == nil
                    && proxy.type != .direct
                    && proxy.type != .reject
                    && !builtInNames.contains(proxy.name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for proxy in inlineProxies where inlineProxyNames.insert(proxy.name).inserted {
            tasks.append { done in
                getProxyDelay(
                    proxyName: proxy.name,
                    benchmarkURL: benchmarkURL,
                    timeout: timeout
                ) { _ in
                    done()
                }
            }
        }

        var providerProxyKeys = Set<String>()
        let providers = response.enclosingProviderResp?.providers.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        } ?? []
        for provider in providers {
            let proxies = provider.proxies.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for proxy in proxies {
                let key = provider.name + "\u{0}" + proxy.name
                guard providerProxyKeys.insert(key).inserted else { continue }
                tasks.append { done in
                    getProviderProxyDelay(
                        providerName: provider.name,
                        proxyName: proxy.name,
                        benchmarkURL: benchmarkURL,
                        timeout: timeout
                    ) { _ in
                        done()
                    }
                }
            }
        }

        Logger.log(
            "[Proxy Delay] Starting leaf-only benchmark: "
                + "\(inlineProxyNames.count) inline, \(providerProxyKeys.count) provider, "
                + "max concurrency \(max(1, maxConcurrent))"
        )
        LimitedAsyncTaskRunner(tasks: tasks, maxConcurrent: maxConcurrent).start(completion: completion)
    }

    private static func requestProxyDelay(path: String,
                                          description: String,
                                          benchmarkURL: String,
                                          timeout: Int,
                                          callback: @escaping ((Int) -> Void)) {
        Logger.log("[Proxy Delay] Testing \(description) with url: \(benchmarkURL)")
        req(path,
            method: .get,
            parameters: ["timeout": timeout, "url": benchmarkURL])
            .responseData { res in
                let statusCode = res.response?.statusCode ?? -1
                switch res.result {
                case let .success(value):
                    let json = JSON(value)
                    let delay = json["delay"].intValue
                    if delay > 0 {
                        Logger.log("[Proxy Delay] \(description) succeeded: \(delay) ms, status: \(statusCode)")
                    } else {
                        let body = String(data: value, encoding: .utf8) ?? "<non-utf8 body>"
                        Logger.log("[Proxy Delay] \(description) returned no delay, status: \(statusCode), body: \(body)", level: .warning)
                    }
                    callback(delay)
                case .failure:
                    let body = res.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<empty body>"
                    Logger.log("[Proxy Delay] \(description) failed, status: \(statusCode), error: \(res.error?.localizedDescription ?? "unknown error"), body: \(body)", level: .error)
                    callback(0)
                }
            }
    }

    static func getRules(completeHandler: @escaping ([ClashRule]) -> Void) {
        req("/rules").responseData { res in
            guard let data = try? res.result.get() else { return }
            let rule = ClashRuleResponse.fromData(data)
            completeHandler(rule.rules ?? [])
        }
    }

    static func healthCheck(proxy: ClashProviderName, completeHandler: (() -> Void)? = nil) {
        Logger.log("HeathCheck for \(proxy) started")
        req("/providers/proxies/\(proxy.encoded)/healthcheck").response { res in
            if res.response?.statusCode == 204 {
                Logger.log("HeathCheck for \(proxy) finished")
            } else {
                Logger.log("HeathCheck for \(proxy) failed:\(res.response?.statusCode ?? -1)")
            }
            completeHandler?()
        }
    }

    static func resetAutoProxyGroup(group: ClashProxyName, completeHandler: (() -> Void)? = nil) {
        Logger.log("[Proxy ReTest] Resetting auto proxy group '\(group)'")
        req("/proxies/\(group.encoded)", method: .delete).responseData { res in
            let statusCode = res.response?.statusCode ?? -1
            if statusCode == 204 {
                Logger.log("[Proxy ReTest] Auto proxy group '\(group)' reset")
            } else {
                let body = res.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<empty body>"
                Logger.log("[Proxy ReTest] Failed resetting auto proxy group '\(group)', status: \(statusCode), body: \(body)", level: .warning)
            }
            completeHandler?()
        }
    }
}

// MARK: - Connections

extension ApiRequest {
    static func getConnections(completeHandler: @escaping ([ClashConnectionBaseSnapShot.Connection]) -> Void) {
        req("/connections").responseDecodable(of: ClashConnectionBaseSnapShot.self) { resp in
            switch resp.result {
            case let .success(snapshot):
                completeHandler(snapshot.connections)
            case .failure:
                completeHandler([])
            }
        }
    }

    static func closeConnection(_ id: String) {
        req("/connections/\(id)", method: .delete).response { _ in }
    }

    static func closeAllConnection() {
        if useDirectApi() {
            clash_closeAllConnections()
        } else {
            req("/connections", method: .delete).response { _ in }
        }
    }

    // MARK: - Providers

    struct AllProviders {
        var proxies = [String]()
        var rules = [String]()
    }

    static func requestExternalProviderNames(completeHandler: @escaping (AllProviders) -> Void) {
        var providers = AllProviders()
        let group = DispatchGroup()
        group.enter()
        ApiRequest.req("/providers/proxies").responseData { resp in
            switch resp.result {
            case let .success(res):
                let json = JSON(res)
                let provoders = json["providers"].dictionaryValue
                    .filter { $0.value["vehicleType"] == "HTTP" }.map(\.key)
                providers.proxies = provoders
            case let .failure(err):
                Logger.log(err.localizedDescription, level: .warning)
            }
            group.leave()
        }

        #if PRO_VERSION
            group.enter()
            ApiRequest.req("/providers/rules").responseData { resp in
                switch resp.result {
                case let .success(res):
                    let json = JSON(res)
                    let provoders = json["providers"].dictionaryValue
                        .filter { $0.value["vehicleType"] == "HTTP" }.map(\.key)
                    providers.rules = provoders
                case let .failure(err):
                    Logger.log(err.localizedDescription, level: .warning)
                }
                group.leave()
            }
        #endif
        group.notify(queue: .main) {
            completeHandler(providers)
        }
    }

    enum ProviderType {
        case proxy
        case rule
    }

    static func updateProvider(name: String, type: ProviderType, completeHandler: @escaping (Bool) -> Void) {
        let url: String
        switch type {
        case .proxy:
            url = "/providers/proxies/\(name.encoded)"
        case .rule:
            url = "/providers/rules/\(name.encoded)"
        }
        ApiRequest.req(url, method: .put).response { resp in
            if resp.response?.statusCode == 204 {
                completeHandler(true)
            } else {
                completeHandler(false)
            }
        }
    }

    static func resetFakeIpCache() {
        ApiRequest.req("/cache/fakeip/flush", method: .post).response { resp in
            Logger.log("flush fake ip: \(resp.response?.statusCode ?? -1)")
        }
    }
}

// MARK: - Stream Apis

extension ApiRequest {
    func resetStreamApis() {
        resetLogStreamApi()
        resetTrafficStreamApi()
    }

    func resetLogStreamApi() {
        loggingWebSocketRetryTimer?.invalidate()
        loggingWebSocketRetryTimer = nil
        loggingWebSocketRetryDelay = 1
        requestLog()
    }

    func resetTrafficStreamApi() {
        trafficWebSocketRetryTimer?.invalidate()
        trafficWebSocketRetryTimer = nil
        trafficWebSocketRetryDelay = 1
        requestTrafficInfo()
    }

    private func requestTrafficInfo() {
        retireWebSocket(&trafficWebSocket)
        trafficWebSocketIsConnected = false

        if ApiRequest.useDirectApi() {
            cancelTrafficWatchdog()
            return
        }
        trafficWebSocketRetryTimer?.invalidate()
        trafficWebSocketRetryTimer = nil

        guard let url = URL(string: ConfigManager.apiUrl.appending("/traffic")) else { return }
        var request = URLRequest(url: url)
        for header in ApiRequest.authHeader() {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        let socket = WebSocket(request: request)
        socket.delegate = self
        trafficWebSocket = socket
        socket.connect()
    }

    private func requestLog() {
        retireWebSocket(&loggingWebSocket)
        loggingWebSocketIsConnected = false

        if ApiRequest.useDirectApi() {
            return
        }
        loggingWebSocketRetryTimer?.invalidate()
        loggingWebSocketRetryTimer = nil

        let uriString = "/logs?level=".appending(ConfigManager.selectLoggingApiLevel.rawValue)
        guard let url = URL(string: ConfigManager.apiUrl.appending(uriString)) else { return }
        var request = URLRequest(url: url)
        for header in ApiRequest.authHeader() {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        let socket = WebSocket(request: request)
        socket.delegate = self
        loggingWebSocket = socket
        socket.connect()
    }

    private func retireWebSocket(_ socket: inout WebSocket?) {
        guard let s = socket else { return }
        s.delegate = nil
        s.forceDisconnect()
        socket = nil
    }
}

extension ApiRequest: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        let webSocket = client as? WebSocket
        let isTraffic = webSocket != nil && webSocket === trafficWebSocket
        let isLogging = webSocket != nil && webSocket === loggingWebSocket

        switch event {
        case .connected:
            if isTraffic {
                trafficWebSocketIsConnected = true
                trafficWebSocketRetryDelay = 1
                armTrafficWatchdog()
                Logger.log("trafficWebSocket did Connect", level: .debug)
            } else if isLogging {
                loggingWebSocketIsConnected = true
                loggingWebSocketRetryDelay = 1
                Logger.log("loggingWebSocket did Connect", level: .debug)
            }
        case let .disconnected(reason, code):
            handleStreamClosed(isTraffic: isTraffic, isLogging: isLogging, description: "\(reason) (code=\(code))")
        case .cancelled:
            handleStreamClosed(isTraffic: isTraffic, isLogging: isLogging, description: "cancelled")
        case .peerClosed:
            handleStreamClosed(isTraffic: isTraffic, isLogging: isLogging, description: "peer closed")
        case let .error(error):
            let desc = error?.localizedDescription ?? "unknown"
            Logger.log("websocket error: \(desc)", level: .error)
            handleStreamClosed(isTraffic: isTraffic, isLogging: isLogging, description: "error: \(desc)")
        case let .text(text):
            let json = JSON(parseJSON: text)
            if isTraffic {
                armTrafficWatchdog()
                delegate?.didUpdateTraffic(up: json["up"].intValue, down: json["down"].intValue)
            } else if isLogging {
                delegate?.didGetLog(log: json["payload"].stringValue, level: json["type"].string ?? "info")
            }
        case .binary, .ping, .pong, .viabilityChanged, .reconnectSuggested:
            break
        }
    }

    private func handleStreamClosed(isTraffic: Bool, isLogging: Bool, description: String) {
        if isTraffic {
            trafficWebSocketIsConnected = false
            Logger.log("trafficWebSocket did disconnect (\(description))", level: .debug)
            scheduleTrafficRetry()
        } else if isLogging {
            loggingWebSocketIsConnected = false
            Logger.log("loggingWebSocket did disconnect (\(description))", level: .debug)
            scheduleLogRetry()
        } else {
            Logger.log("stale websocket disconnect ignored (\(description))", level: .debug)
        }
    }

    private func scheduleTrafficRetry() {
        let arm: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.trafficWebSocketRetryTimer?.invalidate()
            self.trafficWebSocketRetryTimer = Timer.scheduledTimer(
                withTimeInterval: self.trafficWebSocketRetryDelay, repeats: false
            ) { [weak self] _ in
                if self?.trafficWebSocketIsConnected == true { return }
                self?.requestTrafficInfo()
            }
            self.trafficWebSocketRetryDelay = min(self.trafficWebSocketRetryDelay * 2, Self.maxRetryDelaySeconds)
        }
        if Thread.isMainThread { arm() } else { DispatchQueue.main.async(execute: arm) }
    }

    private func scheduleLogRetry() {
        let arm: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.loggingWebSocketRetryTimer?.invalidate()
            self.loggingWebSocketRetryTimer = Timer.scheduledTimer(
                withTimeInterval: self.loggingWebSocketRetryDelay, repeats: false
            ) { [weak self] _ in
                if self?.loggingWebSocketIsConnected == true { return }
                self?.requestLog()
            }
            self.loggingWebSocketRetryDelay = min(self.loggingWebSocketRetryDelay * 2, Self.maxRetryDelaySeconds)
        }
        if Thread.isMainThread { arm() } else { DispatchQueue.main.async(execute: arm) }
    }

    private func armTrafficWatchdog() {
        let arm: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.trafficWatchdogTimer?.invalidate()
            self.trafficWatchdogTimer = Timer.scheduledTimer(
                withTimeInterval: Self.trafficWatchdogTimeoutSeconds, repeats: false
            ) { [weak self] _ in
                Logger.log("trafficWebSocket watchdog: no data for \(Self.trafficWatchdogTimeoutSeconds)s, forcing reset", level: .warning)
                self?.resetTrafficStreamApi()
            }
        }
        if Thread.isMainThread {
            arm()
        } else {
            DispatchQueue.main.async(execute: arm)
        }
    }

    private func cancelTrafficWatchdog() {
        let cancel: () -> Void = { [weak self] in
            self?.trafficWatchdogTimer?.invalidate()
            self?.trafficWatchdogTimer = nil
        }
        if Thread.isMainThread {
            cancel()
        } else {
            DispatchQueue.main.async(execute: cancel)
        }
    }
}

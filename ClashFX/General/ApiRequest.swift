//
//  ApiRequest.swift
//  ClashX
//
//  Created by CYC on 2018/7/30.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import Alamofire
import Cocoa
import CoreFoundation
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
    typealias ProxyGroupDelayResult = ProxyGroupDelayOutcome

    struct ProviderProxyBenchmarkTarget: Hashable {
        let providerName: ClashProviderName
        let proxyName: ClashProxyName
    }

    struct LeafProxyBenchmarkResult {
        let identity: LeafProxyBenchmarkIdentity
        let benchmarkURL: String
        let outcome: ProxyDelayOutcome
    }

    final class BenchmarkSession {
        private let lock = NSLock()
        private var requests: [UUID: DataRequest] = [:]
        private var cancelled = false
        private var terminated = false
        private var terminationObservers = [() -> Void]()
        fileprivate let probeCoreScope: BenchmarkProbeCoreScope

        init(probeCoreScope: BenchmarkProbeCoreScope? = nil) {
            self.probeCoreScope = probeCoreScope ?? ApiRequest.currentBenchmarkProbeCoreScope()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        fileprivate func performIfActive(_ work: () -> Void) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, !terminated else { return false }
            work()
            return true
        }

        fileprivate func track(_ request: DataRequest) -> UUID {
            let id = UUID()
            lock.lock()
            let shouldCancel = cancelled
            if !shouldCancel {
                requests[id] = request
            }
            lock.unlock()

            if shouldCancel {
                request.cancel()
            }
            return id
        }

        fileprivate func finish(_ id: UUID) {
            lock.lock()
            requests[id] = nil
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return
            }
            cancelled = true
            let pendingRequests = Array(requests.values)
            requests.removeAll()
            lock.unlock()

            pendingRequests.forEach { $0.cancel() }
            terminate()
        }

        func onTermination(_ observer: @escaping () -> Void) {
            lock.lock()
            let invokeNow = terminated
            if !invokeNow {
                terminationObservers.append(observer)
            }
            lock.unlock()

            if invokeNow {
                if Thread.isMainThread {
                    observer()
                } else {
                    DispatchQueue.main.async(execute: observer)
                }
            }
        }

        func terminate() {
            lock.lock()
            guard !terminated else {
                lock.unlock()
                return
            }
            terminated = true
            let observers = terminationObservers
            terminationObservers.removeAll()
            lock.unlock()

            if Thread.isMainThread {
                observers.forEach { $0() }
            } else {
                DispatchQueue.main.async {
                    observers.forEach { $0() }
                }
            }
        }
    }

    static let shared = ApiRequest()
    static let benchmarkMaxConcurrent = 10

    private var proxyRespCacheData: Data?
    private var rulesCache: [ClashRule] = []
    private var lastProxyCacheFallbackLogDate = Date.distantPast

    static let clashRequestQueue = DispatchQueue(label: "com.clashfx.clashRequestQueue")
    private static let proxySnapshotDecodeQueue = DispatchQueue(
        label: "com.clashfx.proxySnapshotDecodeQueue",
        qos: .userInitiated
    )

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
        encoding: ParameterEncoding = URLEncoding.default,
        timeoutInterval: TimeInterval? = nil
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
                     headers: authHeader(),
                     requestModifier: { request in
                         if let timeoutInterval {
                             request.timeoutInterval = timeoutInterval
                         }
                     })
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
        let coreUpdateEpoch: UInt64?

        static var current: RequestConfigContext {
            let directApi = ApiRequest.useDirectApi()
            return RequestConfigContext(
                directApi: directApi,
                apiUrl: ConfigManager.apiUrl,
                selectedConfig: ConfigManager.selectConfigName,
                coreUpdateEpoch: directApi ? UInt64(clashCurrentConfigUpdateEpoch()) : nil
            )
        }
    }

    static func currentRuntimeConfigReadbackEpoch() -> UInt64? {
        guard useDirectApi() else { return nil }
        return UInt64(clashCurrentConfigUpdateEpoch())
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
            if config.usedHttpPort > 0 || config.usedSocksPort > 0 {
                completeHandler(config)
                return
            }

            if retriesLeft > 0 {
                retry("port=0 transient")
            } else {
                Logger.log("requestConfig: gave up after retries, port still 0", level: .warning)
            }
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
            guard context.coreUpdateEpoch == UInt64(clashCurrentConfigUpdateEpoch()) else {
                DispatchQueue.main.async { requestConfig(completeHandler: completeHandler) }
                return
            }
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

    struct RuntimeConfigContext: Equatable {
        let direct: Bool
        let apiURL: String
        let secret: String
    }

    static func runtimeConfigContext() -> RuntimeConfigContext {
        RuntimeConfigContext(direct: useDirectApi(), apiURL: ConfigManager.apiUrl,
                             secret: ConfigManager.shared.overrideSecret ?? ConfigManager.shared.apiSecret)
    }

    private static let runtimeSessionsLock = NSLock()
    private static var runtimeSessions = [UUID: URLSession]()

    /// A cancelled request must never reconnect to a replacement core on the same port.
    static func cancelRuntimeConfigOperations() {
        clashCancelPendingConfigUpdate()
        runtimeSessionsLock.lock()
        let sessions = Array(runtimeSessions.values)
        runtimeSessions.removeAll()
        runtimeSessionsLock.unlock()
        sessions.forEach { $0.invalidateAndCancel() }
    }

    private static func runtimeConfigHTTP(
        path: String, method: String = "GET", body: [String: Any]? = nil,
        context: RuntimeConfigContext, timeout: TimeInterval = 8,
        completion: @escaping (Data?, Int?, Error?) -> Void
    ) {
        guard let url = URL(string: context.apiURL + path) else {
            completion(nil, nil, NSError(domain: "ClashFX.RuntimeConfig", code: 1)); return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if !context.secret.isEmpty { request.setValue("Bearer " + context.secret, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let id = UUID()
        runtimeSessionsLock.lock(); runtimeSessions[id] = session; runtimeSessionsLock.unlock()
        session.dataTask(with: request) { data, response, error in
            runtimeSessionsLock.lock(); runtimeSessions[id] = nil; runtimeSessionsLock.unlock()
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                completion(data, (response as? HTTPURLResponse)?.statusCode, error)
            }
        }.resume()
    }

    static func applyRuntimeConfig(
        file: URL, context: RuntimeConfigContext,
        completion: @escaping (RuntimeConfigTransactionController.ApplyResult) -> Void
    ) {
        guard context == runtimeConfigContext() else { completion(.rejected("Runtime API scope changed")); return }
        let requestID = UUID()
        if context.direct {
            // Capture before enqueue: a replacement core can reuse the same URL/secret.
            let epoch = clashCurrentConfigUpdateEpoch()
            let expectedEpoch = UInt64(epoch)
            clashRequestQueue.async {
                guard context == runtimeConfigContext() else {
                    DispatchQueue.main.async { completion(.rejected("Runtime API scope changed")) }; return
                }
                let queuedEpoch = UInt64(clashCurrentConfigUpdateEpoch())
                guard queuedEpoch == expectedEpoch else {
                    DispatchQueue.main.async {
                        guard context == runtimeConfigContext() else {
                            completion(.uncertain("Runtime scope changed before configuration apply")); return
                        }
                        let detail = "Apply was cancelled because the core epoch changed before the request started"
                        let reason = RuntimeConfigApplyDiagnostics.formattedReason(
                            transport: .embedded,
                            stage: .cancelled,
                            requestID: requestID,
                            expectedEpoch: expectedEpoch,
                            currentEpoch: queuedEpoch,
                            detail: detail
                        )
                        Logger.log(reason, level: .warning)
                        completion(.uncertain(RuntimeConfigApplyDiagnostics.displayReason(detail)))
                    }
                    return
                }
                let result = clashUpdateConfigWithEpoch(file.path.goStringBuffer(), epoch)?.toString()
                DispatchQueue.main.async {
                    guard context == runtimeConfigContext() else {
                        completion(.uncertain("Runtime scope changed while applying configuration")); return
                    }
                    let currentEpoch = UInt64(clashCurrentConfigUpdateEpoch())
                    guard currentEpoch == expectedEpoch else {
                        let detail = "Core epoch changed while apply was in flight; core response: \(result ?? "[nil]")"
                        let reason = RuntimeConfigApplyDiagnostics.formattedReason(
                            transport: .embedded,
                            stage: .cancelled,
                            requestID: requestID,
                            expectedEpoch: expectedEpoch,
                            currentEpoch: currentEpoch,
                            detail: detail
                        )
                        Logger.log(reason, level: .warning)
                        completion(.uncertain(RuntimeConfigApplyDiagnostics.displayReason(detail)))
                        return
                    }

                    switch RuntimeConfigApplyDiagnostics.embeddedDecision(result) {
                    case .accepted:
                        completion(.accepted)
                    case let .rejected(detail):
                        let reason = RuntimeConfigApplyDiagnostics.formattedReason(
                            transport: .embedded,
                            stage: .embeddedResponse,
                            requestID: requestID,
                            expectedEpoch: expectedEpoch,
                            currentEpoch: currentEpoch,
                            detail: detail
                        )
                        Logger.log(reason, level: .error)
                        completion(.rejected(RuntimeConfigApplyDiagnostics.displayReason(detail)))
                    case let .uncertain(detail):
                        let reason = RuntimeConfigApplyDiagnostics.formattedReason(
                            transport: .embedded,
                            stage: .embeddedResponse,
                            requestID: requestID,
                            expectedEpoch: expectedEpoch,
                            currentEpoch: currentEpoch,
                            detail: detail
                        )
                        Logger.log(reason, level: .warning)
                        completion(.uncertain(RuntimeConfigApplyDiagnostics.displayReason(detail)))
                    }
                }
            }
        } else {
            runtimeConfigHTTP(path: "/configs?force=true", method: "PUT", body: ["Path": file.path], context: context, timeout: 12) { data, status, error in
                guard context == runtimeConfigContext() else {
                    completion(.uncertain("Runtime scope changed while applying configuration")); return
                }
                let decision = RuntimeConfigApplyDiagnostics.httpDecision(
                    statusCode: status,
                    errorDescription: error?.localizedDescription,
                    body: data
                )
                switch decision {
                case .accepted:
                    completion(.accepted)
                case let .rejected(detail):
                    let reason = RuntimeConfigApplyDiagnostics.formattedReason(
                        transport: .http,
                        stage: .httpResponse,
                        requestID: requestID,
                        expectedEpoch: nil,
                        currentEpoch: nil,
                        detail: detail
                    )
                    Logger.log(reason, level: .error)
                    completion(.rejected(RuntimeConfigApplyDiagnostics.displayReason(detail)))
                case let .uncertain(detail):
                    let stage: RuntimeConfigApplyDiagnostics.Stage = error == nil ? .httpResponse : .httpTransportError
                    let reason = RuntimeConfigApplyDiagnostics.formattedReason(
                        transport: .http,
                        stage: stage,
                        requestID: requestID,
                        expectedEpoch: nil,
                        currentEpoch: nil,
                        detail: detail
                    )
                    Logger.log(reason, level: .warning)
                    completion(.uncertain(RuntimeConfigApplyDiagnostics.displayReason(detail)))
                }
            }
        }
    }

    static func readRuntimeConfig(context: RuntimeConfigContext, completion: @escaping ([String: Any]?, String?) -> Void) {
        guard context == runtimeConfigContext() else { completion(nil, "Runtime API scope changed"); return }
        let decode: (Data?) -> Void = { data in
            guard context == runtimeConfigContext(), let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "Core configuration readback was unavailable"); return
            }
            completion(object, nil)
        }
        if context.direct {
            clashRequestQueue.async {
                let bytes = clashGetConfigs()?.toString().data(using: .utf8)
                DispatchQueue.main.async { decode(bytes) }
            }
        } else {
            runtimeConfigHTTP(path: "/configs", context: context) { data, status, error in
                decode(error == nil && status == 200 ? data : nil)
            }
        }
    }

    static func readRuntimeProxySnapshot(
        context: RuntimeConfigContext, requireCurrentContext: Bool = true,
        completion: @escaping (Data?, String?) -> Void
    ) {
        guard !requireCurrentContext || context == runtimeConfigContext() else {
            completion(nil, "Runtime API scope changed"); return
        }
        runtimeConfigHTTP(path: "/proxies", context: context, timeout: 4) { data, status, error in
            guard !requireCurrentContext || context == runtimeConfigContext() else {
                completion(nil, "Runtime API scope changed"); return
            }
            guard error == nil, status == 200, RuntimeProxySelectionPolicy(data: data) != nil else {
                completion(nil, "Runtime proxy snapshot unavailable"); return
            }
            completion(data, nil)
        }
    }

    static func readRuntimeProxySelections(
        context: RuntimeConfigContext,
        completion: @escaping ([String: String]?, String?) -> Void
    ) {
        let complete: ([String: String]?, String?) -> Void = { records, error in
            if Thread.isMainThread {
                completion(records, error)
            } else {
                DispatchQueue.main.async { completion(records, error) }
            }
        }
        guard context == runtimeConfigContext() else {
            complete(nil, "Runtime API scope changed")
            return
        }
        runtimeConfigHTTP(path: "/proxies", context: context, timeout: 4) { data, status, error in
            guard context == runtimeConfigContext() else {
                complete(nil, "Runtime API scope changed")
                return
            }
            guard error == nil, status == 200,
                  let snapshot = RuntimeProxySelectionPolicy(data: data) else {
                complete(nil, "Runtime proxy selections could not be read.")
                return
            }
            complete(snapshot.manualSelections, nil)
        }
    }

    static func restoreRuntimeProxySelections(
        records: [String: String],
        strict: Bool,
        context: RuntimeConfigContext,
        isCurrent: @escaping () -> Bool,
        completion: @escaping (RuntimeConfigTransactionController.ApplyResult) -> Void
    ) {
        let sequence = RuntimeProxySelectionRestoreSequence(
            records: records,
            strict: strict,
            isCurrent: { context == runtimeConfigContext() && isCurrent() },
            request: { path, method, body, timeout, callback in
                runtimeConfigHTTP(
                    path: path,
                    method: method,
                    body: body,
                    context: context,
                    timeout: timeout,
                    completion: callback
                )
            },
            completion: { outcome in
                switch outcome {
                case .accepted:
                    completion(.accepted)
                case let .rejected(reason):
                    completion(.rejected(reason))
                case let .uncertain(reason):
                    completion(.uncertain(reason))
                }
            }
        )
        sequence.start()
    }

    static func lastSubmittedRuntimeConfig(completion: @escaping (Data?) -> Void) {
        clashRequestQueue.async {
            let data = clashGetLastSubmittedConfig()?.toString().data(using: .utf8)
            DispatchQueue.main.async { completion(data?.isEmpty == false ? data : nil) }
        }
    }

    private struct RuntimeProxyListener {
        enum Kind {
            case http
            case socks
        }

        let port: Int
        let kind: Kind
    }

    /// Probes a confirmed local listener. Authentication-required configs are
    /// deliberately left unprobed until authenticated proxy requests are supported.
    static func probeRuntimeConfigDataPlane(
        context: RuntimeConfigContext,
        authenticationRequired: Bool = false,
        completion: @escaping (RuntimeConfigTransactionController.VerificationResult) -> Void
    ) {
        let complete: (RuntimeConfigTransactionController.VerificationResult) -> Void = { result in
            if Thread.isMainThread {
                completion(result)
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }
        guard context == runtimeConfigContext() else {
            complete(.failed("Runtime scope changed during data-plane probe"))
            return
        }
        guard !authenticationRequired else {
            complete(.verified(.notChecked))
            return
        }

        readRuntimeConfig(context: context) { config, _ in
            guard context == runtimeConfigContext() else {
                complete(.failed("Runtime scope changed during data-plane probe"))
                return
            }
            let listeners = config.map(Self.runtimeProxyListeners(from:)) ?? []
            Self.probeRuntimeProxyListener(
                listeners,
                index: 0,
                context: context,
                completion: complete
            )
        }
    }

    private static func runtimeProxyListeners(from config: [String: Any]) -> [RuntimeProxyListener] {
        let entries: [(String, RuntimeProxyListener.Kind)] = [
            ("mixed-port", .http),
            ("port", .http),
            ("socks-port", .socks)
        ]
        var seen = Set<Int>()
        return entries.compactMap { key, kind in
            guard let port = runtimeProxyPort(config[key]),
                  seen.insert(port).inserted else { return nil }
            return RuntimeProxyListener(port: port, kind: kind)
        }
    }

    private static func runtimeProxyPort(_ value: Any?) -> Int? {
        if let string = value as? String, let port = Int(string), (1 ... 65_535).contains(port) {
            return port
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              (1 ... 65_535).contains(value) else { return nil }
        return Int(value)
    }

    private static func runtimeProxySettings(for listener: RuntimeProxyListener) -> [String: Any] {
        var settings: [String: Any] = [
            "HTTPEnable": false,
            "HTTPSEnable": false,
            "SOCKSEnable": false,
            "ProxyAutoConfigEnable": false,
            "ProxyAutoDiscoveryEnable": false
        ]
        switch listener.kind {
        case .http:
            settings["HTTPEnable"] = true
            settings["HTTPProxy"] = "127.0.0.1"
            settings["HTTPPort"] = listener.port
            settings["HTTPSEnable"] = true
            settings["HTTPSProxy"] = "127.0.0.1"
            settings["HTTPSPort"] = listener.port
        case .socks:
            settings["SOCKSEnable"] = true
            settings["SOCKSProxy"] = "127.0.0.1"
            settings["SOCKSPort"] = listener.port
            settings["SOCKSVersion"] = 5
        }
        return settings
    }

    private static func probeRuntimeProxyListener(
        _ listeners: [RuntimeProxyListener],
        index: Int,
        context: RuntimeConfigContext,
        completion: @escaping (RuntimeConfigTransactionController.VerificationResult) -> Void
    ) {
        guard context == runtimeConfigContext() else {
            completion(.failed("Runtime scope changed during proxy listener probe"))
            return
        }
        guard index < listeners.count else {
            completion(.verified(.unavailable))
            return
        }

        let url = URL(string: "https://cp.cloudflare.com/generate_204")!
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 1.25
        )
        request.httpMethod = "GET"
        runtimeDataPlaneHTTP(
            request: request,
            proxySettings: runtimeProxySettings(for: listeners[index]),
            context: context,
            timeout: 1.25
        ) { _, status, error in
            guard context == runtimeConfigContext() else {
                completion(.failed("Runtime scope changed during proxy listener probe"))
                return
            }
            if error == nil, status == 204 {
                completion(.verified(.healthy))
            } else {
                probeRuntimeProxyListener(
                    listeners,
                    index: index + 1,
                    context: context,
                    completion: completion
                )
            }
        }
    }

    private static func runtimeDataPlaneHTTP(
        request: URLRequest,
        proxySettings: [String: Any],
        context: RuntimeConfigContext,
        timeout: TimeInterval,
        completion: @escaping (Data?, Int?, Error?) -> Void
    ) {
        guard context == runtimeConfigContext() else {
            DispatchQueue.main.async { completion(nil, nil, NSError(domain: "ClashFX.RuntimeConfig", code: 2)) }
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = proxySettings
        let session = URLSession(configuration: configuration)
        let id = UUID()
        runtimeSessionsLock.lock()
        runtimeSessions[id] = session
        runtimeSessionsLock.unlock()
        session.dataTask(with: request) { data, response, error in
            runtimeSessionsLock.lock()
            runtimeSessions[id] = nil
            runtimeSessionsLock.unlock()
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                completion(data, (response as? HTTPURLResponse)?.statusCode, error)
            }
        }.resume()
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
        req("/configs", method: .patch, parameters: ["log-level": level.rawValue], encoding: JSONEncoding.default)
            .validate(statusCode: 200 ..< 300).responseData(completionHandler: { response in
                switch response.result {
                case .success:
                    callback?(true)
                case .failure:
                    callback?(false)
                }
            })
    }

    static func requestProxyGroupList(completeHandler: ((ClashProxyResp) -> Void)? = nil) {
        req("/proxies").responseData(queue: proxySnapshotDecodeQueue) { res in
            let statusCode = res.response?.statusCode ?? -1
            if case let .success(data) = res.result,
               (200 ..< 300).contains(statusCode),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               root["proxies"] is [String: Any] {
                let proxies = ClashProxyResp(data)
                ApiRequest.shared.proxyRespCacheData = data
                DispatchQueue.main.async {
                    completeHandler?(proxies)
                }
                return
            }

            if let cachedData = ApiRequest.shared.proxyRespCacheData {
                let cached = ClashProxyResp(cachedData)
                let now = Date()
                if now.timeIntervalSince(ApiRequest.shared.lastProxyCacheFallbackLogDate) >= 15 {
                    ApiRequest.shared.lastProxyCacheFallbackLogDate = now
                    Logger.log(
                        "Proxy API unavailable (status=\(statusCode)); " +
                            "preserving the last valid menu snapshot with " +
                            "\(cached.proxiesMap.count) entries",
                        level: .warning
                    )
                }
                DispatchQueue.main.async {
                    completeHandler?(cached)
                }
                return
            }

            Logger.log(
                "Proxy API unavailable (status=\(statusCode)) and no valid snapshot exists",
                level: .warning
            )
            DispatchQueue.main.async {
                completeHandler?(ClashProxyResp(nil))
            }
        }
    }

    static func requestProxyProviderList(completeHandler: ((ClashProviderResp) -> Void)? = nil) {
        req("/providers/proxies")
            .responseDecodable(
                of: ClashProviderResp.self,
                queue: proxySnapshotDecodeQueue,
                decoder: ClashProviderResp.decoder
            ) { resp in
                let result: ClashProviderResp
                switch resp.result {
                case let .success(providerResp):
                    result = providerResp
                case let .failure(err):
                    Logger.log("\(err)")
                    result = ClashProviderResp()
                }
                DispatchQueue.main.async {
                    completeHandler?(result)
                }
            }
    }

    static func updateAllowLan(allow: Bool, completeHandler: ((Bool) -> Void)? = nil) {
        Logger.log("update allow lan:\(allow)", level: .debug)
        req("/configs", method: .patch, parameters: ["allow-lan": allow], encoding: JSONEncoding.default)
            .validate(statusCode: 200 ..< 300).responseData { response in
                completeHandler?(response.error == nil)
            }
    }

    static func updateProxyGroup(group: String, selectProxy: String, callback: @escaping ((Bool) -> Void)) {
        req("/proxies/\(group.encoded)",
            method: .put,
            parameters: ["name": selectProxy],
            encoding: JSONEncoding.default,
            timeoutInterval: 10)
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

    static func resetProxyGroup(group: String, callback: @escaping ((Bool) -> Void)) {
        req("/proxies/\(group.encoded)", method: .delete, timeoutInterval: 10)
            .responseData { response in
                let statusCode = response.response?.statusCode ?? -1
                let success = statusCode == 204
                if success {
                    Logger.log("[Proxy Select] Restored automatic selection for group '\(group)'")
                } else {
                    let body = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<empty body>"
                    Logger.log("[Proxy Select] Failed restoring automatic selection for group '\(group)', status: \(statusCode), error: \(response.error?.localizedDescription ?? "unknown error"), body: \(body)", level: .warning)
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

    /// Fetches a fresh topology for a benchmark preflight. Both requests are
    /// bounded and owned by the benchmark session so cancellation cannot leave
    /// a disabled menu action waiting on the API session's normal timeout.
    static func getMergedProxyData(
        session: BenchmarkSession,
        timeout: TimeInterval,
        complete: @escaping (ClashProxyResp?) -> Void
    ) {
        guard !session.isCancelled else {
            complete(nil)
            return
        }

        let stateLock = NSLock()
        var didComplete = false
        var provider: ClashProviderResp?
        var proxyInfo: ClashProxyResp?

        let providerRequest = req("/providers/proxies", timeoutInterval: timeout)
        let proxyRequest = req("/proxies", timeoutInterval: timeout)
        let providerRequestID = session.track(providerRequest)
        let proxyRequestID = session.track(proxyRequest)

        func completeOnce(
            proxyInfo: ClashProxyResp? = nil,
            provider: ClashProviderResp? = nil,
            cancelPendingRequests: Bool = false
        ) {
            stateLock.lock()
            guard !didComplete else {
                stateLock.unlock()
                return
            }
            didComplete = true
            stateLock.unlock()

            if cancelPendingRequests {
                providerRequest.cancel()
                proxyRequest.cancel()
            }

            DispatchQueue.main.async {
                guard !session.isCancelled,
                      let proxyInfo,
                      let provider else {
                    complete(nil)
                    return
                }
                proxyInfo.updateProvider(provider)
                complete(proxyInfo)
            }
        }

        func publishProvider(_ value: ClashProviderResp) {
            stateLock.lock()
            guard !didComplete else {
                stateLock.unlock()
                return
            }
            provider = value
            let proxyInfo = proxyInfo
            let provider = provider
            stateLock.unlock()

            if let proxyInfo, let provider {
                completeOnce(proxyInfo: proxyInfo, provider: provider)
            }
        }

        func publishProxyInfo(_ value: ClashProxyResp) {
            stateLock.lock()
            guard !didComplete else {
                stateLock.unlock()
                return
            }
            proxyInfo = value
            let proxyInfo = proxyInfo
            let provider = provider
            stateLock.unlock()

            if let proxyInfo, let provider {
                completeOnce(proxyInfo: proxyInfo, provider: provider)
            }
        }

        session.onTermination {
            guard session.isCancelled else { return }
            completeOnce(cancelPendingRequests: true)
        }

        providerRequest
            .responseDecodable(of: ClashProviderResp.self, decoder: ClashProviderResp.decoder) { response in
                session.finish(providerRequestID)
                guard !session.isCancelled else {
                    completeOnce(cancelPendingRequests: true)
                    return
                }
                let statusCode = response.response?.statusCode ?? -1
                guard (200 ..< 300).contains(statusCode),
                      case let .success(providerResponse) = response.result else {
                    Logger.log(
                        "[Proxy Delay] Benchmark preflight providers unavailable, status: \(statusCode), error: \(response.error?.localizedDescription ?? "unknown error")",
                        level: .warning
                    )
                    completeOnce(cancelPendingRequests: true)
                    return
                }
                publishProvider(providerResponse)
            }

        proxyRequest.responseData { response in
            session.finish(proxyRequestID)
            guard !session.isCancelled else {
                completeOnce(cancelPendingRequests: true)
                return
            }
            let statusCode = response.response?.statusCode ?? -1
            guard case let .success(data) = response.result,
                  (200 ..< 300).contains(statusCode),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["proxies"] is [String: Any]
            else {
                Logger.log(
                    "[Proxy Delay] Benchmark preflight topology unavailable, status: \(statusCode), error: \(response.error?.localizedDescription ?? "unknown error")",
                    level: .warning
                )
                completeOnce(cancelPendingRequests: true)
                return
            }
            publishProxyInfo(ClashProxyResp(data))
        }
    }

    static func getProxyDelay(proxyName: String,
                              benchmarkURL: String = Settings.benchMarkUrl,
                              timeout: Int = 5000,
                              session: BenchmarkSession? = nil,
                              callback: @escaping ((Int) -> Void)) {
        getProxyDelayOutcome(proxyName: proxyName, benchmarkURL: benchmarkURL,
                             timeout: timeout, session: session) { callback($0.delay ?? 0) }
    }

    static func getProxyDelayOutcome(proxyName: String,
                                     benchmarkURL: String,
                                     timeout: Int,
                                     session: BenchmarkSession?,
                                     identity: LeafProxyBenchmarkIdentity? = nil,
                                     expectedStatus: String? = nil,
                                     callback: @escaping (ProxyDelayOutcome) -> Void) {
        requestProxyDelay(
            path: "/proxies/\(proxyName.encoded)/delay",
            nodeName: proxyName,
            providerName: nil,
            benchmarkURL: benchmarkURL,
            timeout: timeout,
            session: session,
            identity: identity,
            expectedStatus: expectedStatus,
            callback: callback
        )
    }

    static func getProviderProxyDelay(providerName: ClashProviderName,
                                      proxyName: ClashProxyName,
                                      benchmarkURL: String = Settings.benchMarkUrl,
                                      timeout: Int = 5000,
                                      session: BenchmarkSession? = nil,
                                      callback: @escaping ((Int) -> Void)) {
        getProviderProxyDelayOutcome(providerName: providerName, proxyName: proxyName,
                                     benchmarkURL: benchmarkURL, timeout: timeout,
                                     session: session) { callback($0.delay ?? 0) }
    }

    static func getProviderProxyDelayOutcome(providerName: ClashProviderName,
                                             proxyName: ClashProxyName,
                                             benchmarkURL: String,
                                             timeout: Int,
                                             session: BenchmarkSession?,
                                             identity: LeafProxyBenchmarkIdentity? = nil,
                                             expectedStatus: String? = nil,
                                             callback: @escaping (ProxyDelayOutcome) -> Void) {
        requestProxyDelay(
            path: "/providers/proxies/\(providerName.encoded)/\(proxyName.encoded)/healthcheck",
            nodeName: proxyName,
            providerName: providerName,
            benchmarkURL: benchmarkURL,
            timeout: timeout,
            session: session,
            identity: identity,
            expectedStatus: expectedStatus,
            callback: callback
        )
    }

    static func getProxyGroupDelay(groupName: ClashProxyName,
                                   benchmarkURL: String = Settings.benchMarkUrl,
                                   expectedStatus: String? = nil,
                                   timeout: Int = 5000,
                                   session: BenchmarkSession? = nil,
                                   callback: @escaping ((ProxyGroupDelayResult) -> Void)) {
        guard session?.isCancelled != true else {
            callback(.cancelled)
            return
        }
        Logger.log("[Proxy Delay] Testing group '\(groupName)' with its configured URL")
        var parameters: Parameters = ["timeout": timeout, "url": benchmarkURL]
        if let expectedStatus, !expectedStatus.isEmpty {
            parameters["expected"] = expectedStatus
        }
        let request = req(
            "/group/\(groupName.encoded)/delay",
            method: .get,
            parameters: parameters,
            timeoutInterval: BenchmarkRequestPolicy.timeoutInterval(
                coreTimeoutMilliseconds: timeout
            )
        )
        let requestID = session?.track(request)
        request
            .responseData { res in
                if let requestID {
                    session?.finish(requestID)
                }
                guard session?.isCancelled != true else {
                    callback(.cancelled)
                    return
                }
                let statusCode = res.response?.statusCode ?? -1
                let outcome = ProxyGroupDelayOutcome.decode(
                    statusCode: statusCode, data: res.data, transportFailed: res.error != nil
                )
                Logger.log("[Proxy Delay] Group '\(groupName)': \(outcome.diagnostic)")
                callback(outcome)
            }
    }

    /// Fetches one current `/proxies` topology without the normal cached-response fallback.
    static func getFreshProxyGroupList(session: BenchmarkSession,
                                       callback: @escaping (ClashProxyResp?) -> Void) {
        guard !session.isCancelled else {
            callback(nil)
            return
        }
        let request = req(
            "/proxies",
            timeoutInterval: BenchmarkRequestPolicy.timeoutInterval(
                coreTimeoutMilliseconds: 5000
            )
        )
        let requestID = session.track(request)
        request.responseData { response in
            session.finish(requestID)
            guard !session.isCancelled else {
                callback(nil)
                return
            }
            let statusCode = response.response?.statusCode ?? -1
            guard case let .success(data) = response.result,
                  (200 ..< 300).contains(statusCode),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["proxies"] is [String: Any]
            else {
                Logger.log(
                    "[Proxy Delay] Fresh proxy topology unavailable, status: \(statusCode), error: \(response.error?.localizedDescription ?? "unknown error")",
                    level: .warning
                )
                callback(nil)
                return
            }
            callback(ClashProxyResp(data))
        }
    }

    static func benchmarkLeafProxies(in response: ClashProxyResp,
                                     benchmarkURL: String,
                                     timeout: Int,
                                     maxConcurrent: Int = benchmarkMaxConcurrent,
                                     session: BenchmarkSession? = nil,
                                     result: @escaping (LeafProxyBenchmarkResult) -> Void = { _ in },
                                     completion: @escaping () -> Void) {
        guard session?.isCancelled != true else {
            completion()
            return
        }
        guard prepareBenchmarkProbeDiagnostics(using: response, session: session) else {
            completion()
            return
        }
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
                    && !ClashProxyType.isCompatibilityFallback(proxy)
                    && !builtInNames.contains(proxy.name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for proxy in inlineProxies where inlineProxyNames.insert(proxy.name).inserted {
            let identity = LeafProxyBenchmarkIdentity(
                endpoint: .inline,
                providerName: nil,
                proxyName: proxy.name,
                coreID: proxy.id
            )
            tasks.append { done in
                guard session?.isCancelled != true else {
                    done()
                    return
                }
                getProxyDelayOutcome(
                    proxyName: proxy.name,
                    benchmarkURL: benchmarkURL,
                    timeout: timeout,
                    session: session,
                    identity: identity
                ) { outcome in
                    result(LeafProxyBenchmarkResult(
                        identity: identity,
                        benchmarkURL: benchmarkURL,
                        outcome: outcome
                    ))
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
                guard !ClashProxyType.isCompatibilityFallback(proxy) else { continue }
                let key = provider.name + "\u{0}" + proxy.name
                guard providerProxyKeys.insert(key).inserted else { continue }
                let identity = LeafProxyBenchmarkIdentity(
                    endpoint: .provider,
                    providerName: provider.name,
                    proxyName: proxy.name,
                    coreID: proxy.id
                )
                tasks.append { done in
                    guard session?.isCancelled != true else {
                        done()
                        return
                    }
                    getProviderProxyDelayOutcome(
                        providerName: provider.name,
                        proxyName: proxy.name,
                        benchmarkURL: benchmarkURL,
                        timeout: timeout,
                        session: session,
                        identity: identity
                    ) { outcome in
                        result(LeafProxyBenchmarkResult(
                            identity: identity,
                            benchmarkURL: benchmarkURL,
                            outcome: outcome
                        ))
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

    static func benchmarkProxySelection(
        proxyNames: [ClashProxyName],
        providerProxies: [ProviderProxyBenchmarkTarget],
        benchmarkURL: String,
        timeout: Int,
        maxConcurrent: Int = benchmarkMaxConcurrent,
        session: BenchmarkSession,
        proxyResult: @escaping (ClashProxyName, Int) -> Void,
        completion: @escaping () -> Void
    ) {
        guard !session.isCancelled else {
            completion()
            return
        }

        typealias DelayTask = LimitedAsyncTaskRunner.Task
        var tasks = [DelayTask]()
        var uniqueProxyNames = Set<ClashProxyName>()
        var uniqueProviderProxies = Set<ProviderProxyBenchmarkTarget>()

        for proxyName in proxyNames where uniqueProxyNames.insert(proxyName).inserted {
            tasks.append { done in
                guard !session.isCancelled else {
                    done()
                    return
                }
                getProxyDelay(
                    proxyName: proxyName,
                    benchmarkURL: benchmarkURL,
                    timeout: timeout,
                    session: session
                ) { delay in
                    if !session.isCancelled {
                        proxyResult(proxyName, delay)
                    }
                    done()
                }
            }
        }

        let sortedProviderProxies = providerProxies.sorted {
            if $0.providerName == $1.providerName {
                return $0.proxyName.localizedStandardCompare($1.proxyName) == .orderedAscending
            }
            return $0.providerName.localizedStandardCompare($1.providerName) == .orderedAscending
        }
        for target in sortedProviderProxies where uniqueProviderProxies.insert(target).inserted {
            tasks.append { done in
                guard !session.isCancelled else {
                    done()
                    return
                }
                getProviderProxyDelay(
                    providerName: target.providerName,
                    proxyName: target.proxyName,
                    benchmarkURL: benchmarkURL,
                    timeout: timeout,
                    session: session
                ) { delay in
                    if !session.isCancelled {
                        proxyResult(target.proxyName, delay)
                    }
                    done()
                }
            }
        }

        Logger.log(
            "[Proxy Delay] Starting selected benchmark: " +
                "\(uniqueProxyNames.count) inline, " +
                "\(uniqueProviderProxies.count) provider proxy, " +
                "max concurrency \(max(1, maxConcurrent))"
        )
        LimitedAsyncTaskRunner(tasks: tasks, maxConcurrent: maxConcurrent)
            .start(completion: completion)
    }

    /// Progress is delivered on main and counts the plan's deduplicated targets,
    /// including successful measurements reused without another request.
    static func benchmarkSelectorPlan(
        _ plan: SelectorBenchmarkPlan,
        reusing measurements: [SelectorBenchmarkMeasurementKey: Int] = [:],
        session: BenchmarkSession,
        progress: ((BenchmarkProgressSnapshot) -> Void)? = nil,
        result: @escaping (SelectorBenchmarkPlan.Target, ProxyDelayOutcome) -> Void,
        completion: @escaping () -> Void
    ) {
        guard !session.isCancelled else {
            completion()
            return
        }

        let resultQueue = DispatchQueue(label: "com.clashfx.selectorBenchmarkResults")
        let benchmarkStartedAt = Date()
        var didLogFirstResult = false

        let runTarget: (SelectorBenchmarkPlan.Target, @escaping (ProxyDelayOutcome) -> Void) -> Void = { target, done in
            guard !session.isCancelled else {
                done(.cancelled)
                return
            }
            switch target.key.endpoint {
            case .inline:
                getProxyDelayOutcome(
                    proxyName: target.key.proxyName,
                    benchmarkURL: target.key.benchmarkURL,
                    timeout: target.key.timeout,
                    session: session,
                    identity: LeafProxyBenchmarkIdentity(
                        endpoint: target.key.endpoint,
                        providerName: target.key.providerName,
                        proxyName: target.key.proxyName,
                        coreID: target.key.coreID
                    ),
                    expectedStatus: target.key.expectedStatus,
                    callback: done
                )
            case .provider:
                guard let providerName = target.key.providerName else {
                    Logger.log(
                        "[Proxy Delay] Selector provider target '\(target.key.proxyName)' has no provider name",
                        level: .error
                    )
                    done(.unavailable)
                    return
                }
                getProviderProxyDelayOutcome(
                    providerName: providerName,
                    proxyName: target.key.proxyName,
                    benchmarkURL: target.key.benchmarkURL,
                    timeout: target.key.timeout,
                    session: session,
                    identity: LeafProxyBenchmarkIdentity(
                        endpoint: target.key.endpoint,
                        providerName: providerName,
                        proxyName: target.key.proxyName,
                        coreID: target.key.coreID
                    ),
                    expectedStatus: target.key.expectedStatus,
                    callback: done
                )
            }
        }

        SelectorBenchmarkExecutor.runOutcomes(
            plan: plan,
            reusing: measurements,
            progress: progress,
            isCancelled: { session.isCancelled },
            request: runTarget,
            result: { target, delay in
                resultQueue.sync {
                    if !didLogFirstResult {
                        didLogFirstResult = true
                        Logger.log(
                            "[Proxy Delay] Selector first result after "
                                + String(format: "%.2f", Date().timeIntervalSince(benchmarkStartedAt)) + "s"
                        )
                    }
                }
                result(target, delay)
            },
            completion: {
                guard !session.isCancelled else {
                    completion()
                    return
                }

                Logger.log(
                    "[Proxy Delay] Selector benchmark completed in "
                        + String(format: "%.2f", Date().timeIntervalSince(benchmarkStartedAt))
                        + "s"
                )
                completion()
            }
        )
    }

    static func recentBenchmarkProbeDiagnostics(limit: Int = 5) -> [BenchmarkProbeDiagnostic] {
        dispatchPrecondition(condition: .onQueue(.main))
        return BenchmarkProbeDiagnosticsStore.recent(limit: limit, scope: currentBenchmarkProbeCoreScope())
    }

    static func latestBenchmarkProbeDiagnostic(
        for proxy: ClashProxy,
        conditions: BenchmarkConditions
    ) -> BenchmarkProbeDiagnostic? {
        dispatchPrecondition(condition: .onQueue(.main))
        return BenchmarkProbeDiagnosticsStore.latest(
            for: proxy,
            conditions: conditions,
            currentScope: currentBenchmarkProbeCoreScope()
        )
    }

    static func prepareBenchmarkProbeDiagnostics(
        using snapshot: ClashProxyResp,
        session: BenchmarkSession?
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let currentScope = currentBenchmarkProbeCoreScope()
        let scope = session?.probeCoreScope ?? currentScope
        guard session?.isCancelled != true, scope == currentScope else {
            session?.cancel()
            return false
        }
        BenchmarkProbeDiagnosticsStore.prepare(using: snapshot, scope: scope)
        return true
    }

    // Request identity and probe semantics are explicit to prevent cross-node reuse.
    // swiftlint:disable:next function_parameter_count
    private static func requestProxyDelay(path: String,
                                          nodeName: String,
                                          providerName: String?,
                                          benchmarkURL: String,
                                          timeout: Int,
                                          session: BenchmarkSession?,
                                          identity: LeafProxyBenchmarkIdentity?,
                                          expectedStatus: String?,
                                          callback: @escaping (ProxyDelayOutcome) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                requestProxyDelay(path: path, nodeName: nodeName, providerName: providerName,
                                  benchmarkURL: benchmarkURL, timeout: timeout, session: session,
                                  identity: identity, expectedStatus: expectedStatus, callback: callback)
            }
            return
        }
        guard session?.isCancelled != true else {
            callback(.cancelled)
            return
        }
        let startedAt = Date()
        let currentScope = currentBenchmarkProbeCoreScope()
        let scope = session?.probeCoreScope ?? currentScope
        guard scope == currentScope else {
            session?.cancel()
            callback(.cancelled)
            return
        }
        let conditions = BenchmarkConditions(url: benchmarkURL, expectedStatus: expectedStatus)
        let token = BenchmarkProbeDiagnosticsStore.begin(
            nodeName: nodeName,
            providerName: providerName,
            identity: identity,
            conditions: conditions,
            scope: scope
        )
        let requestTimeoutInterval = BenchmarkRequestPolicy.timeoutInterval(
            coreTimeoutMilliseconds: timeout
        )
        let requestTimeoutMilliseconds = Int((requestTimeoutInterval * 1000).rounded())
        let safeURL = BenchmarkProbeDiagnostic.sanitizedURL(benchmarkURL)
        Logger.log(
            "[Proxy Delay] Probe start node='\(BenchmarkProbeDiagnostic.safeNodeLabel(nodeName))' "
                + "provider='\(BenchmarkProbeDiagnostic.safeNodeLabel(providerName ?? "inline"))' "
                + "url=\(safeURL) coreTimeout=\(timeout)ms "
                + "requestTimeout=\(requestTimeoutMilliseconds)ms"
        )
        let request = req(
            path,
            method: .get,
            parameters: ["timeout": timeout, "url": benchmarkURL],
            timeoutInterval: requestTimeoutInterval
        )
        let requestID = session?.track(request)
        request
            .responseData { res in
                if let requestID {
                    session?.finish(requestID)
                }
                guard session?.isCancelled != true else {
                    Logger.log("[Proxy Delay] Probe cancelled", level: .debug)
                    callback(.cancelled)
                    return
                }
                let completedAt = Date()
                let statusCode = res.response?.statusCode
                let outcome = ProxyDelayOutcome.decode(
                    statusCode: statusCode ?? -1,
                    data: res.data,
                    transportFailed: res.error != nil
                )
                guard let diagnostic = BenchmarkProbeDiagnostic.make(
                    nodeName: nodeName,
                    providerName: providerName,
                    benchmarkURL: benchmarkURL,
                    timeoutMilliseconds: timeout,
                    requestTimeoutMilliseconds: requestTimeoutMilliseconds,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    statusCode: statusCode,
                    outcome: outcome,
                    data: res.data,
                    transportError: res.error,
                    identity: token.identity,
                    scopeProvenance: token.scopeProvenance
                ) else {
                    callback(.cancelled)
                    return
                }

                var isCurrent = false
                if let session {
                    let wasActive = session.performIfActive {
                        let currentScope = currentBenchmarkProbeCoreScope()
                        let tokenIsCurrent = BenchmarkProbeDiagnosticsStore.isCurrent(
                            token,
                            currentScope: currentScope
                        )
                        if tokenIsCurrent {
                            _ = BenchmarkProbeDiagnosticsStore.publish(
                                diagnostic,
                                token: token,
                                currentScope: currentScope
                            )
                        }
                        isCurrent = tokenIsCurrent && BenchmarkProbeDiagnosticsStore.isCurrent(
                            token,
                            currentScope: currentBenchmarkProbeCoreScope()
                        )
                    }
                    guard wasActive else {
                        callback(.cancelled)
                        return
                    }
                    guard isCurrent else {
                        session.cancel()
                        callback(.cancelled)
                        return
                    }
                } else {
                    let currentScope = currentBenchmarkProbeCoreScope()
                    guard BenchmarkProbeDiagnosticsStore.isCurrent(token, currentScope: currentScope) else {
                        callback(.cancelled)
                        return
                    }
                    _ = BenchmarkProbeDiagnosticsStore.publish(
                        diagnostic,
                        token: token,
                        currentScope: currentScope
                    )
                    guard BenchmarkProbeDiagnosticsStore.isCurrent(
                        token,
                        currentScope: currentBenchmarkProbeCoreScope()
                    ) else {
                        callback(.cancelled)
                        return
                    }
                }

                Logger.log(diagnostic.safeLogSummary)
                callback(outcome)
            }
    }

    fileprivate static func currentBenchmarkProbeCoreScope() -> BenchmarkProbeCoreScope {
        BenchmarkProbeCoreScope(
            configName: ConfigManager.selectConfigName,
            remoteUUID: RemoteControlManager.selectConfig?.uuid,
            apiURI: ConfigManager.apiUrl,
            proxySelectionGeneration: AppDelegate.shared.proxySelectionGeneration
        )
    }

    static func getRules(completeHandler: @escaping ([ClashRule]) -> Void) {
        req("/rules").responseData { res in
            let statusCode = res.response?.statusCode ?? -1
            if case let .success(data) = res.result,
               (200 ..< 300).contains(statusCode),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               root["rules"] is [Any] {
                let rule = ClashRuleResponse.fromData(data)
                let rules = rule.rules ?? []
                ApiRequest.shared.rulesCache = rules
                completeHandler(rules)
                return
            }

            Logger.log(
                "Rules API unavailable (status=\(statusCode)); preserving the last " +
                    "valid snapshot with \(ApiRequest.shared.rulesCache.count) rules",
                level: .warning
            )
            completeHandler(ApiRequest.shared.rulesCache)
        }
    }

    static func healthCheck(
        proxy: ClashProviderName,
        requestTimeout: TimeInterval? = nil,
        session: BenchmarkSession? = nil,
        completeHandler: (() -> Void)? = nil
    ) {
        guard session?.isCancelled != true else {
            completeHandler?()
            return
        }
        Logger.log("HeathCheck for \(proxy) started")
        let request = req(
            "/providers/proxies/\(proxy.encoded)/healthcheck",
            timeoutInterval: requestTimeout
        )
        let requestID = session?.track(request)
        request.response { res in
            if let requestID {
                session?.finish(requestID)
            }
            guard session?.isCancelled != true else {
                completeHandler?()
                return
            }
            if res.response?.statusCode == 204 {
                Logger.log("HeathCheck for \(proxy) finished")
            } else {
                Logger.log("HeathCheck for \(proxy) failed:\(res.response?.statusCode ?? -1)")
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

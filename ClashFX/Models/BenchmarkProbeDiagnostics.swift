import Foundation

public enum BenchmarkProbeFailureKind: String, Equatable {
    case authentication
    case connection
    case dns
    case http
    case invalidResult
    case nodeProbe
    case quic
    case timeout
    case tls
    case transport
    case unknown
    case zeroDelay
}

public enum BenchmarkProbeFailureReason: String, Equatable {
    case authenticationFailed = "authentication_failed"
    case connectionFailed = "dial_failed"
    case controllerUnavailable = "controller_unavailable"
    case dnsResolutionFailed = "dns_resolution_failed"
    case dnsTimeout = "dns_timeout"
    case httpRequestFailed = "http_request_failed"
    case invalidResult = "invalid_result"
    case probeFailed = "probe_failed"
    case probeTimeout = "probe_timeout"
    case unspecifiedCoreFailure = "unspecified_core_failure"
    case quicHandshakeFailed = "quic_handshake_failed"
    case tlsExpired = "tls_expired"
    case tlsFailure = "tls_failure"
    case tlsNameMismatch = "tls_name_mismatch"
    case tlsUnknownAuthority = "tls_unknown_authority"
    case unexpectedResponse = "unexpected_response"
    case zeroDelay = "zero_delay"
}

struct BenchmarkProbeCoreScope: Hashable {
    let configName: String
    let remoteUUID: String?
    let apiURI: String
    let proxySelectionGeneration: UInt64
}

struct BenchmarkProbeScopeProvenance: Equatable {
    enum Identity: Equatable {
        case leaf(LeafProxyBenchmarkIdentity)
        case nodeNameOnly
    }

    let identity: Identity
    let scopeEpoch: UInt64
    let proxySelectionGeneration: UInt64
}

public struct BenchmarkProbeDiagnostic: Equatable {
    public let nodeName: String
    public let providerName: String?
    public let benchmarkURL: String
    public let timeoutMilliseconds: Int
    public let requestTimeoutMilliseconds: Int
    public let startedAt: Date
    public let completedAt: Date
    public let statusCode: Int?
    let outcome: ProxyDelayOutcome
    public let failureKind: BenchmarkProbeFailureKind?
    public let failureReason: BenchmarkProbeFailureReason?
    let identity: LeafProxyBenchmarkIdentity?
    let scopeProvenance: BenchmarkProbeScopeProvenance

    public var elapsedMilliseconds: Int {
        max(0, Int((completedAt.timeIntervalSince(startedAt) * 1000).rounded()))
    }

    public var localizedDetails: String {
        localizedReport
    }

    public var localizedFailureDescription: String? {
        switch outcome {
        case .measured, .cancelled:
            return nil
        case .failed, .timedOut, .unavailable:
            guard let failureReason else { return nil }
            let key = "benchmark_probe_failure_\(failureReason.rawValue)"
            return NSLocalizedString(key, value: Self.fallbackDescription(for: failureReason), comment: "")
        }
    }

    public var localizedReport: String {
        let result: String
        switch outcome {
        case let .measured(delay):
            result = String(
                format: NSLocalizedString("benchmark_probe_result_success", value: "Success (%d ms)", comment: ""),
                delay
            )
        case .failed:
            result = NSLocalizedString("benchmark_probe_result_failed", value: "Failed", comment: "")
        case .timedOut:
            result = NSLocalizedString("benchmark_probe_result_timed_out", value: "Timed out", comment: "")
        case .unavailable:
            result = NSLocalizedString("benchmark_probe_result_unavailable", value: "Unavailable", comment: "")
        case .cancelled:
            result = NSLocalizedString("benchmark_probe_result_cancelled", value: "Cancelled", comment: "")
        }
        let reason = localizedFailureDescription
            ?? NSLocalizedString("benchmark_probe_failure_none", value: "No failure was reported.", comment: "")

        let startDate = DateFormatter.localizedString(from: startedAt, dateStyle: .medium, timeStyle: .medium)
        let completionDate = DateFormatter.localizedString(from: completedAt, dateStyle: .medium, timeStyle: .medium)
        let identityScope: String
        switch scopeProvenance.identity {
        case .leaf(_):
            identityScope = NSLocalizedString("benchmark_probe_identity_leaf", value: "Leaf identity", comment: "")
        case .nodeNameOnly:
            identityScope = NSLocalizedString(
                "benchmark_probe_identity_name_only",
                value: "Node name only",
                comment: ""
            )
        }
        let failureKindText = failureKind?.rawValue ?? "none"
        let failureCodeText = failureReason?.rawValue ?? "none"
        let requestDeadlineLabel = NSLocalizedString(
            "benchmark_probe_detail_request_deadline",
            value: "request deadline",
            comment: ""
        )
        let timeoutDetails = "\(timeoutMilliseconds) ms ("
            + "\(requestDeadlineLabel): "
            + "\(requestTimeoutMilliseconds) ms)"
        var lines = [
            Self.detailLine("benchmark_probe_detail_node", fallback: "Node", value: nodeName),
            Self.detailLine(
                "benchmark_probe_detail_identity",
                fallback: "Identity scope",
                value: "\(identityScope) (epoch \(scopeProvenance.scopeEpoch))"
            ),
        ]
        if let providerName {
            lines.append(Self.detailLine(
                "benchmark_probe_detail_provider",
                fallback: "Provider",
                value: providerName
            ))
        }
        lines.append(contentsOf: [
            Self.detailLine("benchmark_probe_detail_url", fallback: "URL", value: benchmarkURL),
            Self.detailLine(
                "benchmark_probe_detail_timeout",
                fallback: "Timeout",
                value: timeoutDetails
            ),
            Self.detailLine("benchmark_probe_detail_started", fallback: "Started", value: startDate),
            Self.detailLine("benchmark_probe_detail_completed", fallback: "Completed", value: completionDate),
            Self.detailLine("benchmark_probe_detail_elapsed", fallback: "Elapsed", value: "\(elapsedMilliseconds) ms"),
            Self.detailLine(
                "benchmark_probe_detail_status",
                fallback: "Status",
                value: statusCode.map(String.init)
                    ?? NSLocalizedString("benchmark_probe_status_unknown", value: "Unknown", comment: "")
            ),
            Self.detailLine("benchmark_probe_detail_result", fallback: "Result", value: result),
            Self.detailLine("benchmark_probe_detail_failure_kind", fallback: "Failure kind", value: failureKindText),
            Self.detailLine("benchmark_probe_detail_failure_code", fallback: "Failure code", value: failureCodeText),
            Self.detailLine("benchmark_probe_detail_cause", fallback: "Cause", value: reason),
        ])
        return lines.joined(separator: "\n")
    }

    private static func detailLine(_ key: String, fallback: String, value: String) -> String {
        "\(NSLocalizedString(key, value: fallback, comment: "")): \(value)"
    }

    public var safeLogSummary: String {
        let status = statusCode.map(String.init) ?? "-"
        let kind = failureKind?.rawValue ?? "none"
        let code = failureReason?.rawValue ?? "none"
        return "[Proxy Delay] Probe result node='\(Self.safeNodeLabel(nodeName))' provider='\(Self.safeNodeLabel(providerName ?? "inline"))' "
            + "url=\(benchmarkURL) timeout=\(timeoutMilliseconds)ms "
            + "requestTimeout=\(requestTimeoutMilliseconds)ms "
            + "elapsed=\(elapsedMilliseconds)ms status=\(status) outcome=\(Self.outcomeSummary(outcome)) "
            + "kind=\(kind) code=\(code)"
    }

    static func safeNodeLabel(_ value: String) -> String {
        let display: String
        if let components = URLComponents(string: value), components.scheme != nil, components.host != nil {
            display = sanitizedURL(value)
        } else { display = value }
        let scalars = display.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars)).prefix(200)
            .replacingOccurrences(of: "'", with: "\\'")
    }

    public static func sanitizedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              components.scheme != nil,
              components.host != nil else {
            return NSLocalizedString("benchmark_probe_invalid_url", value: "Invalid URL", comment: "")
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? NSLocalizedString("benchmark_probe_invalid_url", value: "Invalid URL", comment: "")
    }

    // Keep the captured request and response provenance explicit at this boundary.
    // swiftlint:disable:next function_parameter_count
    static func make(
        nodeName: String,
        providerName: String?,
        benchmarkURL: String,
        timeoutMilliseconds: Int,
        requestTimeoutMilliseconds: Int? = nil,
        startedAt: Date,
        completedAt: Date,
        statusCode: Int?,
        outcome: ProxyDelayOutcome,
        data: Data?,
        transportError: Error?,
        identity: LeafProxyBenchmarkIdentity?,
        scopeProvenance: BenchmarkProbeScopeProvenance
    ) -> BenchmarkProbeDiagnostic? {
        guard outcome != .cancelled else { return nil }
        let failure = classifyFailure(
            statusCode: statusCode,
            data: data,
            transportError: transportError,
            outcome: outcome
        )
        return BenchmarkProbeDiagnostic(
            nodeName: nodeName,
            providerName: providerName,
            benchmarkURL: sanitizedURL(benchmarkURL),
            timeoutMilliseconds: timeoutMilliseconds,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds ?? timeoutMilliseconds,
            startedAt: startedAt,
            completedAt: completedAt,
            statusCode: statusCode,
            outcome: outcome,
            failureKind: failure?.kind,
            failureReason: failure?.reason,
            identity: identity,
            scopeProvenance: scopeProvenance
        )
    }

    private static func classifyFailure(
        statusCode: Int?,
        data: Data?,
        transportError: Error?,
        outcome: ProxyDelayOutcome
    ) -> (kind: BenchmarkProbeFailureKind, reason: BenchmarkProbeFailureReason)? {
        if case .measured = outcome { return nil }

        if transportError != nil {
            return (.transport, .controllerUnavailable)
        }

        switch outcome {
        case .measured:
            return nil
        case .failed:
            if statusCode == 200 {
                return (.zeroDelay, .zeroDelay)
            }
            if statusCode == 503,
               let knownFailure = knownCoreFailure(in: data, statusCode: statusCode, outcome: outcome) {
                return knownFailure
            }
            if statusCode == 503 {
                return (.nodeProbe, .unspecifiedCoreFailure)
            }
            return (.unknown, .unexpectedResponse)
        case .timedOut:
            if statusCode == 504,
               let knownFailure = knownCoreFailure(in: data, statusCode: statusCode, outcome: outcome) {
                return knownFailure
            }
            return (.timeout, .probeTimeout)
        case .unavailable:
            if statusCode == 200 {
                return (.invalidResult, .invalidResult)
            }
            return (.unknown, .unexpectedResponse)
        case .cancelled:
            return nil
        }
    }

    private static func knownCoreFailure(
        in data: Data?,
        statusCode: Int?,
        outcome: ProxyDelayOutcome
    ) -> (kind: BenchmarkProbeFailureKind, reason: BenchmarkProbeFailureReason)? {
        guard (statusCode == 503 && outcome == .failed) || (statusCode == 504 && outcome == .timedOut),
              let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = root["clashfx_probe_error"] as? [String: Any],
              let code = details["code"] as? String else {
            return nil
        }
        guard (code == "probe_timeout" && statusCode == 504 && outcome == .timedOut)
            || (code != "probe_timeout" && statusCode == 503 && outcome == .failed) else {
            return nil
        }

        switch code {
        case "dns_resolution_failed": return (.dns, .dnsResolutionFailed)
        case "dns_timeout": return (.dns, .dnsTimeout)
        case "tls_unknown_authority": return (.tls, .tlsUnknownAuthority)
        case "tls_expired": return (.tls, .tlsExpired)
        case "tls_name_mismatch": return (.tls, .tlsNameMismatch)
        case "tls_failure": return (.tls, .tlsFailure)
        case "authentication_failed": return (.authentication, .authenticationFailed)
        case "quic_handshake_failed": return (.quic, .quicHandshakeFailed)
        case "dial_failed": return (.connection, .connectionFailed)
        case "http_request_failed": return (.http, .httpRequestFailed)
        case "probe_timeout": return (.timeout, .probeTimeout)
        case "zero_delay": return (.zeroDelay, .zeroDelay)
        case "probe_failed": return (.nodeProbe, .probeFailed)
        default: return nil
        }
    }

    private static func outcomeSummary(_ outcome: ProxyDelayOutcome) -> String {
        switch outcome {
        case let .measured(delay): return "measured_\(delay)ms"
        case .failed: return "failed"
        case .timedOut: return "timed_out"
        case .unavailable: return "unavailable"
        case .cancelled: return "cancelled"
        }
    }

    private static func fallbackDescription(for reason: BenchmarkProbeFailureReason) -> String {
        switch reason {
        case .authenticationFailed: return "The proxy rejected authentication."
        case .connectionFailed: return "The proxy could not be reached."
        case .controllerUnavailable: return "The network or controller could not confirm the probe result."
        case .dnsResolutionFailed: return "The proxy could not resolve the destination name."
        case .dnsTimeout: return "Name resolution timed out."
        case .httpRequestFailed: return "The destination rejected the probe request."
        case .invalidResult: return "The controller returned an invalid probe result."
        case .unspecifiedCoreFailure: return "The core probe failed, but no specific reason was provided."
        case .probeFailed: return "The proxy probe failed."
        case .probeTimeout: return "The proxy probe timed out."
        case .quicHandshakeFailed: return "The QUIC connection could not be established."
        case .tlsExpired: return "The destination certificate has expired."
        case .tlsFailure: return "The secure connection failed."
        case .tlsNameMismatch: return "The destination certificate name did not match."
        case .tlsUnknownAuthority: return "The destination certificate is not trusted."
        case .unexpectedResponse: return "The controller could not confirm the probe result."
        case .zeroDelay: return "The proxy returned a zero delay."
        }
    }
}

enum BenchmarkProbeDiagnosticsStore {
    static let maximumCount = 256

    static func recent(limit: Int, scope: BenchmarkProbeCoreScope) -> [BenchmarkProbeDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0, activeScope == scope else { return [] }
        return diagnostics.values.map(\.diagnostic)
            .sorted { $0.completedAt > $1.completedAt }
            .prefix(min(limit, maximumCount)).map { $0 }
    }

    static func prepare(using snapshot: ClashProxyResp, scope: BenchmarkProbeCoreScope) {
        let currentIdentities = Set(snapshot.proxiesMap.values.compactMap { proxy -> LeafProxyBenchmarkIdentity? in
            guard proxy.all == nil, !ClashProxyType.isCompatibilityFallback(proxy) else { return nil }
            return LeafProxyBenchmarkIdentity(proxy: proxy)
        })

        lock.lock()
        defer { lock.unlock() }
        if activeScope != scope {
            activeScope = scope
            scopeEpoch &+= 1
            diagnostics.removeAll()
            insertionOrder.removeAll()
        }
        activeIdentities = currentIdentities
        diagnostics = diagnostics.filter { key, _ in
            guard key.epoch == scopeEpoch,
                  case let .leaf(identity) = key.identity else {
                return false
            }
            return currentIdentities.contains(identity)
        }
        insertionOrder.removeAll { diagnostics[$0] == nil }
    }

    struct Token {
        fileprivate let scope: BenchmarkProbeCoreScope
        fileprivate let epoch: UInt64
        fileprivate let ordinal: UInt64
        let identity: LeafProxyBenchmarkIdentity?
        let nodeName: String
        let providerName: String?
        let conditions: BenchmarkConditions

        var scopeProvenance: BenchmarkProbeScopeProvenance {
            BenchmarkProbeScopeProvenance(
                identity: identity.map(BenchmarkProbeScopeProvenance.Identity.leaf) ?? .nodeNameOnly,
                scopeEpoch: epoch,
                proxySelectionGeneration: scope.proxySelectionGeneration
            )
        }
    }

    private enum IdentityKey: Hashable {
        case leaf(LeafProxyBenchmarkIdentity)
        case nodeNameOnly(String, providerName: String?)
    }

    private struct Key: Hashable {
        let identity: IdentityKey
        let conditions: BenchmarkConditions
        let scope: BenchmarkProbeCoreScope
        let epoch: UInt64
    }

    private struct Entry {
        let diagnostic: BenchmarkProbeDiagnostic
        let ordinal: UInt64
    }

    private static let lock = NSLock()
    private static var diagnostics = [Key: Entry]()
    private static var insertionOrder = [Key]()
    private static var activeScope: BenchmarkProbeCoreScope?
    private static var activeIdentities: Set<LeafProxyBenchmarkIdentity>?
    private static var scopeEpoch: UInt64 = 0
    private static var requestOrdinal: UInt64 = 0

    static func begin(
        nodeName: String,
        providerName: String?,
        identity: LeafProxyBenchmarkIdentity?,
        conditions: BenchmarkConditions,
        scope: BenchmarkProbeCoreScope
    ) -> Token {
        lock.lock()
        defer { lock.unlock() }

        if activeScope != scope {
            activeScope = scope
            scopeEpoch &+= 1
            diagnostics.removeAll()
            insertionOrder.removeAll()
            activeIdentities = nil
        }
        requestOrdinal &+= 1

        let acceptedIdentity: LeafProxyBenchmarkIdentity? = {
            guard let identity,
                  identity.proxyName == nodeName,
                  identity.providerName == providerName,
                  (identity.endpoint == .provider) == (providerName != nil) else {
                return nil
            }
            return identity
        }()

        return Token(
            scope: scope,
            epoch: scopeEpoch,
            ordinal: requestOrdinal,
            identity: acceptedIdentity,
            nodeName: nodeName,
            providerName: providerName,
            conditions: conditions
        )
    }

    @discardableResult
    static func publish(
        _ diagnostic: BenchmarkProbeDiagnostic,
        token: Token,
        currentScope: BenchmarkProbeCoreScope,
        isCancelled: Bool = false
    ) -> Bool {
        guard !isCancelled,
              diagnostic.outcome != .cancelled,
              diagnostic.nodeName == token.nodeName,
              diagnostic.providerName == token.providerName,
              diagnostic.identity == token.identity,
              diagnostic.scopeProvenance == token.scopeProvenance else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        guard activeScope == token.scope,
              currentScope == token.scope,
              scopeEpoch == token.epoch,
              token.identity.map({ activeIdentities?.contains($0) ?? true }) ?? (activeIdentities == nil) else {
            return false
        }

        let key = key(for: token)
        if let existing = diagnostics[key], existing.ordinal > token.ordinal {
            return false
        }
        diagnostics[key] = Entry(diagnostic: diagnostic, ordinal: token.ordinal)
        insertionOrder.removeAll { $0 == key }
        insertionOrder.append(key)

        while diagnostics.count > maximumCount, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            diagnostics[oldest] = nil
        }
        return true
    }

    static func isCurrent(
        _ token: Token,
        currentScope: BenchmarkProbeCoreScope,
        isCancelled: Bool = false
    ) -> Bool {
        guard !isCancelled else { return false }
        lock.lock()
        defer { lock.unlock() }
        return activeScope == token.scope
            && currentScope == token.scope
            && scopeEpoch == token.epoch
    }

    static func latest(
        for proxy: ClashProxy,
        conditions: BenchmarkConditions,
        currentScope: BenchmarkProbeCoreScope
    ) -> BenchmarkProbeDiagnostic? {
        guard proxy.all == nil, !ClashProxyType.isCompatibilityFallback(proxy) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard activeScope == currentScope else { return nil }
        let lookup = Key(
            identity: .leaf(LeafProxyBenchmarkIdentity(proxy: proxy)),
            conditions: conditions,
            scope: currentScope,
            epoch: scopeEpoch
        )
        return diagnostics[lookup]?.diagnostic
    }

    static func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        scopeEpoch &+= 1
        activeScope = nil
        activeIdentities = nil
        diagnostics.removeAll()
        insertionOrder.removeAll()
    }

    static func prune(using snapshot: ClashProxyResp) {
        let currentIdentities = Set(snapshot.proxiesMap.values.compactMap { proxy -> LeafProxyBenchmarkIdentity? in
            guard proxy.all == nil, !ClashProxyType.isCompatibilityFallback(proxy) else { return nil }
            return LeafProxyBenchmarkIdentity(proxy: proxy)
        })

        lock.lock()
        defer { lock.unlock() }
        activeIdentities = currentIdentities
        diagnostics = diagnostics.filter { key, _ in
            guard key.epoch == scopeEpoch,
                  case let .leaf(identity) = key.identity else {
                return false
            }
            return currentIdentities.contains(identity)
        }
        insertionOrder.removeAll { diagnostics[$0] == nil }
    }

    private static func key(for token: Token) -> Key {
        let identity: IdentityKey = token.identity.map(IdentityKey.leaf)
            ?? .nodeNameOnly(token.nodeName, providerName: token.providerName)
        return Key(identity: identity, conditions: token.conditions, scope: token.scope, epoch: token.epoch)
    }
}

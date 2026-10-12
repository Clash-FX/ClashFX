import Foundation
import XCTest

final class BenchmarkProbeDiagnosticsTests: XCTestCase {
    private let scope = BenchmarkProbeCoreScope(
        configName: "profile-a",
        remoteUUID: "remote-a",
        apiURI: "http://127.0.0.1:9090",
        proxySelectionGeneration: 7
    )

    override func setUp() {
        super.setUp()
        BenchmarkProbeDiagnosticsStore.clearAll()
    }

    override func tearDown() {
        BenchmarkProbeDiagnosticsStore.clearAll()
        super.tearDown()
    }

    func testKnownCoreFailureIsClassifiedAndSecretURLPartsAreRemoved() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let conditions = BenchmarkConditions(
            url: "https://user:password@example.test/probe?token=query-secret#private-fragment"
        )
        let token = begin(proxy, conditions: conditions)
        let body = Data(
            #"""
            {"message":"raw error must stay hidden","clashfx_probe_error":{"kind":"tls","code":"tls_unknown_authority"}}
            """#.utf8
        )

        let diagnostic = try XCTUnwrap(makeDiagnostic(
            token,
            outcome: .failed,
            statusCode: 503,
            data: body
        ))

        XCTAssertEqual(diagnostic.benchmarkURL, "https://example.test/probe")
        XCTAssertEqual(diagnostic.failureKind, .tls)
        XCTAssertEqual(diagnostic.failureReason, .tlsUnknownAuthority)
        XCTAssertEqual(diagnostic.localizedFailureDescription, "The destination certificate is not trusted.")
        XCTAssertTrue(diagnostic.localizedDetails.contains("URL: https://example.test/probe"))
        XCTAssertTrue(diagnostic.localizedDetails.contains("Timeout: 5000 ms"))
        XCTAssertTrue(diagnostic.localizedDetails.contains("Status: 503"))
        XCTAssertTrue(diagnostic.localizedReport.contains("Node: Tokyo"))
        XCTAssertTrue(diagnostic.localizedReport.contains("request deadline: 7000 ms"))
        XCTAssertTrue(diagnostic.localizedReport.contains("Started:"))
        XCTAssertTrue(diagnostic.localizedReport.contains("Completed:"))
        XCTAssertTrue(diagnostic.localizedReport.contains("Result:"))
        XCTAssertTrue(diagnostic.localizedReport.contains("Cause:"))
        XCTAssertFalse(diagnostic.localizedDetails.contains("password"))
        XCTAssertFalse(diagnostic.localizedDetails.contains("query-secret"))
        XCTAssertFalse(diagnostic.localizedDetails.contains("private-fragment"))
        XCTAssertFalse(diagnostic.safeLogSummary.contains("raw error"))
        XCTAssertFalse(diagnostic.safeLogSummary.contains("query-secret"))
    }

    func testSanitizedURLDropsCredentialsQueryAndFragment() {
        XCTAssertEqual(
            BenchmarkProbeDiagnostic.sanitizedURL(
                "https://name:secret@example.test/path?q=secret#fragment"
            ),
            "https://example.test/path"
        )
        XCTAssertEqual(BenchmarkProbeDiagnostic.sanitizedURL("not a URL with password"), "Invalid URL")
    }

    func testGeneric503FailureDoesNotInventAReasonFromUnknownMessageOrCode() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let token = begin(proxy, conditions: BenchmarkConditions(url: "https://example.test/probe"))
        let body = Data(
            #"""
            {
              "message": "An error occurred in the delay test",
              "clashfx_probe_error": {
                "kind": "mystery",
                "code": "unknown_secret_code"
              }
            }
            """#.utf8
        )
        let outcome = ProxyDelayOutcome.decode(statusCode: 503, data: body, transportFailed: false)
        let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: outcome, statusCode: 503, data: body))

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(diagnostic.failureKind, .nodeProbe)
        XCTAssertEqual(diagnostic.failureReason, .unspecifiedCoreFailure)
        XCTAssertTrue(diagnostic.localizedReport.contains(
            "Cause: The core probe failed, but no specific reason was provided."
        ))
        XCTAssertFalse(diagnostic.localizedDetails.contains("specific secret"))
        XCTAssertFalse(diagnostic.safeLogSummary.contains("unknown_secret_code"))
    }

    func testCore504TimeoutIsTimedOutWithControlledReason() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let token = begin(proxy, conditions: BenchmarkConditions(url: "https://example.test/probe"))
        let body = Data(
            #"{"message":"Timeout","clashfx_probe_error":{"kind":"timeout","code":"probe_timeout"}}"#.utf8
        )
        let outcome = ProxyDelayOutcome.decode(statusCode: 504, data: body, transportFailed: false)
        let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: outcome, statusCode: 504, data: body))

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(diagnostic.failureKind, .timeout)
        XCTAssertEqual(diagnostic.failureReason, .probeTimeout)
    }

    func testLegacyCoreFailureMessagesRemainRecognizedWithoutTypedEnvelope() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let cases: [(Int, String, ProxyDelayOutcome, BenchmarkProbeFailureKind, BenchmarkProbeFailureReason)] = [
            (503, #"{"message":"An error occurred in the delay test"}"#,
             .failed, .nodeProbe, .unspecifiedCoreFailure),
            (504, #"{"message":"Timeout"}"#,
             .timedOut, .timeout, .probeTimeout),
        ]

        for (status, body, expectedOutcome, expectedKind, expectedReason) in cases {
            let token = begin(proxy, conditions: conditions)
            let data = Data(body.utf8)
            let outcome = ProxyDelayOutcome.decode(statusCode: status, data: data, transportFailed: false)
            let diagnostic = try XCTUnwrap(makeDiagnostic(
                token,
                outcome: outcome,
                statusCode: status,
                data: data
            ))

            XCTAssertEqual(outcome, expectedOutcome)
            XCTAssertEqual(diagnostic.failureKind, expectedKind)
            XCTAssertEqual(diagnostic.failureReason, expectedReason)
        }
    }

    func testTypedFailureCodeMustMatchItsHTTPStatus() {
        let timeoutOnFailureStatus = Data(
            #"{"message":"An error occurred in the delay test","clashfx_probe_error":{"kind":"timeout","code":"probe_timeout"}}"#.utf8
        )
        let nodeFailureOnTimeoutStatus = Data(
            #"{"message":"Timeout","clashfx_probe_error":{"kind":"tls","code":"tls_unknown_authority"}}"#.utf8
        )

        XCTAssertEqual(
            ProxyDelayOutcome.decode(statusCode: 503, data: timeoutOnFailureStatus, transportFailed: false),
            .unavailable
        )
        XCTAssertEqual(
            ProxyDelayOutcome.decode(statusCode: 504, data: nodeFailureOnTimeoutStatus, transportFailed: false),
            .unavailable
        )

        let typedTimeoutWithChangedLegacyText = Data(
            #"{"message":"redacted","clashfx_probe_error":{"kind":"timeout","code":"probe_timeout"}}"#.utf8
        )
        XCTAssertEqual(
            ProxyDelayOutcome.decode(statusCode: 504, data: typedTimeoutWithChangedLegacyText, transportFailed: false),
            .timedOut
        )
    }

    func testKnownCoreCodesMapOnlyToControlledKindAndReasonValues() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let cases: [(String, Int, ProxyDelayOutcome, BenchmarkProbeFailureKind, BenchmarkProbeFailureReason)] = [
            ("dns_resolution_failed", 503, .failed, .dns, .dnsResolutionFailed),
            ("dns_timeout", 503, .failed, .dns, .dnsTimeout),
            ("tls_unknown_authority", 503, .failed, .tls, .tlsUnknownAuthority),
            ("tls_expired", 503, .failed, .tls, .tlsExpired),
            ("tls_name_mismatch", 503, .failed, .tls, .tlsNameMismatch),
            ("tls_failure", 503, .failed, .tls, .tlsFailure),
            ("authentication_failed", 503, .failed, .authentication, .authenticationFailed),
            ("quic_handshake_failed", 503, .failed, .quic, .quicHandshakeFailed),
            ("dial_failed", 503, .failed, .connection, .connectionFailed),
            ("http_request_failed", 503, .failed, .http, .httpRequestFailed),
            ("probe_timeout", 504, .timedOut, .timeout, .probeTimeout),
            ("zero_delay", 503, .failed, .zeroDelay, .zeroDelay),
            ("probe_failed", 503, .failed, .nodeProbe, .probeFailed),
        ]

        for (code, status, outcome, expectedKind, expectedReason) in cases {
            let token = begin(proxy, conditions: conditions)
            let body = Data(
                "{\"clashfx_probe_error\":{\"kind\":\"ignored\",\"code\":\"\(code)\"}}".utf8
            )
            let diagnostic = try XCTUnwrap(makeDiagnostic(
                token,
                outcome: outcome,
                statusCode: status,
                data: body
            ))

            XCTAssertEqual(diagnostic.failureKind, expectedKind, "Unexpected kind for \(code)")
            XCTAssertEqual(diagnostic.failureReason, expectedReason, "Unexpected reason for \(code)")
        }
    }

    func testMalformedSuccessfulHTTPResponseIsClassifiedAsInvalidResult() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let token = begin(proxy, conditions: BenchmarkConditions(url: "https://example.test/probe"))
        let body = Data(#"{"delay":"fast"}"#.utf8)
        let outcome = ProxyDelayOutcome.decode(statusCode: 200, data: body, transportFailed: false)
        let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: outcome, statusCode: 200, data: body))

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(diagnostic.failureKind, .invalidResult)
        XCTAssertEqual(diagnostic.failureReason, .invalidResult)
    }

    func testControllerTransportFailureRemainsUnavailableAndDoesNotCallNodeFailed() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let token = begin(proxy, conditions: BenchmarkConditions(url: "https://example.test/probe"))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let partialBody = Data(
            #"{"clashfx_probe_error":{"kind":"authentication","code":"authentication_failed"}}"#.utf8
        )
        let outcome = ProxyDelayOutcome.decode(statusCode: nil, data: nil, transportFailed: true)
        let diagnostic = try XCTUnwrap(makeDiagnostic(
            token,
            outcome: outcome,
            statusCode: nil,
            data: partialBody,
            transportError: error
        ))

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(diagnostic.failureKind, .transport)
        XCTAssertEqual(diagnostic.failureReason, .controllerUnavailable)
        XCTAssertNotEqual(diagnostic.outcome, .failed)
    }

    func testZeroDelayDoesNotTrustAnUnrelatedErrorEnvelope() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let token = begin(proxy, conditions: BenchmarkConditions(url: "https://example.test/probe"))
        let body = Data(
            #"{"delay":0,"clashfx_probe_error":{"kind":"tls","code":"tls_unknown_authority"}}"#.utf8
        )
        let outcome = ProxyDelayOutcome.decode(statusCode: 200, data: body, transportFailed: false)
        let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: outcome, statusCode: 200, data: body))

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(diagnostic.failureKind, .zeroDelay)
        XCTAssertEqual(diagnostic.failureReason, .zeroDelay)
    }

    func testIdentityAndConditionsPreventSameNameAndURLStatusCrossTalk() throws {
        let first = try makeProxy(name: "Tokyo", id: "node-1")
        let second = try makeProxy(name: "Tokyo", id: "node-2")
        let conditions = BenchmarkConditions(url: "https://example.test/probe", expectedStatus: "204")
        let token = begin(first, conditions: conditions)
        let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: .failed, statusCode: 503))
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(diagnostic, token: token, currentScope: scope))

        XCTAssertEqual(latest(for: first, conditions: conditions), diagnostic)
        XCTAssertNil(latest(for: second, conditions: conditions))
        XCTAssertNil(latest(
            for: first,
            conditions: BenchmarkConditions(url: conditions.url, expectedStatus: "200")
        ))
        XCTAssertNil(latest(
            for: first,
            conditions: BenchmarkConditions(url: "https://other.test/probe", expectedStatus: "204")
        ))
    }

    func testUnknownIdentityHasExplicitProvenanceAndCannotMatchKnownNode() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let token = BenchmarkProbeDiagnosticsStore.begin(
            nodeName: proxy.name,
            providerName: nil,
            identity: nil,
            conditions: conditions,
            scope: scope
        )
        let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: .failed, statusCode: 503))

        XCTAssertEqual(diagnostic.scopeProvenance.identity, .nodeNameOnly)
        XCTAssertNil(diagnostic.identity)
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(diagnostic, token: token, currentScope: scope))
        XCTAssertNil(latest(for: proxy, conditions: conditions))
    }

    func testMissingIdentityAfterPruneRejectsOnlyTheDiagnosticRecord() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let token = BenchmarkProbeDiagnosticsStore.begin(
            nodeName: proxy.name,
            providerName: nil,
            identity: nil,
            conditions: conditions,
            scope: scope
        )
        let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: .measured(42), statusCode: 200))
        BenchmarkProbeDiagnosticsStore.prune(using: try makeSnapshot([(proxy.name, proxy.id ?? "")]))

        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.isCurrent(token, currentScope: scope))
        XCTAssertFalse(BenchmarkProbeDiagnosticsStore.publish(diagnostic, token: token, currentScope: scope))
        XCTAssertEqual(diagnostic.outcome, .measured(42))
    }

    func testKnownIdentitySurvivesPruneAndCanRetrieveItsDiagnostic() throws {
        let snapshot = try makeSnapshot([("Tokyo", "node-1")])
        let proxy = try XCTUnwrap(snapshot.proxiesMap["Tokyo"])
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let identity = LeafProxyBenchmarkIdentity(
            endpoint: .inline,
            providerName: nil,
            proxyName: proxy.name,
            coreID: proxy.id
        )
        BenchmarkProbeDiagnosticsStore.prepare(using: snapshot, scope: scope)
        let token = begin(proxy, conditions: conditions, identity: identity)
        let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: .failed, statusCode: 503))

        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(diagnostic, token: token, currentScope: scope))
        XCTAssertEqual(latest(for: proxy, conditions: conditions), diagnostic)
    }

    func testCancelledAndLateScopeResultsAreNotPublished() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let cancelledToken = begin(proxy, conditions: conditions)
        let cancelledDiagnostic = try XCTUnwrap(makeDiagnostic(cancelledToken, outcome: .failed, statusCode: 503))
        XCTAssertFalse(BenchmarkProbeDiagnosticsStore.isCurrent(
            cancelledToken,
            currentScope: scope,
            isCancelled: true
        ))
        XCTAssertFalse(BenchmarkProbeDiagnosticsStore.publish(
            cancelledDiagnostic,
            token: cancelledToken,
            currentScope: scope,
            isCancelled: true
        ))
        XCTAssertNil(latest(for: proxy, conditions: conditions))

        let lateToken = begin(proxy, conditions: conditions)
        let lateDiagnostic = try XCTUnwrap(makeDiagnostic(lateToken, outcome: .failed, statusCode: 503))
        BenchmarkProbeDiagnosticsStore.clearAll()
        XCTAssertFalse(BenchmarkProbeDiagnosticsStore.isCurrent(lateToken, currentScope: scope))
        XCTAssertFalse(BenchmarkProbeDiagnosticsStore.publish(lateDiagnostic, token: lateToken, currentScope: scope))
        XCTAssertNil(latest(for: proxy, conditions: conditions))
    }

    func testNewCoreScopeInvalidatesAnOlderInFlightToken() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let oldToken = begin(proxy, conditions: conditions)
        let diagnostic = try XCTUnwrap(makeDiagnostic(oldToken, outcome: .failed, statusCode: 503))
        let newScope = BenchmarkProbeCoreScope(
            configName: "profile-b",
            remoteUUID: "remote-b",
            apiURI: "http://127.0.0.1:9091",
            proxySelectionGeneration: 8
        )
        _ = BenchmarkProbeDiagnosticsStore.begin(
            nodeName: proxy.name,
            providerName: nil,
            identity: LeafProxyBenchmarkIdentity(proxy: proxy),
            conditions: conditions,
            scope: newScope
        )

        XCTAssertFalse(BenchmarkProbeDiagnosticsStore.publish(diagnostic, token: oldToken, currentScope: scope))
        XCTAssertNil(latest(for: proxy, conditions: conditions))
    }

    func testPruneKeepsOnlyIdentitiesPresentInCurrentCoreSnapshot() throws {
        let retained = try makeProxy(name: "Tokyo", id: "node-1")
        let removed = try makeProxy(name: "Osaka", id: "node-2")
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let retainedToken = begin(retained, conditions: conditions)
        let removedToken = begin(removed, conditions: conditions)
        let lateToken = begin(removed, conditions: conditions)
        let retainedDiagnostic = try XCTUnwrap(makeDiagnostic(retainedToken, outcome: .failed, statusCode: 503))
        let removedDiagnostic = try XCTUnwrap(makeDiagnostic(removedToken, outcome: .failed, statusCode: 503))
        let lateDiagnostic = try XCTUnwrap(makeDiagnostic(lateToken, outcome: .failed, statusCode: 503))
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(
            retainedDiagnostic,
            token: retainedToken,
            currentScope: scope
        ))
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(
            removedDiagnostic,
            token: removedToken,
            currentScope: scope
        ))

        let snapshot = try makeSnapshot([(retained.name, retained.id ?? "")])
        BenchmarkProbeDiagnosticsStore.prune(using: snapshot)

        XCTAssertNotNil(latest(for: retained, conditions: conditions))
        XCTAssertNil(latest(for: removed, conditions: conditions))
        XCTAssertFalse(BenchmarkProbeDiagnosticsStore.publish(lateDiagnostic, token: lateToken, currentScope: scope))
    }

    func testStoreIsBoundedAndNewerSuccessReplacesPreviousFailure() throws {
        var proxies = [ClashProxy]()
        for index in 0 ..< BenchmarkProbeDiagnosticsStore.maximumCount + 1 {
            proxies.append(try makeProxy(name: "Node-\(index)", id: "id-\(index)"))
        }
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let first = proxies[0]
        let newest = proxies[proxies.count - 1]

        let failedToken = begin(newest, conditions: conditions)
        let failure = try XCTUnwrap(makeDiagnostic(failedToken, outcome: .failed, statusCode: 503))
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(failure, token: failedToken, currentScope: scope))
        let successToken = begin(newest, conditions: conditions)
        let success = try XCTUnwrap(makeDiagnostic(successToken, outcome: .measured(24), statusCode: 200))
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(success, token: successToken, currentScope: scope))

        for proxy in proxies.dropFirst().dropLast() {
            let token = begin(proxy, conditions: conditions)
            let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: .failed, statusCode: 503))
            XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(diagnostic, token: token, currentScope: scope))
        }

        let firstToken = begin(first, conditions: conditions)
        let firstDiagnostic = try XCTUnwrap(makeDiagnostic(firstToken, outcome: .failed, statusCode: 503))
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(firstDiagnostic, token: firstToken, currentScope: scope))

        XCTAssertNil(latest(for: newest, conditions: conditions))
        XCTAssertEqual(latest(for: first, conditions: conditions), firstDiagnostic)
        XCTAssertNil(latest(for: newest, conditions: conditions))
    }

    func testSuccessClearsFailureForSameIdentityAndConditions() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let failureToken = begin(proxy, conditions: conditions)
        let failure = try XCTUnwrap(makeDiagnostic(failureToken, outcome: .failed, statusCode: 503))
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(failure, token: failureToken, currentScope: scope))

        let successToken = begin(proxy, conditions: conditions)
        let success = try XCTUnwrap(makeDiagnostic(successToken, outcome: .measured(31), statusCode: 200))
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(success, token: successToken, currentScope: scope))

        let latestDiagnostic = latest(for: proxy, conditions: conditions)
        XCTAssertEqual(latestDiagnostic?.outcome, .measured(31))
        XCTAssertNil(latestDiagnostic?.failureKind)
        XCTAssertNil(latestDiagnostic?.failureReason)
        XCTAssertNil(latestDiagnostic?.localizedFailureDescription)
    }

    func testLatestLookupRejectsDiagnosticsFromAnOlderCoreScope() throws {
        let proxy = try makeProxy(name: "Tokyo", id: "node-1")
        let conditions = BenchmarkConditions(url: "https://example.test/probe")
        let token = begin(proxy, conditions: conditions)
        let diagnostic = try XCTUnwrap(makeDiagnostic(token, outcome: .failed, statusCode: 503))
        XCTAssertTrue(BenchmarkProbeDiagnosticsStore.publish(diagnostic, token: token, currentScope: scope))
        let nextScope = BenchmarkProbeCoreScope(
            configName: "profile-b",
            remoteUUID: "remote-b",
            apiURI: "http://127.0.0.1:9091",
            proxySelectionGeneration: 8
        )

        XCTAssertEqual(latest(for: proxy, conditions: conditions), diagnostic)
        XCTAssertNil(latest(for: proxy, conditions: conditions, scope: nextScope))
    }

    private func begin(
        _ proxy: ClashProxy,
        conditions: BenchmarkConditions,
        identity: LeafProxyBenchmarkIdentity? = nil
    ) -> BenchmarkProbeDiagnosticsStore.Token {
        BenchmarkProbeDiagnosticsStore.begin(
            nodeName: proxy.name,
            providerName: proxy.enclosingProvider?.name,
            identity: identity ?? LeafProxyBenchmarkIdentity(proxy: proxy),
            conditions: conditions,
            scope: scope
        )
    }

    private func latest(
        for proxy: ClashProxy,
        conditions: BenchmarkConditions,
        scope: BenchmarkProbeCoreScope? = nil
    ) -> BenchmarkProbeDiagnostic? {
        BenchmarkProbeDiagnosticsStore.latest(
            for: proxy,
            conditions: conditions,
            currentScope: scope ?? self.scope
        )
    }

    private func makeDiagnostic(
        _ token: BenchmarkProbeDiagnosticsStore.Token,
        outcome: ProxyDelayOutcome,
        statusCode: Int?,
        data: Data? = nil,
        transportError: Error? = nil
    ) -> BenchmarkProbeDiagnostic? {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        return BenchmarkProbeDiagnostic.make(
            nodeName: token.nodeName,
            providerName: token.providerName,
            benchmarkURL: token.conditions.url,
            timeoutMilliseconds: 5000,
            requestTimeoutMilliseconds: 7000,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(0.125),
            statusCode: statusCode,
            outcome: outcome,
            data: data,
            transportError: transportError,
            identity: token.identity,
            scopeProvenance: token.scopeProvenance
        )
    }

    private func makeProxy(name: String, id: String) throws -> ClashProxy {
        guard let proxy = try makeSnapshot([(name, id)]).proxiesMap[name] else {
            throw NSError(domain: "BenchmarkProbeDiagnosticsTests", code: 1)
        }
        return proxy
    }

    private func makeSnapshot(_ proxies: [(String, String)]) throws -> ClashProxyResp {
        var values = [String: [String: Any]]()
        for (name, id) in proxies {
            values[name] = ["name": name, "id": id, "type": "Vmess", "history": []]
        }
        let data = try JSONSerialization.data(withJSONObject: ["proxies": values])
        return ClashProxyResp(data)
    }
}

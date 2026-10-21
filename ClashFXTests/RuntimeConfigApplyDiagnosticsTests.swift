import Foundation
import XCTest

final class RuntimeConfigApplyDiagnosticsTests: XCTestCase {
    func testEmbeddedSuccessIsAccepted() {
        XCTAssertEqual(RuntimeConfigApplyDiagnostics.embeddedDecision("success"), .accepted)
    }

    func testNilAndEmptyEmbeddedReturnsRemainDistinctAndUncertain() {
        guard case let .uncertain(nilDetail) = RuntimeConfigApplyDiagnostics.embeddedDecision(nil) else {
            return XCTFail("A nil response should be uncertain")
        }
        guard case let .uncertain(emptyDetail) = RuntimeConfigApplyDiagnostics.embeddedDecision("") else {
            return XCTFail("An empty response should be uncertain")
        }

        XCTAssertTrue(nilDetail.contains("nil"))
        XCTAssertTrue(emptyDetail.contains("empty"))
        XCTAssertNotEqual(nilDetail, emptyDetail)
    }

    func testEmbeddedBindErrorIsPreserved() {
        let original = "failed to bind 0.0.0.0:7890: address already in use"

        guard case let .rejected(detail) = RuntimeConfigApplyDiagnostics.embeddedDecision(original) else {
            return XCTFail("An explicit embedded-core error should be a rejection")
        }

        XCTAssertEqual(detail, original)
        let reason = RuntimeConfigApplyDiagnostics.formattedReason(
            transport: .embedded,
            stage: .embeddedResponse,
            requestID: UUID(uuidString: "E1AABEE0-65BE-4FA1-BD1D-A20D344127C3")!,
            expectedEpoch: 21,
            currentEpoch: 21,
            detail: detail
        )
        XCTAssertTrue(reason.contains("bind"))
        XCTAssertTrue(reason.contains("7890"))
    }

    func testCancelledReasonIncludesRequestAndEpochIdentity() {
        let requestID = UUID(uuidString: "E1AABEE0-65BE-4FA1-BD1D-A20D344127C3")!
        let reason = RuntimeConfigApplyDiagnostics.formattedReason(
            transport: .embedded,
            stage: .cancelled,
            requestID: requestID,
            expectedEpoch: 21,
            currentEpoch: 22,
            detail: "Core epoch changed"
        )

        XCTAssertTrue(reason.contains("transport=embedded"))
        XCTAssertTrue(reason.contains("stage=cancelled"))
        XCTAssertTrue(reason.contains("requestUUID=\(requestID.uuidString.lowercased())"))
        XCTAssertTrue(reason.contains("expectedEpoch=21"))
        XCTAssertTrue(reason.contains("currentEpoch=22"))
    }

    func testSanitizerRedactsURLsCredentialsAndBoundsOutput() {
        let input = """
        request https://alice:url-password@proxy.example.test:9090/subscriptions/private.yaml?token=url-token&secret=url-secret
        password=plain-password token: yaml-token Authorization: Bearer auth-token api-key: key-token
        Proxy-Authorization: Digest username="header-user", realm="proxy", response="header-response"
        secret: |
          block-secret
          another-block-secret
        listen=7890
        """

        let safe = RuntimeConfigApplyDiagnostics.sanitize(input)
        XCTAssertTrue(safe.contains("https://proxy.example.test:9090/[redacted]"))
        XCTAssertTrue(safe.contains("listen=7890"))
        for secret in [
            "alice", "url-password", "private.yaml", "url-token", "url-secret",
            "plain-password", "yaml-token", "auth-token", "key-token",
            "header-user", "header-response", "block-secret", "another-block-secret",
        ] {
            XCTAssertFalse(safe.contains(secret), "Unexpected secret in sanitized output: \(secret)")
        }

        let longDetail = String(repeating: "x", count: 3_000)
        let longReason = RuntimeConfigApplyDiagnostics.formattedReason(
            transport: .embedded,
            stage: .embeddedResponse,
            requestID: UUID(),
            expectedEpoch: 1,
            currentEpoch: 1,
            detail: longDetail
        )
        XCTAssertLessThanOrEqual(longReason.count, RuntimeConfigApplyDiagnostics.maximumReasonCharacters)
    }

    func testSanitizerCollapsesNewlineAndControlInjection() {
        let safe = RuntimeConfigApplyDiagnostics.sanitize("bind failed\nERROR injected\r\nlisten=7890\u{001B}[31m")

        XCTAssertEqual(safe, "bind failed ERROR injected listen=7890 [31m")
        XCTAssertFalse(safe.contains("\n"))
        XCTAssertFalse(safe.contains("\r"))
    }

    func testHTTPJSONMessageIsExtractedAndExplicitRefusalRetainsIt() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "message": "failed to bind 0.0.0.0:7890 using https://user:pass@api.example.test/private/config?token=abc; password=secret-value",
        ])

        XCTAssertEqual(
            RuntimeConfigApplyDiagnostics.httpMessage(from: body),
            "failed to bind 0.0.0.0:7890 using https://user:pass@api.example.test/private/config?token=abc; password=secret-value"
        )
        guard case let .rejected(detail) = RuntimeConfigApplyDiagnostics.httpDecision(
            statusCode: 422,
            errorDescription: nil,
            body: body
        ) else {
            return XCTFail("An explicit HTTP 4xx response should be a rejection")
        }
        let reason = RuntimeConfigApplyDiagnostics.formattedReason(
            transport: .http,
            stage: .httpResponse,
            requestID: UUID(),
            expectedEpoch: nil,
            currentEpoch: nil,
            detail: detail
        )
        XCTAssertTrue(reason.contains("bind"))
        XCTAssertTrue(reason.contains("7890"))
        XCTAssertTrue(reason.contains("https://api.example.test/[redacted]"))
        XCTAssertFalse(reason.contains("user:pass@"))
        XCTAssertFalse(reason.contains("token=abc"))
        XCTAssertFalse(reason.contains("password=secret-value"))
        XCTAssertFalse(reason.contains("secret-value"))
    }

    func testHTTPTimeoutRemainsUncertain() {
        let decision = RuntimeConfigApplyDiagnostics.httpDecision(
            statusCode: 422,
            errorDescription: "The request timed out",
            body: nil
        )

        guard case let .uncertain(detail) = decision else {
            return XCTFail("A timeout must remain uncertain")
        }
        XCTAssertTrue(detail.contains("timed out"))

        guard case .uncertain = RuntimeConfigApplyDiagnostics.httpDecision(
            statusCode: 408,
            errorDescription: nil,
            body: nil
        ) else {
            return XCTFail("An HTTP 408 response must remain uncertain")
        }
    }
    func testAlertReasonRetainsCoreErrorWithoutRequestBookkeeping() {
        let message = RuntimeConfigApplyDiagnostics.displayReason("bind 127.0.0.1:12345: address already in use; token=private")
        XCTAssertTrue(message.contains("address already in use"))
        XCTAssertFalse(message.contains("private"))
        XCTAssertFalse(message.contains("requestUUID"))
        XCTAssertEqual(RuntimeConfigApplyDiagnostics.displayReason("  "), "Core did not provide a failure reason")
    }

    func testAuthenticationArraysAndOpaqueProxyURIsAreNotLogged() {
        let text = """
        authentication: ["user:first-password", "other:second-password"]
        uuid=private-uuid
        preshared-key=private-psk
        invalid ss://YXV0aDpzZWNyZXQ=
        """
        let safe = RuntimeConfigApplyDiagnostics.sanitize(text)
        XCTAssertFalse(safe.contains("first-password"))
        XCTAssertFalse(safe.contains("second-password"))
        XCTAssertFalse(safe.contains("YXV0aDpzZWNyZXQ="))
        XCTAssertFalse(safe.contains("private-uuid"))
        XCTAssertFalse(safe.contains("private-psk"))
        XCTAssertTrue(safe.contains("ss://[redacted]"))
    }

    func testQuotedCredentialsHonorYAMLApostrophesAndJSONEscapes() {
        let inputs = [
            "password: 'prefix''CANARY_SINGLE_QUOTE suffix' bind=7890",
            #"secret: "prefix\"CANARY_ESCAPED_QUOTE]suffix" bind=7890"#,
            "password: `prefix CANARY_BACKTICK ] } suffix` bind=7890",
        ]
        for input in inputs {
            let safe = RuntimeConfigApplyDiagnostics.sanitize(input)
            XCTAssertFalse(safe.contains("CANARY"), safe)
            XCTAssertTrue(safe.contains("bind=7890"), safe)
        }
    }

    func testNestedCollectionsIgnoreQuotedClosingBracketsAndBraces() throws {
        let object = try JSONSerialization.data(withJSONObject: [
            "credentials": ["value": "before}CANARY_OBJECT", "nested": ["x]CANARY_NESTED", "quote\"CANARY_ESCAPED"]],
        ], options: [.sortedKeys])
        let payloads = [
            #"authentication: ["alice:before]CANARY_ARRAY_A", "bob:CANARY_ARRAY_B"]"#,
            String(decoding: object, as: UTF8.self),
            #"credentials: {"nested": [{"value":"CANARY } ] }"}], "password":"CANARY_FINAL"}"#,
        ]
        for payload in payloads {
            let safe = RuntimeConfigApplyDiagnostics.sanitize("🧪 " + payload + " bind=7890")
            XCTAssertFalse(safe.contains("CANARY"), safe)
            XCTAssertTrue(safe.contains("bind=7890"), safe)
        }
    }

    func testMalformedCredentialValuesFailClosedThroughEndOfInput() {
        for payload in [
            "password: 'unterminated CANARY_SUFFIX",
            #"password: 'prefix\'CANARY_MALFORMED_SINGLE'"#,
            #"authentication: ['prefix\'part]CANARY_MALFORMED_ARRAY', 'CANARY_OTHER']"#,
            #"authentication: ["before]CANARY_PART", "CANARY_TAIL""#,
            #"credentials: {"x": ["CANARY_VALUE"} CANARY_AFTER_MISMATCH"#,
        ] {
            let safe = RuntimeConfigApplyDiagnostics.sanitize("bind failed; " + payload)
            XCTAssertFalse(safe.contains("CANARY"), safe)
            XCTAssertTrue(safe.contains("bind failed"))
        }
    }

    func testPlainScalarsBlocksAndFoldedAuthorizationDoNotExposeContinuation() {
        let payloads = [
            "password: words; CANARY_PUNCTUATION suffix\n  CANARY_CONTINUED\nlisten=7890",
            "- private-key: |-\n    CANARY_PEM\n  listen=7890",
            "Authorization: Bearer CANARY_FIRST\n  CANARY_HEADER_CONTINUATION\nlisten=7890",
            "Authorization: \"CANARY_MULTILINE\nCANARY_UNINDENTED\"\nlisten=7890",
        ]
        for payload in payloads {
            let safe = RuntimeConfigApplyDiagnostics.sanitize(payload)
            XCTAssertFalse(safe.contains("CANARY"), safe)
            XCTAssertTrue(safe.contains("listen=7890"), safe)
        }
    }

    func testCollectionDepthAndOversizedInputAreBounded() {
        let nested = "credentials: " + String(repeating: "[", count: 65) + "CANARY_DEEP" + String(repeating: "]", count: 65)
        XCTAssertFalse(RuntimeConfigApplyDiagnostics.sanitize(nested).contains("CANARY"))
        let oversized = String(repeating: "🧪", count: 40_000) + " secret: CANARY_LARGE"
        let safe = RuntimeConfigApplyDiagnostics.sanitize(oversized)
        XCTAssertFalse(safe.contains("CANARY"))
        XCTAssertTrue(safe.contains("oversized"))
        XCTAssertEqual(RuntimeConfigApplyDiagnostics.sanitize(oversized, maximumCharacters: 0), "")
        XCTAssertLessThanOrEqual(RuntimeConfigApplyDiagnostics.sanitize(oversized, maximumCharacters: 8).count, 8)
    }

    func testSerializedNestedCredentialsWithVariedDelimitersStayPrivate() throws {
        let characters = ["'", "\"", "\\", "}", "]", "{", "[", "\n", "🧪", "\r"]
        for seed in 0 ..< 80 {
            let values = (0 ..< 8).map { index in
                characters[(seed + index) % characters.count] + "CANARY_\(seed)_\(index)" + characters[(seed * 3 + index) % characters.count]
            }
            let payload: [String: Any] = ["credentials": ["array": values, "nested": [["value": values.reversed().joined()]]]]
            let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let safe = RuntimeConfigApplyDiagnostics.sanitize("bind failed 🧪 " + String(decoding: encoded, as: UTF8.self) + " port=7890")
            XCTAssertFalse(safe.contains("CANARY"), "seed=\(seed): \(safe)")
            XCTAssertTrue(safe.contains("bind failed"))
            XCTAssertTrue(safe.contains("port=7890"))
        }
    }

    func testJSONWhitespaceAroundCredentialKeysAndValuesDoesNotLeak() {
        let payloads = [
            "{\"password\"\r\n:\r\n\"CANARY_VALUE\"}",
            "{\"credentials\"\n:\n{\"x\": \"CANARY_OBJECT\"}}",
            "{\"Authorization\"\n:\n\"Bearer CANARY_HEADER\"}",
            "{\"uuid\":\n123456789}",
        ]
        for payload in payloads {
            let safe = RuntimeConfigApplyDiagnostics.sanitize("bind failed: " + payload)
            XCTAssertFalse(safe.contains("CANARY"), safe)
            XCTAssertFalse(safe.contains("123456789"), safe)
            XCTAssertTrue(safe.contains("bind failed"))
        }
        let empty = RuntimeConfigApplyDiagnostics.sanitize("secret:\n\"listen\": 7890")
        XCTAssertTrue(empty.contains("listen"), empty)
        XCTAssertTrue(empty.contains("7890"), empty)
        let diagnostic = RuntimeConfigApplyDiagnostics.sanitize("secret:\nfile not found; bind=7890")
        XCTAssertTrue(diagnostic.contains("file not found"), diagnostic)
    }

    func testYAMLFlowCommentsCannotTerminateSensitiveCollections() {
        let payloads = [
            "authentication: [\"alice:CANARY_FIRST\", # comment contains ]\n  \"bob:CANARY_SECOND\"] bind=7890",
            "credentials: {x: CANARY_FIRST, # comment contains } ]\n  nested: [\"CANARY_SECOND\"]} bind=7890",
            "credentials: [unquoted#not-comment, \"CANARY_SUFFIX\"] bind=7890",
            "credentials: [\"quoted#hash]CANARY\", \"CANARY_END\"] bind=7890",
            "credentials: [foo:#not-comment, \"CANARY_END\"] bind=7890",
            "credentials: [foo\"bar#not-comment, \"CANARY_END\"] bind=7890",
            "credentials: [\"CANARY_FIRST\"# comment contains ]\n, \"CANARY_SECOND\"] bind=7890",
            "credentials: [{x: CANARY_FIRST}# comment contains ] }\n, \"CANARY_SECOND\"] bind=7890",
            "credentials: [https://example.test/path?token=CANARY_URL, \"CANARY_SECOND\"] bind=7890",
        ]
        for payload in payloads {
            let safe = RuntimeConfigApplyDiagnostics.sanitize(payload)
            XCTAssertFalse(safe.contains("CANARY"), safe)
            XCTAssertTrue(safe.contains("bind=7890"), safe)
        }
    }

}

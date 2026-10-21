import XCTest

final class RuntimeConfigReadbackTests: XCTestCase {
    func testJSONReadbackRefreshProducesNativeYAMLScalarValues() throws {
        let raw = Data(#"{"mixed-port":7088,"port":0,"socks-port":0,"redir-port":0,"tproxy-port":0,"mode":"rule","log-level":"info","bind-address":"127.0.0.1","allow-lan":false,"ipv6":true,"tun":{"enable":false}}"#.utf8)
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let confirmed: [String: Any] = ["mixed-port": 7088, "tun": ["enable": false], "rules": ["MATCH,DIRECT"]]
        let refreshed = try XCTUnwrap(RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(confirmed, actual: actual))
        for key in ["mode", "log-level", "bind-address"] {
            XCTAssertTrue(try type(of: XCTUnwrap(refreshed[key])) == String.self, key)
        }
        for key in ["allow-lan", "ipv6"] {
            XCTAssertTrue(try type(of: XCTUnwrap(refreshed[key])) == Bool.self, key)
        }
        XCTAssertEqual(refreshed["allow-lan"] as? Bool, false)
        XCTAssertEqual(refreshed["ipv6"] as? Bool, true)
        XCTAssertEqual(refreshed["rules"] as? [String], ["MATCH,DIRECT"])
    }

    func testSyncReadbackCannotPublishForAReplacementCoreAtTheSameAPIAddress() {
        let captured = RuntimeConfigReadbackPolicy.SyncIdentity(
            runtimeScope: "builtin:session-A",
            apiURL: "http://127.0.0.1:9090",
            directAPI: true,
            secret: "same-secret",
            selectedConfig: "profile.yaml",
            coreUpdateEpoch: 7
        )
        let replacement = RuntimeConfigReadbackPolicy.SyncIdentity(
            runtimeScope: "builtin:session-B",
            apiURL: captured.apiURL,
            directAPI: captured.directAPI,
            secret: captured.secret,
            selectedConfig: captured.selectedConfig,
            coreUpdateEpoch: 8
        )

        XCTAssertFalse(RuntimeConfigReadbackPolicy.canPromoteSyncReadback(
            captured: captured,
            current: replacement,
            transactionBusy: false,
            transactionUncertain: false
        ))
    }

    func testSyncReadbackCannotPromoteWhileTransactionIsBusyOrUncertain() {
        let identity = RuntimeConfigReadbackPolicy.SyncIdentity(
            runtimeScope: "builtin:session-A",
            apiURL: "http://127.0.0.1:9090",
            directAPI: true,
            secret: "secret",
            selectedConfig: "profile.yaml",
            coreUpdateEpoch: 7
        )

        XCTAssertTrue(RuntimeConfigReadbackPolicy.canPromoteSyncReadback(
            captured: identity,
            current: identity,
            transactionBusy: false,
            transactionUncertain: false
        ))
        XCTAssertFalse(RuntimeConfigReadbackPolicy.canPromoteSyncReadback(
            captured: identity,
            current: identity,
            transactionBusy: true,
            transactionUncertain: false
        ))
        XCTAssertFalse(RuntimeConfigReadbackPolicy.canPromoteSyncReadback(
            captured: identity,
            current: identity,
            transactionBusy: false,
            transactionUncertain: true
        ))
    }

    func testVerifiedBaselineRestorationRequiresCurrentCertainIdleScope() {
        XCTAssertTrue(RuntimeConfigReadbackPolicy.canRestoreVerifiedBaseline(
            scopeMatches: true,
            hasConfirmedBaseline: true,
            transactionBusy: false,
            transactionUncertain: false
        ))
        for state in [
            (false, true, false, false),
            (true, false, false, false),
            (true, true, true, false),
            (true, true, false, true),
        ] {
            XCTAssertFalse(RuntimeConfigReadbackPolicy.canRestoreVerifiedBaseline(
                scopeMatches: state.0,
                hasConfirmedBaseline: state.1,
                transactionBusy: state.2,
                transactionUncertain: state.3
            ))
        }
    }

    func testFailedRecoveryFencesCoreAndInvalidatesScopeBeforeReportingStopped() {
        var events = [String]()
        var listenersSuspended = false
        var snapshotVerified = true
        var isRunning = true

        RuntimeConfigRecoveryFailureController.fence(
            suspendCore: {
                events.append("suspend")
                listenersSuspended = true
                XCTAssertTrue(isRunning)
            },
            invalidateScope: {
                events.append("invalidate")
                snapshotVerified = false
            },
            reportStopped: {
                events.append("stopped")
                XCTAssertTrue(listenersSuspended)
                XCTAssertFalse(snapshotVerified)
                isRunning = false
            }
        )

        XCTAssertEqual(events, ["suspend", "invalidate", "stopped"])
        XCTAssertFalse(isRunning)
    }

    func testImplicitPortsReuseConfirmedBindingButExplicitChangesArePreserved() {
        let confirmed: [String: Any] = ["mixed-port": 41888, "port": 0, "socks-port": 0]
        let reused = RuntimeConfigReadbackPolicy.preservingImplicitPorts(in: [:], confirmed: confirmed, fallback: 7890)
        XCTAssertEqual(RuntimeConfigReadbackPolicy.port(reused["mixed-port"]), 41888)
        let changed = RuntimeConfigReadbackPolicy.preservingImplicitPorts(in: ["mixed-port": 7891], confirmed: confirmed, fallback: 7890)
        XCTAssertEqual(RuntimeConfigReadbackPolicy.port(changed["mixed-port"]), 7891)
        let disabled = RuntimeConfigReadbackPolicy.preservingImplicitPorts(in: ["mixed-port": 0], confirmed: confirmed, fallback: 7890)
        XCTAssertEqual(RuntimeConfigReadbackPolicy.port(disabled["mixed-port"]), 0)
    }

    func testReadbackMustMatchPortsModeAndTunRatherThanOnlyHTTPStatus() {
        let expected: [String: Any] = ["mixed-port": 41888, "mode": "rule", "tun": ["enable": true]]
        XCTAssertNil(RuntimeConfigReadbackPolicy.readbackError(expected: expected, actual: expected))
        var actual = expected
        actual["mixed-port"] = 7890
        XCTAssertNotNil(RuntimeConfigReadbackPolicy.readbackError(expected: expected, actual: actual))
        actual = expected; actual["tun"] = ["enable": false]
        XCTAssertNotNil(RuntimeConfigReadbackPolicy.readbackError(expected: expected, actual: actual))
        actual = expected; actual["mode"] = "global"
        XCTAssertNotNil(RuntimeConfigReadbackPolicy.readbackError(expected: expected, actual: actual))
    }

    func testRefreshKeepsConfirmedRoutingGraphAndUsesFreshManualScalars() throws {
        let confirmed: [String: Any] = [
            "mixed-port": 41888,
            "port": 0,
            "socks-port": 0,
            "redir-port": 41890,
            "tproxy-port": 0,
            "mode": "rule",
            "allow-lan": false,
            "ipv6": false,
            "log-level": "info",
            "proxies": [["name": "confirmed-node", "server": "confirmed.example"]],
            "proxy-groups": [["name": "confirmed-group", "proxies": ["confirmed-node"]]],
            "rules": ["MATCH,confirmed-group"],
            "tun": ["enable": true, "stack": "system", "device": "utun-confirmed"],
            "listeners": [["name": "confirmed-listener", "port": 41891, "listen": "127.0.0.1"]],
        ]
        var actual = confirmed
        actual["mode"] = "global"
        actual["allow-lan"] = true
        actual["ipv6"] = true
        actual["log-level"] = "debug"
        actual["proxies"] = [["name": "new-node", "server": "new.example"]]
        actual["proxy-groups"] = [["name": "new-group", "proxies": ["new-node"]]]
        actual["rules"] = ["MATCH,DIRECT"]
        actual["tun"] = ["enable": true, "stack": "gvisor", "device": "utun-new"]
        actual.removeValue(forKey: "listeners")
        actual["new-runtime-field"] = "must not be copied"

        let refreshed = try XCTUnwrap(
            RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(confirmed, actual: actual)
        )

        XCTAssertEqual(refreshed["mode"] as? String, "global")
        XCTAssertEqual(refreshed["allow-lan"] as? Bool, true)
        XCTAssertEqual(refreshed["ipv6"] as? Bool, true)
        XCTAssertEqual(refreshed["log-level"] as? String, "debug")
        XCTAssertEqual(refreshed["mixed-port"] as? Int, 41888)
        XCTAssertEqual((refreshed["proxies"] as? [[String: Any]])?.first?["name"] as? String, "confirmed-node")
        XCTAssertEqual((refreshed["proxy-groups"] as? [[String: Any]])?.first?["name"] as? String, "confirmed-group")
        XCTAssertEqual(refreshed["rules"] as? [String], ["MATCH,confirmed-group"])
        XCTAssertEqual((refreshed["tun"] as? [String: Any])?["device"] as? String, "utun-confirmed")
        XCTAssertEqual((refreshed["listeners"] as? [[String: Any]])?.first?["port"] as? Int, 41891)
        XCTAssertNil(refreshed["new-runtime-field"])
    }

    func testRefreshTreatsOmittedGeneralPortsAsDisabledAndKeepsUnobservedListeners() throws {
        let confirmed: [String: Any] = [
            "mixed-port": 7890,
            "mode": "rule",
            "listeners": [["name": "custom", "port": 9000, "listen": "127.0.0.1"]],
            "proxy-groups": [["name": "route", "proxies": ["DIRECT"]]],
        ]
        let actual: [String: Any] = [
            "mixed-port": 7890,
            "port": 0,
            "socks-port": 0,
            "redir-port": 0,
            "tproxy-port": 0,
            "mode": "global",
            "allow-lan": false,
            "ipv6": false,
            "log-level": "warning",
        ]

        let refreshed = try XCTUnwrap(
            RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(confirmed, actual: actual)
        )
        XCTAssertEqual(refreshed["mixed-port"] as? Int, 7890)
        XCTAssertNil(refreshed["port"])
        XCTAssertEqual(refreshed["mode"] as? String, "global")
        XCTAssertEqual(refreshed["log-level"] as? String, "warning")
        XCTAssertEqual((refreshed["listeners"] as? [[String: Any]])?.first?["port"] as? Int, 9000)
        XCTAssertEqual((refreshed["proxy-groups"] as? [[String: Any]])?.first?["name"] as? String, "route")
    }

    func testRefreshRejectsExternalListenerPortDrift() {
        let confirmed: [String: Any] = [
            "mixed-port": 41888,
            "port": 0,
            "socks-port": 0,
            "redir-port": 41890,
            "tproxy-port": 0,
        ]
        var actual = confirmed
        actual["mixed-port"] = 7890
        XCTAssertNil(RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(confirmed, actual: actual))

        actual = confirmed
        actual["redir-port"] = 7891
        XCTAssertNil(RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(confirmed, actual: actual))
        actual = confirmed
        actual["tproxy-port"] = true
        XCTAssertNil(RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(confirmed, actual: actual))
    }

    func testRefreshRejectsTunEnableDrift() {
        let confirmed: [String: Any] = [
            "mixed-port": 41888,
            "tun": ["enable": true, "stack": "system"],
        ]
        let actual: [String: Any] = [
            "mixed-port": 41888,
            "tun": ["enable": false, "stack": "system"],
        ]
        XCTAssertNil(RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(confirmed, actual: actual))
    }

    func testReadbackRejectsRedirectionListenerDriftBeforeConfirmation() {
        let expected: [String: Any] = ["mixed-port": 41888, "redir-port": 41889, "tproxy-port": 41890]
        XCTAssertNil(RuntimeConfigReadbackPolicy.readbackError(expected: expected, actual: expected))
        for key in ["redir-port", "tproxy-port"] {
            var actual = expected
            actual[key] = 0
            XCTAssertNotNil(RuntimeConfigReadbackPolicy.readbackError(expected: expected, actual: actual))
        }
    }

    func testBindAddressMustMatchAndManualRuntimeAddressSurvivesRollbackSeed() throws {
        let old: [String: Any] = ["mixed-port": 41888, "allow-lan": true, "bind-address": "*", "rules": ["MATCH,DIRECT"]]
        var narrowed = old
        narrowed["bind-address"] = "127.0.0.1"
        XCTAssertNotNil(RuntimeConfigReadbackPolicy.readbackError(expected: narrowed, actual: old))
        XCTAssertNil(RuntimeConfigReadbackPolicy.readbackError(expected: narrowed, actual: narrowed))
        let refreshed = try XCTUnwrap(RuntimeConfigReadbackPolicy.refreshedConfirmedRoot(old, actual: narrowed))
        XCTAssertEqual(refreshed["bind-address"] as? String, "127.0.0.1")
        XCTAssertEqual(refreshed["rules"] as? [String], ["MATCH,DIRECT"])
    }

    func testSyncCapturedDuringTransactionCannotPromoteAfterRollback() {
        let before = RuntimeConfigReadbackPolicy.SyncIdentity(runtimeScope: "same-core", apiURL: "same-api",
                                                              directAPI: true, secret: "", selectedConfig: "same-profile", coreUpdateEpoch: 7,
                                                              configurationGeneration: 10)
        var after = before
        after.configurationGeneration = 11
        XCTAssertFalse(RuntimeConfigReadbackPolicy.canPromoteSyncReadback(captured: before, current: after,
                                                                          transactionBusy: false, transactionUncertain: false))
    }

    func testFailedBaselineReadbackCannotRestoreOldSameScopeReceipt() {
        let old = UUID()
        XCTAssertFalse(RuntimeConfigReadbackPolicy.baselineMatchesReadback(confirmedID: old, validatedID: nil))
        XCTAssertFalse(RuntimeConfigReadbackPolicy.baselineMatchesReadback(confirmedID: old, validatedID: UUID()))
        XCTAssertTrue(RuntimeConfigReadbackPolicy.baselineMatchesReadback(confirmedID: old, validatedID: old))
    }

    func testRejectedNewSessionPublishesFreshBaselinePortsRatherThanOldCurrentConfig() throws {
        let old: [String: Any] = ["mixed-port": 7890, "mode": "rule", "log-level": "info", "allow-lan": false]
        var fresh = old
        fresh["mixed-port"] = 49188
        let metadata = try XCTUnwrap(RuntimeConfigReadbackPolicy.confirmedBasicMetadata(fresh))
        XCTAssertEqual(metadata["mixed-port"] as? Int, 49188)
        XCTAssertEqual(metadata["port"] as? Int, 0)
        XCTAssertEqual(metadata["socks-port"] as? Int, 0)
        XCTAssertNotEqual(metadata["mixed-port"] as? Int, old["mixed-port"] as? Int)
        XCTAssertNil(RuntimeConfigReadbackPolicy.confirmedBasicMetadata([:]))
    }

    func testBuiltInReloadUsesConfirmedIPv6UntilTheCoreRestarts() {
        for running in [false, true] {
            let pending: [String: Any] = ["ipv6": !running, "mixed-port": 41888, "rules": ["MATCH,DIRECT"]]
            let actual: [String: Any] = ["ipv6": running, "mixed-port": 41888]
            XCTAssertNotNil(RuntimeConfigReadbackPolicy.readbackError(expected: pending, actual: actual))
            let candidate = RuntimeConfigReadbackPolicy.preservingBuiltInSessionIPv6(in: pending, confirmed: actual)
            XCTAssertNil(RuntimeConfigReadbackPolicy.readbackError(expected: candidate, actual: actual))
            XCTAssertEqual(candidate["rules"] as? [String], ["MATCH,DIRECT"])
        }
    }

    func testCandidateNeedsAUsableListenerButMayBeSocksOnly() {
        XCTAssertNotNil(RuntimeConfigReadbackPolicy.candidateError(["mixed-port": 0, "port": 0, "socks-port": 0]))
        XCTAssertNil(RuntimeConfigReadbackPolicy.candidateError(["socks-port": 41888]))
        XCTAssertNil(RuntimeConfigReadbackPolicy.candidateError(["mixed-port": 41888]))
    }

    func testPersistedStartupPortsAreValidatedPreferencesWithoutOwnership() throws {
        let plan = try XCTUnwrap(RuntimeConfigReadbackPolicy.startupPortPreference(
            ["apiPort": 49190, "dnsPort": 49191, "owned": true]
        ))
        XCTAssertEqual(plan["owned"] as? Bool, false)
        XCTAssertEqual(plan["apiPort"] as? Int, 49190)
        XCTAssertNil(RuntimeConfigReadbackPolicy.startupPortPreference(["apiPort": true, "dnsPort": 49191]))
        XCTAssertNil(RuntimeConfigReadbackPolicy.startupPortPreference(["apiPort": 49190, "dnsPort": 65536]))
    }

    func testPlanOnlyUsesValidConfirmedMetadataAndDoesNotProbePorts() {
        let config: [String: Any] = ["dns": ["listen": "127.0.0.1:41889"]]
        let plan = RuntimeConfigReadbackPolicy.portPlan(config: config, apiPort: 19090, owned: true)
        XCTAssertEqual(plan?["dnsPort"] as? Int, 41889)
        XCTAssertEqual(plan?["owned"] as? Bool, true)
        XCTAssertNil(RuntimeConfigReadbackPolicy.portPlan(config: config, apiPort: 0, owned: true))
        XCTAssertNil(RuntimeConfigReadbackPolicy.portPlan(config: [:], apiPort: 19090, owned: true))
        XCTAssertEqual(RuntimeConfigReadbackPolicy.port(true), 0)
        XCTAssertEqual(RuntimeConfigReadbackPolicy.port(7890.5), 0)
    }
}

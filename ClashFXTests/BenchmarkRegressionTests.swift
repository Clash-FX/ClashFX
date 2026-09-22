import Cocoa
import JavaScriptCore
import WebKit
import XCTest

final class MenuBarSpeedAlignmentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        Settings.menuBarSpeedAlignment = .right
    }

    func testInvalidPersistedValueFallsBackToExistingRightAlignment() {
        XCTAssertEqual(MenuBarSpeedAlignment.persisted(rawValue: -1), .right)
        XCTAssertEqual(MenuBarSpeedAlignment.persisted(rawValue: 99), .right)
        XCTAssertEqual(MenuBarSpeedAlignment.persisted(rawValue: 0), .left)
        XCTAssertEqual(MenuBarSpeedAlignment.persisted(rawValue: 1), .center)
        XCTAssertEqual(MenuBarSpeedAlignment.persisted(rawValue: 2), .right)
    }

    func testEachAlignmentUsesTheExpectedDrawingOriginAndLegacyTextAlignment() {
        XCTAssertEqual(MenuBarSpeedAlignment.left.textOriginX(containerWidth: 100, textWidth: 40), 0)
        XCTAssertEqual(MenuBarSpeedAlignment.center.textOriginX(containerWidth: 100, textWidth: 40), 30)
        XCTAssertEqual(MenuBarSpeedAlignment.right.textOriginX(containerWidth: 100, textWidth: 40), 60)
        XCTAssertEqual(MenuBarSpeedAlignment.left.textAlignment, .left)
        XCTAssertEqual(MenuBarSpeedAlignment.center.textAlignment, .center)
        XCTAssertEqual(MenuBarSpeedAlignment.right.textAlignment, .right)
    }

    func testTextWiderThanContainerNeverProducesANegativeOrigin() {
        for alignment in MenuBarSpeedAlignment.allCases {
            XCTAssertEqual(
                alignment.textOriginX(containerWidth: 20, textWidth: 40),
                0
            )
        }
    }

    func testProductionSpeedViewSwitchesAlignmentWithoutChangingItsWidth() {
        let view = SpeedTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        let width = view.textWidth
        view.update(up: "2.7KB/s", down: "15.1MB/s")

        for alignment in MenuBarSpeedAlignment.allCases {
            view.updateAlignment(alignment)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            XCTAssertEqual(view.speedAlignment, alignment)
            XCTAssertEqual(view.textWidth, width)
        }
    }
}

final class DashboardWebsiteDataPolicyTests: XCTestCase {
    func testCacheCleanupPreservesPersistentDashboardState() {
        let availableTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let removableTypes = DashboardWebsiteDataPolicy.removableDataTypes(from: availableTypes)

        XCTAssertFalse(removableTypes.contains(WKWebsiteDataTypeLocalStorage))
        XCTAssertFalse(removableTypes.contains(WKWebsiteDataTypeCookies))
        XCTAssertFalse(removableTypes.contains(WKWebsiteDataTypeIndexedDBDatabases))
        XCTAssertTrue(removableTypes.isSubset(of: DashboardWebsiteDataPolicy.volatileDataTypes))
    }

    func testKnownVolatileCachesAreEligibleForCleanup() {
        let availableTypes: Set<String> = [
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeLocalStorage,
        ]

        XCTAssertEqual(
            DashboardWebsiteDataPolicy.removableDataTypes(from: availableTypes),
            [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache]
        )
    }
}

final class ShortcutScopePolicyTests: XCTestCase {
    func testActionShortcutsDefaultToMenuOnly() {
        XCTAssertEqual(ShortcutRegistrationPolicy.defaultActionScope, .menuOnly)
        XCTAssertFalse(ShortcutRegistrationPolicy.shouldRegisterGlobally(.action, scope: .menuOnly))
        XCTAssertTrue(ShortcutRegistrationPolicy.shouldRegisterGlobally(.action, scope: .global))
    }

    func testOpenMenuIsAlwaysGlobal() {
        XCTAssertTrue(ShortcutRegistrationPolicy.shouldRegisterGlobally(.openMenu, scope: .menuOnly))
        XCTAssertTrue(ShortcutRegistrationPolicy.shouldRegisterGlobally(.openMenu, scope: .global))
    }

    func testMenuTrackingSuppressesGlobalActionRegistration() {
        XCTAssertTrue(ShortcutRegistrationPolicy.shouldRegisterActionShortcutsGlobally(
            scope: .global,
            isMenuTracking: false
        ))
        XCTAssertFalse(ShortcutRegistrationPolicy.shouldRegisterActionShortcutsGlobally(
            scope: .global,
            isMenuTracking: true
        ))
    }

    func testPersistedScopeFallsBackSafely() {
        XCTAssertEqual(ShortcutRegistrationPolicy.actionScope(from: ShortcutScope.global.rawValue), .global)
        XCTAssertEqual(ShortcutRegistrationPolicy.actionScope(from: -1), .menuOnly)
    }

    func testDuplicateShortcutIsHardBlockedButExternalConflictCanWarn() {
        XCTAssertEqual(
            ShortcutRegistrationPolicy.duplicateOwner(
                command: "benchmark",
                proposedSignature: "14:256",
                assignments: ["enhanced": "14:256", "menu": "46:256"]
            ),
            "enhanced"
        )
        XCTAssertNil(
            ShortcutRegistrationPolicy.duplicateOwner(
                command: "enhanced",
                proposedSignature: "14:256",
                assignments: ["enhanced": "14:256"]
            )
        )
        XCTAssertTrue(
            ShortcutRegistrationPolicy.shouldWarnBeforeOverride(
                matchesMainMenu: true,
                isKnownSystemShortcut: false
            )
        )
        XCTAssertFalse(
            ShortcutRegistrationPolicy.shouldWarnBeforeOverride(
                matchesMainMenu: false,
                isKnownSystemShortcut: false
            )
        )
    }
}

final class DiagnosticFormattingTests: XCTestCase {
    func testRedactorSanitizesReportMetadataAndLogLines() {
        let input = """
        - Primary IP: 192.168.3.22
        - DNS Servers: 198.18.0.2
        - Config: /Users/example/.config/clashfx/config.yaml
        - Interface: aa:bb:cc:dd:ee:ff
        [Info] ApiRequest.swift request --> api.example.com:443
        - URL: https://cp.cloudflare.com/generate_204?token=private-token
        - Authorization: Bearer private-credential
        """

        let output = DiagnosticRedactor.redact(input, homeDirectory: "/Users/example")

        XCTAssertFalse(output.contains("example/.config"))
        XCTAssertFalse(output.contains("192.168.3.22"))
        XCTAssertFalse(output.contains("198.18.0.2"))
        XCTAssertFalse(output.contains("aa:bb:cc:dd:ee:ff"))
        XCTAssertFalse(output.contains("api.example.com"))
        XCTAssertFalse(output.contains("cp.cloudflare.com"))
        XCTAssertFalse(output.contains("private-token"))
        XCTAssertFalse(output.contains("private-credential"))
        XCTAssertTrue(output.contains("<redacted-home>"))
        XCTAssertTrue(output.contains("<redacted-ipv4>"))
        XCTAssertTrue(output.contains("<redacted-mac>"))
        XCTAssertTrue(output.contains("<redacted-host>"))
        XCTAssertTrue(output.contains("ApiRequest.swift"))
    }

    func testLogTimestampsUseLocalTimeAndExplicitOffset() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 60 * 60))
        let date = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(
            LogTimestampFormatting.lineDateFormatter(timeZone: timeZone).string(from: date),
            "1970/01/01 08:00:00.000 +08:00"
        )
        XCTAssertEqual(
            LogTimestampFormatting.fileName(
                appName: "com.clashfx.app",
                date: date,
                timeZone: timeZone
            ),
            "com.clashfx.app 1970-01-01--08-00-00-000-+0800.log"
        )
    }
}

final class BenchmarkURLSettingsTests: XCTestCase {
    func testCanonicalDefaultMatchesClashXCompatibleHTTPURL() {
        XCTAssertEqual(BenchmarkURLSettings.defaultURL, "http://cp.cloudflare.com/generate_204")
    }

    func testWhitespaceOnlyBenchmarkURLRestoresCanonicalDefault() {
        XCTAssertEqual(
            BenchmarkURLSettings.normalizedURL("  \n\t  "),
            BenchmarkURLSettings.defaultURL
        )
    }

    func testExplicitHTTPBenchmarkURLIsTrimmedAndPreserved() {
        XCTAssertEqual(
            BenchmarkURLSettings.normalizedURL(
                "  http://www.gstatic.com/generate_204  "
            ),
            "http://www.gstatic.com/generate_204"
        )
    }

    func testCustomHTTPSBenchmarkURLIsTrimmedAndPreserved() {
        XCTAssertEqual(
            BenchmarkURLSettings.normalizedURL(
                "  https://www.gstatic.com/generate_204  "
            ),
            "https://www.gstatic.com/generate_204"
        )
    }

    func testSupersededBuiltInHTTPSDefaultRestoresBeforeCompletion() {
        XCTAssertTrue(
            BenchmarkURLSettings.shouldRestoreSupersededBuiltInDefault(
                savedURL: BenchmarkURLSettings.supersededBuiltInDefaultURL,
                restorationCompleted: false
            )
        )
    }

    func testCustomURLsDoNotRequestRestoration() {
        XCTAssertFalse(
            BenchmarkURLSettings.shouldRestoreSupersededBuiltInDefault(
                savedURL: "http://www.gstatic.com/generate_204",
                restorationCompleted: false
            )
        )
        XCTAssertFalse(
            BenchmarkURLSettings.shouldRestoreSupersededBuiltInDefault(
                savedURL: "https://custom.example.test/generate_204",
                restorationCompleted: false
            )
        )
    }

    func testCompletedRestorationPreservesLaterHTTPSCloudflareSelection() {
        XCTAssertFalse(
            BenchmarkURLSettings.shouldRestoreSupersededBuiltInDefault(
                savedURL: BenchmarkURLSettings.supersededBuiltInDefaultURL,
                restorationCompleted: true
            )
        )
    }

    func testInvalidBenchmarkURLDoesNotReplaceSavedValue() {
        XCTAssertNil(
            BenchmarkURLSettings.normalizedURL(
                "gstatic.com/generate_204"
            )
        )
        XCTAssertNil(
            BenchmarkURLSettings.normalizedURL(
                "file:///tmp/generate_204"
            )
        )
    }
}

final class ManagedOperationSettlementTests: XCTestCase {
    func testAsyncOperationsWaitForCompletionAndIgnoreDuplicateCompletion() {
        let queue = DispatchQueue(label: "test.serial-operations")
        let operations = SerializedAsyncOperationQueue(queue: queue)
        let started = expectation(description: "first operation started")
        let drained = expectation(description: "all operations completed")
        var events = [Int]()
        var finishFirst: (() -> Void)?
        var finishSecond: (() -> Void)?
        operations.enqueue { done in
            events.append(1)
            finishFirst = done
            started.fulfill()
        }
        operations.enqueue { done in
            events.append(2)
            finishSecond = done
        }
        operations.enqueue { done in
            events.append(3)
            done()
            drained.fulfill()
        }
        wait(for: [started], timeout: 2)
        queue.sync { XCTAssertEqual(events, [1]); finishFirst?(); finishFirst?() }
        queue.sync { XCTAssertEqual(events, [1, 2]); finishSecond?() }
        wait(for: [drained], timeout: 2)
        queue.sync { XCTAssertEqual(events, [1, 2, 3]) }
    }

    func testNormalResultFiresOnce() {
        var outcomes = [String]()
        let settlement = ManagedOperationSettlement<String> { outcomes.append($0) }

        XCTAssertTrue(settlement.finish("success"))
        XCTAssertFalse(settlement.finish("failure"))
        XCTAssertEqual(outcomes, ["success"])
    }

    func testImmediateFailureFiresOnce() {
        var outcomes = [String]()
        let settlement = ManagedOperationSettlement<String> { outcomes.append($0) }

        XCTAssertTrue(settlement.finish("failure"))
        XCTAssertFalse(settlement.finish("success"))
        XCTAssertEqual(outcomes, ["failure"])
    }

    func testTimeoutWinsOverLateSuccess() {
        var outcomes = [String]()
        let settlement = ManagedOperationSettlement<String> { outcomes.append($0) }

        XCTAssertTrue(settlement.finish("timeout"))
        XCTAssertFalse(settlement.finish("success"))
        XCTAssertEqual(outcomes, ["timeout"])
    }

    func testSuccessWinsOverLaterTimeout() {
        var outcomes = [String]()
        let settlement = ManagedOperationSettlement<String> { outcomes.append($0) }

        XCTAssertTrue(settlement.finish("success"))
        XCTAssertFalse(settlement.finish("timeout"))
        XCTAssertEqual(outcomes, ["success"])
    }
}

final class SystemProxyOperationPolicyTests: XCTestCase {
    func testRestoreVerificationChecksPACAndEnabledFlags() {
        let key = SystemProxyOperationPolicy.capturedServiceIDsKey
        let original: [String: Any] = [
            key: ["wifi"],
            "wifi": ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.test/proxy.pac", "HTTPEnable": 0]
        ]
        XCTAssertTrue(SystemProxyOperationPolicy.restoredSnapshotMatches(expected: original, actual: original))
        var changed = original
        changed["wifi"] = ["ProxyAutoConfigEnable": 0, "ProxyAutoConfigURLString": "https://example.test/proxy.pac", "HTTPEnable": 0]
        XCTAssertFalse(SystemProxyOperationPolicy.restoredSnapshotMatches(expected: original, actual: changed))
        changed["wifi"] = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://wrong.test/proxy.pac", "HTTPEnable": 0]
        XCTAssertFalse(SystemProxyOperationPolicy.restoredSnapshotMatches(expected: original, actual: changed))
        XCTAssertFalse(SystemProxyOperationPolicy.restoredSnapshotMatches(expected: original, actual: [:]))
        changed = original
        changed[SystemProxyOperationPolicy.captureErrorKey] = "read failed"
        XCTAssertFalse(SystemProxyOperationPolicy.restoredSnapshotMatches(expected: original, actual: changed))
    }

    func testRestoreVerificationHandlesAbsentAndNewNetworkServices() {
        let key = SystemProxyOperationPolicy.capturedServiceIDsKey
        let original: [String: Any] = [key: ["wifi", "removed"], "removed": ["HTTPEnable": 1]]
        let actual: [String: Any] = [key: ["wifi", "new"], "new": ["HTTPEnable": 1]]
        XCTAssertTrue(SystemProxyOperationPolicy.restoredSnapshotMatches(expected: original, actual: actual))
        var changed = actual
        changed["wifi"] = ["HTTPEnable": 0]
        XCTAssertFalse(SystemProxyOperationPolicy.restoredSnapshotMatches(expected: original, actual: changed))
    }

    private func clashSnapshot(httpPort: Int = 7890, socksPort: Int = 7891) -> [String: Any] {
        return [
            "wifi": [
                "HTTPEnable": 1,
                "HTTPProxy": "127.0.0.1",
                "HTTPPort": httpPort,
                "HTTPSEnable": 1,
                "HTTPSProxy": "127.0.0.1",
                "HTTPSPort": httpPort,
                "SOCKSEnable": 1,
                "SOCKSProxy": "127.0.0.1",
                "SOCKSPort": socksPort,
            ],
        ]
    }

    func testGenerationRejectsObsoleteCaptureCallback() {
        var policy = SystemProxyOperationPolicy()
        let first = policy.beginTransition()
        let second = policy.beginTransition()

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(policy.acceptsCallback(for: first))
        XCTAssertTrue(policy.acceptsCallback(for: second))
    }

    func testOnlyFullyMatchingLoopbackSnapshotIsOwnedByClashFX() {
        XCTAssertTrue(SystemProxyOperationPolicy.isClashFXOwnedSnapshot(clashSnapshot(), httpPort: 7890, socksPort: 7891))

        var partial = clashSnapshot()
        partial["wifi"] = [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 7890,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": 7890,
            "SOCKSEnable": 0,
        ]
        XCTAssertFalse(SystemProxyOperationPolicy.isClashFXOwnedSnapshot(partial, httpPort: 7890, socksPort: 7891))
    }

    func testPACAndPartialSnapshotsRemainValidPropertyLists() {
        let snapshot: [String: Any] = [
            "wifi": [
                "HTTPEnable": 1,
                "HTTPProxy": "proxy.example",
                "HTTPPort": 8080,
                "HTTPSEnable": 1,
                "HTTPSProxy": "secure.example",
                "HTTPSPort": 8443,
                "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 1,
                "ProxyAutoConfigURLString": "https://pac.example/proxy.pac",
                "ExceptionsList": ["localhost", "*.local"],
            ],
            SystemProxyOperationPolicy.capturedServiceIDsKey: ["wifi", "ethernet"],
        ]
        XCTAssertTrue(SystemProxyOperationPolicy.isValidPropertyListSnapshot(snapshot))
        XCTAssertFalse(SystemProxyOperationPolicy.isClashFXOwnedSnapshot(snapshot, httpPort: 7890, socksPort: 7891))
    }

    func testCaptureErrorIsRecognizedBeforeSnapshotPersistence() {
        let snapshot: [String: Any] = [SystemProxyOperationPolicy.captureErrorKey: "preferences unavailable"]
        XCTAssertEqual(SystemProxyOperationPolicy.captureError(in: snapshot), "preferences unavailable")
    }

    func testLegacySnapshotMigrationRequiresLiveClashFXAndOriginalDictionary() {
        let original: [String: Any] = [
            "wifi": ["HTTPEnable": 1, "HTTPProxy": "proxy.example", "HTTPPort": 8080],
        ]
        XCTAssertTrue(SystemProxyOperationPolicy.shouldMigrateLegacySnapshot(
            original,
            validityMarker: false,
            liveSystemPointsToClashFX: true,
            httpPort: 7890,
            socksPort: 7891
        ))
        XCTAssertFalse(SystemProxyOperationPolicy.shouldMigrateLegacySnapshot(
            original,
            validityMarker: false,
            liveSystemPointsToClashFX: false,
            httpPort: 7890,
            socksPort: 7891
        ))
        XCTAssertFalse(SystemProxyOperationPolicy.shouldMigrateLegacySnapshot(
            original,
            validityMarker: true,
            liveSystemPointsToClashFX: true,
            httpPort: 7890,
            socksPort: 7891
        ))
    }

    func testLegacyClashFXSnapshotCannotBeMigrated() {
        XCTAssertFalse(SystemProxyOperationPolicy.shouldMigrateLegacySnapshot(
            clashSnapshot(),
            validityMarker: false,
            liveSystemPointsToClashFX: true,
            httpPort: 7890,
            socksPort: 7891
        ))
    }

    func testLegacyMigrationRejectsCaptureErrorsAndMalformedPayloads() {
        XCTAssertFalse(SystemProxyOperationPolicy.shouldMigrateLegacySnapshot(
            [SystemProxyOperationPolicy.captureErrorKey: "unavailable"],
            validityMarker: false,
            liveSystemPointsToClashFX: true,
            httpPort: 7890,
            socksPort: 7891
        ))
        XCTAssertFalse(SystemProxyOperationPolicy.shouldMigrateLegacySnapshot(
            ["wifi": Set(["not a property list"])],
            validityMarker: false,
            liveSystemPointsToClashFX: true,
            httpPort: 7890,
            socksPort: 7891
        ))
    }
}

final class TerminationCleanupPolicyTests: XCTestCase {
    func testNoCleanupDoesNotWait() {
        let policy = TerminationCleanupPolicy.make(observation: TerminationCleanupObservation(
            enhancedModeActive: false, proxyPortAutoSet: false, isProxySetByOther: false,
            currentSystemSetToClash: false, hasInterfaceProxySetToClash: false,
            preserveSystemProxyForFailClosed: false
        ))
        XCTAssertFalse(policy.shouldWait)
    }

    func testEnhancedAndProxyCleanupCombineIntoOneWait() {
        let policy = TerminationCleanupPolicy.make(observation: TerminationCleanupObservation(
            enhancedModeActive: true, proxyPortAutoSet: true, isProxySetByOther: false,
            currentSystemSetToClash: false, hasInterfaceProxySetToClash: false,
            preserveSystemProxyForFailClosed: false
        ))
        XCTAssertTrue(policy.cleanEnhancedMode)
        XCTAssertTrue(policy.cleanSystemProxy)
        XCTAssertTrue(policy.shouldWait)
    }

    func testOwnedProxyStateSelectsRestore() {
        let policy = TerminationCleanupPolicy.make(observation: TerminationCleanupObservation(
            enhancedModeActive: false, proxyPortAutoSet: true, isProxySetByOther: false,
            currentSystemSetToClash: false, hasInterfaceProxySetToClash: false,
            preserveSystemProxyForFailClosed: false
        ))
        XCTAssertTrue(policy.cleanSystemProxy)
        XCTAssertFalse(policy.forceDisableProxy)
    }

    func testExternalChangeMarkerDoesNotBypassOriginalProxyRestoration() {
        let policy = TerminationCleanupPolicy.make(observation: TerminationCleanupObservation(
            enhancedModeActive: false, proxyPortAutoSet: false, isProxySetByOther: true,
            currentSystemSetToClash: true, hasInterfaceProxySetToClash: false,
            preserveSystemProxyForFailClosed: false
        ))
        XCTAssertTrue(policy.cleanSystemProxy)
        XCTAssertFalse(policy.forceDisableProxy)
    }

    func testFailClosedLockPreservesSystemProxyWhileCleaningEnhancedMode() {
        let policy = TerminationCleanupPolicy.make(observation: TerminationCleanupObservation(
            enhancedModeActive: true, proxyPortAutoSet: true, isProxySetByOther: false,
            currentSystemSetToClash: true, hasInterfaceProxySetToClash: true,
            preserveSystemProxyForFailClosed: true
        ))
        XCTAssertTrue(policy.cleanEnhancedMode)
        XCTAssertFalse(policy.cleanSystemProxy)
        XCTAssertTrue(policy.shouldWait)
    }
}

final class ClaudeProxyLockPolicyTests: XCTestCase {
    func testRulesCoverClaudeProcessesAndOfficialDomains() {
        XCTAssertEqual(ClaudeProxyLockPolicy.rules(target: "IPRoyal Korea"), [
            "PROCESS-NAME-REGEX,^claude( helper.*)?$,IPRoyal Korea",
            "DOMAIN-SUFFIX,claude.ai,IPRoyal Korea",
            "DOMAIN-SUFFIX,claude.com,IPRoyal Korea",
            "DOMAIN-SUFFIX,anthropic.com,IPRoyal Korea"
        ])
    }

    func testApplyingLockForcesRuleModeAndPrependsRules() {
        var root: [String: Any] = [
            "mode": "global",
            "find-process-mode": "off",
            "rules": ["MATCH,DIRECT"]
        ]
        let outcome = ClaudeProxyLockPolicy.apply(to: &root, target: "Korea")
        XCTAssertTrue(outcome.applied)
        XCTAssertEqual(root["mode"] as? String, "rule")
        XCTAssertEqual(root["find-process-mode"] as? String, "always")
        let rules = root["rules"] as? [String]
        XCTAssertEqual(rules?.last, "MATCH,DIRECT")
        XCTAssertEqual(rules?.first, "PROCESS-NAME-REGEX,^claude( helper.*)?$,Korea")
    }

    func testLockReachesTheProxyServerThroughTheMatchGroup() {
        var root: [String: Any] = [
            "rules": ["MATCH,Final"],
            "proxy-groups": [[
                "name": "Final",
                "type": "select",
                "now": "Japan 27",
                "proxies": ["Japan 27", "Korea"]
            ]],
            "proxies": [[
                "name": "Korea",
                "type": "socks5",
                "server": "147.125.251.178",
                "port": 12323,
                "dialer-proxy": "Japan"
            ]]
        ]
        let outcome = ClaudeProxyLockPolicy.apply(to: &root, target: "Korea")
        XCTAssertTrue(outcome.applied)
        XCTAssertEqual(outcome.relayProxy, "Final")
        XCTAssertEqual(outcome.serverHost, "147.125.251.178")
        let proxies = root["proxies"] as? [[String: Any]]
        XCTAssertEqual(proxies?.first?["dialer-proxy"] as? String, "Final")
        XCTAssertEqual(root["rules"] as? [String], [
            "PROCESS-NAME-REGEX,^claude( helper.*)?$,Korea",
            "DOMAIN-SUFFIX,claude.ai,Korea",
            "DOMAIN-SUFFIX,claude.com,Korea",
            "DOMAIN-SUFFIX,anthropic.com,Korea",
            "MATCH,Final"
        ])
    }

    func testLockDoesNotRelayThroughTheLockedNode() {
        var root: [String: Any] = [
            "rules": ["MATCH,Final"],
            "proxy-groups": [[
                "name": "Final",
                "type": "select",
                "now": "Korea"
            ]],
            "proxies": [[
                "name": "Korea",
                "type": "http",
                "server": "147.125.251.178",
                "port": 12323
            ]]
        ]
        let outcome = ClaudeProxyLockPolicy.apply(to: &root, target: "Korea")
        XCTAssertNil(outcome.relayProxy)
        XCTAssertNil((root["proxies"] as? [[String: Any]])?.first?["dialer-proxy"])
    }

    func testProviderNodeUsesTheMatchGroupAsItsDialer() {
        var root: [String: Any] = [
            "rules": ["MATCH,Final"],
            "proxy-groups": [["name": "Final", "type": "select", "now": "Japan"]],
            "proxy-providers": [
                "airport": [
                    "type": "http",
                    "path": "providers/airport.yaml",
                    "dialer-proxy": "Japan",
                    "exclude-filter": "Ads"
                ]
            ]
        ]
        let providers = [
            ClaudeProxyLockPolicy.ProviderSnapshot(
                name: "airport",
                dialerProxy: "Japan",
                overrideDialerProxy: nil,
                proxies: [[
                    "name": "A (B)",
                    "type": "socks5",
                    "server": "203.0.113.8",
                    "port": 1080
                ]]
            )
        ]
        let outcome = ClaudeProxyLockPolicy.apply(
            to: &root,
            target: "A (B)",
            providers: providers
        )
        XCTAssertEqual(outcome.relayProxy, "Final")
        XCTAssertEqual(outcome.serverHost, "203.0.113.8")
        let proxies = root["proxies"] as? [[String: Any]]
        XCTAssertEqual(proxies?.first?["name"] as? String, "A (B)")
        XCTAssertEqual(proxies?.first?["dialer-proxy"] as? String, "Final")
        let provider = (root["proxy-providers"] as? [String: Any])?["airport"] as? [String: Any]
        XCTAssertEqual(provider?["exclude-filter"] as? String, "Ads`^A \\(B\\)$")
        XCTAssertEqual((root["rules"] as? [String])?.first, "PROCESS-NAME-REGEX,^claude( helper.*)?$,A (B)")
    }

    func testApplyingLockTwiceDoesNotDuplicateRules() {
        var root: [String: Any] = [
            "rules": ["MATCH,DIRECT"],
            "proxies": [["name": "Korea", "server": "147.125.251.178"]]
        ]
        _ = ClaudeProxyLockPolicy.apply(to: &root, target: "Korea")
        let once = root["rules"] as? [String]
        let again = ClaudeProxyLockPolicy.apply(to: &root, target: "Korea")
        XCTAssertNil(again.relayProxy)
        XCTAssertEqual(root["rules"] as? [String], once)
    }

    func testUnsafeOrFallbackTargetsAreRejected() {
        XCTAssertFalse(ClaudeProxyLockPolicy.isValidTarget("DIRECT"))
        XCTAssertFalse(ClaudeProxyLockPolicy.isValidTarget("bad,target"))
        XCTAssertTrue(ClaudeProxyLockPolicy.rules(target: "bad,target").isEmpty)
        var root: [String: Any] = ["rules": ["MATCH,DIRECT"]]
        XCTAssertFalse(ClaudeProxyLockPolicy.apply(to: &root, target: "DIRECT").applied)
        XCTAssertEqual(root["rules"] as? [String], ["MATCH,DIRECT"])
    }
}

final class ManagedRemoteUpdateSettlementTests: XCTestCase {
    private final class Harness {
        var completionCount = 0
        var updating = true
        var updateTime: Date?
        lazy var settlement: ManagedOperationSettlement<String?> = ManagedOperationSettlement<String?> { [weak self] error in
            guard let self = self else { return }
            self.completionCount += 1
            self.updating = false
            if error == nil {
                self.updateTime = Date()
            }
        }

        func finish(_ error: String?) -> Bool {
            settlement.finish(error)
        }
    }

    func testSuccessClearsUpdatingAndRecordsTimestampOnce() {
        let harness = Harness()

        XCTAssertTrue(harness.finish(nil))
        XCTAssertFalse(harness.finish("late failure"))
        XCTAssertEqual(harness.completionCount, 1)
        XCTAssertFalse(harness.updating)
        XCTAssertNotNil(harness.updateTime)
    }

    func testSetupFailureClearsUpdatingWithoutTimestamp() {
        let harness = Harness()

        XCTAssertTrue(harness.finish("setup failed"))
        XCTAssertEqual(harness.completionCount, 1)
        XCTAssertFalse(harness.updating)
        XCTAssertNil(harness.updateTime)
    }

    func testTimeoutRejectsLateNetworkResult() {
        let harness = Harness()

        XCTAssertTrue(harness.finish("timeout"))
        XCTAssertFalse(harness.finish(nil))
        XCTAssertEqual(harness.completionCount, 1)
        XCTAssertFalse(harness.updating)
        XCTAssertNil(harness.updateTime)
    }

    func testCallbackRejectsLateTimeout() {
        let harness = Harness()

        XCTAssertTrue(harness.finish(nil))
        XCTAssertFalse(harness.finish("timeout"))
        XCTAssertEqual(harness.completionCount, 1)
        XCTAssertFalse(harness.updating)
        XCTAssertNotNil(harness.updateTime)
    }
}

final class BenchmarkRegressionTests: XCTestCase {
    private func snapshot(_ proxyJSON: [[String: Any]]) -> ClashProxyResp {
        let proxies = Dictionary(uniqueKeysWithValues: proxyJSON.compactMap { proxy -> (String, Any)? in
            guard let name = proxy["name"] as? String else { return nil }
            return (name, proxy)
        })
        let data = try! JSONSerialization.data(withJSONObject: ["proxies": proxies])
        return ClashProxyResp(data)
    }

    func testDashboardCompatibilityConvertsLabThemeColorsWithoutFallingBackToBlack() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let scriptURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClashFX/Resources/DashboardCompatibility/clashfx-compat.js")
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in
            exception = value?.toString()
        }
        context.evaluateScript("""
        var window = {
          __CLASHFX_DASHBOARD_COMPAT_TESTING__: true,
          CSS: { supports: function () { return false; } },
          getComputedStyle: function () { return {}; }
        };
        var document = {
          readyState: 'loading',
          addEventListener: function () {}
        };
        """)
        context.evaluateScript(source)
        XCTAssertNil(exception)

        func converted(_ cssColor: String) throws -> (Double, Double, Double) {
            let argumentData = try JSONSerialization.data(withJSONObject: [cssColor])
            let argumentJSON = try XCTUnwrap(String(data: argumentData, encoding: .utf8))
            let expression = "window.__CLASHFX_DASHBOARD_COMPAT__.testing.parseRenderedColor(\(argumentJSON)[0])"
            let value = try XCTUnwrap(context.evaluateScript(expression))
            XCTAssertFalse(value.isNull)
            return (
                value.forProperty("red").toDouble(),
                value.forProperty("green").toDouble(),
                value.forProperty("blue").toDouble()
            )
        }

        let darkBackground = try converted("lab(13.3466% -1.2732 -5.67451)")
        XCTAssertEqual(darkBackground.0, 0x1D, accuracy: 1.5)
        XCTAssertEqual(darkBackground.1, 0x23, accuracy: 1.5)
        XCTAssertEqual(darkBackground.2, 0x2A, accuracy: 1.5)

        let darkContent = try converted("lab(97.3754% -1.86676 -10.6283)")
        XCTAssertEqual(darkContent.0, 0xF2, accuracy: 8)
        XCTAssertEqual(darkContent.1, 0xF8, accuracy: 8)
        XCTAssertEqual(darkContent.2, 0xFF, accuracy: 8)

        let darkOKLCHBackground = try converted("oklch(25.33% 0.016 252.42)")
        XCTAssertEqual(darkOKLCHBackground.0, 0x1D, accuracy: 6)
        XCTAssertEqual(darkOKLCHBackground.1, 0x23, accuracy: 6)
        XCTAssertEqual(darkOKLCHBackground.2, 0x2A, accuracy: 6)

        let darkOKLCHContent = try converted("oklch(97.807% 0.029 256.847 / 80%)")
        XCTAssertGreaterThan(darkOKLCHContent.0, 220)
        XCTAssertGreaterThan(darkOKLCHContent.1, 220)
        XCTAssertGreaterThan(darkOKLCHContent.2, 220)

        let polarLabBackground = try converted("lch(13.3466% 5.815 257.35)")
        XCTAssertLessThan(polarLabBackground.0, 60)
        XCTAssertLessThan(polarLabBackground.1, 60)
        XCTAssertLessThan(polarLabBackground.2, 60)

        let probeExpression = context.evaluateScript(
            "window.__CLASHFX_DASHBOARD_COMPAT__.testing.renderedProbeExpression"
        )?.toString()
        XCTAssertEqual(
            probeExpression,
            "color-mix(in oklab, var(--clashfx-probe-color) 50%, transparent)"
        )
    }

    func testProviderMergePreservesProxySnapshotOwnership() throws {
        let response = snapshot([
            [
                "name": "Selector",
                "type": "Selector",
                "all": ["Provider Node"],
                "now": "Provider Node",
                "history": []
            ],
            [
                "name": "Provider Node",
                "type": "Vless",
                "history": []
            ]
        ])
        let providerData = try JSONSerialization.data(withJSONObject: [
            "providers": [
                "Subscription": [
                    "name": "Subscription",
                    "type": "Proxy",
                    "vehicleType": "HTTP",
                    "proxies": [
                        [
                            "name": "Provider Node",
                            "type": "Vless",
                            "history": []
                        ]
                    ]
                ]
            ]
        ])
        let providerResponse = try ClashProviderResp.decoder.decode(
            ClashProviderResp.self,
            from: providerData
        )

        response.updateProvider(providerResponse)

        let mergedNode = try XCTUnwrap(response.proxiesMap["Provider Node"])
        XCTAssertTrue(mergedNode.enclosingResp === response)
        XCTAssertEqual(mergedNode.enclosingProvider?.name, "Subscription")
    }

    func testGlobalLeafFallbackCoversSelectableAndAutomaticGroups() {
        XCTAssertTrue(ProxyBenchmarkPresentationPolicy.allowsGlobalLeafFallback(in: .select))
        XCTAssertTrue(ProxyBenchmarkPresentationPolicy.allowsGlobalLeafFallback(in: .urltest))
        XCTAssertTrue(ProxyBenchmarkPresentationPolicy.allowsGlobalLeafFallback(in: .fallback))
        XCTAssertTrue(ProxyBenchmarkPresentationPolicy.allowsGlobalLeafFallback(in: .loadBalance))
        XCTAssertFalse(ProxyBenchmarkPresentationPolicy.allowsGlobalLeafFallback(in: .relay))

        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(ProxyBenchmarkPresentationPolicy.prefersGlobal(
            publishedAt: newer,
            over: older
        ))
        XCTAssertFalse(ProxyBenchmarkPresentationPolicy.prefersGlobal(
            publishedAt: older,
            over: newer
        ))
    }

    func testSelectorPlanSharesNestedAutomaticFinalLeaf() throws {
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Direct", "Automatic"], "now": "Direct", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Direct"], "now": "Direct", "history": []],
            ["name": "Direct", "type": "Direct", "history": []]
        ])
        let selector = try XCTUnwrap(response.proxiesMap["Selector"])

        let plan = SelectorBenchmarkPlan.make(
            selector: selector,
            snapshot: response,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        )

        XCTAssertEqual(plan.orderedRows.map(\.displayName), ["Direct", "Automatic"])
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertEqual(plan.targets.first?.aliases.map(\.rowName), ["Direct", "Automatic"])
        XCTAssertEqual(plan.targets.first?.key.proxyName, "Direct")
        XCTAssertEqual(plan.maxConcurrentRequests, 1)

        let automatic = AutomaticGroupRetestSnapshot.make(
            groupName: "Automatic",
            candidateDelays: ["Direct": 42, "Unrelated": 1],
            snapshot: response
        )
        XCTAssertEqual(automatic.finalLeaf, "Direct")
        guard case let .measured(delay) = automatic.evidence else {
            return XCTFail("expected fresh final-path measurement")
        }
        XCTAssertEqual(delay, 42)
    }

    func testSelectorMeasuresSelectedLeafWhenAutomaticTestSemanticsDiffer() throws {
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Direct", "Automatic", "Other Auto"], "now": "Automatic", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Direct", "Other"], "now": "Direct", "history": [], "testUrl": "https://automatic.example.test", "expectedStatus": "204"],
            ["name": "Other Auto", "type": "Fallback", "all": ["Other"], "now": "Other", "history": [], "testUrl": "https://other.example.test"],
            ["name": "Direct", "type": "Direct", "history": []],
            ["name": "Other", "type": "Vless", "history": []]
        ])
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(response.proxiesMap["Selector"]),
            snapshot: response,
            benchmarkURL: "https://selector.example.test",
            timeout: 5
        )

        XCTAssertEqual(plan.orderedRows.map(\.rowName), ["Direct", "Automatic", "Other Auto"])
        XCTAssertEqual(
            plan.orderedRows.filter(\.isDeferredAutomaticRetest).map(\.rowName),
            []
        )
        XCTAssertEqual(plan.orderedRows[1].measurementKey?.proxyName, "Direct")
        XCTAssertEqual(plan.orderedRows[1].measurementKey?.benchmarkURL, "https://selector.example.test")
        XCTAssertEqual(plan.orderedRows[2].measurementKey?.proxyName, "Other")
        XCTAssertEqual(plan.targets.map(\.key.proxyName), ["Direct", "Other"])
        XCTAssertNil(plan.selectedAutomaticRetest)
    }

    func testEmptyRegionalGroupsNeverPlanCompatibleButExplicitDirectIsValid() throws {
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Singapore", "Taiwan", "DIRECT", "Real"], "now": "Singapore", "history": []],
            ["name": "Singapore", "type": "URLTest", "all": ["COMPATIBLE"], "now": "COMPATIBLE", "history": []],
            ["name": "Taiwan", "type": "Fallback", "all": ["Singapore"], "now": "Singapore", "history": []],
            ["name": "COMPATIBLE", "type": "Compatible", "id": "fallback-id", "history": []],
            ["name": "DIRECT", "type": "Direct", "id": "direct-id", "history": []],
            ["name": "Real", "type": "Vless", "id": "real-id", "history": []]
        ])
        let plan = try SelectorBenchmarkPlan.make(selector: XCTUnwrap(response.proxiesMap["Selector"]),
                                                  snapshot: response, benchmarkURL: "https://test.invalid", timeout: 5000)
        XCTAssertNil(plan.selectedAutomaticRetest)
        XCTAssertEqual(Set(plan.targets.map(\.key.proxyName)), ["DIRECT", "Real"])
        for row in plan.orderedRows.prefix(2) {
            XCTAssertNil(row.measurementKey)
            XCTAssertEqual(row.unavailableReason, .compatibilityFallback)
        }
        XCTAssertFalse(response.hasBenchmarkCandidates(in: "Taiwan"))
        XCTAssertTrue(response.hasBenchmarkCandidates(in: "DIRECT"))
        let result = AutomaticGroupRetestSnapshot.make(groupName: "Singapore", candidateDelays: ["COMPATIBLE": 532], snapshot: response)
        guard case .unavailable(.compatibilityFallback) = result.evidence else {
            return XCTFail("Direct fallback must not become proxy latency")
        }
        let proxy = try XCTUnwrap(response.proxiesMap["COMPATIBLE"])
        let value = GlobalLeafBenchmarkPresentation(identity: .init(proxy: proxy), benchmarkURL: "https://test.invalid",
                                                    sessionIdentifier: UUID(), rowState: .measured(displayName: "COMPATIBLE", delay: 532))
        var cache = BenchmarkEvidenceCache()
        cache.publish(value)
        XCTAssertNil(value.reconciled(with: proxy))
        XCTAssertNil(cache.measurement(for: proxy, conditions: .init(url: "https://test.invalid")))
    }

    func testMissingCompatibleAndInvalidGroupMembershipCannotResolveToSuccess() {
        let response = snapshot([
            ["name": "Implicit", "type": "URLTest", "all": ["COMPATIBLE"], "now": "COMPATIBLE", "history": []],
            ["name": "Empty", "type": "Selector", "all": [], "now": "DIRECT", "history": []],
            ["name": "Invalid", "type": "Selector", "all": ["Missing"], "now": "DIRECT", "history": []],
            ["name": "DIRECT", "type": "Direct", "history": []]
        ])
        for name in ["Implicit", "Empty", "Invalid"] {
            guard case .unavailable = response.resolveSelectedPath(from: name) else {
                return XCTFail("\(name) cannot represent an available proxy path")
            }
            XCTAssertFalse(response.hasBenchmarkCandidates(in: name))
        }
    }

    func testSelectorPlanHandlesNilEmptyAndSingleLeafMembers() throws {
        let nilMembers = snapshot([
            ["name": "Selector", "type": "Selector", "history": []]
        ])
        XCTAssertTrue(try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(nilMembers.proxiesMap["Selector"]),
            snapshot: nilMembers,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        ).orderedRows.isEmpty)

        let emptyMembers = snapshot([
            ["name": "Selector", "type": "Selector", "all": [], "history": []]
        ])
        XCTAssertTrue(try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(emptyMembers.proxiesMap["Selector"]),
            snapshot: emptyMembers,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        ).targets.isEmpty)

        let singleLeaf = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Direct"], "now": "Direct", "history": []],
            ["name": "Direct", "type": "Direct", "history": []]
        ])
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(singleLeaf.proxiesMap["Selector"]),
            snapshot: singleLeaf,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        )
        XCTAssertEqual(plan.orderedRows.map(\.rowName), ["Direct"])
        XCTAssertEqual(plan.targets.count, 1)
    }

    func testResolutionReportsCycleMissingNowAndUnknownTarget() {
        let cycle = snapshot([
            ["name": "A", "type": "Selector", "all": ["B"], "now": "B", "history": []],
            ["name": "B", "type": "URLTest", "all": ["A"], "now": "A", "history": []]
        ])
        guard case let .unavailable(_, .cycle(name)) = cycle.resolveSelectedPath(from: "A") else {
            return XCTFail("expected cycle")
        }
        XCTAssertEqual(name, "A")

        let missingNow = snapshot([
            ["name": "A", "type": "Selector", "all": ["Direct"], "history": []],
            ["name": "Direct", "type": "Direct", "history": []]
        ])
        guard case let .unavailable(_, .missingSelection(name)) = missingNow.resolveSelectedPath(from: "A") else {
            return XCTFail("expected missingNow")
        }
        XCTAssertEqual(name, "A")

        let unknownTarget = snapshot([
            ["name": "A", "type": "Selector", "all": ["Ghost"], "now": "Ghost", "history": []]
        ])
        guard case let .unavailable(_, .unknownTarget(name)) = unknownTarget.resolveSelectedPath(from: "A") else {
            return XCTFail("expected unknownTarget")
        }
        XCTAssertEqual(name, "Ghost")
    }

    func testDistinctLeavesDoNotCoalesceAndRowsKeepStableOrder() throws {
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["First", "Second", "First"], "now": "First", "history": []],
            ["name": "First", "type": "Direct", "history": []],
            ["name": "Second", "type": "Reject", "history": []]
        ])
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(response.proxiesMap["Selector"]),
            snapshot: response,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        )
        XCTAssertEqual(plan.orderedRows.map(\.rowName), ["First", "Second", "First"])
        XCTAssertEqual(plan.targets.map(\.key.proxyName), ["First", "Second"])
        XCTAssertEqual(plan.targets[0].aliases.map(\.rowName), ["First", "First"])
        XCTAssertNotEqual(plan.targets[0].key, plan.targets[1].key)
        XCTAssertEqual(plan.targets[0].key.endpoint, .inline)
        XCTAssertNil(plan.targets[0].key.providerName)
        XCTAssertEqual(plan.targets[0].key.benchmarkURL, "https://benchmark.example.test")
        XCTAssertEqual(plan.targets[0].key.timeout, 5)
    }

    func testSelectorConcurrencyStartsBoundedForLargeMenus() throws {
        let names = (1 ... 25).map { "Proxy \($0)" }
        var proxies: [[String: Any]] = [
            ["name": "Selector", "type": "Selector", "all": names, "now": names[0], "history": []]
        ]
        proxies.append(contentsOf: names.map {
            ["name": $0, "type": "Direct", "history": []]
        })
        let response = snapshot(proxies)
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(response.proxiesMap["Selector"]),
            snapshot: response,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        )

        XCTAssertEqual(plan.targets.count, 25)
        XCTAssertEqual(plan.maxConcurrentRequests, 8)
        XCTAssertEqual(plan.concurrencyPolicy.minimumLimit, 8)
        XCTAssertEqual(plan.concurrencyPolicy.maximumLimit, 12)
    }

    func testSelectorConcurrencyRampsFromEightToTwelveAndStops() {
        var policy = SelectorBenchmarkConcurrencyPolicy(targetCount: 49)
        XCTAssertEqual(policy.currentLimit, 8)

        policy.recordCohort(Array(repeating: true, count: 8))
        XCTAssertEqual(policy.currentLimit, 12)

        policy.recordCohort(Array(repeating: true, count: 10) + [false, false])
        XCTAssertEqual(policy.currentLimit, 12)

        policy.recordCohort(Array(repeating: true, count: 16))
        XCTAssertEqual(policy.currentLimit, 12)
    }

    func testSelectorConcurrencyHoldsForMixedWindowAndBacksOffOnClusteredFailures() {
        var policy = SelectorBenchmarkConcurrencyPolicy(targetCount: 49)

        policy.recordCohort(Array(repeating: true, count: 5) + Array(repeating: false, count: 3))
        XCTAssertEqual(policy.currentLimit, 8)

        policy.recordCohort(Array(repeating: true, count: 4) + Array(repeating: false, count: 4))
        XCTAssertEqual(policy.currentLimit, 8)

        policy.recordCohort(Array(repeating: false, count: 8))
        XCTAssertEqual(policy.currentLimit, 8)

        policy.recordCohort(Array(repeating: true, count: 4))
        XCTAssertEqual(policy.currentLimit, 12)

        policy.recordCohort(Array(repeating: false, count: 12))
        XCTAssertEqual(policy.currentLimit, 8)
    }

    func testSelectorConcurrencyNeverExceedsSmallPlanSize() {
        var policy = SelectorBenchmarkConcurrencyPolicy(targetCount: 3)
        XCTAssertEqual(policy.minimumLimit, 3)
        XCTAssertEqual(policy.currentLimit, 3)
        XCTAssertEqual(policy.maximumLimit, 3)

        policy.recordCohort(Array(repeating: true, count: 3))
        XCTAssertEqual(policy.currentLimit, 3)
    }

    func testSelectorExecutionInterleavesProtocolBucketsWithoutChangingRows() throws {
        let trojans = (1 ... 14).map { "Trojan \($0)" }
        let vless = (1 ... 6).map { "VLESS \($0)" }
        let hysteria = (1 ... 6).map { "HY2 \($0)" }
        let names = trojans + vless + hysteria
        var proxies: [[String: Any]] = [
            ["name": "Selector", "type": "Selector", "all": names, "now": names[0], "history": []]
        ]
        proxies.append(contentsOf: trojans.map { ["name": $0, "type": "Trojan", "history": []] })
        proxies.append(contentsOf: vless.map { ["name": $0, "type": "Vless", "history": []] })
        proxies.append(contentsOf: hysteria.map { ["name": $0, "type": "Hysteria2", "history": []] })

        let response = snapshot(proxies)
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(response.proxiesMap["Selector"]),
            snapshot: response,
            benchmarkURL: "https://benchmark.example.test",
            timeout: 5
        )

        XCTAssertEqual(plan.orderedRows.map(\.rowName), names)
        XCTAssertEqual(
            plan.interleavedTargets.prefix(8).map(\.schedulingBucket.proxyType),
            [.trojan, .vless, .hysteria2, .trojan, .vless, .hysteria2, .trojan, .vless]
        )
    }

    func testAdaptiveRunnerContinuouslyReplenishesBeforeSlowRequestFinishes() {
        let firstCohortStarted = expectation(description: "first cohort started")
        firstCohortStarted.expectedFulfillmentCount = 8
        let replacementTasksStarted = expectation(description: "replacement tasks started")
        replacementTasksStarted.expectedFulfillmentCount = 7
        let partialCohortSettled = expectation(description: "partial cohort settled")
        let completed = expectation(description: "runner completes")
        let lock = NSLock()
        var firstCohortCompletions = [(Bool) -> Void]()
        var startedTaskCount = 0

        let tasks: [AdaptiveAsyncTaskRunner.Task] = (0 ..< 20).map { index in
            return { done in
                lock.lock()
                startedTaskCount += 1
                lock.unlock()
                if index < 8 {
                    lock.lock()
                    firstCohortCompletions.append(done)
                    lock.unlock()
                    firstCohortStarted.fulfill()
                } else {
                    if index < 15 {
                        replacementTasksStarted.fulfill()
                    }
                    done(true)
                }
            }
        }
        AdaptiveAsyncTaskRunner(
            tasks: tasks,
            policy: SelectorBenchmarkConcurrencyPolicy(targetCount: tasks.count)
        ).start {
            completed.fulfill()
        }

        wait(for: [firstCohortStarted], timeout: 2)
        lock.lock()
        let completions = firstCohortCompletions
        lock.unlock()
        for done in completions.dropLast() {
            done(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            partialCohortSettled.fulfill()
        }
        wait(for: [partialCohortSettled], timeout: 1)
        lock.lock()
        let partialStartedTaskCount = startedTaskCount
        lock.unlock()
        XCTAssertEqual(partialStartedTaskCount, 20)
        completions.last?(true)
        wait(for: [replacementTasksStarted, completed], timeout: 2)
    }

    func testSelectorReusesOnlySuccessfulEquivalentDirectLeafMeasurements() throws {
        let url = "https://benchmark.example.test"
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Automatic", "First", "Second", "Third"], "now": "Automatic", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["First", "Second"], "now": "First", "testUrl": url, "history": []],
            ["name": "First", "type": "Trojan", "history": []],
            ["name": "Second", "type": "Vless", "history": []],
            ["name": "Third", "type": "Hysteria2", "history": []]
        ])
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(response.proxiesMap["Selector"]),
            snapshot: response,
            benchmarkURL: url,
            timeout: 5
        )
        let group = try XCTUnwrap(response.proxiesMap["Automatic"])
        let delays = ["First": 120, "Second": 0, "Third": 300]
        let reused = plan.reusableMeasurements(group: group, candidateDelays: delays, timeout: 5)
        XCTAssertEqual(reused.count, 1)
        XCTAssertEqual(reused.first?.key.proxyName, "First")
        XCTAssertEqual(reused.first?.value, 120)
        XCTAssertTrue(plan.reusableMeasurements(group: group, candidateDelays: delays, timeout: 10).isEmpty)
    }

    func testAdaptiveRunnerAppliesPolicyLimitChanges() {
        let completion = expectation(description: "adaptive runner completes")
        var limitChanges = [(Int, Int)]()
        let tasks: [AdaptiveAsyncTaskRunner.Task] = (0 ..< 49).map { _ in
            return { done in
                done(true)
            }
        }
        let runner = AdaptiveAsyncTaskRunner(
            tasks: tasks,
            policy: SelectorBenchmarkConcurrencyPolicy(targetCount: tasks.count),
            limitChanged: { previousLimit, currentLimit in
                limitChanges.append((previousLimit, currentLimit))
            }
        )

        runner.start {
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)

        XCTAssertEqual(limitChanges.map(\.0), [8])
        XCTAssertEqual(limitChanges.map(\.1), [12])
    }

    func testSelectorDoesNotReuseAutomaticResultsWithDifferentURLOrStatus() throws {
        let url = "https://benchmark.example.test"
        for (groupURL, status) in [
            ("https://other.example.test", ""),
            (url, "204")
        ] {
            let response = snapshot([
                ["name": "Selector", "type": "Selector", "all": ["Automatic", "Leaf"], "now": "Automatic", "history": []],
                ["name": "Automatic", "type": "URLTest", "all": ["Leaf"], "now": "Leaf", "testUrl": groupURL, "expectedStatus": status, "history": []],
                ["name": "Leaf", "type": "Vless", "history": []]
            ])
            let plan = try SelectorBenchmarkPlan.make(
                selector: XCTUnwrap(response.proxiesMap["Selector"]), snapshot: response,
                benchmarkURL: url, timeout: 5
            )
            XCTAssertNil(plan.selectedAutomaticRetest)
            XCTAssertEqual(plan.orderedRows[0].measurementKey?.benchmarkURL, url)
            XCTAssertTrue(try plan.reusableMeasurements(
                group: XCTUnwrap(response.proxiesMap["Automatic"]),
                candidateDelays: ["Leaf": 120], timeout: 5
            ).isEmpty)
        }
    }

    func testSelectorDoesNotReuseNestedGroupCandidateAsLeafMeasurement() throws {
        let url = "https://benchmark.example.test"
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Automatic", "Leaf"], "now": "Automatic", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Nested"], "now": "Nested", "testUrl": url, "history": []],
            ["name": "Nested", "type": "Selector", "all": ["Leaf"], "now": "Leaf", "history": []],
            ["name": "Leaf", "type": "Vless", "history": []]
        ])
        let plan = try SelectorBenchmarkPlan.make(
            selector: XCTUnwrap(response.proxiesMap["Selector"]), snapshot: response,
            benchmarkURL: url, timeout: 5
        )
        XCTAssertTrue(try plan.reusableMeasurements(
            group: XCTUnwrap(response.proxiesMap["Automatic"]),
            candidateDelays: ["Nested": 120], timeout: 5
        ).isEmpty)
    }

    func testSelectorReuseRequiresMatchingProviderIdentity() throws {
        let url = "https://benchmark.example.test"
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Automatic", "Leaf"], "now": "Automatic", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Leaf"], "now": "Leaf", "testUrl": url, "history": []],
            ["name": "Leaf", "type": "Vless", "history": []]
        ])
        let selector = try XCTUnwrap(response.proxiesMap["Selector"])
        let group = try XCTUnwrap(response.proxiesMap["Automatic"])
        let inlinePlan = SelectorBenchmarkPlan.make(selector: selector, snapshot: response, benchmarkURL: url, timeout: 5)
        var firstProviderPlan: SelectorBenchmarkPlan?
        for providerName in ["Subscription", "Other Subscription"] {
            let data = try JSONSerialization.data(withJSONObject: ["providers": [providerName: [
                "name": providerName, "type": "Proxy", "vehicleType": "HTTP",
                "proxies": [["name": "Leaf", "type": "Vless", "history": []]]
            ]]])
            try response.updateProvider(ClashProviderResp.decoder.decode(ClashProviderResp.self, from: data))
            XCTAssertTrue(inlinePlan.reusableMeasurements(group: group, candidateDelays: ["Leaf": 120], timeout: 5).isEmpty)
            if let firstProviderPlan {
                XCTAssertTrue(firstProviderPlan.reusableMeasurements(group: group, candidateDelays: ["Leaf": 120], timeout: 5).isEmpty)
            } else {
                firstProviderPlan = SelectorBenchmarkPlan.make(selector: selector, snapshot: response, benchmarkURL: url, timeout: 5)
            }
        }
        let providerPlan = SelectorBenchmarkPlan.make(selector: selector, snapshot: response, benchmarkURL: url, timeout: 5)
        let reused = providerPlan.reusableMeasurements(group: group, candidateDelays: ["Leaf": 120], timeout: 5)
        XCTAssertEqual(reused.count, 1)
        XCTAssertEqual(reused.first?.key.providerName, "Other Subscription")
        XCTAssertEqual(reused.first?.key.endpoint, .provider)
    }

    func testProxyHistoryIsScopedToExactBenchmarkURL() throws {
        let firstURL = "https://first.example.test/generate_204"
        let secondURL = "https://second.example.test/generate_204"
        let response = snapshot([
            [
                "name": "Node",
                "type": "Hysteria2",
                "alive": true,
                "history": [
                    ["time": "2026-08-17T10:00:00.000+0000", "delay": 999]
                ],
                "extra": [
                    firstURL: [
                        "alive": true,
                        "history": [
                            ["time": "2026-08-17T10:01:00.000+0000", "delay": 120]
                        ]
                    ],
                    secondURL: [
                        "alive": false,
                        "history": [
                            ["time": "2026-08-17T10:02:00.000+0000", "delay": 0]
                        ]
                    ]
                ]
            ]
        ])
        let proxy = try XCTUnwrap(response.proxiesMap["Node"])

        XCTAssertEqual(proxy.history.last?.delay, 999)
        XCTAssertEqual(proxy.testState(for: "  \(firstURL)  ")?.history.last?.delay, 120)
        XCTAssertEqual(proxy.testState(for: secondURL)?.history.last?.delay, 0)
        XCTAssertEqual(proxy.testState(for: secondURL)?.alive, false)
        XCTAssertNil(proxy.testState(for: "https://unknown.example.test/generate_204"))
    }

    func testGlobalLeafPresentationFillsSelectorURLGapAfterRefresh() throws {
        let globalURL = "https://global.example.test/generate_204"
        let selectorURL = "https://selector.example.test/generate_204"
        let response = snapshot([
            [
                "name": "All Nodes",
                "type": "Selector",
                "all": ["Provider Node"],
                "now": "Provider Node",
                "history": [],
                "testUrl": selectorURL
            ],
            [
                "name": "Provider Node",
                "type": "Vless",
                "history": [],
                "extra": [
                    globalURL: [
                        "alive": true,
                        "history": [
                            ["time": "2026-09-03T09:17:32.000+0000", "delay": 118]
                        ]
                    ]
                ]
            ]
        ])
        let proxy = try XCTUnwrap(response.proxiesMap["Provider Node"])
        let publishedAt = Date(timeIntervalSince1970: 1_788_427_852)
        let presentation = GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: proxy),
            benchmarkURL: globalURL,
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: proxy.name, delay: 118),
            publishedAt: publishedAt
        )

        XCTAssertNil(proxy.testState(for: selectorURL))
        XCTAssertEqual(
            presentation.reconciled(
                with: proxy,
                now: publishedAt.addingTimeInterval(1)
            )?.rowState.rawDelay,
            118
        )
        XCTAssertTrue(presentation.isNewer(than: proxy.testState(for: selectorURL)))
    }

    func testGlobalLeafPresentationYieldsToNewerSelectorEvidenceAndRejectsWrongIdentity() throws {
        let selectorURL = "https://selector.example.test/generate_204"
        let response = snapshot([
            [
                "name": "Node",
                "type": "Vless",
                "history": [],
                "extra": [
                    selectorURL: [
                        "alive": true,
                        "history": [
                            ["time": "2026-09-03T09:20:00.000+0000", "delay": 95]
                        ]
                    ]
                ]
            ]
        ])
        let proxy = try XCTUnwrap(response.proxiesMap["Node"])
        let selectorState = try XCTUnwrap(proxy.testState(for: selectorURL))
        let selectorMeasurementTime = try XCTUnwrap(selectorState.history.last?.time)
        let presentation = GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: proxy),
            benchmarkURL: "https://global.example.test/generate_204",
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: proxy.name, delay: 118),
            publishedAt: selectorMeasurementTime.addingTimeInterval(-1)
        )

        XCTAssertFalse(presentation.isNewer(than: selectorState))

        let wrongProviderPresentation = GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(
                endpoint: .provider,
                providerName: "Different Provider",
                proxyName: proxy.name
            ),
            benchmarkURL: selectorURL,
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: proxy.name, delay: 72),
            publishedAt: selectorMeasurementTime
        )
        XCTAssertNil(wrongProviderPresentation.reconciled(
            with: proxy,
            now: selectorMeasurementTime
        ))
    }

    func testEffectiveBenchmarkURLUsesExplicitNonEmptyValue() throws {
        let response = snapshot([
            [
                "name": "Explicit",
                "type": "URLTest",
                "history": [],
                "url": "unused",
                "testUrl": "  https://group.example.test/generate_204  "
            ],
            [
                "name": "Fallback",
                "type": "Selector",
                "history": [],
                "testUrl": "   "
            ]
        ])

        XCTAssertEqual(
            try XCTUnwrap(response.proxiesMap["Explicit"]).effectiveBenchmarkURL(
                fallback: "https://fallback.example.test"
            ),
            "https://group.example.test/generate_204"
        )
        XCTAssertEqual(
            try XCTUnwrap(response.proxiesMap["Fallback"]).effectiveBenchmarkURL(
                fallback: "https://fallback.example.test"
            ),
            "https://fallback.example.test"
        )
    }

    func testSelectorPresentationRejectsChangedPathOrBenchmarkURL() {
        let original = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Automatic"], "now": "Automatic", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Leaf A", "Leaf B"], "now": "Leaf A", "history": []],
            ["name": "Leaf A", "type": "Hysteria2", "history": []],
            ["name": "Leaf B", "type": "Hysteria2", "history": []]
        ])
        let presentation = SelectorBenchmarkPresentation(
            selectorName: "Selector",
            rowName: "Automatic",
            resolvedLeafName: "Leaf A",
            benchmarkURL: "https://benchmark.example.test",
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Automatic", delay: 241)
        )

        XCTAssertEqual(
            presentation.reconciled(
                with: original,
                currentBenchmarkURL: "https://benchmark.example.test"
            ).rowState.rawDelay,
            241
        )

        let changedPath = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Automatic"], "now": "Automatic", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Leaf A", "Leaf B"], "now": "Leaf B", "history": []],
            ["name": "Leaf A", "type": "Hysteria2", "history": []],
            ["name": "Leaf B", "type": "Hysteria2", "history": []]
        ])
        XCTAssertNil(
            presentation.reconciled(
                with: changedPath,
                currentBenchmarkURL: "https://benchmark.example.test"
            ).rowState.rawDelay
        )
        XCTAssertNil(
            presentation.reconciled(
                with: original,
                currentBenchmarkURL: "https://changed.example.test"
            ).rowState.rawDelay
        )
    }

    func testSelectorPresentationRejectsAutomaticGroupsDifferentURL() {
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Automatic"], "now": "Automatic", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Leaf"], "now": "Leaf", "history": [], "testUrl": "https://automatic.example.test"],
            ["name": "Leaf", "type": "Vless", "history": []]
        ])
        let presentation = SelectorBenchmarkPresentation(
            selectorName: "Selector",
            rowName: "Automatic",
            resolvedLeafName: "Leaf",
            benchmarkURL: "https://automatic.example.test",
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Automatic", delay: 210)
        )

        XCTAssertNil(
            presentation.reconciled(
                with: response,
                currentBenchmarkURL: "https://selector.example.test"
            ).rowState.rawDelay
        )
    }

    func testOldLeafAndAutomaticMeasurementsRemainAvailableOnlyForMatchingIdentity() throws {
        let url = "https://benchmark.example.test"
        let response = snapshot([
            ["name": "Auto", "type": "URLTest", "all": ["Leaf"], "now": "Leaf", "testUrl": url, "history": []],
            ["name": "Leaf", "type": "Vless", "history": []],
            ["name": "Other", "type": "Vless", "history": []]
        ])
        let leaf = try XCTUnwrap(response.proxiesMap["Leaf"])
        let group = try XCTUnwrap(response.proxiesMap["Auto"])
        let date = Date(timeIntervalSinceNow: -(48 * 60 * 60))
        let measurement = GlobalLeafBenchmarkPresentation(
            identity: LeafProxyBenchmarkIdentity(proxy: leaf), benchmarkURL: url,
            sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf", delay: 90), publishedAt: date
        )
        XCTAssertEqual(measurement.reconciled(with: leaf)?.rowState.rawDelay, 90)
        XCTAssertNil(try measurement.reconciled(with: XCTUnwrap(response.proxiesMap["Other"])))
        let child = AutomaticGroupChildBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(group: group, fallbackBenchmarkURL: url),
            rowName: "Leaf", sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Leaf", delay: 90), publishedAt: date
        )
        XCTAssertEqual(child.reconciled(group: group, fallbackBenchmarkURL: url)?.rowState.rawDelay, 90)
        let changed = snapshot([
            ["name": "Auto", "type": "URLTest", "all": ["Other"], "now": "Other", "testUrl": url, "history": []]
        ])
        XCTAssertNil(try child.reconciled(group: XCTUnwrap(changed.proxiesMap["Auto"]), fallbackBenchmarkURL: url))
    }

    func testSelectorPresentationRetainsLastMeasurementAfterOneDay() {
        let response = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Leaf"], "now": "Leaf", "history": []],
            ["name": "Leaf", "type": "Vless", "history": []]
        ])
        let stale = SelectorBenchmarkPresentation(
            selectorName: "Selector",
            rowName: "Leaf",
            resolvedLeafName: "Leaf",
            benchmarkURL: "https://benchmark.example.test",
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Leaf", delay: 90),
            publishedAt: Date(timeIntervalSinceNow: -(31 * 60))
        )
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(
            stale.reconciled(
                with: response,
                currentBenchmarkURL: "https://benchmark.example.test"
            ).rowState.rawDelay,
            90
        )

        let expired = SelectorBenchmarkPresentation(
            selectorName: "Selector",
            rowName: "Leaf",
            resolvedLeafName: "Leaf",
            benchmarkURL: "https://benchmark.example.test",
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Leaf", delay: 90),
            publishedAt: Date(timeIntervalSinceNow: -(25 * 60 * 60))
        )
        XCTAssertEqual(
            expired.reconciled(
                with: response,
                currentBenchmarkURL: "https://benchmark.example.test"
            ).rowState.rawDelay,
            90
        )
    }

    func testAutomaticSnapshotsMapOnlyFreshPathEvidence() {
        let response = snapshot([
            ["name": "Automatic", "type": "URLTest", "all": ["Final", "LowerSibling"], "now": "Final", "history": []],
            ["name": "Final", "type": "Direct", "history": []],
            ["name": "LowerSibling", "type": "Direct", "history": []]
        ])
        let measured = AutomaticGroupRetestSnapshot.make(
            groupName: "Automatic",
            candidateDelays: ["Final": 50, "LowerSibling": 1],
            snapshot: response
        )
        XCTAssertEqual(measured.finalLeaf, "Final")
        guard case let .measured(delay) = measured.evidence else {
            return XCTFail("expected fresh final evidence")
        }
        XCTAssertEqual(delay, 50)

        let noMatchingCandidate = AutomaticGroupRetestSnapshot.make(
            groupName: "Automatic",
            candidateDelays: ["LowerSibling": 1],
            snapshot: response
        )
        guard case .noMatchingCandidate = noMatchingCandidate.evidence else {
            return XCTFail("expected noMatchingCandidate")
        }

        let zeroDelay = AutomaticGroupRetestSnapshot.make(
            groupName: "Automatic",
            candidateDelays: ["Final": 0],
            snapshot: response
        )
        guard case let .zeroDelay(node) = zeroDelay.evidence else {
            return XCTFail("expected zeroDelay")
        }
        XCTAssertEqual(node, "Final")
    }

    func testAutomaticChildPresentationRejectsMembershipURLAndStatusChanges() throws {
        let original = snapshot([
            [
                "name": "Automatic",
                "type": "URLTest",
                "all": ["Leaf A", "Leaf B"],
                "now": "Leaf A",
                "history": [],
                "testUrl": "https://group.example.test",
                "expectedStatus": "204",
            ],
            ["name": "Leaf A", "type": "Vless", "history": []],
            ["name": "Leaf B", "type": "Vless", "history": []],
        ])
        let originalGroup = try XCTUnwrap(original.proxiesMap["Automatic"])
        let presentation = AutomaticGroupChildBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(
                group: originalGroup,
                fallbackBenchmarkURL: "https://fallback.example.test"
            ),
            rowName: "Leaf A",
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Leaf A", delay: 87)
        )
        XCTAssertNotNil(presentation.reconciled(
            group: originalGroup,
            fallbackBenchmarkURL: "https://fallback.example.test"
        ))

        let membershipChanged = snapshot([
            [
                "name": "Automatic",
                "type": "URLTest",
                "all": ["Leaf B"],
                "now": "Leaf B",
                "history": [],
                "testUrl": "https://group.example.test",
                "expectedStatus": "204",
            ],
            ["name": "Leaf B", "type": "Vless", "history": []],
        ])
        XCTAssertNil(try presentation.reconciled(
            group: XCTUnwrap(membershipChanged.proxiesMap["Automatic"]),
            fallbackBenchmarkURL: "https://fallback.example.test"
        ))

        let benchmarkChanged = snapshot([
            [
                "name": "Automatic",
                "type": "URLTest",
                "all": ["Leaf A", "Leaf B"],
                "now": "Leaf A",
                "history": [],
                "testUrl": "https://changed.example.test",
                "expectedStatus": "200",
            ],
            ["name": "Leaf A", "type": "Vless", "history": []],
            ["name": "Leaf B", "type": "Vless", "history": []],
        ])
        XCTAssertNil(try presentation.reconciled(
            group: XCTUnwrap(benchmarkChanged.proxiesMap["Automatic"]),
            fallbackBenchmarkURL: "https://fallback.example.test"
        ))
    }

    func testAutomaticChildPresentationRetainsLastMeasurementAfterOneDay() throws {
        let response = snapshot([
            ["name": "Automatic", "type": "Fallback", "all": ["Leaf"], "now": "Leaf", "history": []],
            ["name": "Leaf", "type": "Vless", "history": []],
        ])
        let group = try XCTUnwrap(response.proxiesMap["Automatic"])
        let presentation = AutomaticGroupChildBenchmarkPresentation(
            identity: AutomaticGroupBenchmarkIdentity(
                group: group,
                fallbackBenchmarkURL: "https://fallback.example.test"
            ),
            rowName: "Leaf",
            sessionIdentifier: UUID(),
            rowState: .measured(displayName: "Leaf", delay: 120),
            publishedAt: Date(timeIntervalSinceNow: -(25 * 60 * 60))
        )
        XCTAssertEqual(presentation.reconciled(
            group: group,
            fallbackBenchmarkURL: "https://fallback.example.test"
        )?.rowState.rawDelay, 120)
    }

    func testCancelTerminatesObserversOnceAndRejectsObsoleteGeneration() {
        let session = IsolatedBenchmarkSession()
        var terminationCount = 0
        session.onTermination { terminationCount += 1 }
        session.cancel()
        session.cancel()
        session.terminate()
        XCTAssertTrue(session.isCancelled)
        XCTAssertEqual(terminationCount, 1)

        var ownership = IsolatedBenchmarkOwnership()
        let obsoleteSession = ownership.begin()
        let replacementSession = ownership.begin()
        XCTAssertFalse(ownership.finish(obsoleteSession))
        XCTAssertEqual(ownership.activeGeneration, replacementSession)
        XCTAssertTrue(ownership.finish(replacementSession))
        XCTAssertNil(ownership.activeGeneration)
    }
}

final class BenchmarkEvidenceFlowTests: XCTestCase {
    private let url = "https://benchmark.example.test"

    private func snapshot(id: String = "node-v1", now: String = "Leaf") -> ClashProxyResp {
        let proxies: [String: Any] = [
            "Selector": ["name": "Selector", "type": "Selector", "all": ["Leaf", "Other"], "now": now, "history": []],
            "Leaf": ["name": "Leaf", "id": id, "type": "Vless", "history": []],
            "Other": ["name": "Other", "id": "other-v1", "type": "Vless", "history": []]
        ]
        return ClashProxyResp(try! JSONSerialization.data(withJSONObject: ["proxies": proxies]))
    }

    func testResponseClassificationNeverTurnsAPIErrorsIntoDeadNodes() {
        func decode(_ code: Int, _ body: String, failed: Bool = false) -> ProxyDelayOutcome {
            ProxyDelayOutcome.decode(statusCode: code, data: Data(body.utf8), transportFailed: failed)
        }
        XCTAssertEqual(decode(200, "{\"delay\":83}"), .measured(83))
        XCTAssertEqual(decode(200, "{\"delay\":0}"), .failed)
        for body in ["{}", "{\"delay\":true}", "{\"delay\":1.5}", "{\"delay\":-1}", "{\"delay\":\"83\"}", "not json"] {
            XCTAssertEqual(decode(200, body), .unavailable, body)
        }
        for code in [401, 403, 404, 429, 500, 502] {
            XCTAssertEqual(decode(code, "{\"message\":\"API unavailable\"}"), .unavailable)
        }
        XCTAssertEqual(decode(504, "<html>gateway timeout</html>"), .unavailable)
        XCTAssertEqual(decode(503, "{\"message\":\"upstream unavailable\"}"), .unavailable)
        XCTAssertEqual(decode(503, "{\"message\":\"An error occurred in the delay test\"}"), .failed)
        XCTAssertEqual(decode(504, "{\"message\":\"Timeout\"}"), .failed)
        XCTAssertEqual(decode(200, "{\"delay\":83}", failed: true), .unavailable)
        XCTAssertEqual(ProxyDelayOutcome.decode(statusCode: nil, data: nil, transportFailed: true, cancelled: true), .cancelled)
    }

    func testGroupDecoderDistinguishesEmptyMalformedAndActualAllFailed() {
        func decode(_ code: Int, _ body: String) -> ProxyGroupDelayOutcome {
            .decode(statusCode: code, data: Data(body.utf8), transportFailed: false)
        }
        XCTAssertFalse(decode(200, "{}").hasProbeEvidence)
        XCTAssertFalse(decode(200, "{\"Leaf\":\"bad\"}").hasProbeEvidence)
        XCTAssertFalse(decode(401, "{\"message\":\"Unauthorized\"}").hasProbeEvidence)
        XCTAssertTrue(decode(504, "{\"message\":\"get delay: all proxies timeout\"}").hasProbeEvidence)
        XCTAssertEqual(decode(200, "{\"Leaf\":90}").candidateDelays, ["Leaf": 90])
    }

    func testCacheSeparatesURLStatusAndNodeIdentityAndPrunesReplacements() throws {
        let original = snapshot()
        let node = try XCTUnwrap(original.proxiesMap["Leaf"])
        var cache = BenchmarkEvidenceCache()
        for (testURL, status, delay) in [(url, nil as String?, 90), (url + "/other", nil, 130), (url, "204", 150)] {
            cache.publish(GlobalLeafBenchmarkPresentation(
                identity: LeafProxyBenchmarkIdentity(proxy: node), benchmarkURL: testURL,
                expectedStatus: status, sessionIdentifier: UUID(), rowState: .measured(displayName: "Leaf", delay: delay)
            ))
        }
        XCTAssertEqual(cache.measurement(for: node, conditions: .init(url: url))?.rowState.rawDelay, 90)
        XCTAssertEqual(cache.measurement(for: node, conditions: .init(url: url + "/other"))?.rowState.rawDelay, 130)
        XCTAssertEqual(cache.measurement(for: node, conditions: .init(url: url, expectedStatus: "204"))?.rowState.rawDelay, 150)
        let replacement = snapshot(id: "node-v2")
        XCTAssertNil(try cache.measurement(for: XCTUnwrap(replacement.proxiesMap["Leaf"]), conditions: .init(url: url)))
        cache.prune(using: replacement)
        XCTAssertNil(cache.measurement(for: node, conditions: .init(url: url)))
    }

    func testProductionNotificationsAndRefreshResolveTheSameEvidence() {
        let finished = expectation(description: "production store notifications")
        DispatchQueue.main.async {
            let snapshot = self.snapshot()
            let node = snapshot.proxiesMap["Leaf"]!
            let conditions = BenchmarkConditions(url: self.url)
            let base = Date()
            GlobalLeafBenchmarkPresentationStore.clearAll()
            defer { GlobalLeafBenchmarkPresentationStore.clearAll() }
            func render() -> BenchmarkRowResolver.Presentation {
                let value = GlobalLeafBenchmarkPresentationStore.presentation(for: node, conditions: conditions)
                let attempt = GlobalLeafBenchmarkPresentationStore.attempt(for: node, conditions: conditions)
                return BenchmarkRowResolver.resolve(
                    name: "Leaf", core: nil,
                    cached: value.map { .init(state: $0.rowState, measuredAt: $0.publishedAt) }, contextual: nil,
                    activity: attempt.map { .init(state: $0.rowState, measuredAt: $0.publishedAt) }, now: base
                )
            }
            var notifications = [Int?]()
            let observer = NotificationCenter.default.addObserver(forName: .speedTestFinishForProxy, object: nil, queue: nil) { _ in
                notifications.append(render().state.rawDelay)
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            func publish(_ outcome: ProxyDelayOutcome, offset: Double, url: String? = nil) {
                GlobalLeafBenchmarkPresentationStore.publish(.init(
                    identity: LeafProxyBenchmarkIdentity(proxy: node), benchmarkURL: url ?? self.url,
                    sessionIdentifier: UUID(), rowState: outcome.rowState(name: "Leaf"),
                    publishedAt: base.addingTimeInterval(offset)
                ))
            }
            publish(.measured(90), offset: 0)
            publish(.measured(800), offset: 1, url: self.url + "/other")
            publish(.decode(statusCode: 401, data: Data("{\"message\":\"Unauthorized\"}".utf8), transportFailed: false), offset: 2)
            XCTAssertEqual(render().state.rawDelay, 90)
            XCTAssertTrue(render().isHistorical)
            XCTAssertTrue(render().lastAttemptUnavailable)
            publish(.failed, offset: 3)
            XCTAssertEqual(render().state.rawDelay, 0)
            XCTAssertFalse(render().isHistorical)
            // A delayed old result cannot overwrite a newer failed probe.
            publish(.measured(50), offset: -1)
            XCTAssertEqual(notifications, [90, 90, 90, 0, 0])
            XCTAssertEqual(render().state.rawDelay, notifications.last!)
            XCTAssertEqual(snapshot.proxiesMap["Selector"]?.now, "Leaf")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testLatestFailureWinsAndOldResultsAreExplicitlyHistorical() throws {
        let base = Date()
        let data = Data("{\"alive\":false,\"history\":[{\"time\":\"2026-09-19T12:00:00.000+0000\",\"delay\":0}]}".utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(DateFormatter.js)
        let core = try decoder.decode(ClashProxyTestState.self, from: data)
        let result = BenchmarkRowResolver.resolve(name: "Leaf", core: core,
                                                  cached: .init(state: .measured(displayName: "Leaf", delay: 90), measuredAt: core.history[0].time.addingTimeInterval(-10)),
                                                  contextual: nil, activity: nil, now: core.history[0].time)
        XCTAssertEqual(result.state.rawDelay, 0)
        let old = BenchmarkRowResolver.resolve(name: "Leaf", core: nil,
                                               cached: .init(state: .measured(displayName: "Leaf", delay: 90), measuredAt: base.addingTimeInterval(-48 * 3600)),
                                               contextual: nil, activity: nil, now: base)
        XCTAssertEqual(old.state.rawDelay, 90)
        XCTAssertTrue(old.isHistorical)
    }

    func testSelectorEvidenceRejectsSameNameReplacementAndChangedPath() throws {
        let original = snapshot()
        let plan = try SelectorBenchmarkPlan.make(selector: XCTUnwrap(original.proxiesMap["Selector"]), snapshot: original, benchmarkURL: url, timeout: 5000)
        XCTAssertEqual(plan.targets.first?.key.coreID, "node-v1")
        let presentation = SelectorBenchmarkPresentation(selectorName: "Selector", rowName: "Selector",
                                                         resolvedLeafName: "Leaf", resolvedCoreID: "node-v1", benchmarkURL: url,
                                                         sessionIdentifier: UUID(), rowState: .measured(displayName: "Selector", delay: 90))
        XCTAssertEqual(presentation.reconciled(with: original, currentBenchmarkURL: url).rowState.rawDelay, 90)
        XCTAssertNil(presentation.reconciled(with: snapshot(id: "node-v2"), currentBenchmarkURL: url).rowState.rawDelay)
        XCTAssertNil(presentation.reconciled(with: snapshot(now: "Other"), currentBenchmarkURL: url).rowState.rawDelay)
    }

    func testProductionExecutorDropsCancelledAndDuplicateLateCallbacks() throws {
        let snapshot = snapshot()
        let plan = try SelectorBenchmarkPlan.make(selector: XCTUnwrap(snapshot.proxiesMap["Selector"]), snapshot: snapshot,
                                                  benchmarkURL: url, timeout: 5000)
        let started = expectation(description: "requests started")
        started.expectedFulfillmentCount = plan.targets.count
        let completed = expectation(description: "cancelled executor settled")
        let lock = NSLock()
        var cancelled = false
        var callbacks = [(ProxyDelayOutcome) -> Void]()
        var published = 0
        SelectorBenchmarkExecutor.runOutcomes(plan: plan, isCancelled: {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }, request: { _, callback in
            lock.lock()
            callbacks.append(callback)
            lock.unlock()
            started.fulfill()
        }, result: { _, _ in
            lock.lock(); defer { lock.unlock() }
            published += 1
        }, completion: { completed.fulfill() })
        wait(for: [started], timeout: 2)
        lock.lock()
        cancelled = true
        let pending = callbacks
        lock.unlock()
        for callback in pending {
            callback(.unavailable)
            callback(.measured(90))
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(published, 0)
    }
}

final class ProxyMenuRefreshPolicyTests: XCTestCase {
    private func snapshot(_ proxyJSON: [[String: Any]]) -> ClashProxyResp {
        let proxies = Dictionary(uniqueKeysWithValues: proxyJSON.compactMap { proxy -> (String, Any)? in
            guard let name = proxy["name"] as? String else { return nil }
            return (name, proxy)
        })
        let data = try! JSONSerialization.data(withJSONObject: ["proxies": proxies])
        return ClashProxyResp(data)
    }

    func testIncrementalRefreshesAreSingleFlightAndThrottledAfterCompletion() throws {
        var coordinator = ProxyMenuRefreshCoordinator(minimumIncrementalInterval: 1)
        let start = Date(timeIntervalSince1970: 100)

        let first = try XCTUnwrap(coordinator.request(.incremental, now: start))
        XCTAssertNil(coordinator.request(.incremental, now: start.addingTimeInterval(0.1)))

        let completion = coordinator.complete(first, now: start.addingTimeInterval(0.2))
        XCTAssertTrue(completion.shouldApply)
        XCTAssertNil(completion.nextTicket)
        XCTAssertNil(coordinator.request(.incremental, now: start.addingTimeInterval(1.1)))
        XCTAssertNotNil(coordinator.request(.incremental, now: start.addingTimeInterval(1.3)))
    }

    func testProxyMenuPreparationCanBeginOnlyOnce() {
        var state = ProxyMenuPreparationState()

        XCTAssertFalse(state.isPrepared)
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.isPrepared)
        XCTAssertFalse(state.begin())
    }

    func testRebuildInvalidatesIncrementalResultAndRunsAfterItSettles() throws {
        var coordinator = ProxyMenuRefreshCoordinator(minimumIncrementalInterval: 1)
        let start = Date(timeIntervalSince1970: 100)
        let incremental = try XCTUnwrap(coordinator.request(.incremental, now: start))

        XCTAssertNil(coordinator.request(.rebuild, now: start.addingTimeInterval(0.1)))
        let staleCompletion = coordinator.complete(incremental, now: start.addingTimeInterval(0.2))
        XCTAssertFalse(staleCompletion.shouldApply)

        let rebuild = try XCTUnwrap(staleCompletion.nextTicket)
        XCTAssertEqual(rebuild.mode, .rebuild)
        XCTAssertGreaterThan(rebuild.generation, incremental.generation)
        XCTAssertTrue(coordinator.complete(rebuild, now: start.addingTimeInterval(0.3)).shouldApply)
    }

    func testRepeatedRebuildsCollapseToLatestGeneration() throws {
        var coordinator = ProxyMenuRefreshCoordinator()
        let first = try XCTUnwrap(coordinator.request(.rebuild))
        XCTAssertNil(coordinator.request(.rebuild))
        XCTAssertNil(coordinator.request(.rebuild))

        let staleCompletion = coordinator.complete(first)
        XCTAssertFalse(staleCompletion.shouldApply)
        let latest = try XCTUnwrap(staleCompletion.nextTicket)
        XCTAssertEqual(latest.generation, first.generation + 2)
        XCTAssertTrue(coordinator.complete(latest).shouldApply)
    }

    func testStructureSignatureDetectsMembershipAndBenchmarkChanges() {
        let original = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Leaf"], "now": "Leaf", "history": [], "testUrl": "https://one.example"],
            ["name": "Leaf", "type": "Direct", "history": []]
        ])
        let changed = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Leaf", "Other"], "now": "Leaf", "history": [], "testUrl": "https://two.example"],
            ["name": "Leaf", "type": "Direct", "history": []],
            ["name": "Other", "type": "Direct", "history": []]
        ])

        XCTAssertNotEqual(
            ProxyMenuStructureSignature(snapshot: original),
            ProxyMenuStructureSignature(snapshot: changed)
        )
    }

    func testChangedLeafNotifiesEveryAffectedAncestorOnly() {
        let original = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Automatic", "Stable"], "now": "Automatic", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Leaf"], "now": "Leaf", "history": []],
            ["name": "Leaf", "type": "Vless", "alive": true, "history": []],
            ["name": "Stable", "type": "Direct", "alive": true, "history": []]
        ])
        let current = snapshot([
            ["name": "Selector", "type": "Selector", "all": ["Automatic", "Stable"], "now": "Automatic", "history": []],
            ["name": "Automatic", "type": "URLTest", "all": ["Leaf"], "now": "Leaf", "history": []],
            ["name": "Leaf", "type": "Vless", "alive": false, "history": []],
            ["name": "Stable", "type": "Direct", "alive": true, "history": []]
        ])

        XCTAssertEqual(
            ProxyMenuSnapshotDelta.affectedNames(previous: original, current: current),
            Set(["Leaf", "Automatic", "Selector"])
        )
        XCTAssertTrue(ProxyMenuSnapshotDelta.affectedNames(previous: current, current: current).isEmpty)
    }
}

final class SubscriptionStatusPresentationTests: XCTestCase {
    private func renderedWidth(_ text: String, font: NSFont) -> CGFloat {
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    func testShortStatusTextIsPreserved() {
        let font = NSFont.menuFont(ofSize: 0)
        XCTAssertEqual(
            SubscriptionInfoFormatter.truncatedMenuText("My Subscription", font: font),
            "My Subscription"
        )
    }

    func testLongASCIIChineseAndEmojiTextFitsStatusLineWidth() {
        let font = NSFont.menuFont(ofSize: 0)
        let samples = [
            String(repeating: "subscription-name-", count: 12),
            String(repeating: "这是一个非常长的订阅名称", count: 12),
            String(repeating: "全球节点🚀🌏", count: 16),
        ]

        for sample in samples {
            let result = SubscriptionInfoFormatter.truncatedMenuText(sample, font: font)
            XCTAssertTrue(result.hasSuffix("…"), result)
            XCTAssertLessThanOrEqual(
                renderedWidth(result, font: font),
                SubscriptionInfoFormatter.maximumStatusLineWidth + 0.5
            )
        }
    }

    func testStatusRowBoundsBothLinesAndTooltipKeepsFullText() {
        let name = String(repeating: "Very Long Subscription Name ", count: 10)
        let summary = String(repeating: "123.45 GB / 999.99 GB used · 365 days left ", count: 8)
        let title = SubscriptionInfoFormatter.statusRowAttributedTitle(name: name, summary: summary)
        let lines = title.string.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 2)
        XCTAssertLessThanOrEqual(
            renderedWidth(lines[0], font: NSFont.menuFont(ofSize: 0)),
            SubscriptionInfoFormatter.maximumStatusLineWidth + 0.5
        )
        XCTAssertLessThanOrEqual(
            renderedWidth(lines[1], font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)),
            SubscriptionInfoFormatter.maximumStatusLineWidth + 0.5
        )
        XCTAssertEqual(
            SubscriptionInfoFormatter.statusRowTooltip(name: name, summary: summary),
            "\(name.trimmingCharacters(in: .whitespacesAndNewlines))\n\(summary)"
        )
    }

    func testSubscriptionVisibilityPreferenceDefaultsOnAndPersistsOff() throws {
        let suiteName = "SubscriptionStatusPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preference = UserDefault(
            "trayMenuShowSubscriptionInfo",
            defaultValue: true,
            userDefaults: defaults
        )
        XCTAssertTrue(preference.wrappedValue)
        preference.wrappedValue = false
        XCTAssertFalse(preference.wrappedValue)
    }
}

final class CoreLogGuardTests: XCTestCase {
    private let badFileDescriptorMessage = "batch read packet: bad file descriptor"

    func testDarwinClosedTunErrorsRequestImmediateRecovery() {
        let messages = [
            "batch read packet: socket operation on non-socket",
            badFileDescriptorMessage
        ]

        for (index, message) in messages.enumerated() {
            let logGuard = CoreLogGuard()
            let decision = logGuard.process(
                message: message,
                level: .error,
                now: Date(timeIntervalSince1970: TimeInterval(100 + index))
            )
            guard case .closedTunSocket? = decision.recoveryReason else {
                return XCTFail("Expected closed-TUN recovery for \(message)")
            }
        }
    }

    func testBadFileDescriptorFloodIsBoundedAcrossInterleavedMessages() {
        let logGuard = CoreLogGuard()
        let baseTime = Date(timeIntervalSince1970: 100)
        var fatalEntries = 0

        for index in 0 ..< 100 {
            let now = baseTime.addingTimeInterval(TimeInterval(index) / 1_000)
            let fatalDecision = logGuard.process(
                message: badFileDescriptorMessage,
                level: .error,
                now: now
            )
            fatalEntries += fatalDecision.entries.filter {
                $0.0 == badFileDescriptorMessage
            }.count
            _ = logGuard.process(
                message: "[TCP] unrelated log \(index)",
                level: .info,
                now: now
            )
        }

        XCTAssertEqual(fatalEntries, 3)

        let nextDecision = logGuard.process(
            message: badFileDescriptorMessage,
            level: .error,
            now: baseTime.addingTimeInterval(1.1)
        )
        XCTAssertTrue(nextDecision.entries.contains {
            $0.0.contains("Suppressed 97 closed TUN read failures entries")
        })
    }
}

final class StartupProxyRecoveryPolicyTests: XCTestCase {
    private func cpuSample(
        launchID: String = "launch-a",
        processIdentifier: Int = 42,
        cpuTime: TimeInterval,
        uptime: TimeInterval
    ) -> CoreCPUWatchdogSample {
        CoreCPUWatchdogSample(
            launchID: launchID,
            processIdentifier: processIdentifier,
            cpuTime: cpuTime,
            sampleUptime: uptime
        )
    }

    private func observation(
        wantsSystemProxy: Bool = true,
        proxyPaused: Bool = false,
        enhancedModeActive: Bool = false,
        initialConfigLoaded: Bool = true,
        coreRunning: Bool = true,
        httpPort: Int = 7890,
        socksPort: Int = 7891,
        helperReady: Bool = true,
        primaryInterfaceReady: Bool = true
    ) -> StartupProxyRecoveryObservation {
        StartupProxyRecoveryObservation(
            wantsSystemProxy: wantsSystemProxy,
            proxyPaused: proxyPaused,
            enhancedModeActive: enhancedModeActive,
            initialConfigLoaded: initialConfigLoaded,
            coreRunning: coreRunning,
            httpPort: httpPort,
            socksPort: socksPort,
            helperReady: helperReady,
            primaryInterfaceReady: primaryInterfaceReady
        )
    }

    func testRecoveryStopsWhenSystemProxyIsNoLongerDesired() {
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(wantsSystemProxy: false)),
            .stop
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(proxyPaused: true)),
            .stop
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(enhancedModeActive: true)),
            .stop
        )
    }

    func testRecoveryWaitsForEveryStartupPrerequisite() {
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(initialConfigLoaded: false)),
            .waitForConfig
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(httpPort: 0)),
            .waitForConfig
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(coreRunning: false)),
            .waitForCore
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(helperReady: false)),
            .waitForHelper
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation(primaryInterfaceReady: false)),
            .waitForNetwork
        )
        XCTAssertEqual(
            StartupProxyRecoveryPolicy.decide(observation()),
            .verifyAndApply
        )
    }

    func testInconclusiveDataPlaneProbePreservesFailureEvidence() {
        XCTAssertEqual(
            RuntimeDataPlaneFailurePolicy.nextFailureCount(
                current: 2,
                outcome: .baselineUnavailable
            ),
            2
        )
        XCTAssertEqual(
            RuntimeDataPlaneFailurePolicy.nextFailureCount(
                current: 2,
                outcome: .healthy
            ),
            0
        )
        XCTAssertEqual(
            RuntimeDataPlaneFailurePolicy.nextFailureCount(
                current: 2,
                outcome: .confirmedCoreFailure
            ),
            3
        )
    }

    func testCoreCPUWatchdogCapturesThenRecoversAfterSustainedSingleCoreLoad() {
        var policy = CoreCPUWatchdogPolicy(
            utilizationThreshold: 0.9,
            diagnosticSampleCount: 2,
            recoverySampleCount: 3,
            maximumSampleInterval: 20
        )

        XCTAssertEqual(
            policy.observe(cpuSample(cpuTime: 10, uptime: 100)),
            .baseline
        )
        XCTAssertEqual(
            policy.observe(cpuSample(cpuTime: 19.5, uptime: 110)),
            .elevated(utilization: 0.95, consecutiveSamples: 1)
        )
        XCTAssertEqual(
            policy.observe(cpuSample(cpuTime: 29, uptime: 120)),
            .captureDiagnostic(utilization: 0.95, consecutiveSamples: 2)
        )
        XCTAssertEqual(
            policy.observe(cpuSample(cpuTime: 38.5, uptime: 130)),
            .recover(utilization: 0.95, consecutiveSamples: 3)
        )
    }

    func testCoreCPUWatchdogResetsOnNormalLoadCoreReplacementAndLongGap() {
        var policy = CoreCPUWatchdogPolicy(
            utilizationThreshold: 0.9,
            diagnosticSampleCount: 2,
            recoverySampleCount: 3,
            maximumSampleInterval: 20
        )

        XCTAssertEqual(policy.observe(cpuSample(cpuTime: 0, uptime: 0)), .baseline)
        XCTAssertEqual(
            policy.observe(cpuSample(cpuTime: 9.5, uptime: 10)),
            .elevated(utilization: 0.95, consecutiveSamples: 1)
        )
        XCTAssertEqual(
            policy.observe(cpuSample(cpuTime: 10.5, uptime: 20)),
            .normal(utilization: 0.1)
        )
        XCTAssertEqual(
            policy.observe(cpuSample(
                launchID: "launch-b",
                processIdentifier: 84,
                cpuTime: 2,
                uptime: 30
            )),
            .baseline
        )
        XCTAssertEqual(
            policy.observe(cpuSample(
                launchID: "launch-b",
                processIdentifier: 84,
                cpuTime: 40,
                uptime: 70
            )),
            .baseline
        )
    }

    func testCoreCPUWatchdogRejectsInvalidTelemetry() {
        var policy = CoreCPUWatchdogPolicy()

        XCTAssertEqual(
            policy.observe(cpuSample(cpuTime: .infinity, uptime: 100)),
            .invalid
        )
        XCTAssertEqual(
            policy.observe(cpuSample(cpuTime: 1, uptime: -1)),
            .invalid
        )
        XCTAssertEqual(
            policy.observe(cpuSample(cpuTime: 1, uptime: 100)),
            .baseline
        )
    }

    func testWakeRetryBackoffIsBounded() {
        XCTAssertEqual(
            WakeRecoveryRetryPolicy.delay(
                baseDelay: 2,
                maximumAttempts: 3,
                attemptsLeft: 3
            ),
            2
        )
        XCTAssertEqual(
            WakeRecoveryRetryPolicy.delay(
                baseDelay: 2,
                maximumAttempts: 3,
                attemptsLeft: 2
            ),
            4
        )
        XCTAssertEqual(
            WakeRecoveryRetryPolicy.delay(
                baseDelay: 2,
                maximumAttempts: 9,
                attemptsLeft: 1
            ),
            8
        )
    }

    func testAutomaticPortDisplaysRuntimeOnlyAsPlaceholder() {
        XCTAssertEqual(PortPreferencePolicy.editableText(configuredPort: 0), "")
        XCTAssertEqual(PortPreferencePolicy.editableText(configuredPort: 7890), "7890")
        XCTAssertEqual(PortPreferencePolicy.configuredPort(from: ""), 0)
        XCTAssertEqual(PortPreferencePolicy.configuredPort(from: " 9090 "), 9090)
        XCTAssertNil(PortPreferencePolicy.configuredPort(from: "70000"))
        XCTAssertNil(PortPreferencePolicy.configuredPort(from: "not-a-port"))
        XCTAssertNil(
            PortPreferencePolicy.runtimeFallback(
                configuredPort: 7890,
                runtimePort: 7890
            )
        )
        let fallback = PortPreferencePolicy.runtimeFallback(
            configuredPort: 7890,
            runtimePort: 23456
        )
        XCTAssertEqual(fallback?.configured, 7890)
        XCTAssertEqual(fallback?.runtime, 23456)
    }
}

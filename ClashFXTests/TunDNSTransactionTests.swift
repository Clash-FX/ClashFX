import Darwin
import Foundation
import XCTest

final class TunDNSTransactionTests: XCTestCase {
    private final class LoopbackDNSResponder {
        let descriptor: Int32
        let type: Int32
        let port: Int

        init?(family: Int32, type: Int32) {
            let descriptor = socket(family, type, 0)
            guard descriptor >= 0 else { return nil }
            var port: Int?

            if family == AF_INET {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bound == 0 else { close(descriptor); return nil }
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let named = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(descriptor, $0, &length)
                    }
                }
                guard named == 0 else { close(descriptor); return nil }
                port = Int(UInt16(bigEndian: address.sin_port))
            } else if family == AF_INET6 {
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                var loopback = in6_addr()
                guard inet_pton(AF_INET6, "::1", &loopback) == 1 else { close(descriptor); return nil }
                address.sin6_addr = loopback
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
                guard bound == 0 else { close(descriptor); return nil }
                var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                let named = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(descriptor, $0, &length)
                    }
                }
                guard named == 0 else { close(descriptor); return nil }
                port = Int(UInt16(bigEndian: address.sin6_port))
            } else {
                close(descriptor)
                return nil
            }

            if type == SOCK_STREAM, listen(descriptor, 1) != 0 {
                close(descriptor)
                return nil
            }
            guard let port else { close(descriptor); return nil }
            self.descriptor = descriptor
            self.type = type
            self.port = port
        }

        func respondOnce(then expectation: XCTestExpectation) {
            DispatchQueue.global().async {
                defer { expectation.fulfill() }
                var readiness = pollfd(fd: self.descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&readiness, 1, 1500) > 0 else { return }
                if self.type == SOCK_DGRAM {
                    self.respondToUDP()
                } else {
                    self.respondToTCP()
                }
            }
        }

        private func respondToUDP() {
            var packet = [UInt8](repeating: 0, count: 4096)
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = packet.withUnsafeMutableBytes { bytes -> Int in
                withUnsafeMutablePointer(to: &peer) { peerPointer in
                    peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Int(recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &peerLength))
                    }
                }
            }
            guard count > 0 else { return }
            let response = Self.dnsResponse(Array(packet.prefix(count)))
            response.withUnsafeBytes { bytes in
                withUnsafePointer(to: peer) { peerPointer in
                    peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, peerLength)
                    }
                }
            }
        }

        private func respondToTCP() {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            guard let prefix = readExactly(2, from: client) else { return }
            let length = (Int(prefix[0]) << 8) | Int(prefix[1])
            guard length >= 12, let query = readExactly(length, from: client) else { return }
            let response = Self.dnsResponse(query)
            let frame = [UInt8(response.count >> 8), UInt8(response.count & 0xff)] + response
            sendAll(frame, to: client)
        }

        private func readExactly(_ length: Int, from descriptor: Int32) -> [UInt8]? {
            var result = [UInt8]()
            while result.count < length {
                var chunk = [UInt8](repeating: 0, count: length - result.count)
                let count = chunk.withUnsafeMutableBytes { bytes in
                    recv(descriptor, bytes.baseAddress, bytes.count, 0)
                }
                if count > 0 {
                    result.append(contentsOf: chunk.prefix(count))
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return nil
                }
            }
            return result
        }

        private func sendAll(_ data: [UInt8], to descriptor: Int32) {
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var total = 0
                while total < bytes.count {
                    let count = send(descriptor, base.advanced(by: total), bytes.count - total, 0)
                    if count > 0 {
                        total += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }

        private static func dnsResponse(_ query: [UInt8]) -> [UInt8] {
            guard query.count >= 12 else { return query }
            var response = query
            response[2] = 0x81
            response[3] = 0x80
            return response
        }
    }

    private final class Fixture {
        var snapshot: [String: Any] = [:]
        var captured: [String: Any] = [
            "version": 2, "transactionID": "capture-1",
            "services": ["wifi": ["original": NSNull()]]
        ]
        var events = [String]()
        var canSave = true
        var saveDelay: TimeInterval = 0
        var clearDelayBeforeWrite: TimeInterval = 0
        var journalClearTimeout: TimeInterval = 1
        var loadRanOnMainThread: Bool?
        var saveRanOnMainThread: Bool?
        var applyError: String?
        var failPruningSave = false
        var restoreError: String?
        var flushError: String?
        var holdCapture = false
        var holdApply = false
        var holdRestore = false
        var dropFlushReply = false
        var captureReply: (([String: Any]) -> Void)?
        var applyReply: ((String?) -> Void)?
        var restoreReply: ((String?) -> Void)?
        var restoreSnapshot: [String: Any]?

        lazy var controller = TunDNSTransactionController(
            load: {
                self.loadRanOnMainThread = Thread.isMainThread
                return self.snapshot
            },
            save: { snapshot in
                self.saveRanOnMainThread = Thread.isMainThread
                self.events.append(snapshot.isEmpty ? "clear" : "persist")
                if snapshot.isEmpty && self.clearDelayBeforeWrite > 0 {
                    Thread.sleep(forTimeInterval: self.clearDelayBeforeWrite)
                }
                if self.canSave { self.snapshot = snapshot }
                if self.saveDelay > 0 { Thread.sleep(forTimeInterval: self.saveDelay) }
                return self.canSave
            },
            log: { _ in self.events.append("warning") },
            journalClearTimeout: self.journalClearTimeout
        )

        var client: TunDNSHelperClient {
            TunDNSHelperClient(
                capture: { _, reply in
                    self.events.append("capture")
                    self.captureReply = reply
                    if !self.holdCapture { reply(self.captured) }
                },
                apply: { _, _, reply in
                    self.events.append("apply")
                    if self.failPruningSave { self.canSave = false }
                    self.applyReply = reply
                    if !self.holdApply { reply(self.applyError) }
                },
                restore: { snapshot, reply in
                    self.events.append("restore")
                    self.restoreSnapshot = snapshot
                    self.restoreReply = reply
                    if !self.holdRestore { reply(self.restoreError) }
                },
                flush: { reply in
                    self.events.append("flush")
                    if !self.dropFlushReply { reply(self.flushError) }
                }
            )
        }

        func apply(client: TunDNSHelperClient? = nil, timeout: TimeInterval = 1,
                   isCurrent: @escaping () -> Bool = { true },
                   completion: @escaping (String?) -> Void) {
            controller.apply(client: client ?? self.client, servers: ["198.18.0.2"], filterInterface: true,
                             timeout: timeout, isCurrent: isCurrent, completion: completion)
        }
    }

    func testJournalIsPersistedBeforeApplyAndRetainedWhileActive() {
        let f = Fixture()
        let done = expectation(description: "applied")
        f.apply { error in
            XCTAssertNil(error)
            XCTAssertEqual(f.events, ["capture", "persist", "apply", "flush"])
            XCTAssertEqual(f.snapshot["transactionID"] as? String, "capture-1")
            let services = f.snapshot["services"] as? [String: [String: Any]]
            XCTAssertTrue(services?["wifi"]?["original"] is NSNull)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testPersistenceFailureNeverChangesSystemDNS() {
        let f = Fixture()
        f.canSave = false
        let done = expectation(description: "persistence rejected")
        f.apply { error in
            XCTAssertNotNil(error)
            XCTAssertEqual(f.events, ["capture", "persist"])
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testJournalIORunsOffMainAndCompletesOnMain() {
        let f = Fixture()
        let done = expectation(description: "background journal I/O")
        f.apply { error in
            XCTAssertNil(error)
            XCTAssertFalse(f.loadRanOnMainThread ?? true)
            XCTAssertFalse(f.saveRanOnMainThread ?? true)
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testSixtySixSuccessfulAppliesPruneConfirmedPredecessors() {
        let f = Fixture()
        let done = expectation(description: "repeated successful applies")
        var transactionIndex = 0

        func applyNext() {
            guard transactionIndex < 66 else {
                XCTAssertEqual(f.snapshot["transactionID"] as? String, "transaction-65")
                XCTAssertEqual(f.snapshot["previousTransactionIDs"] as? [String], [])
                XCTAssertEqual(f.events.filter { $0 == "apply" }.count, 66)
                done.fulfill()
                return
            }
            f.captured = [
                "version": 2,
                "transactionID": "transaction-\(transactionIndex)",
                "services": ["wifi": ["original": NSNull()]]
            ]
            f.apply { error in
                XCTAssertNil(error)
                transactionIndex += 1
                applyNext()
            }
        }

        applyNext()
        wait(for: [done], timeout: 10)
    }

    func testFailedPredecessorPruningRetainsLineageAndDoesNotFailApply() {
        let f = Fixture()
        f.captured = ["version": 2, "transactionID": "A", "services": ["wifi": ["original": NSNull()]]]
        let firstApply = expectation(description: "A applied")
        f.apply { error in
            XCTAssertNil(error)
            firstApply.fulfill()
        }
        wait(for: [firstApply], timeout: 2)

        f.captured = ["version": 2, "transactionID": "B", "services": ["wifi": ["original": NSNull()]]]
        f.failPruningSave = true
        let secondApply = expectation(description: "B applied with retained lineage")
        f.apply { error in
            XCTAssertNil(error)
            XCTAssertEqual(f.snapshot["transactionID"] as? String, "B")
            XCTAssertEqual(f.snapshot["previousTransactionIDs"] as? [String], ["A"])
            XCTAssertTrue(f.events.contains("warning"))
            secondApply.fulfill()
        }
        wait(for: [secondApply], timeout: 2)
    }

    func testPredecessorOverflowExplainsThatRecoveryIsPending() {
        let f = Fixture()
        f.snapshot = [
            "version": 2,
            "transactionID": "latest",
            "previousTransactionIDs": (0 ..< 64).map { "transaction-\($0)" },
            "services": ["wifi": ["original": NSNull()]]
        ]
        let done = expectation(description: "pending recovery reported")
        f.apply { error in
            XCTAssertTrue(error?.contains("pending predecessor transactions") ?? false)
            XCTAssertFalse(f.events.contains("persist"))
            XCTAssertFalse(f.events.contains("apply"))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testTimedOutRecaptureRetainsPredecessorForRecoveryWhenApplyWasNeverSent() {
        let f = Fixture()
        f.captured = ["version": 2, "transactionID": "A", "services": ["wifi": ["original": NSNull()]]]
        let firstApply = expectation(description: "A applied")
        f.apply { error in
            XCTAssertNil(error)
            firstApply.fulfill()
        }
        wait(for: [firstApply], timeout: 2)

        f.captured = ["version": 2, "transactionID": "B", "services": ["wifi": ["original": NSNull()]]]
        f.saveDelay = 0.08
        let applyTimedOutBeforeHelperDelivery = expectation(description: "B journal saved before apply timed out")
        f.apply(timeout: 0.02) { error in
            XCTAssertNotNil(error)
            XCTAssertEqual(f.snapshot["transactionID"] as? String, "B")
            XCTAssertEqual(f.snapshot["previousTransactionIDs"] as? [String], ["A"])
            XCTAssertEqual(f.events.filter { $0 == "apply" }.count, 1)
            applyTimedOutBeforeHelperDelivery.fulfill()
        }
        wait(for: [applyTimedOutBeforeHelperDelivery], timeout: 2)

        let recovered = expectation(description: "B restored using predecessor A")
        f.controller.restore(client: f.client, timeout: 1) { error in
            XCTAssertNil(error)
            XCTAssertEqual(f.restoreSnapshot?["transactionID"] as? String, "B")
            XCTAssertEqual(f.restoreSnapshot?["previousTransactionIDs"] as? [String], ["A"])
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 2)
    }

    func testApplyAndCacheFailureRetainRecoveryEvidence() {
        for error in ["commit failed", "cache failed"] {
            let f = Fixture()
            if error == "commit failed" { f.applyError = error } else { f.flushError = error }
            let done = expectation(description: error)
            f.apply { outcome in
                XCTAssertNotNil(outcome)
                XCTAssertFalse(f.snapshot.isEmpty)
                XCTAssertFalse(f.events.contains("clear"))
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testFailedRestoreKeepsJournalForNextLaunch() {
        let f = Fixture()
        f.snapshot = f.captured
        f.restoreError = "readback mismatch"
        let done = expectation(description: "failed restore")
        f.controller.restore(client: f.client, timeout: 1) { error in
            XCTAssertEqual(error, "readback mismatch")
            XCTAssertEqual(f.snapshot["transactionID"] as? String, "capture-1")
            XCTAssertEqual(f.events, ["restore"])
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testVerifiedRestoreClearsJournalAndReportsCacheFailureSeparately() {
        let f = Fixture()
        f.snapshot = f.captured
        f.flushError = "flush unavailable"
        let done = expectation(description: "restored")
        f.controller.restore(client: f.client, timeout: 1) { error in
            XCTAssertNil(error)
            XCTAssertTrue(f.snapshot.isEmpty)
            XCTAssertEqual(f.events, ["restore", "clear", "flush", "warning"])
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testDelayedJournalClearCannotEraseAQueuedNewerApply() {
        let f = Fixture()
        f.snapshot = f.captured
        f.clearDelayBeforeWrite = 0.3
        f.journalClearTimeout = 0.1
        let newerApply = expectation(description: "newer journal saved after delayed clear")
        f.controller.restore(client: f.client, timeout: 1) { error in
            XCTAssertEqual(error, "DNS restored, but recovery journal clear is still in progress")
            XCTAssertFalse(error?.contains("journal retained") ?? true)
            f.captured = [
                "version": 2,
                "transactionID": "newer-apply",
                "services": ["wifi": ["original": NSNull()]]
            ]
            f.apply { applyError in
                XCTAssertNil(applyError)
                XCTAssertEqual(f.snapshot["transactionID"] as? String, "newer-apply")
                XCTAssertEqual(f.snapshot["previousTransactionIDs"] as? [String], [])
                newerApply.fulfill()
            }
        }
        wait(for: [newerApply], timeout: 3)
    }

    func testMissingCacheReplyCannotTurnVerifiedRestoreIntoFailure() {
        let f = Fixture()
        f.snapshot = f.captured
        f.dropFlushReply = true
        let done = expectation(description: "cache budget elapsed")
        f.controller.restore(client: f.client, timeout: 0.02) { error in
            XCTAssertNil(error)
            XCTAssertTrue(f.snapshot.isEmpty)
            XCTAssertEqual(f.events, ["restore", "clear", "flush", "warning"])
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testUnknownJournalVersionIsRetainedWithoutCallingHelper() {
        let f = Fixture()
        f.snapshot = ["version": 3, "transactionID": "future", "services": ["wifi": ["original": NSNull()]]]
        let done = expectation(description: "future journal rejected")
        f.controller.restore(client: f.client, timeout: 1) { error in
            XCTAssertNotNil(error)
            XCTAssertEqual(f.snapshot["version"] as? Int, 3)
            XCTAssertTrue(f.events.isEmpty)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testDroppedCaptureCallbackStillSettlesWithinItsBudget() {
        let f = Fixture()
        let original = f.client
        let dropped = TunDNSHelperClient(capture: { _, _ in }, apply: original.apply,
                                         restore: original.restore, flush: original.flush)
        let done = expectation(description: "dropped request settled")
        f.controller.apply(client: dropped, servers: ["198.18.0.2"], filterInterface: true,
                           timeout: 0.02, isCurrent: { true }) { error in
            XCTAssertNotNil(error)
            XCTAssertTrue(f.snapshot.isEmpty)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testNoJournalNeverResetsUncapturedNetworkServices() {
        let f = Fixture()
        let done = expectation(description: "no restore required")
        f.controller.restore(client: f.client, timeout: 1) { error in
            XCTAssertNil(error)
            XCTAssertTrue(f.events.isEmpty)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testTimedOutCaptureCannotApplyWhenItsReplyArrivesLate() {
        let f = Fixture()
        f.holdCapture = true
        let done = expectation(description: "timed out")
        var completions = 0
        f.apply(timeout: 0.02) { error in
            completions += 1
            XCTAssertNotNil(error)
            f.captureReply?(f.captured)
            DispatchQueue.main.async {
                XCTAssertEqual(completions, 1)
                XCTAssertEqual(f.events, ["capture"])
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
    }

    func testSupersededCaptureDoesNotWriteOrReplaceJournal() {
        let f = Fixture()
        var current = true
        let done = expectation(description: "superseded")
        f.holdCapture = true
        f.apply(isCurrent: { current }) { error in
            XCTAssertNotNil(error)
            XCTAssertFalse(f.events.contains("persist"))
            done.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            current = false
            f.captureReply?(f.captured)
        }
        wait(for: [done], timeout: 2)
    }

    func testRestoreCannotClearAReplacementJournal() {
        let f = Fixture()
        f.snapshot = f.captured
        f.holdRestore = true
        let done = expectation(description: "newer journal retained")
        f.controller.restore(client: f.client, timeout: 1) { error in
            XCTAssertNotNil(error)
            XCTAssertEqual(f.snapshot["transactionID"] as? String, "new-launch")
            XCTAssertFalse(f.events.contains("clear"))
            done.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            f.snapshot["transactionID"] = "new-launch"
            f.restoreReply?(nil)
        }
        wait(for: [done], timeout: 2)
    }

    func testApplyAndRestoreRemainSerializedAcrossAsyncReplies() {
        let f = Fixture()
        f.holdApply = true
        let applied = expectation(description: "apply completed")
        let restored = expectation(description: "restore completed")
        f.apply { error in XCTAssertNil(error); applied.fulfill() }
        f.controller.restore(client: f.client, timeout: 1) { error in
            XCTAssertNil(error)
            XCTAssertEqual(f.events, ["capture", "persist", "apply", "flush", "restore", "clear", "flush"])
            restored.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            XCTAssertFalse(f.events.contains("restore"))
            f.applyReply?(nil)
        }
        wait(for: [applied, restored], timeout: 2)
    }

    func testRecapturePreservesOriginalDNSAndIncludesNewServices() throws {
        let original: [String: Any] = ["ServerAddresses": ["192.168.1.1"], "SearchDomains": ["office.test"]]
        let applied: [String: Any] = ["ServerAddresses": ["198.18.0.2"], "SearchDomains": ["office.test"]]
        let previous: [String: Any] = ["services": ["wifi": ["original": original]], "expectedServers": ["198.18.0.2"]]
        let captured: [String: Any] = ["version": 2, "transactionID": "network-switch", "services": [
            "wifi": ["original": applied], "ethernet": ["original": NSNull()]
        ]]
        let merged = try XCTUnwrap(TunDNSTransactionController.merging(captured, previous: previous, servers: ["198.18.0.2"]))
        let services = try XCTUnwrap(merged["services"] as? [String: [String: Any]])
        XCTAssertEqual((services["wifi"]?["original"] as? [String: Any])?["ServerAddresses"] as? [String], ["192.168.1.1"])
        XCTAssertTrue(services["ethernet"]?["original"] is NSNull)
        XCTAssertEqual(merged["applyServiceIDs"] as? [String], ["ethernet", "wifi"])
    }

    func testRecaptureCarriesPredecessorChainAndRejectsOverflow() throws {
        let services: [String: [String: Any]] = ["wifi": ["original": NSNull()]]
        let captured: [String: Any] = ["version": 2, "transactionID": "C", "services": services]
        let previous: [String: Any] = [
            "version": 2,
            "transactionID": "B",
            "previousTransactionIDs": ["A"],
            "services": services
        ]
        let merged = try XCTUnwrap(TunDNSTransactionController.merging(captured, previous: previous,
                                                                       servers: ["198.18.0.2"]))
        XCTAssertEqual(merged["previousTransactionIDs"] as? [String], ["A", "B"])

        let fullHistory = (0 ..< 64).map { "transaction-\($0)" }
        let overflowingPrevious: [String: Any] = [
            "version": 2,
            "transactionID": "latest",
            "previousTransactionIDs": fullHistory,
            "services": services
        ]
        XCTAssertNil(TunDNSTransactionController.merging(captured, previous: overflowingPrevious,
                                                         servers: ["198.18.0.2"]))
    }

    func testDurableStorePreservesAbsenceAndFailsClosedOnCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = "TunDNSTransactionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suiteName) }
        let url = directory.appendingPathComponent("journal.json")
        let store = TunDNSSnapshotStore(defaults: defaults, journalURL: url)
        XCTAssertTrue(store.save(Fixture().captured))
        XCTAssertTrue((store.load()["services"] as? [String: [String: Any]])?["wifi"]?["original"] is NSNull)
        try Data("broken".utf8).write(to: url)
        XCTAssertNotNil(store.load()["error"])
        XCTAssertEqual(try String(contentsOf: url), "broken")
    }

    func testDurableStoreRejectsJournalLargerThanOneMiB() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = "TunDNSTransactionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suiteName) }
        let url = directory.appendingPathComponent("journal.json")
        let store = TunDNSSnapshotStore(defaults: defaults, journalURL: url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 1_048_577).write(to: url)
        XCTAssertNotNil(store.load()["error"])
    }

    func testDurableStoreRejectsFIFOWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = "TunDNSTransactionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suiteName) }
        let url = directory.appendingPathComponent("journal.json")
        let store = TunDNSSnapshotStore(defaults: defaults, journalURL: url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let createdFIFO = url.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
        guard createdFIFO == 0 else { throw XCTSkip("Cannot create FIFO fixture") }

        let done = expectation(description: "FIFO rejected promptly")
        var result: [String: Any]?
        DispatchQueue.global().async {
            result = store.load()
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        XCTAssertNotNil(result?["error"])
    }

    func testStartupRecoveryBudgetCannotSpinOrDuplicatePendingRetries() {
        let controller = StartupCoreRecoveryController(delays: [0.01, 0.02])
        controller.begin(window: 1, now: 100)
        XCTAssertTrue(controller.schedule(now: 100, action: { XCTFail("cancelled retry ran") }))
        XCTAssertFalse(controller.schedule(now: 100, action: {}))
        controller.cancelPending()
        XCTAssertTrue(controller.schedule(now: 100, action: {}))
        controller.cancelPending()
        XCTAssertFalse(controller.schedule(now: 100, action: {}))
        controller.begin(window: 0.005, now: 100)
        XCTAssertFalse(controller.schedule(now: 100, action: {}))
    }

    func testRecapturePreservesUserSearchDomainChangesWithoutBackingUpVirtualDNS() throws {
        let previous: [String: Any] = ["services": ["wifi": ["original": NSNull()]], "expectedServers": ["198.18.0.2"]]
        let captured: [String: Any] = ["version": 2, "transactionID": "updated", "services": [
            "wifi": ["original": ["ServerAddresses": ["198.18.0.2"], "SearchDomains": ["new.office.test"]]]
        ]]
        let merged = try XCTUnwrap(TunDNSTransactionController.merging(captured, previous: previous, servers: ["198.18.0.2"]))
        let original = try XCTUnwrap(((merged["services"] as? [String: [String: Any]])?["wifi"]?["original"]) as? [String: Any])
        XCTAssertNil(original["ServerAddresses"])
        XCTAssertEqual(original["SearchDomains"] as? [String], ["new.office.test"])
    }

    func testRuntimeListenerManifestValidatesMetadataWithoutInventingBindingConflicts() {
        // The same port may belong to disjoint addresses or TCP/UDP listeners.
        // Full-config Go tests verify actual overlap; this manifest lacks that data.
        XCTAssertNil(RuntimeEndpointSet(apiPort: 19090, dnsPort: 7890, proxyPorts: [7890]).validationError)
        XCTAssertNil(RuntimeEndpointSet(apiPort: 7890, dnsPort: 7874, proxyPorts: [7890]).validationError)
        XCTAssertNotNil(RuntimeEndpointSet(apiPort: 0, dnsPort: 7874, proxyPorts: [7890]).validationError)
        XCTAssertNotNil(RuntimeEndpointSet(apiPort: 19090, dnsPort: 65536, proxyPorts: [7890]).validationError)
        XCTAssertNotNil(RuntimeEndpointSet(apiPort: 19090, dnsPort: 7874, proxyPorts: []).validationError)
        XCTAssertNil(RuntimeEndpointSet(apiPort: 19090, dnsPort: 7874, proxyPorts: [7890]).validationError)
    }

    func testDNSProbeBoundsAConnectedServerThatNeverReplies() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw XCTSkip("Cannot create loopback fixture socket") }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        let stopped = expectation(description: "fixture stopped")
        DispatchQueue.global().async {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 1000) > 0 {
                let client = accept(listener, nil, nil)
                if client >= 0 {
                    usleep(100_000)
                    close(client)
                }
            }
            stopped.fulfill()
        }
        let start = ProcessInfo.processInfo.systemUptime
        let response = BoundedDNSProbe.query(host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)),
                                             type: SOCK_STREAM, payload: [1, 2, 3], timeout: 0.03)
        XCTAssertNil(response)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.3)
        wait(for: [stopped], timeout: 2)
    }

    func testEnhancedDNSProbeTargetPolicyMapsWildcardAndSpecificAddresses() {
        let mappings = [
            ("0.0.0.0:7874", "127.0.0.1"),
            (":7874", "127.0.0.1"),
            ("localhost:7874", "127.0.0.1"),
            ("127.0.0.1:0", "127.0.0.1"),
            ("127.0.0.2:7874", "127.0.0.2"),
            ("192.168.1.25:5353", "192.168.1.25"),
            ("[::]:7874", "::1"),
            ("[0:0:0:0:0:0:0:0]:7874", "::1"),
            ("[::1]:7874", "::1"),
            ("[2001:db8::5]:5353", "2001:db8::5"),
            ("[fe80::1%en0]:5353", "fe80::1%en0")
        ]
        for (listen, expectedHost) in mappings {
            XCTAssertEqual(EnhancedDNSProbeTargetPolicy.host(from: listen), expectedHost, listen)
        }
    }

    func testEnhancedDNSProbeTargetPolicyRejectsInvalidAddressesAndPorts() {
        let invalidListeners = [
            "", "127.0.0.1", "example.com:53", "localhost.example:53",
            "127.0.0.1:65536", "127.0.0.1:abc", "127.0.0.1:-53", "127.0.0.1:", "[not-ip]:53",
            "2001:db8::1:53", "[]:53", "127.0.0.1:53/path", "udp://127.0.0.1:53",
            " 127.0.0.1:53", "127.0.0.1:53 "
        ]
        for listen in invalidListeners {
            XCTAssertNil(EnhancedDNSProbeTargetPolicy.host(from: listen), listen)
        }
    }

    func testDNSProbeQueriesIPv4LoopbackUDPAndTCPAgainstFakeResponder() throws {
        try assertDNSProbeUsesLoopback(family: AF_INET, host: "127.0.0.1")
    }

    func testDNSProbeQueriesIPv6LoopbackUDPAndTCPAgainstFakeResponder() throws {
        try assertDNSProbeUsesLoopback(family: AF_INET6, host: "::1")
    }

    private func assertDNSProbeUsesLoopback(family: Int32, host: String) throws {
        let query: [UInt8] = [
            0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x78, 0x00, 0x00, 0x01, 0x00, 0x01
        ]
        for type in [Int32(SOCK_DGRAM), Int32(SOCK_STREAM)] {
            guard let responder = LoopbackDNSResponder(family: family, type: type) else {
                if family == AF_INET6 { throw XCTSkip("IPv6 loopback responder is unavailable") }
                XCTFail("Cannot create IPv4 loopback DNS responder")
                return
            }
            let served = expectation(description: "fake DNS responder handled request")
            responder.respondOnce(then: served)
            let response = BoundedDNSProbe.query(host: host, port: responder.port, type: type,
                                                 payload: query, timeout: 0.6)
            XCTAssertEqual(response?.prefix(2), Data([0x12, 0x34]))
            XCTAssertEqual(response?[2], 0x81)
            wait(for: [served], timeout: 2)
            close(responder.descriptor)
        }
    }
}

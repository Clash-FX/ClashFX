import Foundation
import XCTest

final class RuntimeConfigTransactionTests: XCTestCase {
    private final class MockClient {
        var validationFiles = [URL]()
        var validationCallbacks = [(String?) -> Void]()
        var applyFiles = [URL]()
        var applyCallbacks = [(RuntimeConfigTransactionController.ApplyResult) -> Void]()
        var verificationFiles = [URL]()
        var verificationCallbacks = [(RuntimeConfigTransactionController.VerificationResult) -> Void]()
        var clientCallsOnMain = [Bool]()

        var client: RuntimeConfigTransactionController.Client {
            return RuntimeConfigTransactionController.Client(
                validate: { [weak self] file, callback in
                    self?.clientCallsOnMain.append(Thread.isMainThread)
                    self?.validationFiles.append(file)
                    self?.validationCallbacks.append(callback)
                },
                apply: { [weak self] file, callback in
                    self?.clientCallsOnMain.append(Thread.isMainThread)
                    self?.applyFiles.append(file)
                    self?.applyCallbacks.append(callback)
                },
                verify: { [weak self] file, callback in
                    self?.clientCallsOnMain.append(Thread.isMainThread)
                    self?.verificationFiles.append(file)
                    self?.verificationCallbacks.append(callback)
                }
            )
        }
    }

    private var temporaryDirectories = [URL]()

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testVerifiedApplyPromotesReceiptAndPreservesUnavailableDataPlane() {
        let controller = makeController()
        let mock = MockClient()
        var outcomes = [RuntimeConfigTransactionController.Outcome]()

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcomes.append($0)
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }

        mock.validationCallbacks[0](nil)
        XCTAssertEqual(mock.applyCallbacks.count, 1)
        XCTAssertNil(controller.confirmed, "A successful apply is not confirmed before readback.")

        mock.applyCallbacks[0](.accepted)
        XCTAssertEqual(mock.verificationCallbacks.count, 1)
        XCTAssertNil(controller.confirmed)

        mock.verificationCallbacks[0](.verified(.unavailable))

        guard outcomes.count == 1, case let .applied(receipt) = outcomes[0] else {
            return XCTFail("Expected a verified apply outcome")
        }
        XCTAssertEqual(receipt.dataPlane, .unavailable)
        XCTAssertEqual(controller.confirmed?.id, receipt.id)
        XCTAssertFalse(controller.isUncertain)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(mock.clientCallsOnMain.allSatisfy { $0 })
    }

    func testValidationRejectionDoesNotApplyOrReplaceConfirmedReceipt() throws {
        let controller = makeController()
        let baseline = try controller.adoptConfirmed(data: Data("baseline".utf8), scope: "core-A")
        let mock = MockClient()
        var outcomes = [RuntimeConfigTransactionController.Outcome]()
        var snapshotVerified = false

        controller.submit(data: Data("invalid".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcomes.append($0)
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        mock.validationCallbacks[0]("parse error")

        guard outcomes.count == 1, case let .rejected(reason) = outcomes[0] else {
            return XCTFail("Expected validation rejection")
        }
        snapshotVerified = RuntimeConfigReadbackPolicy.canRestoreVerifiedBaseline(
            scopeMatches: controller.confirmed?.scope == "core-A",
            hasConfirmedBaseline: controller.confirmed?.id == baseline.id,
            transactionBusy: controller.isBusy,
            transactionUncertain: controller.isUncertain
        )
        XCTAssertEqual(reason, "parse error")
        XCTAssertTrue(mock.applyCallbacks.isEmpty)
        XCTAssertEqual(controller.confirmed?.id, baseline.id)
        XCTAssertFalse(controller.isUncertain)
        XCTAssertTrue(snapshotVerified, "A same-scope confirmed baseline remains verified after pre-apply rejection.")
    }

    func testDeterministicApplyRejectionRestoresSameScopeBaseline() throws {
        let controller = makeController()
        let baseline = try controller.adoptConfirmed(data: Data("baseline".utf8), scope: "core-A")
        let mock = MockClient()
        var outcomes = [RuntimeConfigTransactionController.Outcome]()

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcomes.append($0)
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        mock.validationCallbacks[0](nil)
        mock.applyCallbacks[0](.rejected("core rejected candidate"))

        XCTAssertEqual(mock.applyCallbacks.count, 2, "A deterministic rejection reapplies the last verified snapshot.")
        XCTAssertEqual(mock.applyFiles[1], baseline.file)
        mock.applyCallbacks[1](.accepted)
        mock.verificationCallbacks[0](.verified(.notChecked))

        guard outcomes.count == 1, case let .rolledBack(receipt, reason) = outcomes[0] else {
            return XCTFail("Expected successful rollback after deterministic rejection")
        }
        XCTAssertEqual(receipt.id, baseline.id)
        XCTAssertEqual(reason, "core rejected candidate")
        XCTAssertEqual(receipt.dataPlane, .notChecked)
        XCTAssertEqual(controller.confirmed?.id, baseline.id)
        XCTAssertFalse(controller.isUncertain)
    }

    func testUncertainApplyBlocksRetryAndIgnoresLateCallback() throws {
        let controller = makeController()
        let baseline = try controller.adoptConfirmed(data: Data("baseline".utf8), scope: "core-A")
        let mock = MockClient()
        var outcomes = [RuntimeConfigTransactionController.Outcome]()

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcomes.append($0)
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        mock.validationCallbacks[0](nil)
        mock.applyCallbacks[0](.uncertain("connection lost"))

        XCTAssertEqual(outcomes.count, 1)
        guard case .unknown = outcomes[0] else { return XCTFail("Expected an unknown outcome") }
        XCTAssertNil(controller.confirmed)
        XCTAssertTrue(controller.isUncertain)
        XCTAssertEqual(mock.applyCallbacks.count, 1)

        var retryOutcome: RuntimeConfigTransactionController.Outcome?
        controller.submit(data: Data("retry".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            retryOutcome = $0
        }
        guard case .unknown? = retryOutcome else { return XCTFail("Uncertain state must block another apply") }
        XCTAssertEqual(mock.validationCallbacks.count, 1)

        mock.applyCallbacks[0](.accepted)
        XCTAssertTrue(mock.verificationCallbacks.isEmpty)
        XCTAssertNil(controller.confirmed)
        XCTAssertTrue(controller.isUncertain)
        XCTAssertNotEqual(controller.confirmed?.id, baseline.id)

        let readback = try controller.adoptConfirmed(
            data: Data("fresh readback".utf8),
            scope: "core-A",
            dataPlane: .unavailable
        )
        XCTAssertFalse(controller.isUncertain)
        XCTAssertEqual(controller.confirmed?.id, readback.id)
        XCTAssertEqual(controller.confirmed?.dataPlane, .unavailable)

        let retryClient = MockClient()
        controller.submit(data: Data("retry".utf8), scope: "core-A", isCurrent: { true }, client: retryClient.client) { _ in }
        waitUntil("a fresh readback should permit another transaction") {
            retryClient.validationCallbacks.count == 1
        }
        XCTAssertTrue(controller.isBusy)
        controller.invalidate()
    }

    func testAsyncSeedWithStaleScopeDoesNotPromoteAndCleansItsSnapshot() {
        let controller = makeController()
        let directory = temporaryDirectories[temporaryDirectories.count - 1]
        var isCurrent = true
        var result: Result<RuntimeConfigTransactionController.Receipt, Error>?
        var completionOnMain: Bool?

        controller.adoptConfirmed(
            data: Data("stale seed".utf8),
            scope: "core-old",
            isCurrent: { isCurrent }
        ) {
            completionOnMain = Thread.isMainThread
            result = $0
        }
        isCurrent = false

        waitUntil("stale seed should finish") { result != nil }
        guard case .failure? = result else { return XCTFail("A stale seed must be rejected") }
        XCTAssertEqual(completionOnMain, true)
        XCTAssertNil(controller.confirmed)
        waitUntil("stale seed snapshot should be removed") {
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true
        }
    }

    func testAsyncSeedDoesNotReplaceSuccessfulSameScopeTransaction() {
        let controller = makeController()
        let directory = temporaryDirectories[temporaryDirectories.count - 1]
        let mock = MockClient()
        var transactionOutcome: RuntimeConfigTransactionController.Outcome?
        var seedResult: Result<RuntimeConfigTransactionController.Receipt, Error>?
        var seedCompletionOnMain: Bool?

        controller.submit(data: Data("transaction".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            transactionOutcome = $0
        }
        waitUntil("transaction validation should start") { mock.validationCallbacks.count == 1 }

        // The seed write is queued while this same-scope transaction is busy.
        // Keep the main queue occupied through commit so its later callback
        // cannot race between the transaction's phases.
        controller.adoptConfirmed(
            data: Data("older seed".utf8),
            scope: "core-A",
            isCurrent: { true }
        ) {
            seedCompletionOnMain = Thread.isMainThread
            seedResult = $0
        }
        mock.validationCallbacks[0](nil)
        mock.applyCallbacks[0](.accepted)
        mock.verificationCallbacks[0](.verified(.healthy))

        guard case let .applied(transactionReceipt)? = transactionOutcome else {
            return XCTFail("Expected the newer same-scope transaction to apply")
        }
        XCTAssertEqual(controller.confirmed?.id, transactionReceipt.id)

        waitUntil("queued seed should finish as superseded") { seedResult != nil }
        guard case .failure? = seedResult else { return XCTFail("The older seed must not replace the transaction receipt") }
        XCTAssertEqual(seedCompletionOnMain, true)
        XCTAssertEqual(controller.confirmed?.id, transactionReceipt.id)
        waitUntil("only the confirmed transaction snapshot should remain") {
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) == 1
        }
    }

    func testAsyncSeedWhileBusyDoesNotCancelOrReplaceCurrentTransaction() throws {
        let controller = makeController()
        let baseline = try controller.adoptConfirmed(data: Data("baseline".utf8), scope: "core-A")
        let mock = MockClient()
        var transactionOutcome: RuntimeConfigTransactionController.Outcome?
        var seedResult: Result<RuntimeConfigTransactionController.Receipt, Error>?

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            transactionOutcome = $0
        }
        waitUntil("transaction validation should start") { mock.validationCallbacks.count == 1 }
        controller.adoptConfirmed(
            data: Data("busy seed".utf8),
            scope: "core-A",
            isCurrent: { true }
        ) {
            seedResult = $0
        }

        waitUntil("busy seed should be rejected") { seedResult != nil }
        guard case .failure? = seedResult else { return XCTFail("An adoption during a transaction must be rejected") }
        XCTAssertTrue(controller.isBusy)
        XCTAssertEqual(controller.confirmed?.id, baseline.id)
        XCTAssertTrue(mock.applyCallbacks.isEmpty)

        mock.validationCallbacks[0]("finish active transaction")
        guard case .rejected? = transactionOutcome else { return XCTFail("Active transaction should finish normally") }
        XCTAssertEqual(controller.confirmed?.id, baseline.id)
        XCTAssertFalse(controller.isBusy)
    }

    func testVerificationFailureRestoresAndVerifiesPreviousSnapshot() throws {
        let controller = makeController()
        let baseline = try controller.adoptConfirmed(
            data: Data("baseline".utf8),
            scope: "core-A",
            dataPlane: .healthy
        )
        let mock = MockClient()
        var outcomes = [RuntimeConfigTransactionController.Outcome]()

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcomes.append($0)
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        mock.validationCallbacks[0](nil)
        mock.applyCallbacks[0](.accepted)
        let candidateReadbackGeneration = controller.readbackGeneration
        mock.verificationCallbacks[0](.failed("listener readback mismatch"))

        XCTAssertEqual(mock.applyCallbacks.count, 2)
        XCTAssertEqual(mock.applyFiles[1], baseline.file)
        XCTAssertTrue(outcomes.isEmpty)

        mock.applyCallbacks[1](.accepted)
        XCTAssertEqual(mock.verificationCallbacks.count, 2)
        XCTAssertEqual(mock.verificationFiles[1], baseline.file)
        mock.verificationCallbacks[1](.verified(.unavailable))

        guard outcomes.count == 1, case let .rolledBack(receipt, reason) = outcomes[0] else {
            return XCTFail("Expected a verified rollback")
        }
        XCTAssertEqual(receipt.id, baseline.id)
        XCTAssertEqual(receipt.data, Data("baseline".utf8))
        XCTAssertEqual(receipt.dataPlane, .unavailable)
        XCTAssertEqual(reason, "listener readback mismatch")
        XCTAssertEqual(controller.confirmed?.id, baseline.id)
        XCTAssertFalse(controller.isUncertain)
        XCTAssertNotEqual(controller.readbackGeneration, candidateReadbackGeneration,
                          "A read captured before rollback must not match the restored baseline generation")
    }

    func testRollbackFailureClearsConfirmedStateAndBecomesUnknown() throws {
        let controller = makeController()
        _ = try controller.adoptConfirmed(data: Data("baseline".utf8), scope: "core-A")
        let mock = MockClient()
        var outcomes = [RuntimeConfigTransactionController.Outcome]()

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcomes.append($0)
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        mock.validationCallbacks[0](nil)
        mock.applyCallbacks[0](.accepted)
        mock.verificationCallbacks[0](.failed("verify failed"))
        mock.applyCallbacks[1](.rejected("rollback rejected"))

        guard outcomes.count == 1, case .unknown = outcomes[0] else {
            return XCTFail("Rollback failure must leave the runtime state unknown")
        }
        XCTAssertNil(controller.confirmed)
        XCTAssertTrue(controller.isUncertain)
        XCTAssertFalse(controller.isBusy)
    }

    func testApplyTimeoutDoesNotStartConcurrentRollbackAndLateCallbackCannotCommit() throws {
        let controller = makeController(timeout: 0.5)
        _ = try controller.adoptConfirmed(data: Data("baseline".utf8), scope: "core-A")
        let mock = MockClient()
        var outcomes = [RuntimeConfigTransactionController.Outcome]()

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcomes.append($0)
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        mock.validationCallbacks[0](nil)
        let submittedFile = mock.applyFiles[0]
        waitUntil("apply timeout should settle") { outcomes.count == 1 }

        guard case .unknown = outcomes[0] else { return XCTFail("Apply timeout must produce unknown state") }
        XCTAssertEqual(mock.applyCallbacks.count, 1, "No rollback may race an unresolved apply.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: submittedFile.path), "A timed-out HTTP path remains available to the core.")
        XCTAssertNil(controller.confirmed)
        XCTAssertTrue(controller.isUncertain)

        mock.applyCallbacks[0](.accepted)
        XCTAssertTrue(mock.verificationCallbacks.isEmpty)
        XCTAssertEqual(mock.applyCallbacks.count, 1)
        XCTAssertNil(controller.confirmed)
        XCTAssertTrue(controller.isUncertain)
    }

    func testVerificationFailureWithoutSameScopeBaselineIsUnknown() {
        let controller = makeController()
        let mock = MockClient()
        var outcomes = [RuntimeConfigTransactionController.Outcome]()

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcomes.append($0)
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        mock.validationCallbacks[0](nil)
        mock.applyCallbacks[0](.accepted)
        mock.verificationCallbacks[0](.failed("no matching runtime config"))

        guard outcomes.count == 1, case .unknown = outcomes[0] else {
            return XCTFail("A failed verify without a baseline must not claim recovery")
        }
        XCTAssertEqual(mock.applyCallbacks.count, 1)
        XCTAssertNil(controller.confirmed)
        XCTAssertTrue(controller.isUncertain)
    }

    func testInvalidationAfterApplyDoesNotSendOldRollbackToNewScope() throws {
        let controller = makeController()
        _ = try controller.adoptConfirmed(data: Data("old baseline".utf8), scope: "core-old")
        let oldClient = MockClient()
        var oldOutcome: RuntimeConfigTransactionController.Outcome?

        controller.submit(data: Data("old candidate".utf8), scope: "core-old", isCurrent: { true }, client: oldClient.client) {
            oldOutcome = $0
        }
        waitUntil("old validation should start") { oldClient.validationCallbacks.count == 1 }
        oldClient.validationCallbacks[0](nil)
        let inFlightApplyFile = oldClient.applyFiles[0]
        controller.invalidate()

        guard case .unknown? = oldOutcome else { return XCTFail("An in-flight apply becomes unknown on scope change") }
        XCTAssertNil(controller.confirmed)
        XCTAssertFalse(controller.isUncertain, "The new lifecycle starts without inheriting old-scope uncertainty.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlightApplyFile.path), "Invalidation must retain a path submitted to the old core.")

        let newBaseline = try controller.adoptConfirmed(data: Data("new baseline".utf8), scope: "core-new")
        let newClient = MockClient()
        var newOutcome: RuntimeConfigTransactionController.Outcome?
        controller.submit(data: Data("new candidate".utf8), scope: "core-new", isCurrent: { true }, client: newClient.client) {
            newOutcome = $0
        }
        waitUntil("new validation should start") { newClient.validationCallbacks.count == 1 }

        oldClient.applyCallbacks[0](.rejected("late old-core response"))
        XCTAssertTrue(newClient.applyCallbacks.isEmpty)
        XCTAssertEqual(controller.confirmed?.id, newBaseline.id)
        XCTAssertTrue(controller.isBusy)

        newClient.validationCallbacks[0](nil)
        newClient.applyCallbacks[0](.accepted)
        newClient.verificationCallbacks[0](.verified(.notChecked))
        guard case .applied? = newOutcome else { return XCTFail("New-scope operation should complete independently") }
        XCTAssertEqual(oldClient.applyCallbacks.count, 1)
        XCTAssertTrue(oldClient.verificationCallbacks.isEmpty)
    }

    func testInvalidationBeforeApplyCancelsWithoutCallingApply() {
        let controller = makeController()
        let mock = MockClient()
        var outcome: RuntimeConfigTransactionController.Outcome?

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcome = $0
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        controller.invalidate()

        guard case .cancelled? = outcome else { return XCTFail("Pre-apply invalidation should cancel") }
        mock.validationCallbacks[0](nil)
        XCTAssertTrue(mock.applyCallbacks.isEmpty)
        XCTAssertFalse(controller.isBusy)
    }

    func testConcurrentSubmitIsRejectedWithoutDisturbingActiveTransaction() {
        let controller = makeController()
        let first = MockClient()
        let second = MockClient()
        var firstOutcome: RuntimeConfigTransactionController.Outcome?
        var secondOutcome: RuntimeConfigTransactionController.Outcome?

        controller.submit(data: Data("first".utf8), scope: "core-A", isCurrent: { true }, client: first.client) {
            firstOutcome = $0
        }
        waitUntil("first validation should start") { first.validationCallbacks.count == 1 }
        controller.submit(data: Data("second".utf8), scope: "core-A", isCurrent: { true }, client: second.client) {
            secondOutcome = $0
        }

        guard case .rejected? = secondOutcome else { return XCTFail("Concurrent submit should be rejected") }
        XCTAssertTrue(second.validationCallbacks.isEmpty)
        XCTAssertTrue(controller.isBusy)

        first.validationCallbacks[0]("stop")
        guard case .rejected? = firstOutcome else { return XCTFail("First transaction should finish normally") }
        XCTAssertFalse(controller.isBusy)
    }

    func testSnapshotCopiesSourceDataAndUsesSha256AndMode0600() throws {
        let controller = makeController()
        let mock = MockClient()
        var source = Data("abc".utf8)
        var outcome: RuntimeConfigTransactionController.Outcome?

        controller.submit(data: source, scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcome = $0
        }
        source = Data("caller changed its buffer".utf8)
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }

        let candidateFile = mock.validationFiles[0]
        XCTAssertEqual(try Data(contentsOf: candidateFile), Data("abc".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: candidateFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        mock.validationCallbacks[0](nil)
        mock.applyCallbacks[0](.accepted)
        mock.verificationCallbacks[0](.verified(.notChecked))

        guard case let .applied(receipt)? = outcome else { return XCTFail("Expected applied receipt") }
        XCTAssertEqual(receipt.data, Data("abc".utf8))
        XCTAssertEqual(try Data(contentsOf: receipt.file), receipt.data)
        XCTAssertEqual(receipt.digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(receipt.dataPlane, .notChecked)
    }

    func testValidationTimeoutDoesNotApply() {
        let controller = makeController(timeout: 0.5)
        let mock = MockClient()
        var outcome: RuntimeConfigTransactionController.Outcome?

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            outcome = $0
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        waitUntil("validation timeout should settle") { outcome != nil }

        guard case .rejected? = outcome else { return XCTFail("Validation timeout must be a rejection") }
        XCTAssertTrue(mock.applyCallbacks.isEmpty)
        XCTAssertFalse(controller.isUncertain)
        XCTAssertFalse(controller.isBusy)
    }

    func testBackgroundClientCallbackIsHandledAndCompletedOnMainQueue() {
        let controller = makeController()
        let mock = MockClient()
        var completionOnMain: Bool?
        var outcome: RuntimeConfigTransactionController.Outcome?

        controller.submit(data: Data("candidate".utf8), scope: "core-A", isCurrent: { true }, client: mock.client) {
            completionOnMain = Thread.isMainThread
            outcome = $0
        }
        waitUntil("validation should start") { mock.validationCallbacks.count == 1 }
        DispatchQueue.global().async {
            mock.validationCallbacks[0](nil)
        }
        waitUntil("background validation callback should reach apply") { mock.applyCallbacks.count == 1 }

        mock.applyCallbacks[0](.accepted)
        mock.verificationCallbacks[0](.verified(.healthy))
        guard case .applied? = outcome else { return XCTFail("Expected a verified apply") }
        XCTAssertEqual(completionOnMain, true)
        XCTAssertTrue(mock.clientCallsOnMain.allSatisfy { $0 })
    }

    private func makeController(timeout: TimeInterval = 1) -> RuntimeConfigTransactionController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeConfigTransactionTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return RuntimeConfigTransactionController(directory: directory, timeout: timeout)
    }

    private func waitUntil(
        _ message: String,
        timeout: TimeInterval = 2,
        file: StaticString = #file,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }
}

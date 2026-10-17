import CommonCrypto
import Darwin
import Foundation

/// Applies a configuration snapshot only after validation and confirms it only
/// after a readback. Every state transition and client invocation is serialized
/// on the main queue; snapshot file I/O uses a private serial queue.
final class RuntimeConfigTransactionController {
    enum ApplyResult {
        case accepted
        case rejected(String)
        case uncertain(String)
    }

    enum DataPlaneStatus: Equatable {
        case healthy
        case unavailable
        case notChecked
    }

    enum VerificationResult {
        case verified(DataPlaneStatus)
        case failed(String)
    }

    struct Client {
        let validate: (URL, @escaping (String?) -> Void) -> Void
        let apply: (URL, @escaping (ApplyResult) -> Void) -> Void
        let verify: (URL, @escaping (VerificationResult) -> Void) -> Void
    }

    struct Receipt {
        let id: UUID
        let scope: String
        let file: URL
        let data: Data
        let digest: String
        let dataPlane: DataPlaneStatus
    }

    enum Outcome {
        case applied(Receipt)
        case rejected(String)
        case rolledBack(Receipt, String)
        case unknown(String)
        case cancelled
    }

    private enum Phase: Equatable {
        case preparing
        case validating
        case applying
        case verifying
        case rollbackApplying
        case rollbackVerifying
        case finished
    }

    private enum SeedAdoptionError: LocalizedError {
        case staleScope
        case busy
        case superseded

        var errorDescription: String? {
            switch self {
            case .staleScope:
                return "The core scope changed before the readback snapshot could be adopted."
            case .busy:
                return "A runtime configuration transaction is in progress."
            case .superseded:
                return "Controller state changed before the readback snapshot could be adopted."
            }
        }
    }

    private final class Operation {
        let scope: String
        let isCurrent: () -> Bool
        let client: Client
        let previous: Receipt?
        var completion: ((Outcome) -> Void)?
        var candidate: Receipt?
        var phase: Phase = .preparing
        var phaseToken = UUID()
        var deadline: DispatchWorkItem?
        var applyStarted = false
        var applySettled = false
        var fileMayBeInUse = false
        var rollbackReason: String?
        var finished = false

        init(
            scope: String,
            isCurrent: @escaping () -> Bool,
            client: Client,
            previous: Receipt?,
            completion: @escaping (Outcome) -> Void
        ) {
            self.scope = scope
            self.isCurrent = isCurrent
            self.client = client
            self.previous = previous
            self.completion = completion
        }
    }

    private let directory: URL
    private let timeout: TimeInterval
    private let fileQueue = DispatchQueue(label: "com.clashfx.runtime-config-snapshots")
    private var activeOperation: Operation?
    private var confirmedReceipt: Receipt?
    private var uncertain = false
    private var stateEpoch: UInt64 = 0
    // Core requests receive paths, not open file descriptors. Keep any snapshot
    // that may still be read by an in-flight request because there is no signal
    // here that the remote reader has closed the path.
    private var retainedSnapshots = Set<UUID>()

    init(directory: URL, timeout: TimeInterval = 15) {
        self.directory = directory.standardizedFileURL
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 15
    }

    var confirmed: Receipt? {
        return onMainSync { self.confirmedReceipt }
    }

    /// Changes at baseline adoption and every transaction boundary. Readbacks
    /// captured during a transaction cannot publish after it settles/rolls back.
    var readbackGeneration: UInt64 {
        return onMainSync { self.stateEpoch }
    }

    var isBusy: Bool {
        return onMainSync { self.activeOperation != nil }
    }

    var isUncertain: Bool {
        return onMainSync { self.uncertain }
    }

    /// Adopts an API and listener readback supplied by the caller. The new
    /// snapshot is written before any current state is replaced.
    @discardableResult
    func adoptConfirmed(
        data: Data,
        scope: String,
        dataPlane: DataPlaneStatus = .notChecked
    ) throws -> Receipt {
        let receipt = try writeSnapshot(data: data, scope: scope, dataPlane: dataPlane)

        return onMainSync {
            let oldConfirmed = self.confirmedReceipt
            let detached = self.detachActiveOperationForAdoption()

            self.confirmedReceipt = receipt
            self.uncertain = false
            self.advanceStateEpoch()

            if let oldConfirmed = oldConfirmed, oldConfirmed.id != receipt.id {
                self.removeSnapshot(oldConfirmed)
            }
            detached?.cleanup.forEach(self.removeSnapshot)
            if let detached = detached {
                detached.completion?(detached.outcome)
            }
            return receipt
        }
    }

    /// Asynchronously adopts a readback snapshot without blocking the main
    /// queue or cancelling an in-flight transaction. The captured state epoch
    /// prevents a seed queued before a newer operation from replacing its
    /// confirmed receipt after that operation has already completed.
    func adoptConfirmed(
        data: Data,
        scope: String,
        dataPlane: DataPlaneStatus = .notChecked,
        isCurrent: @escaping () -> Bool,
        completion: @escaping (Result<Receipt, Error>) -> Void
    ) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.advanceStateEpoch()
            let capturedEpoch = self.stateEpoch

            self.fileQueue.async {
                let result: Result<Receipt, Error>
                do {
                    result = .success(try self.writeSnapshotOnFileQueue(
                        data: data,
                        scope: scope,
                        dataPlane: dataPlane
                    ))
                } catch {
                    result = .failure(error)
                }

                self.onMain {
                    switch result {
                    case let .failure(error):
                        completion(.failure(error))
                    case let .success(receipt):
                        guard self.stateEpoch == capturedEpoch else {
                            self.removeSnapshot(receipt)
                            completion(.failure(SeedAdoptionError.superseded))
                            return
                        }
                        guard self.activeOperation == nil else {
                            self.removeSnapshot(receipt)
                            completion(.failure(SeedAdoptionError.busy))
                            return
                        }
                        guard isCurrent() else {
                            self.removeSnapshot(receipt)
                            completion(.failure(SeedAdoptionError.staleScope))
                            return
                        }
                        // isCurrent is external code and may reenter or update
                        // the controller. Recheck the epoch and busy state
                        // before changing the confirmed receipt.
                        guard self.stateEpoch == capturedEpoch else {
                            self.removeSnapshot(receipt)
                            completion(.failure(SeedAdoptionError.superseded))
                            return
                        }
                        guard self.activeOperation == nil else {
                            self.removeSnapshot(receipt)
                            completion(.failure(SeedAdoptionError.busy))
                            return
                        }

                        let oldConfirmed = self.confirmedReceipt
                        self.confirmedReceipt = receipt
                        self.uncertain = false
                        self.advanceStateEpoch()
                        if let oldConfirmed = oldConfirmed, oldConfirmed.id != receipt.id {
                            self.removeSnapshot(oldConfirmed)
                        }
                        completion(.success(receipt))
                    }
                }
            }
        }
    }

    func submit(
        data: Data,
        scope: String,
        isCurrent: @escaping () -> Bool,
        client: Client,
        completion: @escaping (Outcome) -> Void
    ) {
        onMain { [weak self] in
            guard let self = self else { return }

            if self.activeOperation != nil {
                completion(.rejected("Another runtime configuration transaction is already in progress."))
                return
            }
            if self.uncertain {
                completion(.unknown("Runtime configuration state is uncertain; adopt a fresh readback or invalidate the scope before retrying."))
                return
            }

            guard isCurrent() else {
                let staleReceipt = self.confirmedReceipt
                self.confirmedReceipt = nil
                if staleReceipt != nil {
                    self.advanceStateEpoch()
                }
                if let staleReceipt = staleReceipt {
                    self.removeSnapshot(staleReceipt)
                }
                completion(.cancelled)
                return
            }

            self.discardConfirmedIfScopeDiffers(from: scope)
            let previous = self.confirmedReceipt?.scope == scope ? self.confirmedReceipt : nil
            let operation = Operation(
                scope: scope,
                isCurrent: isCurrent,
                client: client,
                previous: previous,
                completion: completion
            )
            self.activeOperation = operation
            self.advanceStateEpoch()

            let phaseToken = self.beginPhase(.preparing, for: operation)
            self.fileQueue.async { [weak self, weak operation] in
                guard let self = self, let operation = operation else { return }
                let result = Result {
                    try self.writeSnapshotOnFileQueue(data: data, scope: scope, dataPlane: .notChecked)
                }
                self.onMain { [weak self, weak operation] in
                    guard let self = self else { return }
                    guard let operation = operation else {
                        if case let .success(receipt) = result {
                            self.removeSnapshot(receipt)
                        }
                        return
                    }
                    guard self.matches(operation, phase: .preparing, token: phaseToken) else {
                        if case let .success(receipt) = result {
                            self.removeSnapshot(receipt)
                        }
                        return
                    }
                    self.clearDeadline(for: operation)
                    guard self.ensureCurrent(operation) else {
                        if case let .success(receipt) = result {
                            self.removeSnapshot(receipt)
                        }
                        return
                    }

                    switch result {
                    case let .success(receipt):
                        operation.candidate = receipt
                        self.beginValidation(operation)
                    case let .failure(error):
                        self.finish(operation, with: .rejected(error.localizedDescription))
                    }
                }
            }
        }
    }

    /// Invalidates controller state for a core lifecycle change. The lifecycle
    /// owner should cancel the old transport before calling this. Submitted
    /// snapshot paths remain on disk when a request may still be reading them;
    /// late callbacks from the old lifecycle are ignored.
    func invalidate() {
        onMain { [weak self] in
            guard let self = self else { return }

            self.advanceStateEpoch()
            let oldConfirmed = self.confirmedReceipt
            let detached = self.detachActiveOperationForInvalidation()

            self.confirmedReceipt = nil
            self.uncertain = false

            if let oldConfirmed = oldConfirmed {
                self.removeSnapshot(oldConfirmed)
            }
            detached?.cleanup.forEach(self.removeSnapshot)
            if let detached = detached {
                detached.completion?(detached.outcome)
            }
        }
    }

    private func beginValidation(_ operation: Operation) {
        guard ensureCurrent(operation), let candidate = operation.candidate else { return }
        let token = beginPhase(.validating, for: operation)
        operation.fileMayBeInUse = true
        operation.client.validate(candidate.file) { [weak self, weak operation] error in
            guard let self = self, let operation = operation else { return }
            self.receive(operation, phase: .validating, token: token) {
                if let error = error {
                    self.finish(operation, with: .rejected(error))
                } else {
                    self.beginApply(operation)
                }
            }
        }
    }

    private func beginApply(_ operation: Operation) {
        guard ensureCurrent(operation), let candidate = operation.candidate else { return }
        let token = beginPhase(.applying, for: operation)
        operation.applyStarted = true
        operation.fileMayBeInUse = true
        operation.client.apply(candidate.file) { [weak self, weak operation] result in
            guard let self = self, let operation = operation else { return }
            self.receive(operation, phase: .applying, token: token) {
                operation.applySettled = true
                self.handleApplyResult(result, for: operation)
            }
        }
    }

    private func handleApplyResult(_ result: ApplyResult, for operation: Operation) {
        switch result {
        case .accepted:
            guard let candidate = operation.candidate else {
                markUnknown("The candidate snapshot disappeared after apply.", for: operation)
                return
            }
            beginVerification(of: candidate.file, phase: .verifying, for: operation)
        case let .rejected(reason):
            if let previous = operation.previous, previous.scope == operation.scope {
                // A deterministic core rejection can still leave parse or
                // listener side effects. Reapply the last verified snapshot.
                operation.rollbackReason = reason
                beginRollback(operation)
            } else {
                finish(operation, with: .rejected(reason))
            }
        case let .uncertain(reason):
            markUnknown(reason, for: operation)
        }
    }

    private func beginVerification(of file: URL, phase: Phase, for operation: Operation) {
        guard ensureCurrent(operation) else { return }
        let token = beginPhase(phase, for: operation)
        operation.fileMayBeInUse = true
        operation.client.verify(file) { [weak self, weak operation] result in
            guard let self = self, let operation = operation else { return }
            self.receive(operation, phase: phase, token: token) {
                switch result {
                case let .verified(status):
                    if phase == .rollbackVerifying {
                        self.completeRollback(status, for: operation)
                    } else {
                        self.promoteCandidate(status, for: operation)
                    }
                case let .failed(reason):
                    if phase == .rollbackVerifying {
                        self.markUnknown("Rollback verification failed: \(reason)", for: operation)
                    } else {
                        self.rollbackOrBecomeUnknown(reason, for: operation)
                    }
                }
            }
        }
    }

    private func rollbackOrBecomeUnknown(_ reason: String, for operation: Operation) {
        guard operation.applySettled else {
            markUnknown("Configuration verification failed before apply settled: \(reason)", for: operation)
            return
        }
        guard let previous = operation.previous, previous.scope == operation.scope else {
            markUnknown("Configuration was applied but could not be verified, and no same-scope baseline exists: \(reason)", for: operation)
            return
        }
        operation.rollbackReason = reason
        beginRollback(operation)
    }

    private func beginRollback(_ operation: Operation) {
        guard ensureCurrent(operation), let previous = operation.previous,
              previous.scope == operation.scope else {
            if activeOperation === operation {
                markUnknown("The previous confirmed snapshot is unavailable for rollback.", for: operation)
            }
            return
        }

        let token = beginPhase(.rollbackApplying, for: operation)
        operation.fileMayBeInUse = true
        operation.client.apply(previous.file) { [weak self, weak operation] result in
            guard let self = self, let operation = operation else { return }
            self.receive(operation, phase: .rollbackApplying, token: token) {
                switch result {
                case .accepted:
                    self.beginVerification(
                        of: previous.file,
                        phase: .rollbackVerifying,
                        for: operation
                    )
                case let .rejected(reason):
                    self.markUnknown("Rollback apply was rejected: \(reason)", for: operation)
                case let .uncertain(reason):
                    self.markUnknown("Rollback apply is uncertain: \(reason)", for: operation)
                }
            }
        }
    }

    private func completeRollback(_ dataPlane: DataPlaneStatus, for operation: Operation) {
        guard let previous = operation.previous else {
            markUnknown("Rollback completed without a baseline receipt.", for: operation)
            return
        }
        let restored = Receipt(
            id: previous.id,
            scope: previous.scope,
            file: previous.file,
            data: previous.data,
            digest: previous.digest,
            dataPlane: dataPlane
        )
        confirmedReceipt = restored
        uncertain = false
        advanceStateEpoch()
        finish(
            operation,
            with: .rolledBack(restored, operation.rollbackReason ?? "Configuration verification failed.")
        )
    }

    private func promoteCandidate(_ dataPlane: DataPlaneStatus, for operation: Operation) {
        guard let candidate = operation.candidate else {
            markUnknown("The verified candidate snapshot is unavailable.", for: operation)
            return
        }
        let promoted = Receipt(
            id: candidate.id,
            scope: candidate.scope,
            file: candidate.file,
            data: candidate.data,
            digest: candidate.digest,
            dataPlane: dataPlane
        )
        let oldConfirmed = confirmedReceipt
        confirmedReceipt = promoted
        uncertain = false
        advanceStateEpoch()
        operation.candidate = promoted
        finish(operation, with: .applied(promoted), keepCandidate: true)

        if let oldConfirmed = oldConfirmed, oldConfirmed.id != promoted.id {
            removeSnapshot(oldConfirmed)
        }
    }

    private func ensureCurrent(_ operation: Operation) -> Bool {
        guard activeOperation === operation, !operation.finished else { return false }
        guard operation.isCurrent() else {
            endForStaleScope(operation)
            return false
        }
        // isCurrent is caller supplied and may reenter the controller.
        return activeOperation === operation && !operation.finished
    }

    private func receive(
        _ operation: Operation,
        phase: Phase,
        token: UUID,
        body: @escaping () -> Void
    ) {
        onMain { [weak self, weak operation] in
            guard let self = self, let operation = operation,
                  self.matches(operation, phase: phase, token: token) else { return }
            operation.fileMayBeInUse = false
            self.clearDeadline(for: operation)
            guard self.ensureCurrent(operation) else { return }
            body()
        }
    }

    private func matches(_ operation: Operation, phase: Phase, token: UUID) -> Bool {
        return activeOperation === operation
            && !operation.finished
            && operation.phase == phase
            && operation.phaseToken == token
    }

    @discardableResult
    private func beginPhase(_ phase: Phase, for operation: Operation) -> UUID {
        clearDeadline(for: operation)
        let token = UUID()
        operation.phase = phase
        operation.phaseToken = token
        let deadline = DispatchWorkItem { [weak self, weak operation] in
            guard let self = self, let operation = operation,
                  self.matches(operation, phase: phase, token: token) else { return }
            self.handleTimeout(phase, for: operation)
        }
        operation.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        return token
    }

    private func clearDeadline(for operation: Operation) {
        operation.deadline?.cancel()
        operation.deadline = nil
    }

    private func handleTimeout(_ phase: Phase, for operation: Operation) {
        guard ensureCurrent(operation) else { return }
        switch phase {
        case .preparing:
            finish(operation, with: .rejected("Creating the configuration snapshot timed out."))
        case .validating:
            retainSnapshot(operation.candidate)
            finish(operation, with: .rejected("Configuration validation timed out."), keepCandidate: true)
        case .applying:
            markUnknown("Configuration apply timed out; no concurrent rollback was attempted.", for: operation)
        case .verifying:
            rollbackOrBecomeUnknown("Configuration verification timed out.", for: operation)
        case .rollbackApplying:
            markUnknown("Rollback apply timed out.", for: operation)
        case .rollbackVerifying:
            markUnknown("Rollback verification timed out.", for: operation)
        case .finished:
            return
        }
    }

    private func markUnknown(_ reason: String, for operation: Operation) {
        guard activeOperation === operation, !operation.finished else { return }
        let staleConfirmed = confirmedReceipt
        if staleConfirmed?.scope == operation.scope {
            confirmedReceipt = nil
        }
        uncertain = true
        retainSnapshot(operation.candidate)
        retainSnapshot(operation.previous)
        if let staleConfirmed = staleConfirmed, staleConfirmed.scope == operation.scope {
            retainSnapshot(staleConfirmed)
        }
        finish(operation, with: .unknown(reason), keepCandidate: true)
    }

    private func retainSnapshot(_ receipt: Receipt?) {
        guard let receipt = receipt else { return }
        retainedSnapshots.insert(receipt.id)
    }

    private func endForStaleScope(_ operation: Operation) {
        guard activeOperation === operation, !operation.finished else { return }
        let staleConfirmed = confirmedReceipt
        if staleConfirmed?.scope == operation.scope {
            confirmedReceipt = nil
        }

        if operation.applyStarted {
            uncertain = true
            retainSnapshot(operation.candidate)
            retainSnapshot(operation.previous)
            retainSnapshot(staleConfirmed)
            finish(operation, with: .unknown("The core scope changed after apply began; the old operation was not committed or rolled back."), keepCandidate: true)
        } else if operation.fileMayBeInUse {
            retainSnapshot(operation.candidate)
            finish(operation, with: .cancelled, keepCandidate: true)
        } else {
            if let staleConfirmed = staleConfirmed, staleConfirmed.scope == operation.scope {
                removeSnapshot(staleConfirmed)
            }
            finish(operation, with: .cancelled)
        }
    }

    private func finish(_ operation: Operation, with outcome: Outcome, keepCandidate: Bool = false) {
        guard activeOperation === operation, !operation.finished else { return }
        operation.finished = true
        operation.phase = .finished
        clearDeadline(for: operation)
        activeOperation = nil
        advanceStateEpoch()

        if !keepCandidate, let candidate = operation.candidate {
            removeSnapshot(candidate)
        }

        let completion = operation.completion
        operation.completion = nil
        completion?(outcome)
    }

    private func detachActiveOperationForAdoption() -> (completion: ((Outcome) -> Void)?, outcome: Outcome, cleanup: [Receipt])? {
        guard let operation = activeOperation else { return nil }
        let outcome: Outcome = operation.applyStarted
            ? .unknown("A fresh readback superseded an in-flight apply.")
            : .cancelled
        let snapshots = [operation.candidate, operation.previous].compactMap { $0 }
        let cleanup: [Receipt]
        if operation.fileMayBeInUse {
            snapshots.forEach(retainSnapshot)
            cleanup = []
        } else {
            cleanup = snapshots
        }
        return detach(operation, with: outcome, cleanup: cleanup)
    }

    private func detachActiveOperationForInvalidation() -> (completion: ((Outcome) -> Void)?, outcome: Outcome, cleanup: [Receipt])? {
        guard let operation = activeOperation else { return nil }
        let outcome: Outcome = operation.applyStarted
            ? .unknown("The core lifecycle changed after apply began.")
            : .cancelled
        let snapshots = [operation.candidate, operation.previous].compactMap { $0 }
        let cleanup: [Receipt]
        if operation.fileMayBeInUse {
            snapshots.forEach(retainSnapshot)
            cleanup = []
        } else {
            cleanup = snapshots
        }
        return detach(operation, with: outcome, cleanup: cleanup)
    }

    private func detach(
        _ operation: Operation,
        with outcome: Outcome,
        cleanup: [Receipt]
    ) -> (completion: ((Outcome) -> Void)?, outcome: Outcome, cleanup: [Receipt]) {
        operation.finished = true
        operation.phase = .finished
        clearDeadline(for: operation)
        activeOperation = nil
        advanceStateEpoch()
        let completion = operation.completion
        operation.completion = nil
        return (completion, outcome, cleanup)
    }

    private func discardConfirmedIfScopeDiffers(from scope: String) {
        guard let receipt = confirmedReceipt, receipt.scope != scope else { return }
        confirmedReceipt = nil
        advanceStateEpoch()
        removeSnapshot(receipt)
    }

    private func writeSnapshot(
        data: Data,
        scope: String,
        dataPlane: DataPlaneStatus
    ) throws -> Receipt {
        return try fileQueue.sync {
            try writeSnapshotOnFileQueue(data: data, scope: scope, dataPlane: dataPlane)
        }
    }

    private func writeSnapshotOnFileQueue(
        data: Data,
        scope: String,
        dataPlane: DataPlaneStatus
    ) throws -> Receipt {
        guard directory.isFileURL else {
            throw NSError(
                domain: "RuntimeConfigTransactionController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The snapshot directory must be a local file URL."]
            )
        }

        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let id = UUID()
        let snapshotDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try manager.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let file = snapshotDirectory.appendingPathComponent("config.yaml", isDirectory: false)
        let descriptor = file.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            let error = Self.snapshotIOError("Could not create the configuration snapshot", path: file.path)
            try? manager.removeItem(at: snapshotDirectory)
            throw error
        }

        do {
            try Self.writeAll(data, to: descriptor)
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw Self.snapshotIOError("Could not secure the configuration snapshot", path: file.path)
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw Self.snapshotIOError("Could not flush the configuration snapshot", path: file.path)
            }
            guard Darwin.close(descriptor) == 0 else {
                throw Self.snapshotIOError("Could not close the configuration snapshot", path: file.path)
            }
        } catch {
            _ = Darwin.close(descriptor)
            try? manager.removeItem(at: snapshotDirectory)
            throw error
        }

        return Receipt(
            id: id,
            scope: scope,
            file: file,
            data: data,
            digest: Self.sha256Hex(data),
            dataPlane: dataPlane
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard data.isEmpty || bytes.baseAddress != nil else {
                throw NSError(
                    domain: "RuntimeConfigTransactionController",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not access the configuration snapshot bytes."]
                )
            }

            var offset = 0
            while offset < data.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw Self.snapshotIOError("Could not write the configuration snapshot", code: errno)
                }
                guard result > 0 else {
                    throw NSError(
                        domain: "RuntimeConfigTransactionController",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Writing the configuration snapshot made no progress."]
                    )
                }
                offset += result
            }
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < data.count {
                let length = min(data.count - offset, Int(UInt32.max))
                _ = CC_SHA256_Update(
                    &context,
                    bytes.baseAddress!.advanced(by: offset),
                    CC_LONG(length)
                )
                offset += length
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBufferPointer { buffer in
            _ = CC_SHA256_Final(buffer.baseAddress!, &context)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func removeSnapshot(_ receipt: Receipt) {
        guard !retainedSnapshots.contains(receipt.id) else { return }
        let expectedDirectory = directory
            .appendingPathComponent(receipt.id.uuidString, isDirectory: true)
            .standardizedFileURL
        let expectedFile = expectedDirectory
            .appendingPathComponent("config.yaml", isDirectory: false)
            .standardizedFileURL
        guard receipt.file.standardizedFileURL == expectedFile else { return }

        fileQueue.async {
            try? FileManager.default.removeItem(at: expectedDirectory)
        }
    }

    private static func snapshotIOError(_ message: String, path: String? = nil, code: Int32? = nil) -> NSError {
        let errorCode = code ?? errno
        var info: [String: Any] = [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errorCode)))"]
        if let path = path {
            info[NSFilePathErrorKey] = path
        }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: info)
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private func onMainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    private func advanceStateEpoch() {
        stateEpoch &+= 1
    }
}

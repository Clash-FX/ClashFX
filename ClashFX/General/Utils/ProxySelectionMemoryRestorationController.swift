import Foundation

/// Restores only saved manual Selector choices from a fresh core snapshot.
/// Requests are serialized so a reload can keep its interaction gate raised
/// until restoration has either completed or reached its bounded timeout.
final class ProxySelectionMemoryRestorationController {
    struct Record {
        let group: String
        let name: String
    }

    struct Dependencies {
        let isCurrent: () -> Bool
        let refresh: (_ completion: @escaping (ClashProxyResp?) -> Void) -> Void
        let select: (_ group: String, _ name: String, _ completion: @escaping (Bool) -> Void) -> Void
        let stageTimeout: TimeInterval

        init(
            isCurrent: @escaping () -> Bool,
            refresh: @escaping (_ completion: @escaping (ClashProxyResp?) -> Void) -> Void,
            select: @escaping (_ group: String, _ name: String, _ completion: @escaping (Bool) -> Void) -> Void,
            stageTimeout: TimeInterval = 10
        ) {
            self.isCurrent = isCurrent
            self.refresh = refresh
            self.select = select
            self.stageTimeout = stageTimeout
        }
    }

    private enum StageKind: Equatable {
        case refresh
        case selection
    }

    private enum StageOutcome {
        case snapshot(ClashProxyResp?)
        case selection(Bool)
        case timedOut
    }

    private let dependencies: Dependencies
    private var activeRunID: UUID?
    private var activeStageID: UUID?
    private var activeStageKind: StageKind?
    private var activeStageSettlement: ManagedOperationSettlement<StageOutcome>?
    private var isCancelled = false
    private var didAnySelectionSucceed = false
    private var records = [Record]()
    private var nextRecordIndex = 0
    private var freshSnapshot: ClashProxyResp?
    private var completion: ((Bool) -> Void)?
    private var keepAliveWhileRunning: ProxySelectionMemoryRestorationController?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Loads one fresh snapshot, then restores the last saved record for each
    /// group in deterministic input order. Only Selector groups and known,
    /// selectable members from that snapshot can produce a PUT.
    func restore(records: [Record], completion: @escaping (Bool) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in restore(records: records, completion: completion) }
            return
        }
        guard activeRunID == nil else {
            completion(false)
            return
        }
        guard dependencies.isCurrent() else {
            completion(false)
            return
        }

        let uniqueRecords = Self.lastRecordPerGroup(records)
        guard !uniqueRecords.isEmpty else {
            completion(false)
            return
        }

        let runID = UUID()
        activeRunID = runID
        self.records = uniqueRecords
        nextRecordIndex = 0
        freshSnapshot = nil
        didAnySelectionSucceed = false
        isCancelled = false
        self.completion = completion
        keepAliveWhileRunning = self

        startStage(runID: runID, kind: .refresh) { settle in
            dependencies.refresh { snapshot in settle(.snapshot(snapshot)) }
        }
    }

    /// Stops a pending restore. A selection PUT already handed to the API is
    /// allowed to settle or time out before the completion releases the gate.
    func cancel() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in cancel() }
            return
        }
        guard let runID = activeRunID else { return }
        isCancelled = true
        if activeStageKind == .selection {
            return
        }
        activeStageSettlement?.cancelTimeout()
        finish(runID: runID, result: false)
    }

    private func startStage(
        runID: UUID,
        kind: StageKind,
        request: (@escaping (StageOutcome) -> Void) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeRunID == runID else { return }
        guard !isCancelled, dependencies.isCurrent() else {
            finish(runID: runID, result: false)
            return
        }

        let stageID = UUID()
        activeStageID = stageID
        activeStageKind = kind
        let settlement = ManagedOperationSettlement<StageOutcome> { [weak self] outcome in
            DispatchQueue.main.async { [weak self] in
                self?.stageDidSettle(outcome, runID: runID, stageID: stageID, kind: kind)
            }
        }
        activeStageSettlement = settlement
        settlement.scheduleTimeout(after: max(0.01, dependencies.stageTimeout), queue: .main) {
            .timedOut
        }
        request { outcome in _ = settlement.finish(outcome) }
    }

    private func stageDidSettle(
        _ outcome: StageOutcome,
        runID: UUID,
        stageID: UUID,
        kind: StageKind
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeRunID == runID, activeStageID == stageID, activeStageKind == kind else { return }
        activeStageID = nil
        activeStageKind = nil
        activeStageSettlement = nil

        guard !isCancelled, dependencies.isCurrent() else {
            finish(runID: runID, result: false)
            return
        }

        switch (kind, outcome) {
        case let (.refresh, .snapshot(snapshot)):
            guard let snapshot else {
                finish(runID: runID, result: false)
                return
            }
            freshSnapshot = snapshot
            restoreNextRecord(runID: runID)
        case let (.selection, .selection(succeeded)):
            guard succeeded else {
                finish(runID: runID, result: didAnySelectionSucceed)
                return
            }
            didAnySelectionSucceed = true
            restoreNextRecord(runID: runID)
        case (_, .timedOut):
            finish(runID: runID, result: didAnySelectionSucceed)
        default:
            finish(runID: runID, result: didAnySelectionSucceed)
        }
    }

    private func restoreNextRecord(runID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeRunID == runID else { return }
        guard !isCancelled, dependencies.isCurrent() else {
            finish(runID: runID, result: false)
            return
        }
        guard let freshSnapshot else {
            finish(runID: runID, result: didAnySelectionSucceed)
            return
        }

        while nextRecordIndex < records.count {
            let record = records[nextRecordIndex]
            nextRecordIndex += 1
            guard Self.isSelectable(record, in: freshSnapshot) else { continue }

            startStage(runID: runID, kind: .selection) { settle in
                dependencies.select(record.group, record.name) { succeeded in
                    settle(.selection(succeeded))
                }
            }
            return
        }

        finish(runID: runID, result: didAnySelectionSucceed)
    }

    private func finish(runID: UUID, result: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeRunID == runID else { return }
        activeStageSettlement?.cancelTimeout()
        activeStageSettlement = nil
        activeStageID = nil
        activeStageKind = nil
        activeRunID = nil
        isCancelled = false
        didAnySelectionSucceed = false
        records.removeAll()
        nextRecordIndex = 0
        freshSnapshot = nil
        let callback = completion
        completion = nil
        keepAliveWhileRunning = nil
        callback?(result)
    }

    private static func lastRecordPerGroup(_ records: [Record]) -> [Record] {
        var lastIndexByGroup = [String: Int]()
        for (index, record) in records.enumerated() where !record.group.isEmpty {
            lastIndexByGroup[record.group] = index
        }
        return records.enumerated().compactMap { index, record in
            guard !record.group.isEmpty,
                  !record.name.isEmpty,
                  lastIndexByGroup[record.group] == index else { return nil }
            return record
        }
    }

    private static func isSelectable(_ record: Record, in snapshot: ClashProxyResp) -> Bool {
        guard let group = snapshot.proxiesMap[record.group],
              group.name == record.group,
              group.type == .select,
              (group.all ?? []).contains(record.name),
              let candidate = snapshot.proxiesMap[record.name],
              candidate.name == record.name,
              !ClashProxyType.isCompatibilityFallback(candidate) else { return false }
        return true
    }
}

import Foundation

struct RuntimeProxySelectionPolicy {
    struct Proxy {
        let name: String
        let type: String
        let now: String?
        let all: [String]?

        var isCompatibilityFallback: Bool {
            type == "Compatible" || name == "COMPATIBLE"
        }
    }

    private let proxies: [String: Proxy]

    init?(data: Data?) {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawProxies = root["proxies"] as? [String: Any] else { return nil }

        var proxies = [String: Proxy]()
        for rawValue in rawProxies.values {
            guard let value = rawValue as? [String: Any],
                  let name = value["name"] as? String,
                  let type = value["type"] as? String else { continue }
            proxies[name] = Proxy(
                name: name,
                type: type,
                now: value["now"] as? String,
                all: value["all"] as? [String]
            )
        }
        self.proxies = proxies
    }

    var manualSelections: [String: String] {
        var records = [String: String]()
        for group in proxies.values where group.type == "Selector" {
            guard let selected = group.now,
                  isSelectable(group: group.name, target: selected) else { continue }
            records[group.name] = selected
        }
        return records
    }

    func isSelectable(group groupName: String, target targetName: String) -> Bool {
        // Mirrors ProxySelectionMemoryRestorationController's fresh-snapshot predicate.
        guard let group = proxies[groupName],
              group.name == groupName,
              group.type == "Selector",
              (group.all ?? []).contains(targetName),
              let candidate = proxies[targetName],
              candidate.name == targetName,
              !candidate.isCompatibilityFallback else { return false }
        return true
    }

    func confirms(_ records: [String: String]) -> Bool {
        records.allSatisfy { group, target in
            guard isSelectable(group: group, target: target),
                  proxies[group]?.now == target else { return false }
            return true
        }
    }
}

final class RuntimeProxySelectionRestoreSequence {
    enum Outcome {
        case accepted
        case rejected(String)
        case uncertain(String)
    }

    typealias HTTPCompletion = (Data?, Int?, Error?) -> Void
    typealias HTTPRequest = (String, String, [String: Any]?, TimeInterval, @escaping HTTPCompletion) -> Void

    private let records: [String: String]
    private let strict: Bool
    private let isCurrent: () -> Bool
    private let request: HTTPRequest
    private let operationTimeout: TimeInterval
    private let deadline: TimeInterval
    private var completion: ((Outcome) -> Void)?
    private var targets = [(group: String, name: String)]()
    private var nextTargetIndex = 0
    private var hasIssuedWrite = false
    private var hasFinished = false
    private var deadlineWorkItem: DispatchWorkItem?
    private var keepAliveWhileRunning: RuntimeProxySelectionRestoreSequence?

    init(
        records: [String: String],
        strict: Bool,
        operationTimeout: TimeInterval = 10,
        isCurrent: @escaping () -> Bool,
        request: @escaping HTTPRequest,
        completion: @escaping (Outcome) -> Void
    ) {
        self.records = records
        self.strict = strict
        self.operationTimeout = operationTimeout.isFinite && operationTimeout > 0
            ? operationTimeout
            : 10
        deadline = ProcessInfo.processInfo.systemUptime + self.operationTimeout
        self.isCurrent = isCurrent
        self.request = request
        self.completion = completion
    }

    func start() {
        onMain { self.startOnMain() }
    }

    private func startOnMain() {
        guard !hasFinished else { return }
        keepAliveWhileRunning = self
        guard isCurrent() else {
            finish(.rejected("Runtime API scope changed"))
            return
        }
        guard !records.isEmpty else {
            finish(.accepted)
            return
        }

        let deadlineItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finishForDeadline()
        }
        deadlineWorkItem = deadlineItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime, execute: deadlineItem)
        request("/proxies", "GET", nil, remainingTime) { [weak self] data, status, error in
            guard let self else { return }
            self.onMain { self.initialSnapshotDidLoad(data, status: status, error: error) }
        }
    }

    private func initialSnapshotDidLoad(_ data: Data?, status: Int?, error: Error?) {
        guard !hasFinished else { return }
        guard checkCurrentScope() else { return }
        guard checkDeadline() else { return }
        guard error == nil, status == 200,
              let snapshot = RuntimeProxySelectionPolicy(data: data) else {
            finish(.rejected("Runtime proxy selections could not be read."))
            return
        }

        let validTargets = records.keys.sorted().compactMap { group -> (group: String, name: String)? in
            guard let name = records[group], snapshot.isSelectable(group: group, target: name) else {
                return nil
            }
            return (group, name)
        }
        if strict, validTargets.count != records.count {
            finish(.rejected("A previous proxy selection is missing or invalid."))
            return
        }
        targets = validTargets
        guard !targets.isEmpty else {
            finish(.accepted)
            return
        }
        sendNextSelection()
    }

    private func sendNextSelection() {
        guard !hasFinished else { return }
        guard checkCurrentScope() else { return }
        guard checkDeadline() else { return }
        guard nextTargetIndex < targets.count else {
            verifySelections()
            return
        }

        let target = targets[nextTargetIndex]
        hasIssuedWrite = true
        request(
            "/proxies/\(Self.encodePathComponent(target.group))",
            "PUT",
            ["name": target.name],
            remainingTime
        ) { [weak self] _, status, error in
            guard let self else { return }
            self.onMain {
                guard !self.hasFinished else { return }
                guard self.checkCurrentScope() else { return }
                guard self.checkDeadline() else { return }
                if error != nil {
                    self.finish(.uncertain("A proxy selection request did not receive a conclusive reply."))
                } else if let status, (400 ... 499).contains(status) {
                    self.finish(.rejected("The core rejected a proxy selection (HTTP \(status))."))
                } else if status == 204 {
                    self.nextTargetIndex += 1
                    DispatchQueue.main.async { self.sendNextSelection() }
                } else {
                    self.finish(.uncertain("The proxy selection result is unknown."))
                }
            }
        }
    }

    private func verifySelections() {
        guard !hasFinished else { return }
        guard checkCurrentScope() else { return }
        guard checkDeadline() else { return }
        request("/proxies", "GET", nil, remainingTime) { [weak self] data, status, error in
            guard let self else { return }
            self.onMain {
                guard !self.hasFinished else { return }
                guard self.checkCurrentScope() else { return }
                guard self.checkDeadline() else { return }
                guard error == nil, status == 200,
                      let snapshot = RuntimeProxySelectionPolicy(data: data) else {
                    self.finish(.uncertain("Proxy selections could not be verified after applying them."))
                    return
                }
                let expected = Dictionary(uniqueKeysWithValues: self.targets.map { ($0.group, $0.name) })
                guard snapshot.confirms(expected) else {
                    self.finish(.rejected("The core did not retain the requested proxy selections."))
                    return
                }
                self.finish(.accepted)
            }
        }
    }

    private func checkCurrentScope() -> Bool {
        guard isCurrent() else {
            let reason = hasIssuedWrite
                ? "Runtime API scope changed after proxy selection writes began."
                : "Runtime API scope changed"
            finish(hasIssuedWrite ? .uncertain(reason) : .rejected(reason))
            return false
        }
        return true
    }

    private func checkDeadline() -> Bool {
        guard remainingTime > 0 else {
            finishForDeadline()
            return false
        }
        return true
    }

    private func finishForDeadline() {
        let reason = hasIssuedWrite
            ? "Proxy selection operation timed out after a write was issued."
            : "Proxy selection operation timed out before applying any writes."
        finish(hasIssuedWrite ? .uncertain(reason) : .rejected(reason))
    }

    private func finish(_ outcome: Outcome) {
        guard !hasFinished else { return }
        let keepAlive = self
        hasFinished = true
        deadlineWorkItem?.cancel()
        deadlineWorkItem = nil
        let callback = completion
        completion = nil
        keepAliveWhileRunning = nil
        callback?(outcome)
        _ = keepAlive
    }

    private var remainingTime: TimeInterval {
        max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private static func encodePathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}


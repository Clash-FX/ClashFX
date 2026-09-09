//
//  CoreLogGuard.swift
//  ClashFX
//

import Foundation

enum CoreLogRecoveryReason {
    case closedTunSocket
    case outboundInterfaceUnavailable
}

struct CoreLogDecision {
    let entries: [(String, ClashLogLevel)]
    let recoveryReason: CoreLogRecoveryReason?
}

private struct GroupedCoreLogState {
    var windowStartedAt: Date
    var emittedCount: Int
    var suppressedCount: Int
    var sampleMessage: String
    var level: ClashLogLevel
}

/// Prevents a broken core loop from turning one error into unbounded file I/O
/// and queued CocoaLumberjack work. State is protected because Starscream may
/// deliver callbacks off the main queue.
final class CoreLogGuard {
    private let lock = NSLock()
    private let repeatWindow: TimeInterval = 1
    private let fatalSignalInterval: TimeInterval = 2
    private let interfaceFailureWindow: TimeInterval = 2
    private let interfaceFailureThreshold = 50
    private let interfaceFailureSignalInterval: TimeInterval = 30
    private let maximumIdenticalEntries = 3
    private let fatalTunReadErrors = [
        "batch read packet: socket operation on non-socket",
        "batch read packet: bad file descriptor"
    ]
    private let fatalTunReadGroupKey = "closed TUN read failures"

    private var currentMessage: String?
    private var currentLevel: ClashLogLevel = .info
    private var windowStartedAt = Date.distantPast
    private var emittedCount = 0
    private var suppressedCount = 0
    private var lastFatalSignalAt = Date.distantPast
    private var groupedStates: [String: GroupedCoreLogState] = [:]
    private var interfaceFailureWindowStartedAt = Date.distantPast
    private var interfaceFailureCount = 0
    private var lastInterfaceFailureSignalAt = Date.distantPast

    func process(message: String, level: ClashLogLevel, now: Date = Date()) -> CoreLogDecision {
        lock.lock()
        defer { lock.unlock() }

        let isFatalTunReadFailure = fatalTunReadErrors.contains { message.contains($0) }
        let groupedKey = groupedMessageKey(
            for: message,
            isFatalTunReadFailure: isFatalTunReadFailure
        )
        let entries = groupedKey.map {
            processGroupedMessage(key: $0, message: message, level: level, now: now)
        } ?? processExactMessage(message: message, level: level, now: now)

        var recoveryReason: CoreLogRecoveryReason?
        let shouldSignalFatal = isFatalTunReadFailure &&
            now.timeIntervalSince(lastFatalSignalAt) >= fatalSignalInterval
        if shouldSignalFatal {
            lastFatalSignalAt = now
            recoveryReason = .closedTunSocket
        } else if groupedKey != nil, !isFatalTunReadFailure {
            if now.timeIntervalSince(interfaceFailureWindowStartedAt) >= interfaceFailureWindow {
                interfaceFailureWindowStartedAt = now
                interfaceFailureCount = 0
            }
            interfaceFailureCount += 1
            let shouldSignalInterfaceFailure =
                interfaceFailureCount >= interfaceFailureThreshold &&
                now.timeIntervalSince(lastInterfaceFailureSignalAt) >= interfaceFailureSignalInterval
            if shouldSignalInterfaceFailure {
                lastInterfaceFailureSignalAt = now
                recoveryReason = .outboundInterfaceUnavailable
            }
        }

        return CoreLogDecision(entries: entries, recoveryReason: recoveryReason)
    }

    private func processExactMessage(
        message: String,
        level: ClashLogLevel,
        now: Date
    ) -> [(String, ClashLogLevel)] {
        var entries: [(String, ClashLogLevel)] = []
        let isSameWindow = currentMessage == message &&
            now.timeIntervalSince(windowStartedAt) < repeatWindow

        if isSameWindow {
            if emittedCount < maximumIdenticalEntries {
                emittedCount += 1
                entries.append((message, level))
            } else {
                suppressedCount += 1
            }
        } else {
            if let previous = currentMessage, suppressedCount > 0 {
                entries.append((
                    "[Core Log] Suppressed \(suppressedCount) repeated entries: \(previous)",
                    currentLevel
                ))
            }
            currentMessage = message
            currentLevel = level
            windowStartedAt = now
            emittedCount = 1
            suppressedCount = 0
            entries.append((message, level))
        }

        return entries
    }

    private func processGroupedMessage(
        key: String,
        message: String,
        level: ClashLogLevel,
        now: Date
    ) -> [(String, ClashLogLevel)] {
        var entries: [(String, ClashLogLevel)] = []
        var state = groupedStates[key] ?? GroupedCoreLogState(
            windowStartedAt: now,
            emittedCount: 0,
            suppressedCount: 0,
            sampleMessage: message,
            level: level
        )

        if now.timeIntervalSince(state.windowStartedAt) >= repeatWindow {
            if state.suppressedCount > 0 {
                entries.append((
                    "[Core Log] Suppressed \(state.suppressedCount) \(key) entries; sample: \(state.sampleMessage)",
                    state.level
                ))
            }
            state = GroupedCoreLogState(
                windowStartedAt: now,
                emittedCount: 0,
                suppressedCount: 0,
                sampleMessage: message,
                level: level
            )
        }

        if state.emittedCount < maximumIdenticalEntries {
            state.emittedCount += 1
            entries.append((message, level))
        } else {
            state.suppressedCount += 1
        }
        groupedStates[key] = state
        return entries
    }

    private func groupedMessageKey(
        for message: String,
        isFatalTunReadFailure: Bool
    ) -> String? {
        if isFatalTunReadFailure {
            return fatalTunReadGroupKey
        }
        let isAutoDetectMessage = message.contains("[TUN] Auto detect interface for ")
        let isAutoDetectFailure = message.contains("get empty name") ||
            message.contains("failed, return '<invalid>'")
        if isAutoDetectMessage, isAutoDetectFailure {
            return "TUN interface auto-detect failures"
        }
        if message.contains("error: interface not found") {
            return "TUN interface-not-found failures"
        }
        return nil
    }
}

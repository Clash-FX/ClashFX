//
//  Logger.swift
//  ClashX
//
//  Created by CYC on 2018/8/7.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import CocoaLumberjack
import Foundation

private final class ClashFXLogFileManager: DDLogFileManagerDefault {
    override var newLogFileName: String {
        let appName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return LogTimestampFormatting.fileName(appName: appName)
    }
}

enum CoreLogRecoveryReason {
    case closedTunSocket
    case outboundInterfaceUnavailable
}

private struct CoreLogDecision {
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
private final class CoreLogGuard {
    private let lock = NSLock()
    private let repeatWindow: TimeInterval = 1
    private let fatalSignalInterval: TimeInterval = 2
    private let interfaceFailureWindow: TimeInterval = 2
    private let interfaceFailureThreshold = 50
    private let interfaceFailureSignalInterval: TimeInterval = 30
    private let maximumIdenticalEntries = 3
    private let fatalTunReadError = "batch read packet: socket operation on non-socket"

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

        let groupedKey = groupedMessageKey(for: message)
        let entries = groupedKey.map {
            processGroupedMessage(key: $0, message: message, level: level, now: now)
        } ?? processExactMessage(message: message, level: level, now: now)

        var recoveryReason: CoreLogRecoveryReason?
        let shouldSignalFatal = message.contains(fatalTunReadError) &&
            now.timeIntervalSince(lastFatalSignalAt) >= fatalSignalInterval
        if shouldSignalFatal {
            lastFatalSignalAt = now
            recoveryReason = .closedTunSocket
        } else if groupedKey != nil {
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

    private func groupedMessageKey(for message: String) -> String? {
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

class Logger {
    static let shared = Logger()
    var fileLogger: DDFileLogger
    private let coreLogGuard = CoreLogGuard()

    private init() {
        fileLogger = DDFileLogger(logFileManager: ClashFXLogFileManager())
        #if DEBUG
            DDLog.add(DDOSLogger.sharedInstance)
        #endif
        fileLogger.logFormatter = DDLogFileFormatterDefault(
            dateFormatter: LogTimestampFormatting.lineDateFormatter()
        )
        fileLogger.rollingFrequency = TimeInterval(60 * 60 * 24) // 24 hours
        fileLogger.logFileManager.maximumNumberOfLogFiles = 3
        DDLog.add(fileLogger)
        dynamicLogLevel = ConfigManager.selectLoggingApiLevel.toDDLogLevel()
    }

    private func logToFile(msg: String, level: ClashLogLevel) {
        switch level {
        case .debug, .silent:
            DDLogDebug(DDLogMessageFormat(stringLiteral: msg))
        case .error:
            DDLogError(DDLogMessageFormat(stringLiteral: msg))
        case .info:
            DDLogInfo(DDLogMessageFormat(stringLiteral: msg))
        case .warning:
            DDLogWarn(DDLogMessageFormat(stringLiteral: msg))
        case .unknow:
            DDLogWarn(DDLogMessageFormat(stringLiteral: msg))
        }
    }

    static func log(_ msg: String, level: ClashLogLevel = .info, file: String = #file, function: String = #function) {
        shared.logToFile(msg: "[\(level.rawValue)] \(file) \(function) \(msg)", level: level)
    }

    /// Returns a recovery reason when the active TUN core should be rebuilt.
    /// Exact repeats and known interface-error variants are bounded before
    /// reaching the asynchronous file logger.
    @discardableResult
    static func logCore(_ msg: String, level: ClashLogLevel) -> CoreLogRecoveryReason? {
        let decision = shared.coreLogGuard.process(message: msg, level: level)
        for (entry, entryLevel) in decision.entries {
            shared.logToFile(
                msg: "[\(entryLevel.rawValue)] [mihomo_core] \(entry)",
                level: entryLevel
            )
        }
        return decision.recoveryReason
    }

    func logFilePath() -> String {
        return fileLogger.logFileManager.sortedLogFilePaths.first ?? ""
    }

    func logFolder() -> String {
        return fileLogger.logFileManager.logsDirectory
    }
}

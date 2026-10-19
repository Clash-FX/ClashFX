//
//  Logger.swift
//  ClashX
//
//  Created by CYC on 2018/8/7.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import CocoaLumberjack
import Foundation

private enum RecoveryJournalOrigin {
    case application
    case core
}

/// Extracts only known structured fields from trusted recovery markers. Free
/// text, resolver values, URLs, and error descriptions never enter the journal.
private enum RecoveryJournalRecord {
    static func make(from message: String, origin: RecoveryJournalOrigin) -> String? {
        switch origin {
        case .application:
            return automaticRecoveryRecord(from: message)
        case .core:
            return dnsListenerRecord(from: message)
        }
    }

    private static func automaticRecoveryRecord(from message: String) -> String? {
        let marker = "[Automatic Recovery]"
        guard message.hasPrefix(marker) else { return nil }
        let tail = message.dropFirst(marker.count).prefix(2_048)
        let allowedKeys: Set<String> = [
            "id", "stage", "trigger", "generation", "groups", "source", "launch", "outcome", "code",
        ]
        var fields = [String: String]()

        for token in tail.split(whereSeparator: \.isWhitespace) {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0])
            let value = String(pair[1])
            guard allowedKeys.contains(key), fields[key] == nil, isSafeToken(value) else { continue }

            var validValue = false
            switch key {
            case "id", "launch":
                validValue = value == "unknown" || UUID(uuidString: value) != nil
            case "stage":
                validValue = ["request", "capture", "commit", "readback", "launch", "blocked", "cancelled", "failed"].contains(value)
            case "trigger":
                validValue = ["cpu-watchdog", "data-plane", "runtime-health", "wake-or-network"].contains(value)
            case "generation", "groups":
                validValue = Int(value).map { $0 >= 0 } ?? false
            case "source":
                validValue = ["profile-memory", "fresh-runtime+profile-memory"].contains(value)
            case "outcome":
                validValue = ["blocked", "rejected", "failed", "verified", "accepted"].contains(value)
            case "code":
                validValue = [
                    "checkpoint-unavailable", "selection-mismatch", "listener-readiness",
                    "runtime-restore-failed", "builtin-fallback", "explicit-scope-change", "mode-queue-wait", "mode-queue-drained", "mode-queue-timeout",
                ].contains(value)
            default:
                break
            }
            if validValue {
                fields[key] = value
            }
        }
        guard let stage = fields["stage"] else { return nil }
        let orderedKeys = ["id", "stage", "trigger", "generation", "groups", "source", "launch", "outcome", "code"]
        let payload = orderedKeys.compactMap { key in
            fields[key].map { "\(key)=\($0)" }
        }.joined(separator: " ")
        return "event=automatic_recovery \(payload.isEmpty ? "stage=\(stage)" : payload)"
    }

    private static func dnsListenerRecord(from message: String) -> String? {
        if let range = message.range(of: "dns_listener_transition family=ipv6 ") {
            let tail = message[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let fields = structuredFields(after: Substring(tail),
                allowed: ["source_port", "target_port", "bootstrap_references_retargeted"])
            guard let sourcePort = validPort(fields["source_port"]),
                  let targetPort = validPort(fields["target_port"]),
                  let count = fields["bootstrap_references_retargeted"],
                  let number = Int(count), number >= 0 else { return nil }
            return "event=dns_listener_transition family=ipv6 source_port=\(sourcePort) target_port=\(targetPort) bootstrap_references_retargeted=\(number)"
        }

        if let range = message.range(of: "dns_listener_transition ") {
            let fields = structuredFields(
                after: message[range.upperBound...],
                allowed: ["source_host_class", "source_port", "target_address", "target_port", "bootstrap_references_retargeted"]
            )
            guard let hostClass = fields["source_host_class"],
                  ["wildcard", "loopback", "other", "unspecified"].contains(hostClass),
                  let sourcePort = validPort(fields["source_port"]),
                  fields["target_address"] == "127.0.0.1",
                  let targetPort = validPort(fields["target_port"]),
                  let referenceCount = fields["bootstrap_references_retargeted"], Int(referenceCount) != nil else {
                return nil
            }
            return "event=dns_listener_transition source_host_class=\(hostClass) source_port=\(sourcePort) target_address=127.0.0.1 target_port=\(targetPort) bootstrap_references_retargeted=\(referenceCount)"
        }

        if let range = message.range(of: "dns_listener_probe ") {
            let fields = structuredFields(
                after: message[range.upperBound...],
                allowed: ["address", "port", "transport", "result", "transports"]
            )
            guard fields["address"] == "127.0.0.1",
                  let port = validPort(fields["port"]),
                  let result = fields["result"], ["available", "unavailable"].contains(result) else {
                return nil
            }
            if let transport = fields["transport"], ["tcp", "udp"].contains(transport) {
                return "event=dns_listener_probe address=127.0.0.1 port=\(port) transport=\(transport) result=\(result)"
            }
            if fields["transports"] == "tcp,udp" {
                return "event=dns_listener_probe address=127.0.0.1 port=\(port) transports=tcp,udp result=\(result)"
            }
        }
        return nil
    }

    private static func structuredFields(after tail: Substring, allowed: Set<String>) -> [String: String] {
        var fields = [String: String]()
        for token in tail.split(whereSeparator: \.isWhitespace) {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { break }
            let key = String(pair[0])
            let value = String(pair[1])
            guard allowed.contains(key), fields[key] == nil, isSafeToken(value) else { break }
            fields[key] = value
        }
        return fields
    }

    private static func validPort(_ value: String?) -> Int? {
        guard let value = value, let port = Int(value), (1 ... 65_535).contains(port) else { return nil }
        return port
    }

    private static func isSafeToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let character = scalar.value
            return (48 ... 57).contains(character) || (65 ... 90).contains(character) ||
                (97 ... 122).contains(character) || [45, 95, 46, 43, 44].contains(character)
        }
    }
}

private final class ClashFXLogFileManager: DDLogFileManagerDefault {
    override var newLogFileName: String {
        let appName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return LogTimestampFormatting.fileName(appName: appName)
    }
}

class Logger {
    static let shared = Logger()
    var fileLogger: DDFileLogger
    private let coreLogGuard = CoreLogGuard()
    private let recoveryEventJournal: RecoveryEventJournal?

    private init() {
        let createdFileLogger = DDFileLogger(logFileManager: ClashFXLogFileManager())
        fileLogger = createdFileLogger
        let logDirectory = createdFileLogger.logFileManager.logsDirectory
        recoveryEventJournal = logDirectory.isEmpty ? nil : RecoveryEventJournal(
            directory: URL(fileURLWithPath: logDirectory, isDirectory: true)
                .appendingPathComponent("Recovery", isDirectory: true)
        )
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

    private func logToFile(msg: String, level: ClashLogLevel, recoveryRecord: String? = nil) {
        if let recoveryRecord = recoveryRecord {
            recoveryEventJournal?.append(recoveryRecord)
        }
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
        shared.logToFile(
            msg: "[\(level.rawValue)] \(file) \(function) \(msg)",
            level: level,
            recoveryRecord: RecoveryJournalRecord.make(from: msg, origin: .application)
        )
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
                level: entryLevel,
                recoveryRecord: RecoveryJournalRecord.make(from: entry, origin: .core)
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

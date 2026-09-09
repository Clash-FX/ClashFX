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

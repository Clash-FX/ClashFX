//
//  DiagnosticFormatting.swift
//  ClashFX
//

import Foundation

enum DiagnosticRedactor {
    static func redact(_ input: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var output = input

        if !homeDirectory.isEmpty {
            let escapedHome = NSRegularExpression.escapedPattern(for: homeDirectory)
            output = replacingMatches(
                in: output,
                pattern: "\(escapedHome)(?=/|\\s|$)",
                with: "<redacted-home>"
            )
        }

        let patterns: [(String, String)] = [
            (#"(?<![A-Za-z0-9._-])/(?:Users|home)/[^/\s]+"#, "<redacted-home>"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<redacted-ipv4>"),
            (#"(?i)\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b"#, "<redacted-mac>"),
            (#"(?i)\b([a-z][a-z0-9+.-]*://)(?:[^@\s/]+@)?([a-z0-9-]+(?:\.[a-z0-9-]+)+)(?=[:/?#\s]|$)"#, "$1<redacted-host>"),
            (#"(?i)\b((?:server|host|hostname|dns|nameserver|url|endpoint|proxy|sni)\s*[:=]\s*)([a-z0-9-]+(?:\.[a-z0-9-]+)+)(?=[:/\s]|$)"#, "$1<redacted-host>"),
            (#"(?i)((?:-->|dial(?:ing)?|lookup|connect(?:ing)?(?:\s+to)?|resolved?|destination)\s+)([a-z0-9-]+(?:\.[a-z0-9-]+)+)(?=[:/\s]|$)"#, "$1<redacted-host>"),
            (#"(?i)(?<![:/@])\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
            (#"(?<![0-9a-fA-F:])(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(?![0-9a-fA-F:])"#, "<redacted-ipv6>"),
            (#"(?<![0-9a-fA-F:])[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{1,4}){0,6}::[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{1,4}){0,6}(?![0-9a-fA-F:])"#, "<redacted-ipv6>"),
            (#"(?i)\b(authorization)\s*[:=]\s*(?:bearer\s+)?\S+"#, "$1: <redacted>"),
            (#"(?i)\b(bearer)\s+\S+"#, "$1 <redacted>"),
            (#"(?i)\b(token|password|secret|auth|api[-_]?key|key|cookie)\s*[:=]\s*\S+"#, "$1=<redacted>")
        ]

        for (pattern, replacement) in patterns {
            output = replacingMatches(in: output, pattern: pattern, with: replacement)
        }
        return output
    }

    private static func replacingMatches(
        in input: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex ..< input.endIndex, in: input)
        return regex.stringByReplacingMatches(
            in: input,
            range: range,
            withTemplate: replacement
        )
    }
}

enum LogTimestampFormatting {
    static func lineDateFormatter(timeZone: TimeZone = .current) -> DateFormatter {
        return formatter(format: "yyyy/MM/dd HH:mm:ss.SSS XXX", timeZone: timeZone)
    }

    static func fileName(
        appName: String,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let dateFormatter = formatter(format: "yyyy-MM-dd--HH-mm-ss-SSS-xx", timeZone: timeZone)
        return "\(appName) \(dateFormatter.string(from: date)).log"
    }

    private static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = format
        return dateFormatter
    }
}

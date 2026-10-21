import Foundation

/// Keeps runtime-apply failure details useful while safe to show in the UI and logs.
enum RuntimeConfigApplyDiagnostics {
    static let maximumReasonCharacters = 2_000

    enum Transport: String {
        case embedded
        case http
    }

    enum Stage: String {
        case embeddedResponse = "embedded-response"
        case httpResponse = "http-response"
        case httpTransportError = "http-transport-error"
        case cancelled
    }

    enum Decision: Equatable {
        case accepted
        case rejected(String)
        case uncertain(String)
    }

    private static let urlPattern = try? NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#
    )
    private static let credentialKeyPattern = try? NSRegularExpression(
        pattern: #"(?i)[\"']?\b(?:password|passwd|token|secret|auth|authentication|(?:proxy-)?authorization|api[_-]?key|access[_-]?key|client[_-]?(?:secret|id)|credential(?:s)?|private[_-]?key|username|uuid|preshared[_-]?key)\b[\"']?\s*[:=][ \t]*"#
    )
    private static let maximumInputCodeUnits = 65_536

    /// A nil or empty return is not a successful apply and carries a different
    /// diagnostic from an explicit error returned by the embedded core.
    static func embeddedDecision(_ response: String?) -> Decision {
        guard let response = response else {
            return .uncertain("Embedded core returned nil (no response)")
        }
        guard !response.isEmpty else {
            return .uncertain("Embedded core returned an empty response")
        }
        return response == "success" ? .accepted : .rejected(response)
    }

    /// Only a conclusive 2xx apply reply succeeds. A transport error, including
    /// a timeout, leaves the result uncertain even if a status was also present.
    static func httpDecision(statusCode: Int?, errorDescription: String?, body: Data?) -> Decision {
        if let errorDescription = errorDescription, !errorDescription.isEmpty {
            return .uncertain(errorDescription)
        }
        if statusCode == 204 {
            return .accepted
        }
        if statusCode == 408 {
            return .uncertain("HTTP 408 timed out before the configuration apply was confirmed")
        }
        if let statusCode = statusCode, (400 ... 499).contains(statusCode) {
            let detail = httpMessage(from: body) ?? "Core rejected configuration (HTTP \(statusCode))"
            return .rejected(detail)
        }
        if let statusCode = statusCode {
            return .uncertain("HTTP \(statusCode) did not confirm the configuration apply")
        }
        return .uncertain("HTTP response did not include a status code")
    }

    /// Reads only a JSON message field, never the full response body.
    static func httpMessage(from body: Data?) -> String? {
        guard let body = body,
              let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        if let message = nonemptyString(dictionary["message"]) {
            return message
        }
        if let error = dictionary["error"] as? [String: Any],
           let message = nonemptyString(error["message"]) {
            return message
        }
        if let error = nonemptyString(dictionary["error"]) {
            return error
        }
        return nonemptyString(dictionary["detail"])
    }

    /// Redacts URLs and credential fields, removes log-control characters, and
    /// bounds the resulting single-line detail.
    static func sanitize(_ text: String, maximumCharacters: Int = maximumReasonCharacters) -> String {
        let limit = max(0, maximumCharacters)
        guard (text as NSString).length <= maximumInputCodeUnits else {
            return String("[oversized diagnostic detail redacted]".prefix(limit))
        }
        guard let urlPattern, let credentialKeyPattern else {
            return String("[diagnostic redaction unavailable]".prefix(limit))
        }
        let source = text as NSString
        let urlRanges = urlPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map { $0.range }
        let credentialsRedacted = redactCredentialValues(in: text, pattern: credentialKeyPattern, urlRanges: urlRanges)
        let safe = replacingURLs(in: credentialsRedacted, pattern: urlPattern)

        var singleLine = String.UnicodeScalarView()
        for scalar in safe.unicodeScalars {
            let isBidiControl = (0x202A ... 0x202E).contains(scalar.value)
                || (0x2066 ... 0x2069).contains(scalar.value)
                || scalar.value == 0x061C
                || scalar.value == 0x200E
                || scalar.value == 0x200F
            if CharacterSet.controlCharacters.contains(scalar) || isBidiControl {
                singleLine.append(" ")
            } else {
                singleLine.append(scalar)
            }
        }

        let normalized = String(singleLine)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(normalized.prefix(limit))
    }

    /// Keep transport bookkeeping in the log; the alert carries the safe core reason.
    static func displayReason(_ detail: String) -> String {
        let safe = sanitize(detail)
        return safe.isEmpty ? "Core did not provide a failure reason" : safe
    }

    /// Include request identity in diagnostic logs without exposing credentials.
    static func formattedReason(
        transport: Transport,
        stage: Stage,
        requestID: UUID,
        expectedEpoch: UInt64?,
        currentEpoch: UInt64?,
        detail: String
    ) -> String {
        let prefix = "[Runtime Config Apply] transport=\(transport.rawValue) stage=\(stage.rawValue) "
            + "requestUUID=\(requestID.uuidString.lowercased()) "
            + "expectedEpoch=\(epochText(expectedEpoch)) currentEpoch=\(epochText(currentEpoch)) detail="
        let detailLimit = max(0, maximumReasonCharacters - prefix.count)
        let safeDetail = sanitize(detail, maximumCharacters: detailLimit)
        return prefix + (safeDetail.isEmpty ? "[empty detail]" : safeDetail)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func epochText(_ epoch: UInt64?) -> String {
        return epoch.map(String.init) ?? "n/a"
    }

    /// A regexp identifies keys only. Values may contain escaped quotes and
    /// nested collections, so their boundary must not be guessed from `]`/`}`.
    private static func redactCredentialValues(in text: String, pattern: NSRegularExpression, urlRanges: [NSRange]) -> String {
        let source = text as NSString
        let scanner = CredentialValueScanner(source: source)
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        var cursor = 0
        var urlIndex = 0
        var result = ""
        for match in matches where match.range.location >= cursor {
            // A token/username query inside a URL is handled by URL redaction,
            // not mistaken for an unquoted scalar that swallows the next error.
            while urlIndex < urlRanges.count, NSMaxRange(urlRanges[urlIndex]) <= match.range.location { urlIndex += 1 }
            if urlIndex < urlRanges.count, NSLocationInRange(match.range.location, urlRanges[urlIndex]) { continue }
            let start = NSMaxRange(match.range)
            result += source.substring(with: NSRange(location: cursor, length: start - cursor))
            result += "[redacted]"
            let key = source.substring(with: match.range).lowercased()
            cursor = scanner.endOfValue(at: start, keyStart: match.range.location,
                                        authorization: key.contains("authorization"))
        }
        result += source.substring(from: cursor)
        return result
    }

    private struct CredentialValueScanner {
        let source: NSString

        private func isQuote(_ character: unichar) -> Bool {
            character == 34 || character == 39 || character == 96
        }

        private func lineEnd(from start: Int) -> Int {
            var index = start
            while index < source.length, source.character(at: index) != 10, source.character(at: index) != 13 {
                index += 1
            }
            return index
        }

        private func afterNewline(_ start: Int) -> Int {
            guard start < source.length else { return start }
            if source.character(at: start) == 13, start + 1 < source.length, source.character(at: start + 1) == 10 {
                return start + 2
            }
            return start + 1
        }

        private func indentation(before key: Int) -> Int {
            var start = key
            while start > 0, source.character(at: start - 1) != 10, source.character(at: start - 1) != 13 {
                start -= 1
            }
            let prefix = source.substring(with: NSRange(location: start, length: key - start))
            if prefix.trimmingCharacters(in: .whitespaces) == "-" { return key - start }
            return prefix.prefix { $0 == " " || $0 == "\t" }.count
        }

        /// Single-quoted YAML escapes an apostrophe by doubling it. JSON/YAML
        /// double quotes instead use backslash escapes. Unterminated input is
        /// redacted through EOF, never returned as a partial credential.
        private func quotedEnd(at start: Int) -> Int {
            let quote = source.character(at: start)
            var index = start + 1
            while index < source.length {
                let character = source.character(at: index)
                if quote == 34, character == 92 {
                    index = min(source.length, index + 2)
                } else if character == quote {
                    if quote == 39, index + 1 < source.length, source.character(at: index + 1) == quote {
                        index += 2
                    } else {
                        return index + 1
                    }
                } else {
                    index += 1
                }
            }
            return source.length
        }

        private func hasValueBoundary(after end: Int, allowColon: Bool) -> Bool {
            guard end < source.length else { return true }
            let delimiters: [unichar] = [9, 10, 13, 32, 41, 44, 59, 93, 125]
            let character = source.character(at: end)
            return delimiters.contains(character) || (allowColon && (character == 58 || character == 35))
        }

        private func collectionEnd(at start: Int) -> Int {
            var closers = [unichar]()
            var index = start
            var expectsNode = true
            var plain = false
            var nodeClosed = false
            let spaces: [unichar] = [9, 10, 13, 32]
            while index < source.length {
                let character = source.character(at: index)
                let separated = index == start || spaces.contains(source.character(at: index - 1))
                if character == 35, separated || expectsNode || nodeClosed {
                    // Comments may contain delimiters; foo#bar and quoted #
                    // remain plain/quoted data. Flow punctuation separates nodes.
                    index = lineEnd(from: index)
                    continue
                }
                if isQuote(character), expectsNode {
                    index = quotedEnd(at: index)
                    guard hasValueBoundary(after: index, allowColon: true) else { return source.length }
                    expectsNode = false
                    plain = false
                    nodeClosed = true
                    continue
                }
                if character == 91 || character == 123 {
                    guard !plain, !nodeClosed, closers.count < 64 else { return source.length }
                    closers.append(character == 91 ? 93 : 125)
                    expectsNode = true
                    nodeClosed = false
                } else if character == 93 || character == 125 {
                    guard closers.last == character else { return source.length }
                    closers.removeLast()
                    if closers.isEmpty { return index + 1 }
                    expectsNode = false
                    plain = false
                    nodeClosed = true
                } else if character == 44 {
                    expectsNode = true
                    plain = false
                    nodeClosed = false
                } else if character == 58 {
                    let next = index + 1
                    let separatedValue = next == source.length || spaces.contains(source.character(at: next))
                        || [44, 91, 93, 123, 125].contains(source.character(at: next))
                    if nodeClosed || separatedValue {
                        expectsNode = true
                        plain = false
                        nodeClosed = false
                    } else {
                        expectsNode = false
                        plain = true
                    }
                } else if !spaces.contains(character) {
                    guard !nodeClosed else { return source.length }
                    expectsNode = false
                    plain = true
                }
                index += 1
            }
            return source.length
        }

        private func continuationEnd(after end: Int, indentation: Int) -> Int {
            var last = end
            var next = afterNewline(end)
            while next < source.length {
                let end = lineEnd(from: next)
                var content = next
                while content < end, source.character(at: content) == 32 || source.character(at: content) == 9 {
                    content += 1
                }
                guard content == end || content - next > indentation else { break }
                last = end
                next = afterNewline(end)
            }
            return last
        }

        private func isJSONPrimitive(at start: Int) -> Bool {
            let boundaries: [unichar] = [9, 10, 13, 32, 44, 93, 125]
            for literal in ["true", "false", "null"] {
                let end = start + literal.utf16.count
                if end <= source.length,
                   source.substring(with: NSRange(location: start, length: end - start)) == literal {
                    return end == source.length || boundaries.contains(source.character(at: end))
                }
            }
            guard source.character(at: start) == 45 || (48 ... 57).contains(source.character(at: start)) else { return false }
            var end = start
            let numberCharacters: [unichar] = [43, 45, 46, 69, 101]
            while end < source.length,
                  (48 ... 57).contains(source.character(at: end)) || numberCharacters.contains(source.character(at: end)) { end += 1 }
            guard end == source.length || boundaries.contains(source.character(at: end)) else { return false }
            return Double(source.substring(with: NSRange(location: start, length: end - start))) != nil
        }

        /// JSON permits line breaks around `:` and before a flow value. Do
        /// not confuse an unindented quoted YAML peer key with that value.
        private func flowValueStart(after start: Int) -> Int {
            var next = start
            while next < source.length, [9, 10, 13, 32].contains(source.character(at: next)) { next += 1 }
            guard next > start, next < source.length else { return start }
            let character = source.character(at: next)
            if isQuote(character) {
                let end = quotedEnd(at: next)
                var suffix = end
                while suffix < source.length, [9, 32].contains(source.character(at: suffix)) { suffix += 1 }
                if suffix < source.length, source.character(at: suffix) == 58 { return start }
                return next
            }
            if character == 91 || character == 123 || isJSONPrimitive(at: next) {
                return next
            }
            return start
        }

        func endOfValue(at input: Int, keyStart: Int, authorization: Bool) -> Int {
            guard input < source.length else { return source.length }
            let start = flowValueStart(after: input)
            let character = source.character(at: start)
            if authorization {
                // Digest attributes and folded headers are all sensitive.
                let valueEnd = isQuote(character) ? quotedEnd(at: start) : start
                return continuationEnd(after: lineEnd(from: valueEnd), indentation: indentation(before: keyStart))
            }
            if isQuote(character) {
                var end = quotedEnd(at: start)
                while end < source.length, isQuote(source.character(at: end)) { end = quotedEnd(at: end) }
                guard hasValueBoundary(after: end, allowColon: false) else {
                    return continuationEnd(after: lineEnd(from: end), indentation: indentation(before: keyStart))
                }
                return end
            }
            if character == 91 || character == 123 {
                let end = collectionEnd(at: start)
                guard hasValueBoundary(after: end, allowColon: false) else {
                    return continuationEnd(after: lineEnd(from: end), indentation: indentation(before: keyStart))
                }
                return end
            }
            // A plain YAML scalar may contain spaces and punctuation. Treat its
            // whole line and indented continuations as sensitive; splitting it
            // at a semicolon/space could expose a valid password suffix.
            return continuationEnd(after: lineEnd(from: start), indentation: indentation(before: keyStart))
        }
    }

    private static func replacingURLs(in text: String, pattern: NSRegularExpression) -> String {
        let source = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        var result = source
        for match in matches.reversed() {
            var token = source.substring(with: match.range)
            var trailing = ""
            while let last = token.last, ".,;:!?)]}".contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                token.removeLast()
            }
            let replacement = safeURL(token) + trailing
            result = result.replacingCharacters(in: match.range, with: replacement) as NSString
        }
        return result as String
    }

    private static func safeURL(_ value: String) -> String {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme else {
            return "[redacted-url]"
        }
        guard ["http", "https", "tcp", "udp", "tls", "quic"].contains(scheme.lowercased()) else {
            return "\(scheme.lowercased())://[redacted]"
        }
        guard let rawHost = components.host, !rawHost.isEmpty else {
            return "\(scheme.lowercased())://[redacted]"
        }

        let host = rawHost.contains(":") && !rawHost.hasPrefix("[") ? "[\(rawHost)]" : rawHost
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme.lowercased())://\(host)\(port)/[redacted]"
    }
}

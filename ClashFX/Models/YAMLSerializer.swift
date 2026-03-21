import Foundation

enum YAMLSerializer {
    static func serialize(_ document: ConfigDocument) -> String {
        let dict = document.toYAMLDictionary()
        var lines: [String] = []
        serializeMapping(dict, to: &lines, indent: 0)
        return lines.joined(separator: "\n") + "\n"
    }

    static func serializeValue(_ value: Any, to lines: inout [String], indent: Int) {
        switch value {
        case let dict as OrderedDictionary<String, Any>:
            serializeMapping(dict, to: &lines, indent: indent)
        case let dict as [String: Any]:
            let ordered = stableSortedDict(dict)
            serializeMapping(ordered, to: &lines, indent: indent)
        case let arr as [Any]:
            serializeArray(arr, to: &lines, indent: indent)
        default:
            break
        }
    }

    private static func serializeMapping(_ dict: OrderedDictionary<String, Any>, to lines: inout [String], indent: Int) {
        let pad = String(repeating: " ", count: indent)
        for (key, value) in dict {
            let yamlKey = quoteKeyIfNeeded(String(describing: key))
            if isScalar(value) {
                lines.append("\(pad)\(yamlKey): \(formatScalar(value))")
            } else if let arr = value as? [Any], arr.allSatisfy({ isScalar($0) }), arr.count <= 6 {
                let items = arr.map { formatScalar($0) }.joined(separator: ", ")
                lines.append("\(pad)\(yamlKey): [\(items)]")
            } else if let arr = value as? [Any] {
                lines.append("\(pad)\(yamlKey):")
                serializeArray(arr, to: &lines, indent: indent + 2)
            } else if value is [String: Any] || value is OrderedDictionary<String, Any> {
                lines.append("\(pad)\(yamlKey):")
                serializeValue(value, to: &lines, indent: indent + 2)
            }
        }
    }

    private static func serializeArray(_ arr: [Any], to lines: inout [String], indent: Int) {
        let pad = String(repeating: " ", count: indent)
        for element in arr {
            if isScalar(element) {
                lines.append("\(pad)- \(formatScalar(element))")
            } else if let dict = element as? [String: Any] {
                let ordered = stableSortedDict(dict)
                serializeInlineMapElement(ordered, to: &lines, indent: indent)
            } else if let dict = element as? OrderedDictionary<String, Any> {
                serializeInlineMapElement(dict, to: &lines, indent: indent)
            } else if let subArr = element as? [Any] {
                lines.append("\(pad)-")
                serializeArray(subArr, to: &lines, indent: indent + 2)
            }
        }
    }

    private static func serializeInlineMapElement(_ dict: OrderedDictionary<String, Any>, to lines: inout [String], indent: Int) {
        let pad = String(repeating: " ", count: indent)
        let innerPad = String(repeating: " ", count: indent + 2)
        var isFirst = true
        for (key, value) in dict {
            let yamlKey = quoteKeyIfNeeded(String(describing: key))
            if isFirst {
                if isScalar(value) {
                    lines.append("\(pad)- \(yamlKey): \(formatScalar(value))")
                } else if let arr = value as? [Any], arr.allSatisfy({ isScalar($0) }), arr.count <= 6 {
                    let items = arr.map { formatScalar($0) }.joined(separator: ", ")
                    lines.append("\(pad)- \(yamlKey): [\(items)]")
                } else {
                    lines.append("\(pad)- \(yamlKey):")
                    serializeValue(value, to: &lines, indent: indent + 4)
                }
                isFirst = false
            } else {
                if isScalar(value) {
                    lines.append("\(innerPad)\(yamlKey): \(formatScalar(value))")
                } else if let arr = value as? [Any], arr.allSatisfy({ isScalar($0) }), arr.count <= 6 {
                    let items = arr.map { formatScalar($0) }.joined(separator: ", ")
                    lines.append("\(innerPad)\(yamlKey): [\(items)]")
                } else if let arr = value as? [Any] {
                    lines.append("\(innerPad)\(yamlKey):")
                    serializeArray(arr, to: &lines, indent: indent + 4)
                } else if value is [String: Any] || value is OrderedDictionary<String, Any> {
                    lines.append("\(innerPad)\(yamlKey):")
                    serializeValue(value, to: &lines, indent: indent + 4)
                }
            }
        }
    }

    private static func isScalar(_ value: Any) -> Bool {
        value is String || value is Int || value is Double || value is Bool || value is NSNull
    }

    private static func formatScalar(_ value: Any) -> String {
        switch value {
        case let b as Bool:
            return b ? "true" : "false"
        case let i as Int:
            return String(i)
        case let d as Double:
            if d == d.rounded() && d < 1e15 {
                return String(Int(d))
            }
            return String(d)
        case let s as String:
            return quoteStringIfNeeded(s)
        case is NSNull:
            return "null"
        default:
            return quoteStringIfNeeded(String(describing: value))
        }
    }

    private static func quoteStringIfNeeded(_ s: String) -> String {
        if s.isEmpty { return "''" }

        let lowered = s.lowercased()
        if ["true", "false", "yes", "no", "null", "~", "on", "off"].contains(lowered) {
            return "'\(s)'"
        }

        if let _ = Int(s) { return "'\(s)'" }
        if let _ = Double(s), s.contains(".") { return "'\(s)'" }

        let specialChars = CharacterSet(charactersIn: ":{}[],%&*?|-><=!@`#\"'\n\\")
        if s.unicodeScalars.contains(where: { specialChars.contains($0) }) {
            let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }

        if s.hasPrefix(" ") || s.hasSuffix(" ") {
            return "'\(s)'"
        }

        return s
    }

    private static func quoteKeyIfNeeded(_ key: String) -> String {
        let specialChars = CharacterSet(charactersIn: " :{}[],%&*?|-><=!@`#\"'\n")
        if key.unicodeScalars.contains(where: { specialChars.contains($0) }) {
            return "'\(key)'"
        }
        return key
    }

    private static func stableSortedDict(_ dict: [String: Any]) -> OrderedDictionary<String, Any> {
        let priorityKeys = ["name", "type", "server", "port"]
        var ordered = OrderedDictionary<String, Any>()
        for pk in priorityKeys {
            if let v = dict[pk] { ordered[pk] = v }
        }
        for key in dict.keys.sorted() where !priorityKeys.contains(key) {
            ordered[key] = dict[key]
        }
        return ordered
    }
}

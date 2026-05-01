//
//  SubscriptionInfoFormatter.swift
//  ClashFX
//
//  Formats SubscriptionInfo into human-readable strings for the tray menu.
//

import Cocoa

enum SubscriptionInfoFormatter {
    static func menuSubtitle(for info: SubscriptionInfo) -> String? {
        var parts: [String] = []
        if let traffic = trafficSummary(for: info) {
            parts.append(traffic)
        }
        if let expiry = expirySummary(for: info) {
            parts.append(expiry)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func menuAttributedTitle(title: String, subtitle: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        let separator = NSAttributedString(
            string: "  ",
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        let subFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: subFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        result.append(separator)
        result.append(NSAttributedString(string: subtitle, attributes: subAttrs))
        return result
    }

    static func statusRowAttributedTitle(name: String, summary: String) -> NSAttributedString {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameLine = displayName.isEmpty
            ? NSLocalizedString("Subscription", comment: "subscription status row fallback name")
            : displayName

        let nameParagraph = NSMutableParagraphStyle()
        nameParagraph.paragraphSpacing = 2
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .paragraphStyle: nameParagraph
        ]
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let result = NSMutableAttributedString(string: nameLine, attributes: nameAttrs)
        result.append(NSAttributedString(string: "\n", attributes: nameAttrs))
        result.append(NSAttributedString(string: summary, attributes: summaryAttrs))
        return result
    }

    private static func trafficSummary(for info: SubscriptionInfo) -> String? {
        let used = info.used
        let total = info.total

        if let total, total > 0, let used {
            let usedString = byteString(used)
            let totalString = byteString(total)
            return String(format: NSLocalizedString("%@ / %@ used", comment: "subscription traffic usage"), usedString, totalString)
        }
        if let used {
            return String(format: NSLocalizedString("%@ used", comment: "subscription traffic used only"), byteString(used))
        }
        if let total, total > 0 {
            return String(format: NSLocalizedString("Quota %@", comment: "subscription total quota only"), byteString(total))
        }
        return nil
    }

    private static func expirySummary(for info: SubscriptionInfo) -> String? {
        if let expire = info.expire, expire > 0 {
            let expiryDate = Date(timeIntervalSince1970: expire)
            let now = Date()
            let secondsLeft = expiryDate.timeIntervalSince(now)
            if secondsLeft <= 0 {
                return NSLocalizedString("Expired", comment: "subscription expired")
            }
            let daysLeft = Int(secondsLeft / 86400)
            if daysLeft > 0 {
                return String(format: NSLocalizedString("%d days left", comment: "subscription days remaining"), daysLeft)
            }
            let hoursLeft = max(1, Int(secondsLeft / 3600))
            return String(format: NSLocalizedString("%d hours left", comment: "subscription hours remaining"), hoursLeft)
        }
        if let text = info.expireText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return nil
    }

    private static func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: bytes)
    }
}

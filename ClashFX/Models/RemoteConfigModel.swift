//
//  RemoteConfigModel.swift
//  ClashX
//
//  Created by yicheng on 2019/7/28.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa

class RemoteConfigModel: Codable {
    var url: String
    var name: String
    var userAgent: String?
    var updateTime: Date?
    var updating = false
    var isPlaceHolderName = false
    var generatedByShareLinks = false
    var generatedTemplateVersion: Int?
    var subscriptionInfo: SubscriptionInfo?

    init(url: String, name: String, userAgent: String? = nil, updateTime: Date? = nil) {
        self.url = url
        self.name = name
        self.userAgent = userAgent
        self.updateTime = updateTime
    }

    private enum CodingKeys: String, CodingKey {
        case url, name, userAgent, updateTime, generatedByShareLinks, generatedTemplateVersion, subscriptionInfo
    }

    func displayingTimeString() -> String {
        if updating { return NSLocalizedString("Updating", comment: "") }
        let dateFormater = DateFormatter()
        dateFormater.dateFormat = "MM-dd HH:mm"
        if let date = updateTime {
            return dateFormater.string(from: date)
        }
        return NSLocalizedString("Never", comment: "")
    }
}

extension RemoteConfigModel: Equatable {
    static func == (lhs: RemoteConfigModel, rhs: RemoteConfigModel) -> Bool {
        return lhs.name == rhs.name && lhs.url == rhs.url
    }
}

/// Subscription metadata captured from a remote config response.
///
/// Sourced primarily from the `Subscription-Userinfo` HTTP response header
/// (de-facto Clash/V2Ray convention: `upload=N; download=N; total=N; expire=N`),
/// or as a fallback from pseudo-proxy entries embedded in the subscription
/// body (e.g. names containing "剩余流量" / "套餐到期").
///
/// All fields are optional. A value of `nil` means "unknown / not provided".
/// `total = 0` is treated as "unlimited" by the UI.
struct SubscriptionInfo: Codable, Equatable {
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    /// Unix epoch seconds. `nil` or `0` means no expiry.
    var expire: TimeInterval?
    /// Optional human-readable expiry string captured from pseudo-proxy
    /// entries when the header didn't provide a numeric `expire`.
    /// Examples: "长期有效", "2026-12-31", "Lifetime".
    var expireText: String?

    var used: Int64? {
        switch (upload, download) {
        case let (u?, d?): return u + d
        case let (u?, nil): return u
        case let (nil, d?): return d
        case (nil, nil): return nil
        }
    }

    var hasAnyData: Bool {
        return upload != nil || download != nil || total != nil || expire != nil || expireText != nil
    }

    static func merging(primary: SubscriptionInfo?, fallback: SubscriptionInfo?) -> SubscriptionInfo? {
        guard primary != nil || fallback != nil else { return nil }
        var merged = SubscriptionInfo()
        merged.upload = primary?.upload ?? fallback?.upload
        merged.download = primary?.download ?? fallback?.download
        merged.total = primary?.total ?? fallback?.total
        merged.expire = primary?.expire ?? fallback?.expire
        merged.expireText = primary?.expireText ?? fallback?.expireText
        return merged.hasAnyData ? merged : nil
    }
}

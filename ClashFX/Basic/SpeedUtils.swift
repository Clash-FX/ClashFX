//
//  SpeedUtils.swift
//  ClashX
//
//  Created by yicheng on 2023/7/6.
//  Copyright © 2023 west2online. All rights reserved.
//

import Foundation

enum SpeedUtils {
    private static let menuBarSpeedUnits = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
    private static let menuBarSpeedThreshold = 1000.0
    private static let menuBarSpeedScales = [
        1.0,
        1024.0,
        1024.0 * 1024.0,
        1024.0 * 1024.0 * 1024.0,
        1024.0 * 1024.0 * 1024.0 * 1024.0
    ]

    static func getSpeedString(for byte: Int) -> String {
        return getNetString(for: byte).appending("/s")
    }

    static func getMenuBarSpeedString(for byte: Int) -> String {
        let bytesPerSecond = max(byte, 0)
        if bytesPerSecond < Int(menuBarSpeedThreshold) {
            return "\(bytesPerSecond)\(menuBarSpeedUnits[0])"
        }

        var unitIndex = 0
        while unitIndex < menuBarSpeedUnits.count - 1,
              Double(bytesPerSecond) / menuBarSpeedScales[unitIndex] >= menuBarSpeedThreshold {
            unitIndex += 1
        }

        var value = Double(bytesPerSecond) / menuBarSpeedScales[unitIndex]
        if value.rounded() >= menuBarSpeedThreshold,
           unitIndex < menuBarSpeedUnits.count - 1 {
            unitIndex += 1
            value = Double(bytesPerSecond) / menuBarSpeedScales[unitIndex]
        }

        if value < 9.95 {
            return String(format: "%.1f%@", value, menuBarSpeedUnits[unitIndex])
        }
        return String(format: "%.0f%@", value.rounded(), menuBarSpeedUnits[unitIndex])
    }

    static func getNetString(for byte: Int) -> String {
        let kb = byte / 1024
        if kb < 1024 {
            return "\(kb)KB"
        } else {
            let mb = Double(kb) / 1024.0
            if mb >= 100 {
                if mb >= 1000 {
                    return String(format: "%.1fGB", mb / 1024)
                }
                return String(format: "%.1fMB", mb)
            } else {
                return String(format: "%.2fMB", mb)
            }
        }
    }
}

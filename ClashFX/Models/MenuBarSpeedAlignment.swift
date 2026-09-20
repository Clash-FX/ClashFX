//
//  MenuBarSpeedAlignment.swift
//  ClashFX
//

import AppKit

enum MenuBarSpeedAlignment: Int, CaseIterable {
    case left
    case center
    case right

    static func persisted(rawValue: Int) -> MenuBarSpeedAlignment {
        return MenuBarSpeedAlignment(rawValue: rawValue) ?? .right
    }

    var textAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    func textOriginX(containerWidth: CGFloat, textWidth: CGFloat) -> CGFloat {
        let available = max(0, containerWidth - textWidth)
        switch self {
        case .left:
            return 0
        case .center:
            return available / 2
        case .right:
            return available
        }
    }
}

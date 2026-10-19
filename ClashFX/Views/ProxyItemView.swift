//
//  ProxyItemView.swift
//  ClashX
//
//  Created by yicheng on 2019/11/2.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa

enum ProxyBenchmarkDelayColorCategory: Equatable {
    case fast
    case moderate
    case slow
    case failed
    case unknown

    static func category(for rawValue: Int?) -> ProxyBenchmarkDelayColorCategory {
        guard let rawValue else { return .unknown }
        guard rawValue > 0 else { return .failed }
        if rawValue < 300 { return .fast }
        if rawValue < 800 { return .moderate }
        return .slow
    }

    static func labelColor(for rawValue: Int?) -> NSColor {
        switch category(for: rawValue) {
        case .fast:
            return NSColor(calibratedRed: 30.0 / 255, green: 181.0 / 255, blue: 30.0 / 255, alpha: 1)
        case .moderate:
            return NSColor(calibratedRed: 193.0 / 255, green: 135.0 / 255, blue: 0, alpha: 1)
        case .slow:
            return NSColor(calibratedRed: 1, green: 116.0 / 255, blue: 0, alpha: 1)
        case .failed:
            return NSColor(calibratedRed: 218.0 / 255, green: 0, blue: 3.0 / 255, alpha: 1)
        case .unknown:
            return NSColor.secondaryLabelColor
        }
    }
}

class ProxyItemView: MenuItemBaseView {
    let nameLabel: NSTextField
    let delayLabel: NSTextField
    var imageView: NSImageView?

    static let fixedPlaceHolderWidth: CGFloat = 20 + 50 + 25

    init(proxy: ClashProxy) {
        nameLabel = VibrancyTextField(labelWithString: proxy.name)
        delayLabel = VibrancyTextField(labelWithString: "").setup(allowsVibrancy: false)
        let cell = PaddedNSTextFieldCell()
        cell.widthPadding = 2
        if #available(macOS 11, *) {
            cell.heightPadding = 2
        } else {
            cell.heightPadding = 1
        }
        delayLabel.cell = cell
        super.init(autolayout: false)
        effectView.addSubview(nameLabel)
        effectView.addSubview(delayLabel)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        delayLabel.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = type(of: self).labelFont
        if #available(macOS 11, *) {
            delayLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        } else {
            delayLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        }
        nameLabel.alignment = .left
        nameLabel.lineBreakMode = .byTruncatingTail
        delayLabel.alignment = .right
        delayLabel.lineBreakMode = .byTruncatingTail

        delayLabel.wantsLayer = true
        delayLabel.layer?.cornerRadius = 2
        delayLabel.textColor = NSColor.white

        update(str: proxy.history.last?.delayDisplay, value: proxy.history.last?.delay)
    }

    override func layout() {
        dispatchPrecondition(condition: .onQueue(.main))
        super.layout()
        nameLabel.sizeToFit()
        delayLabel.sizeToFit()
        let fullNameWidth = nameLabel.bounds.width
        let nameOriginX: CGFloat = 18
        let interLabelSpacing: CGFloat = delayLabel.stringValue.isEmpty ? 0 : 8
        let rightEdge = max(nameOriginX, effectView.bounds.width - 8)
        let delayWidth = min(delayLabel.bounds.width, max(0, rightEdge - nameOriginX))
        let delayOriginX = max(nameOriginX, rightEdge - delayWidth)
        let availableNameWidth = max(0, delayOriginX - interLabelSpacing - nameOriginX)
        let visibleNameWidth = min(fullNameWidth, availableNameWidth)
        imageView?.frame = CGRect(x: 5, y: effectView.bounds.height / 2 - 6, width: 12, height: 12)
        nameLabel.frame = CGRect(x: nameOriginX,
                                 y: (effectView.bounds.height - nameLabel.bounds.height) / 2,
                                 width: visibleNameWidth,
                                 height: nameLabel.bounds.height)
        delayLabel.frame = CGRect(x: delayOriginX,
                                  y: (effectView.bounds.height - delayLabel.bounds.height) / 2,
                                  width: delayWidth,
                                  height: delayLabel.bounds.height)
        nameLabel.toolTip = fullNameWidth > availableNameWidth ? nameLabel.stringValue : nil
    }

    func update(str: String?, value: Int?) {
        dispatchPrecondition(condition: .onQueue(.main))
        delayLabel.stringValue = str ?? ""
        needsLayout = true
        needsDisplay = true

        guard let delay = value, str != nil else {
            delayLabel.textColor = NSColor.labelColor
            delayLabel.layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        delayLabel.textColor = NSColor.white
        switch ProxyBenchmarkDelayColorCategory.category(for: delay) {
        case .failed:
            delayLabel.layer?.backgroundColor = CGColor.fail
        case .fast:
            delayLabel.layer?.backgroundColor = CGColor.good
        case .moderate:
            delayLabel.layer?.backgroundColor = CGColor.moderate
        case .slow:
            delayLabel.layer?.backgroundColor = CGColor.slow
        case .unknown:
            delayLabel.textColor = NSColor.labelColor
            delayLabel.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    func update(name: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        nameLabel.stringValue = name
        needsLayout = true
        needsDisplay = true
    }

    func update(selected: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        needsLayout = true
        needsDisplay = true
        if selected {
            if imageView == nil {
                let image: NSImage
                if #available(OSX 11.0, *) {
                    image = NSImage(named: NSImage.menuOnStateTemplateName)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .bold, scale: .small))!
                } else {
                    image = NSImage(named: NSImage.menuOnStateTemplateName)!
                }
                imageView = NSImageView(image: image)
                imageView?.translatesAutoresizingMaskIntoConstraints = false
                effectView.addSubview(imageView!)
            }
        } else {
            imageView?.removeFromSuperview()
            imageView = nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didClickView() {
        (enclosingMenuItem as? ProxyMenuItem)?.didClick()
    }

    override var cells: [NSCell?] {
        return [nameLabel.cell, imageView?.cell]
    }
}

private extension CGColor {
    static let good = CGColor(red: 30.0 / 255, green: 181.0 / 255, blue: 30.0 / 255, alpha: 1)
    static let moderate = CGColor(red: 193.0 / 255, green: 135.0 / 255, blue: 0, alpha: 1)
    static let slow = CGColor(red: 1, green: 116.0 / 255, blue: 0, alpha: 1)
    static let fail = CGColor(red: 218.0 / 255, green: 0.0, blue: 3.0 / 255, alpha: 1)
}

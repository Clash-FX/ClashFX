//
//  StatusItemView.swift
//  ClashX
//
//  Created by CYC on 2018/6/23.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import AppKit
import Foundation
import RxCocoa
import RxSwift

class StatusItemView: NSView, StatusItemViewProtocol {
    @IBOutlet var imageView: NSImageView!

    @IBOutlet var uploadSpeedLabel: NSTextField!
    @IBOutlet var downloadSpeedLabel: NSTextField!
    @IBOutlet var speedContainerView: NSView!

    var up: Int = 0
    var down: Int = 0

    weak var statusItem: NSStatusItem?

    static func create(statusItem: NSStatusItem?) -> StatusItemView {
        var topLevelObjects: NSArray?
        if Bundle.main.loadNibNamed("StatusItemView", owner: self, topLevelObjects: &topLevelObjects) {
            let view = (topLevelObjects!.first(where: { $0 is NSView }) as? StatusItemView)!
            view.statusItem = statusItem
            view.setupView()
            view.imageView.image = StatusItemTool.menuImage

            if let button = statusItem?.button {
                // 修复 macOS 15+ 兼容性：在添加新子视图前移除所有现有子视图
                // 这样可以避免在新版 macOS 中因为多次添加子视图而导致的崩溃
                button.subviews.forEach { $0.removeFromSuperview() }
                button.addSubview(view)
                button.imagePosition = .imageOverlaps
            } else {
                Logger.log("button = nil")
                AppDelegate.shared.openConfigFolder(self)
            }
            view.updateViewStatus(enableProxy: false)
            return view
        }
        return NSView() as! StatusItemView
    }

    private lazy var separatorLine: NSView = {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
        return line
    }()

    func setupView() {
        uploadSpeedLabel.font = StatusItemTool.font
        downloadSpeedLabel.font = StatusItemTool.font

        uploadSpeedLabel.textColor = NSColor.labelColor
        downloadSpeedLabel.textColor = NSColor.labelColor

        addSubview(separatorLine)
        NSLayoutConstraint.activate([
            separatorLine.widthAnchor.constraint(equalToConstant: 1),
            separatorLine.heightAnchor.constraint(equalToConstant: 12),
            separatorLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            separatorLine.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
            speedContainerView.leadingAnchor.constraint(greaterThanOrEqualTo: separatorLine.trailingAnchor, constant: 4),
        ])
    }

    func updateSize(width: CGFloat) {
        frame = CGRect(x: 0, y: 0, width: width, height: 22)
    }

    func updateViewStatus(enableProxy: Bool) {
        if enableProxy {
            imageView.contentTintColor = NSColor.labelColor
        } else {
            imageView.contentTintColor = NSColor.labelColor.withSystemEffect(.disabled)
        }
    }

    func updateSpeedLabel(up: Int, down: Int) {
        guard !speedContainerView.isHidden else { return }
        var needsResize = false
        if up != self.up {
            uploadSpeedLabel.stringValue = SpeedUtils.getSpeedString(for: up)
            self.up = up
            needsResize = true
        }
        if down != self.down {
            downloadSpeedLabel.stringValue = SpeedUtils.getSpeedString(for: down)
            self.down = down
            needsResize = true
        }
        if needsResize {
            updateDynamicWidth()
        }
    }

    func showSpeedContainer(show: Bool) {
        speedContainerView.isHidden = !show
        separatorLine.isHidden = !show
    }

    private func updateDynamicWidth() {
        guard !speedContainerView.isHidden else { return }
        let font = StatusItemTool.font
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let upWidth = (uploadSpeedLabel.stringValue as NSString).size(withAttributes: attrs).width
        let downWidth = (downloadSpeedLabel.stringValue as NSString).size(withAttributes: attrs).width
        let maxTextWidth = ceil(max(upWidth, downWidth))

        // leading(3) + icon(18) + gap(5) + separator(1) + gap(4) + text + trailing(3)
        let neededWidth = 34.0 + maxTextWidth
        let width = max(statusItemLengthWithSpeed, neededWidth)

        if abs(frame.width - width) > 0.5 {
            updateSize(width: width)
            statusItem?.length = width
        }
    }
}

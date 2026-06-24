//
//  StatusItemView.swift
//  ClashX
//
//  Created by CYC on 2018/6/23.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import AppKit
import Foundation

class StatusItemView: NSView, StatusItemViewProtocol {
    @IBOutlet var imageView: NSImageView!
    @IBOutlet var speedContainerView: NSView!

    private var speedTextView: SpeedTextView!
    private let iconOnlyWidth: CGFloat = 25
    private let speedTextPadding: CGFloat = 7

    // Use -1 so the first updateSpeedLabel(0, 0) call always triggers a redraw.
    var up: Int = -1
    var down: Int = -1

    weak var statusItem: NSStatusItem?
    private var speedLeadingConstraint: NSLayoutConstraint?
    private var collapsedSpeedWidthConstraint: NSLayoutConstraint?

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

    func setupView() {
        // Replace NSTextField with custom draw-based view to avoid
        // macOS 26+ status bar NSTextField infinite redraw loop (high CPU bug)
        speedTextView = SpeedTextView()
        speedTextView.translatesAutoresizingMaskIntoConstraints = false
        speedContainerView.subviews.forEach { $0.removeFromSuperview() }
        speedContainerView.addSubview(speedTextView)
        NSLayoutConstraint.activate([
            speedTextView.leadingAnchor.constraint(equalTo: speedContainerView.leadingAnchor),
            speedTextView.trailingAnchor.constraint(equalTo: speedContainerView.trailingAnchor),
            speedTextView.topAnchor.constraint(equalTo: speedContainerView.topAnchor),
            speedTextView.bottomAnchor.constraint(equalTo: speedContainerView.bottomAnchor)
        ])

        speedLeadingConstraint = speedContainerView.leadingAnchor.constraint(greaterThanOrEqualTo: imageView.trailingAnchor, constant: 4)
        speedLeadingConstraint?.isActive = true
        collapsedSpeedWidthConstraint = speedContainerView.widthAnchor.constraint(equalToConstant: 0)

        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView.setContentHuggingPriority(.required, for: .horizontal)
    }

    func updateSize(width: CGFloat) {
        frame = CGRect(x: 0, y: 0, width: width, height: 22)
    }

    var preferredWidth: CGFloat {
        guard !speedContainerView.isHidden else { return iconOnlyWidth }
        return iconOnlyWidth + speedTextView.textWidth + speedTextPadding
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
        var needsRedraw = false
        if up != self.up {
            self.up = up
            needsRedraw = true
        }
        if down != self.down {
            self.down = down
            needsRedraw = true
        }
        if needsRedraw {
            speedTextView.update(
                up: SpeedUtils.getMenuBarSpeedString(for: up),
                down: SpeedUtils.getMenuBarSpeedString(for: down)
            )
            updateStatusItemWidthIfNeeded()
        }
    }

    func showSpeedContainer(show: Bool) {
        speedContainerView.isHidden = !show
        speedLeadingConstraint?.isActive = show
        collapsedSpeedWidthConstraint?.isActive = !show
        updateStatusItemWidthIfNeeded()
    }

    private func updateStatusItemWidthIfNeeded() {
        let width = preferredWidth
        guard statusItem?.length != width else { return }
        statusItem?.length = width
        updateSize(width: width)
    }
}

//
//  DashboardViewController.swift
//  ClashX
//
//  Created by yicheng on 2023/7/14.
//  Copyright © 2023 west2online. All rights reserved.
//

import Cocoa

enum DashboardContentType: Int, CaseIterable {
    case allConnection
    case activeConnection

    var title: String {
        switch self {
        case .allConnection:
            return NSLocalizedString("Recent Connections", comment: "")
        case .activeConnection:
            return NSLocalizedString("Active Connections", comment: "")
        }
    }
}

@available(macOS 10.15, *)
class DashboardViewController: NSViewController {
    private var segmentControl: NSSegmentedControl!
    private let searchField = NSSearchField()
    private let headerView = NSView()

    private let connectionVC = ConnectionsViewController()

    private var currentContentVC: DashboardSubViewControllerProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        segmentControl = NSSegmentedControl(labels: DashboardContentType.allCases.map(\.title),
                                            trackingMode: .selectOne,
                                            target: self,
                                            action: #selector(actionSwitchSegmentControl(sender:)))
        segmentControl.selectedSegment = 0
        searchField.delegate = self
        setupHeader()
        setCurrentVC(connectionVC)
    }

    override func loadView() {
        view = NSView()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.toolbar = nil
        view.window?.titleVisibility = .visible
        view.window?.titlebarAppearsTransparent = false
        if let window = view.window {
            window.styleMask.remove(.fullSizeContentView)
        }
    }

    func setCurrentVC(_ vc: DashboardSubViewControllerProtocol) {
        currentContentVC?.removeFromParent()
        currentContentVC?.view.removeFromSuperview()
        addChild(vc)
        view.addSubview(vc.view)
        vc.view.makeConstraints { [
            $0.leftAnchor.constraint(equalTo: view.leftAnchor),
            $0.rightAnchor.constraint(equalTo: view.rightAnchor),
            $0.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            $0.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ] }
        currentContentVC = vc
    }

    private func setupHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(headerView)

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        headerView.addSubview(divider)

        segmentControl.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(segmentControl)
        headerView.addSubview(searchField)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leftAnchor.constraint(equalTo: view.leftAnchor),
            headerView.rightAnchor.constraint(equalTo: view.rightAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 44),

            segmentControl.leftAnchor.constraint(equalTo: headerView.leftAnchor, constant: 16),
            segmentControl.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            segmentControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),

            searchField.leftAnchor.constraint(greaterThanOrEqualTo: segmentControl.rightAnchor, constant: 16),
            searchField.rightAnchor.constraint(equalTo: headerView.rightAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            divider.leftAnchor.constraint(equalTo: headerView.leftAnchor),
            divider.rightAnchor.constraint(equalTo: headerView.rightAnchor),
            divider.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    @objc func actionSwitchSegmentControl(sender: NSSegmentedControl) {
        guard let contentType = DashboardContentType(rawValue: sender.selectedSegment) else { return }
        switch contentType {
        case .allConnection:
            connectionVC.setActiveMode(enable: false)
        case .activeConnection:
            connectionVC.setActiveMode(enable: true)
        }
    }
}

@available(macOS 10.15, *)
extension DashboardViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if let textField = obj.object as? NSTextField {
            currentContentVC?.actionSearch(string: textField.stringValue)
        }
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        currentContentVC?.actionSearch(string: sender.stringValue)
    }
}

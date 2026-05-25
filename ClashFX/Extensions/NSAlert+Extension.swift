//
//  NSAlert+Extension.swift
//  ClashX
//
//  Created by yicheng on 2019/1/11.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa

extension NSAlert {
    static func alert(with text: String) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }
}

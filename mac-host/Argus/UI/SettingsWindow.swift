//
//  SettingsWindow.swift
//  Argus
//
//  Hosts the Settings UI in a real, standalone NSWindow. A SwiftUI .sheet
//  presented from a MenuBarExtra(.window) is torn down as soon as the
//  menu-bar window resigns key — which happens on the first control
//  interaction — so Settings must live in its own window instead.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(state: AppState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(state: state))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Argus Settings"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

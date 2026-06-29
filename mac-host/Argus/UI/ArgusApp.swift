//
//  ArgusApp.swift
//  Argus
//
//  Menu-bar-only SwiftUI app (LSUIElement = YES, no Dock icon).
//

import SwiftUI

@main
struct ArgusApp: App {
    @StateObject private var state = AppState()
    @State private var coordinator: StreamCoordinator?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state)
                .onAppear { ensureCoordinator() }
        } label: {
            Image(systemName: state.status == .disconnected
                  ? "display" : "display.trianglebadge.exclamationmark")
            // Glyph swaps subtly with state; a tinted dot is drawn in the menu.
        }
        .menuBarExtraStyle(.window)
    }

    private func ensureCoordinator() {
        if coordinator == nil {
            let c = StreamCoordinator(state: state)
            coordinator = c
            
            // Prompt for Accessibility permissions (required for CGEvent injection)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            if !trusted {
                NSLog("[Argus] Accessibility permissions not granted. Touch/Stylus injection will fail.")
                state.lastError = "Please grant Accessibility permissions in System Settings -> Privacy & Security."
            }
            
            // Probe adb on launch.
            let adb = ADBManager()
            if adb.locate() == nil {
                state.adbAvailable = false
                state.lastError = "adb not found. Install: brew install android-platform-tools"
            }
        }
    }
}

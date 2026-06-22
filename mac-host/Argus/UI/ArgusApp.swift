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
            // Probe adb on launch.
            let adb = ADBManager()
            if adb.locate() == nil {
                state.adbAvailable = false
                state.lastError = "adb not found. Install: brew install android-platform-tools"
            }
        }
    }
}

//
//  AppState.swift
//  Argus
//
//  Observable state shared between the SwiftUI menu-bar UI and the streaming
//  pipeline. All mutations are marshalled to the main actor.
//

import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // Live status
    @Published var status: ConnectionStatus = .disconnected
    @Published var fps: Int = 0
    @Published var bitrateMbps: Double = 15.0
    @Published var inputMode: InputMode = .none
    @Published var stylusPressure: Double = 0.0
    @Published var isUSB: Bool = false

    // Auto-detected tablet resolution + panel refresh (set when streaming begins).
    @Published var tabletWidth: Int = ArgusDisplaySpec.fallbackWidth
    @Published var tabletHeight: Int = ArgusDisplaySpec.fallbackHeight
    @Published var tabletRefresh: Int = 144

    var effectiveFrameRate: Int {
        if targetFPS > 0 { return targetFPS }
        return max(24, tabletRefresh)
    }

    // Environment checks
    @Published var adbAvailable: Bool = true
    @Published var adbPath: String = "adb"
    @Published var lastError: String?

    // Settings (persisted)
    @AppStorage("scalingPreset") var scalingPreset: String = "Default"
    @AppStorage("bitrateMbpsSetting") var bitrateSetting: Double = 15.0
    @AppStorage("codec") var codec: String = "H.265"
    // Content frame rate target. 0 means match tablet's native refresh.
    @AppStorage("targetFPS") var targetFPS: Int = 0

    @AppStorage("enablePressure") var enablePressure: Bool = true
    @AppStorage("enableTilt") var enableTilt: Bool = true
    @AppStorage("enableHover") var enableHover: Bool = true

    // Coordinator reference (set at launch)
    weak var coordinator: StreamCoordinator?

    func update(status: ConnectionStatus) { self.status = status }
    func update(fps: Int) { self.fps = fps }
    func update(inputMode: InputMode, pressure: Double = 0.0) {
        self.inputMode = inputMode
        self.inputMode = inputMode
        self.stylusPressure = pressure
    }
    func update(isUSB: Bool) { self.isUSB = isUSB }
}

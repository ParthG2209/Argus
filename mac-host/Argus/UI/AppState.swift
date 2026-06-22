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

    // Auto-detected tablet resolution + panel refresh (set when streaming begins).
    @Published var tabletWidth: Int = ArgusDisplaySpec.fallbackWidth
    @Published var tabletHeight: Int = ArgusDisplaySpec.fallbackHeight
    @Published var tabletRefresh: Int = 144

    /// Effective content frame rate = panel refresh / divisor. Must be an integer
    /// divisor so each frame shows for a whole number of refreshes (smooth).
    var effectiveFrameRate: Int { max(24, tabletRefresh / max(1, refreshDivisor)) }

    // Environment checks
    @Published var adbAvailable: Bool = true
    @Published var adbPath: String = "adb"
    @Published var lastError: String?

    // Settings (persisted)
    @AppStorage("scalingPreset") var scalingPreset: String = "Default"
    @AppStorage("bitrateMbpsSetting") var bitrateSetting: Double = 15.0
    @AppStorage("codec") var codec: String = "H.265"
    // Content frame rate as panel-refresh ÷ divisor (1 = full, 2 = half, 3 = third).
    // Default Full: frame pacing on the tablet keeps it smooth at max fps. Drop
    // to Half (a perfect divisor) only if Full still judders.
    @AppStorage("refreshDivisor") var refreshDivisor: Int = 1
    @AppStorage("enablePressure") var enablePressure: Bool = true
    @AppStorage("enableTilt") var enableTilt: Bool = true
    @AppStorage("enableHover") var enableHover: Bool = true

    // Coordinator reference (set at launch)
    weak var coordinator: StreamCoordinator?

    func update(status: ConnectionStatus) { self.status = status }
    func update(fps: Int) { self.fps = fps }
    func update(inputMode: InputMode, pressure: Double = 0.0) {
        self.inputMode = inputMode
        self.stylusPressure = pressure
    }
}

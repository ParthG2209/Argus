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

    // Environment checks
    @Published var adbAvailable: Bool = true
    @Published var adbPath: String = "adb"
    @Published var lastError: String?

    // Settings (persisted)
    @AppStorage("resolutionPreset") var resolutionPreset: String = "2732x2048"
    @AppStorage("bitrateMbpsSetting") var bitrateSetting: Double = 15.0
    @AppStorage("codec") var codec: String = "H.264"
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

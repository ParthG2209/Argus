//
//  Protocol.swift
//  Argus
//
//  Shared constants and the input-event wire model. Mirrors
//  shared/PROTOCOL.md. Keep in sync with android-client Protocol.kt.
//

import Foundation

enum ArgusPorts {
    static let video: UInt16 = 7175   // Mac -> Tablet
    static let input: UInt16 = 7176   // Tablet -> Mac
    static let audio: UInt16 = 7177   // Mac -> Tablet
}

enum ArgusDisplaySpec {
    static let pixelsWide: UInt32 = 2732
    static let pixelsHigh: UInt32 = 2048
    static let refreshHz: Double  = 60.0
    static let hiDPI              = true
    static let widthMM: Double    = 597.0
    static let heightMM: Double   = 336.0
    static let name               = "Argus Display"
}

enum ArgusAudioSpec {
    static let sampleRate: Double = 48_000
    static let channels: UInt32   = 2
    static let bitrate: Int       = 128_000
}

// MARK: - Input event model (decoded from port 7176 JSON)

struct InputPoint: Codable {
    let x: Double
    let y: Double
    let pressure: Double
    let tiltX: Double
    let tiltY: Double
    let toolMajor: Double
    let toolMinor: Double
    let timestamp: Int64
}

struct InputEvent: Codable {
    let action: String     // down|move|up|hover|button_press|button_release
    let toolType: String   // finger|stylus|eraser
    let button: String?    // primary|secondary|null
    let points: [InputPoint]
}

enum ConnectionStatus: String {
    case disconnected = "Disconnected"
    case connected    = "Connected"
    case streaming    = "Streaming"
}

enum InputMode: String {
    case none   = "—"
    case touch  = "Touch"
    case stylus = "Stylus"
    case eraser = "Eraser"
    case hover  = "Hover"
}

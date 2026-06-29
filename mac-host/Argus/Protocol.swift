//
//  Protocol.swift
//  Argus
//
//  Shared constants and the input-event wire model. Mirrors
//  shared/PROTOCOL.md. Keep in sync with android-client Protocol.kt.
//

import Foundation
import CoreMedia

/// Selected video codec. Both ends must agree; the Mac announces it to the
/// tablet via the video-stream handshake (see ArgusHandshake).
enum VideoCodec: String, CaseIterable {
    case h264 = "H.264"
    case h265 = "H.265"

    var cmType: CMVideoCodecType {
        self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
    }
    var handshakeByte: UInt8 { self == .h264 ? 0 : 1 }
}

/// The first framed payload on the video socket is a 4-byte handshake:
/// ['A','R','G', codecByte]. Real video frames begin with an Annex B start
/// code (00 00 00 01), never "ARG", so there is no ambiguity.
enum ArgusHandshake {
    static let prefix: [UInt8] = [0x41, 0x52, 0x47]  // "ARG"
    static func make(_ codec: VideoCodec) -> Data {
        Data(prefix + [codec.handshakeByte])
    }
}

enum ArgusPorts {
    static let video: UInt16 = 7175   // Mac -> Tablet
    static let input: UInt16 = 7176   // Tablet -> Mac
    static let audio: UInt16 = 7177   // Mac -> Tablet
}

/// A macOS-style scaling preset, defined as a factor of the tablet's native
/// resolution (which is auto-detected, so presets must be resolution-relative).
///
/// `factor` scales the HiDPI *backing* relative to native: 1.0 = 1:1 with the
/// panel (sharpest), >1.0 supersamples ("More Space" — smaller UI), <1.0
/// upscales ("Larger Text" — bigger UI). The mode itself is created in POINTS
/// (backing / 2, since hiDPI doubles); the stream is always captured at the
/// tablet's native pixels regardless of preset, so it fills the panel exactly.
struct ScalingPreset: Identifiable, Hashable {
    let name: String
    let factor: Double
    var id: String { name }

    /// Mode dimensions in POINTS for a given native pixel size.
    func points(forNativeWidth w: Int, height h: Int) -> (UInt32, UInt32) {
        let pw = UInt32(max(1, (Double(w) * factor / 2.0).rounded()))
        let ph = UInt32(max(1, (Double(h) * factor / 2.0).rounded()))
        return (pw, ph)
    }
    /// HiDPI backing pixels (= points * 2) for matching/activating the mode.
    func pixels(forNativeWidth w: Int, height h: Int) -> (UInt32, UInt32) {
        let (pw, ph) = points(forNativeWidth: w, height: h)
        return (pw * 2, ph * 2)
    }
    func looksLike(forNativeWidth w: Int, height h: Int) -> String {
        let (pw, ph) = points(forNativeWidth: w, height: h)
        return "\(pw) × \(ph)"
    }
}

enum ArgusDisplaySpec {
    // Fallback native pixels, used only if the tablet doesn't report its
    // resolution (older client / handshake timeout). The real value is
    // auto-detected from the tablet's "hello" message — see PROTOCOL.md.
    static let fallbackWidth  = 2732
    static let fallbackHeight = 2048

    static let refreshHz: Double = 60.0
    static let hiDPI             = true
    static let widthMM: Double   = 597.0
    static let heightMM: Double  = 336.0
    static let name              = "Argus Display"

    static let scalingPresets: [ScalingPreset] = [
        ScalingPreset(name: "Larger Text",   factor: 0.83),
        ScalingPreset(name: "Default",       factor: 1.00),  // 1:1, sharpest
        ScalingPreset(name: "More Space",    factor: 1.18),
        ScalingPreset(name: "Maximum Space", factor: 1.40),
    ]
    static let defaultPresetIndex = 1   // "Default"

    static func preset(named name: String) -> ScalingPreset {
        scalingPresets.first { $0.name == name } ?? scalingPresets[defaultPresetIndex]
    }
}

/// First message the tablet sends on the input socket (7176): its real screen
/// resolution, so the Mac can size the virtual display to match.
struct HelloMessage: Codable {
    let type: String   // "hello"
    let width: Int
    let height: Int
    let refresh: Int?  // panel refresh rate in Hz (for clean-divisor pacing)
}

enum ArgusAudioSpec {
    static let sampleRate: Double = 48_000
    static let channels: UInt32   = 2
    static let bitrate: Int       = 128_000
}

// MARK: - Input event model (decoded from port 7176 JSON)

struct InputPointer: Codable {
    let id: Int
    let toolType: String
    let x: Double
    let y: Double
    let pressure: Double
    let tiltX: Double
    let tiltY: Double
    let button: String?
}

struct InputEvent: Codable {
    let action: String     // down|move|up|cancel|hover|button_press|button_release
    let actionPointerId: Int
    let timestamp: Int64
    let pointers: [InputPointer]
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

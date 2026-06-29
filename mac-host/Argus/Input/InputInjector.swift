//
//  InputInjector.swift
//  Argus
//
//  Decodes input-event JSON from port 7176 and injects it into macOS:
//    - finger        -> CGEvent mouse events on the virtual display
//    - stylus/eraser -> reports to the virtual HID graphics tablet
//
//  Multi-touch (Future Phase): true multi-finger support will require an
//  IOHIDUserDevice with a multitouch *digitizer* report descriptor (multiple
//  contact collections, contact IDs, contact count). For Phase 1 we treat
//  only the primary/last touch point as a single mouse pointer.
//

import Foundation
import CoreGraphics

final class InputInjector {
    private let displayID: CGDirectDisplayID
    private let decoder = JSONDecoder()
    private let engine: GestureEngine

    /// Settings gates (mirrors the Settings toggles).
    var enablePressure = true
    var enableTilt = true
    var enableHover = true

    /// Reports the live input mode + pressure back to the UI.
    var onInputModeChange: ((InputMode, Double) -> Void)?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.engine = GestureEngine(displayID: displayID)
    }

    func start() {
        // No-op. GestureEngine is stateless until it receives events.
    }

    func stop() {
        // No-op
    }

    /// Handle one JSON line from the input socket.
    func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? decoder.decode(InputEvent.self, from: data) else {
            return
        }
        
        // Drop hover frames if hover is disabled
        if event.action == "hover" && !enableHover {
            return
        }
        
        engine.process(frame: event, enablePressure: enablePressure, enableTilt: enableTilt, enableHover: enableHover)
        
        // Report UI state based on first active pointer
        if let first = event.pointers.first {
            let mode: InputMode
            if first.toolType == "eraser" {
                mode = .eraser
            } else if first.toolType == "stylus" {
                mode = (event.action == "hover") ? .hover : .stylus
            } else {
                mode = .touch
            }
            onInputModeChange?(mode, first.pressure)
        }
    }
}

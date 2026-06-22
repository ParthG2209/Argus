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
    private let stylus = ArgusStylusHID()
    private let decoder = JSONDecoder()

    /// Settings gates (mirrors the Settings toggles).
    var enablePressure = true
    var enableTilt = true
    var enableHover = true

    /// Reports the live input mode + pressure back to the UI.
    var onInputModeChange: ((InputMode, Double) -> Void)?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func start() {
        if !stylus.create() {
            NSLog("[Argus] Stylus HID device unavailable; stylus will fall "
                  + "back to mouse events.")
        }
    }

    func stop() {
        stylus.destroy()
    }

    /// Handle one JSON line from the input socket.
    func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? decoder.decode(InputEvent.self, from: data) else {
            return
        }
        switch event.toolType {
        case "stylus", "eraser":
            injectStylus(event)
        default: // "finger"
            injectFinger(event)
        }
    }

    // MARK: - Coordinate mapping

    private func mapToGlobal(_ x: Double, _ y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.origin.x + x * bounds.size.width,
                       y: bounds.origin.y + y * bounds.size.height)
    }

    // MARK: - Finger -> mouse

    private func injectFinger(_ event: InputEvent) {
        guard let last = event.points.last else { return }
        let point = mapToGlobal(last.x, last.y)

        let type: CGEventType?
        switch event.action {
        case "down": type = .leftMouseDown
        case "move": type = .leftMouseDragged
        case "up":   type = .leftMouseUp
        case "hover": type = .mouseMoved
        default:      type = nil
        }
        guard let eventType = type else { return }

        if let cgEvent = CGEvent(mouseEventSource: nil,
                                 mouseType: eventType,
                                 mouseCursorPosition: point,
                                 mouseButton: .left) {
            cgEvent.post(tap: .cghidEventTap)
        }

        onInputModeChange?(event.action == "hover" ? .hover : .touch, 0.0)
    }

    // MARK: - Stylus/eraser -> HID tablet

    private func injectStylus(_ event: InputEvent) {
        let isEraser = (event.toolType == "eraser")
        let barrel = (event.button == "secondary")

        // Replay every historical point in order, then the current one, to
        // preserve stroke fidelity at high sampling rates.
        for p in event.points {
            let tip: Bool
            let inRange: Bool
            switch event.action {
            case "down", "move":
                tip = true;  inRange = true
            case "up":
                tip = false; inRange = false
            case "hover":
                guard enableHover else { continue }
                tip = false; inRange = true
            case "button_press", "button_release":
                // Position unchanged; report current button state with the
                // pen in range (tip follows whether it's also touching).
                tip = p.pressure > 0.0
                inRange = true
            default:
                continue
            }

            let pressure = enablePressure ? p.pressure : (tip ? 1.0 : 0.0)
            let tiltX = enableTilt ? p.tiltX : 0.0
            let tiltY = enableTilt ? p.tiltY : 0.0

            stylus.sendReportX(p.x, y: p.y,
                               pressure: pressure,
                               tiltX: tiltX, tiltY: tiltY,
                               tipSwitch: tip,
                               barrel: barrel,
                               eraser: isEraser,
                               inRange: inRange)
        }

        let mode: InputMode = isEraser ? .eraser
            : (event.action == "hover" ? .hover : .stylus)
        onInputModeChange?(mode, event.points.last?.pressure ?? 0.0)
    }
}

//
//  GestureEngine.swift
//  Argus
//
//  Action-driven gesture state machine.
//  Uses the `action` field ("down"/"move"/"up"/"cancel") and `actionPointerId`
//  to correctly handle pointer lifecycle instead of trying to infer it from
//  pointer presence in the frame.
//

import Foundation
import CoreGraphics
import Carbon.HIToolbox

final class GestureEngine {
    private let displayID: CGDirectDisplayID

    // ── Per-pointer tracking ────────────────────────────────────────────
    private struct Pointer {
        let id: Int
        var toolType: String
        var point: CGPoint          // current position (global screen coords)
        let startPoint: CGPoint     // where the pointer first touched
        let startTime: Int64        // timestamp of the down event (ms)
        var pressure: Double
        var tiltX: Double
        var tiltY: Double
        var button: String?
    }
    private var pointers: [Int: Pointer] = [:]
    
    // ── Double click tracking ───────────────────────────────────────────
    private var lastClickTime: Int64 = 0
    private var lastClickPoint: CGPoint = .zero
    private var currentClickCount: Int64 = 1

    // ── Gesture classification ──────────────────────────────────────────
    private enum Phase {
        case idle
        case fingerDown(id: Int)                     // waiting to classify
        case scrolling(id: Int, lastPoint: CGPoint)  // 1-finger scroll
        case dragging(id: Int)                       // long-press + drag
        case stylusDown(id: Int)                     // stylus/eraser active
        case multiTouch(maxFingers: Int, startPoint: CGPoint)
    }
    private var phase: Phase = .idle

    // ── Tuning constants ────────────────────────────────────────────────
    private let moveThreshold: CGFloat = 5.0        // px to leave "fingerDown"
    private let scrollVsDragMs: Int64 = 200         // quick move = scroll
    private let longPressMs: Int64 = 400            // held still = right-click
    private let swipeThreshold: CGFloat = 50.0      // multi-finger swipe px

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Public entry point
    // ════════════════════════════════════════════════════════════════════

    func process(frame: InputEvent,
                 enablePressure: Bool,
                 enableTilt: Bool,
                 enableHover: Bool) {

        let targetId = frame.actionPointerId

        // 1. Update ALL tracked pointers with their latest positions.
        for p in frame.pointers {
            if var tracked = pointers[p.id] {
                tracked.point     = mapToGlobal(p.x, p.y)
                tracked.pressure  = enablePressure ? p.pressure : (p.pressure > 0 ? 1.0 : 0.0)
                tracked.tiltX     = enableTilt ? p.tiltX : 0.0
                tracked.tiltY     = enableTilt ? p.tiltY : 0.0
                tracked.button    = p.button
                tracked.toolType  = p.toolType
                pointers[p.id]    = tracked
            }
        }

        // 2. Dispatch by action.
        switch frame.action {
        case "down":
            onDown(frame: frame, targetId: targetId,
                   enablePressure: enablePressure, enableTilt: enableTilt)
        case "move":
            onMove(timestamp: frame.timestamp)
        case "up":
            onUp(targetId: targetId, timestamp: frame.timestamp)
        case "cancel":
            onCancel()
        case "hover":
            if let p = frame.pointers.first {
                let pt = mapToGlobal(p.x, p.y)
                postMouseEvent(type: .mouseMoved, pt: pt)
            }
        case "button_press", "button_release":
            // Button state already updated in the pointer-update loop above.
            // The next "move" will use the new button automatically.
            break
        default:
            break
        }
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Down
    // ════════════════════════════════════════════════════════════════════

    private func onDown(frame: InputEvent, targetId: Int,
                        enablePressure: Bool, enableTilt: Bool) {
        guard let p = frame.pointers.first(where: { $0.id == targetId }) else { return }
        let pt = mapToGlobal(p.x, p.y)

        let ptr = Pointer(
            id: p.id,
            toolType: p.toolType,
            point: pt,
            startPoint: pt,
            startTime: frame.timestamp,
            pressure: enablePressure ? p.pressure : 1.0,
            tiltX:    enableTilt ? p.tiltX : 0.0,
            tiltY:    enableTilt ? p.tiltY : 0.0,
            button:   p.button
        )
        pointers[targetId] = ptr

        // ── Stylus always takes priority (palm rejection) ───────────
        if p.toolType == "stylus" || p.toolType == "eraser" {
            cancelCurrentGesture()
            phase = .stylusDown(id: ptr.id)
            let isRight = (p.button == "secondary") || (p.toolType == "eraser")
            postMouseEvent(type: isRight ? .rightMouseDown : .leftMouseDown,
                           pt: pt, pressure: ptr.pressure,
                           tiltX: ptr.tiltX, tiltY: ptr.tiltY)
            return
        }

        // Ignore fingers while stylus is active
        if case .stylusDown = phase { return }

        let fingerCount = pointers.values.filter { $0.toolType == "finger" }.count

        if fingerCount == 1 {
            phase = .fingerDown(id: ptr.id)
        } else {
            // Multi-touch: cancel any pending single-finger gesture
            cancelCurrentGesture()
            phase = .multiTouch(maxFingers: fingerCount, startPoint: pt)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Move
    // ════════════════════════════════════════════════════════════════════

    private func onMove(timestamp: Int64) {
        switch phase {

        case .stylusDown(let id):
            guard let ptr = pointers[id] else { return }
            let isRight = (ptr.button == "secondary") || (ptr.toolType == "eraser")
            postMouseEvent(type: isRight ? .rightMouseDragged : .leftMouseDragged,
                           pt: ptr.point, pressure: ptr.pressure,
                           tiltX: ptr.tiltX, tiltY: ptr.tiltY)

        case .fingerDown(let id):
            guard let ptr = pointers[id] else { return }
            let dx = ptr.point.x - ptr.startPoint.x
            let dy = ptr.point.y - ptr.startPoint.y
            let dist = hypot(dx, dy)

            if dist > moveThreshold {
                let elapsed = timestamp - ptr.startTime
                if elapsed < scrollVsDragMs {
                    // Quick swipe → SCROLL
                    phase = .scrolling(id: id, lastPoint: ptr.startPoint)
                    postScroll(dx: dx, dy: dy)
                } else {
                    // Held then moved → DRAG
                    phase = .dragging(id: id)
                    postMouseEvent(type: .leftMouseDown, pt: ptr.startPoint)
                    postMouseEvent(type: .leftMouseDragged, pt: ptr.point)
                }
            }

        case .scrolling(let id, let lastPt):
            guard let ptr = pointers[id] else { return }
            let dx = ptr.point.x - lastPt.x
            let dy = ptr.point.y - lastPt.y
            postScroll(dx: dx, dy: dy)
            phase = .scrolling(id: id, lastPoint: ptr.point)

        case .dragging(let id):
            guard let ptr = pointers[id] else { return }
            postMouseEvent(type: .leftMouseDragged, pt: ptr.point)

        case .multiTouch:
            break   // evaluated on lift

        default:
            break
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Up
    // ════════════════════════════════════════════════════════════════════

    private func onUp(targetId: Int, timestamp: Int64) {
        guard let ptr = pointers[targetId] else {
            pointers.removeValue(forKey: targetId)
            return
        }

        switch phase {

        case .stylusDown(let id) where id == targetId:
            let isRight = (ptr.button == "secondary") || (ptr.toolType == "eraser")
            postMouseEvent(type: isRight ? .rightMouseUp : .leftMouseUp,
                           pt: ptr.point, pressure: ptr.pressure,
                           tiltX: ptr.tiltX, tiltY: ptr.tiltY)
            phase = .idle

        case .fingerDown(let id) where id == targetId:
            // Finger lifted without moving past threshold.
            let elapsed = timestamp - ptr.startTime
            if elapsed < longPressMs {
                // ── TAP → Left Click ────────────────────────────────
                // Check for double click
                let clickElapsed = timestamp - lastClickTime
                let dx = ptr.point.x - lastClickPoint.x
                let dy = ptr.point.y - lastClickPoint.y
                let dist = hypot(dx, dy)
                
                if clickElapsed < 500 && dist < 10.0 {
                    currentClickCount += 1
                } else {
                    currentClickCount = 1
                }
                
                postMouseEvent(type: .leftMouseDown, pt: ptr.point, clicks: currentClickCount)
                postMouseEvent(type: .leftMouseUp,   pt: ptr.point, clicks: currentClickCount)
                
                lastClickTime = timestamp
                lastClickPoint = ptr.point
            } else {
                // ── Long Press → Right Click ────────────────────────
                postMouseEvent(type: .rightMouseDown, pt: ptr.point)
                postMouseEvent(type: .rightMouseUp,   pt: ptr.point)
            }
            phase = .idle

        case .scrolling(let id, _) where id == targetId:
            phase = .idle

        case .dragging(let id) where id == targetId:
            postMouseEvent(type: .leftMouseUp, pt: ptr.point)
            phase = .idle

        case .multiTouch(let maxFingers, let startPt):
            let dx = ptr.point.x - startPt.x
            let dy = ptr.point.y - startPt.y

            // Evaluate swipe when fingers lift
            let remainingFingers = pointers.values.filter {
                $0.toolType == "finger" && $0.id != targetId
            }.count

            if remainingFingers == 0 {
                evaluateMultiFingerSwipe(count: maxFingers, dx: dx, dy: dy)
                phase = .idle
            }

        default:
            break
        }

        pointers.removeValue(forKey: targetId)

        // Safety: if all pointers are gone, force idle
        if pointers.isEmpty { phase = .idle }
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Cancel
    // ════════════════════════════════════════════════════════════════════

    private func onCancel() {
        cancelCurrentGesture()
        pointers.removeAll()
        phase = .idle
    }

    private func cancelCurrentGesture() {
        if case .dragging(let id) = phase, let ptr = pointers[id] {
            postMouseEvent(type: .leftMouseUp, pt: ptr.point)
        }
        // Scrolling and fingerDown need no cleanup events.
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Multi-finger swipe evaluation
    // ════════════════════════════════════════════════════════════════════

    private func evaluateMultiFingerSwipe(count: Int, dx: CGFloat, dy: CGFloat) {
        if count == 5 {
            if dy < -swipeThreshold      { postKey(keyCode: kVK_UpArrow, flags: .maskControl) }     // Mission Control
            else if dy > swipeThreshold  { postKey(keyCode: kVK_DownArrow, flags: .maskControl) }   // App Exposé
            else if dx < -swipeThreshold { postKey(keyCode: kVK_RightArrow, flags: .maskControl) }  // Next Space
            else if dx > swipeThreshold  { postKey(keyCode: kVK_LeftArrow, flags: .maskControl) }   // Prev Space
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Coordinate mapping
    // ════════════════════════════════════════════════════════════════════

    private func mapToGlobal(_ x: Double, _ y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        
        // Edge snapping for Dock and Menu Bar access
        var snappedY = y
        if y < 0.015 { snappedY = 0.0 } // Top ~1.5% snaps to Menu Bar
        if y > 0.985 { snappedY = 1.0 } // Bottom ~1.5% snaps to Dock
        
        return CGPoint(x: bounds.origin.x + x * bounds.size.width,
                       y: bounds.origin.y + snappedY * bounds.size.height)
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - CGEvent injection
    // ════════════════════════════════════════════════════════════════════

    private func postMouseEvent(type: CGEventType, pt: CGPoint,
                                pressure: Double = 0, tiltX: Double = 0, tiltY: Double = 0, clicks: Int64 = 1) {
        let btn: CGMouseButton =
            (type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged)
            ? .right : .left
        guard let event = CGEvent(mouseEventSource: nil,
                                  mouseType: type,
                                  mouseCursorPosition: pt,
                                  mouseButton: btn) else { return }
        
        if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: clicks)
        }
        
        if pressure > 0 {
            event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }

    private func postScroll(dx: CGFloat, dy: CGFloat) {
        // Reverse of natural scrolling:
        //   finger moves up (dy < 0) → page scrolls DOWN → positive wheel1
        //   finger moves down (dy > 0) → page scrolls UP → negative wheel1
        // So we pass dy directly (not negated).
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(dy), wheel2: Int32(dx),
                                  wheel3: 0) else { return }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }

    private func postKey(keyCode: Int, flags: CGEventFlags = []) {
        let code = CGKeyCode(keyCode)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        down.post(tap: CGEventTapLocation.cghidEventTap)
        up.flags = flags
        up.post(tap: CGEventTapLocation.cghidEventTap)
    }
}

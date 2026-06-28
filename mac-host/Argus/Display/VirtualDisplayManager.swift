//
//  VirtualDisplayManager.swift
//  Argus
//
//  Thin Swift facade over the ArgusVirtualDisplay ObjC bridge.
//

import Foundation
import CoreGraphics
import AppKit
import CoreVideo

final class VirtualDisplayManager {
    private let display = ArgusVirtualDisplay()
    private var nativeWidth = ArgusDisplaySpec.fallbackWidth
    private var nativeHeight = ArgusDisplaySpec.fallbackHeight
    private var currentRefreshHz: Double = 60.0
    private var keepAliveWindow: NSWindow?

    var displayID: CGDirectDisplayID { display.displayID }
    var isActive: Bool { display.isActive }

    /// Create the Argus virtual display sized to the tablet's native pixels,
    /// advertising all scaling presets (computed relative to that resolution)
    /// as HiDPI modes, and activating `presetName`. Positions it right of the
    /// primary display. Returns the new display ID.
    @discardableResult
    func start(presetName: String, nativeWidth w: Int, nativeHeight h: Int,
               refreshHz: Double) async -> CGDirectDisplayID? {
        nativeWidth = w
        nativeHeight = h
        currentRefreshHz = refreshHz

        let presets = ArgusDisplaySpec.scalingPresets
        // Mode dimensions are POINTS; the bridge derives the 2x backing.
        let pts = presets.map { $0.points(forNativeWidth: w, height: h) }
        let widths = pts.map { $0.0 }
        let heights = pts.map { $0.1 }
        let defaultIdx = presets.firstIndex { $0.name == presetName }
            ?? ArgusDisplaySpec.defaultPresetIndex

        let ok = widths.withUnsafeBufferPointer { wptr in
            heights.withUnsafeBufferPointer { hptr in
                display.create(withModeWidths: wptr.baseAddress!,
                               modeHeights: hptr.baseAddress!,
                               modeCount: UInt(presets.count),
                               defaultMode: UInt(defaultIdx),
                               refreshHz: refreshHz,
                               hiDPI: ArgusDisplaySpec.hiDPI,
                               widthMM: ArgusDisplaySpec.widthMM,
                               heightMM: ArgusDisplaySpec.heightMM,
                               name: ArgusDisplaySpec.name)
            }
        }

        guard ok else {
            NSLog("[Argus] VirtualDisplayManager: creation failed.")
            return nil
        }
        
        let did = display.displayID
        
        // Asynchronously poll until WindowServer publishes the display
        var modeSet = false
        for attempt in 1...20 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            if self.setScaling(presetName: presetName) {
                modeSet = true
                break
            }
            NSLog("[Argus] Mode set attempt \(attempt) failed, retrying async...")
        }
        
        if modeSet {
            self.display.positionToRightOfPrimary()
            NSLog("[Argus] Virtual display mode set successfully.")
            
            // Spawn the invisible keep-alive window on the main thread
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.spawnKeepAliveWindow(displayID: did)
            }
        } else {
            NSLog("[Argus] WARNING: Async mode set failed after 2s. macOS may use default refresh rate.")
        }
        
        return did
    }

    /// Switch scaling at runtime to the named preset.
    @discardableResult
    func setScaling(presetName: String) -> Bool {
        guard isActive else { return false }
        let p = ArgusDisplaySpec.preset(named: presetName)
        let (pxW, pxH) = p.pixels(forNativeWidth: nativeWidth, height: nativeHeight)
        return display.setActiveModePixelWidth(pxW, pixelHeight: pxH, refreshHz: currentRefreshHz)
    }

    func stop() {
        // Must close the window synchronously BEFORE destroying the virtual display,
        // otherwise macOS crashes trying to update a window on a non-existent screen.
        if Thread.isMainThread {
            keepAliveWindow?.close()
            keepAliveWindow = nil
        } else {
            DispatchQueue.main.sync {
                keepAliveWindow?.close()
                keepAliveWindow = nil
            }
        }
        display.destroy()
    }
    
    private func spawnKeepAliveWindow(displayID: CGDirectDisplayID) {
        var targetScreen: NSScreen?
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                if num.uint32Value == displayID {
                    targetScreen = screen
                    break
                }
            }
        }
        
        let screenRect = targetScreen?.frame ?? NSRect(x: 10000, y: 10000, width: 1, height: 1)
        let tinyRect = NSRect(x: screenRect.minX, y: screenRect.minY, width: 1, height: 1)
        
        let window = KeepAliveWindow(contentRect: tinyRect, displayID: displayID)
        window.orderFront(nil)
        self.keepAliveWindow = window
        NSLog("[Argus] KeepAliveWindow spawned to lock refresh rate.")
    }
}

// MARK: - KeepAliveWindow

final class KeepAliveWindow: NSWindow {
    init(contentRect: NSRect, displayID: CGDirectDisplayID) {
        super.init(contentRect: contentRect,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.level = .floating // Ensure it stays on top
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.wantsLayer = true
        self.contentView = view
        
        // Attach a continuous CoreAnimation to force the WindowServer to composite
        // the display at maximum refresh rate without flooding the main thread.
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = NSColor(white: 0.5, alpha: 0.01).cgColor
        anim.toValue = NSColor(white: 0.5, alpha: 0.02).cgColor
        anim.duration = 0.5
        anim.autoreverses = true
        anim.repeatCount = .infinity
        view.layer?.add(anim, forKey: "keepAlive")
    }
}

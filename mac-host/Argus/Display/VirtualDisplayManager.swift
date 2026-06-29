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
    private var keepAliveWindow: KeepAliveWindow?
    private var stopped = false

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
        stopped = false

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
                guard let self, !self.stopped else { return }
                self.spawnKeepAliveWindow(displayID: did)
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
        stopped = true
        
        // Invalidate the timer first — this is synchronous and immediate,
        // guaranteeing no more timer callbacks can fire.
        keepAliveWindow?.stopKeepAlive()
        keepAliveWindow?.orderOut(nil)
        keepAliveWindow = nil
        
        // Destroy the display after the WindowServer has had time to flush
        // the removed window from its render tree.
        let d = display
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            d.destroy()
        }
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
        
        let window = KeepAliveWindow(contentRect: tinyRect)
        window.orderFront(nil)
        self.keepAliveWindow = window
        NSLog("[Argus] KeepAliveWindow spawned to lock refresh rate.")
    }
}

// MARK: - KeepAliveWindow
//
// Uses a plain Timer to toggle the layer's background color.
// Unlike CABasicAnimation (which lives in the CoreAnimation render server and
// survives window.close()), a Timer is trivially cancelled with .invalidate()
// — no lingering render-server references that crash when the virtual display
// is destroyed.

final class KeepAliveWindow: NSWindow {
    private var timer: Timer?
    private var toggle = false
    
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.01).cgColor
        self.contentView = view
        
        // Toggle the layer's background color at ~30 Hz to force the
        // WindowServer to composite the display continuously.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.toggle.toggle()
            self.contentView?.layer?.backgroundColor = self.toggle
                ? NSColor(white: 0.5, alpha: 0.02).cgColor
                : NSColor(white: 0.5, alpha: 0.01).cgColor
        }
    }
    
    /// Cleanly stop the timer. Safe to call multiple times.
    func stopKeepAlive() {
        timer?.invalidate()
        timer = nil
    }
    
    deinit {
        timer?.invalidate()
    }
}

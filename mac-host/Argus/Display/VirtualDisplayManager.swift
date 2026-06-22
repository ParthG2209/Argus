//
//  VirtualDisplayManager.swift
//  Argus
//
//  Thin Swift facade over the ArgusVirtualDisplay ObjC bridge.
//

import Foundation
import CoreGraphics

final class VirtualDisplayManager {
    private let display = ArgusVirtualDisplay()
    private var nativeWidth = ArgusDisplaySpec.fallbackWidth
    private var nativeHeight = ArgusDisplaySpec.fallbackHeight

    var displayID: CGDirectDisplayID { display.displayID }
    var isActive: Bool { display.isActive }

    /// Create the Argus virtual display sized to the tablet's native pixels,
    /// advertising all scaling presets (computed relative to that resolution)
    /// as HiDPI modes, and activating `presetName`. Positions it right of the
    /// primary display. Returns the new display ID.
    @discardableResult
    func start(presetName: String, nativeWidth w: Int, nativeHeight h: Int,
               refreshHz: Double) -> CGDirectDisplayID? {
        nativeWidth = w
        nativeHeight = h

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
        display.positionToRightOfPrimary()
        return display.displayID
    }

    /// Switch scaling at runtime to the named preset.
    @discardableResult
    func setScaling(presetName: String) -> Bool {
        guard isActive else { return false }
        let p = ArgusDisplaySpec.preset(named: presetName)
        let (pxW, pxH) = p.pixels(forNativeWidth: nativeWidth, height: nativeHeight)
        return display.setActiveModePixelWidth(pxW, pixelHeight: pxH)
    }

    func stop() {
        display.destroy()
    }
}

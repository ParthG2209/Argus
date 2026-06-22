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

    var displayID: CGDirectDisplayID { display.displayID }
    var isActive: Bool { display.isActive }

    /// Create the Argus virtual display per ArgusDisplaySpec and position it
    /// to the right of the primary display. Returns the new display ID.
    @discardableResult
    func start() -> CGDirectDisplayID? {
        let ok = display.create(withPixelsWide: ArgusDisplaySpec.pixelsWide,
                                pixelsHigh: ArgusDisplaySpec.pixelsHigh,
                                refreshHz: ArgusDisplaySpec.refreshHz,
                                hiDPI: ArgusDisplaySpec.hiDPI,
                                widthMM: ArgusDisplaySpec.widthMM,
                                heightMM: ArgusDisplaySpec.heightMM,
                                name: ArgusDisplaySpec.name)
        guard ok else {
            NSLog("[Argus] VirtualDisplayManager: creation failed.")
            return nil
        }
        // Give the system a beat to register the display before we move it.
        display.positionToRightOfPrimary()
        return display.displayID
    }

    func stop() {
        display.destroy()
    }
}

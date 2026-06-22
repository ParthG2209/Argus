//
//  ScreenCaptureManager.swift
//  Argus
//
//  Captures the virtual display with ScreenCaptureKit at 60fps and delivers
//  NV12 CVPixelBuffers to a delegate on a high-priority queue.
//

import Foundation
import ScreenCaptureKit
import CoreMedia

protocol ScreenCaptureDelegate: AnyObject {
    func didCapture(pixelBuffer: CVPixelBuffer, pts: CMTime)
}

final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var delegate: ScreenCaptureDelegate?

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.argus.capture",
                                             qos: .userInteractive,
                                             attributes: .concurrent)
    private let targetDisplayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID) {
        self.targetDisplayID = displayID
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)

        guard let scDisplay = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
            throw NSError(domain: "Argus", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Virtual display \(targetDisplayID) not found in shareable content."
            ])
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let config = SCStreamConfiguration()
        // Stream at the tablet's physical resolution. The Mac renders HiDPI
        // (2x) internally, but we downscale to the panel's native pixels for
        // transmission efficiency (see README "Known limitations").
        config.width  = Int(ArgusDisplaySpec.pixelsWide)
        config.height = Int(ArgusDisplaySpec.pixelsHigh)
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12
        config.queueDepth = 6
        config.showsCursor = true
        config.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
        NSLog("[Argus] ScreenCaptureKit started on display \(targetDisplayID) "
              + "(\(config.width)x\(config.height) @60).")
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Only deliver complete frames.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let frameStatus = SCFrameStatus(rawValue: statusRaw),
              frameStatus == .complete else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        delegate?.didCapture(pixelBuffer: pixelBuffer, pts: pts)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Argus] SCStream stopped with error: \(error.localizedDescription)")
    }
}

//
//  ScreenCaptureManager.swift
//  Argus
//
//  Captures the virtual display with a SINGLE ScreenCaptureKit stream that
//  carries both video and audio. (Phase 1 used a second stream for audio,
//  which produced orphan video frames with no registered output — the source
//  of the "stream output NOT found. Dropping frame" spam.)
//
//  Frames are delivered via closures on dedicated serial queues; nothing on
//  this path touches the main actor.
//

import Foundation
import ScreenCaptureKit
import CoreMedia

final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the serial video queue with each complete NV12 frame.
    var onVideoFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Called on the serial audio queue with each PCM audio sample buffer.
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "com.argus.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.argus.capture.audio", qos: .userInitiated)

    private let targetDisplayID: CGDirectDisplayID
    private let captureWidth: Int
    private let captureHeight: Int
    private let frameRate: Int

    init(displayID: CGDirectDisplayID, width: Int, height: Int, frameRate: Int) {
        self.targetDisplayID = displayID
        self.captureWidth = width
        self.captureHeight = height
        self.frameRate = frameRate
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
        // Always capture at the tablet's native panel resolution. macOS may be
        // rendering a larger HiDPI framebuffer (More Space); ScreenCaptureKit
        // scales it down to these dimensions for transmission.
        config.width = captureWidth
        config.height = captureHeight
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12
        // Shallow queue: hand frames off immediately, don't let SCK buffer a
        // backlog (that's latency). We process fast, so 3 is plenty.
        config.queueDepth = 3
        config.showsCursor = true
        config.colorSpaceName = CGColorSpace.sRGB

        // Audio in the same stream.
        config.capturesAudio = true
        config.sampleRate = Int(ArgusAudioSpec.sampleRate)
        config.channelCount = Int(ArgusAudioSpec.channels)
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
        NSLog("[Argus] ScreenCaptureKit started on display \(targetDisplayID) "
              + "(\(captureWidth)x\(captureHeight), video+audio).")
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            onAudioSample?(sampleBuffer)
        default:
            break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
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
        onVideoFrame?(pixelBuffer, pts)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Argus] SCStream stopped with error: \(error.localizedDescription)")
    }
}

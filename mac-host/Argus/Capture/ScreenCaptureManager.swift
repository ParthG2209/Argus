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
import os
import CoreMedia

final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the serial video queue with each complete NV12 frame.
    var onVideoFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Called on the serial audio queue with each PCM audio sample buffer.
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private let audioQueue = DispatchQueue(label: "com.argus.capture.audio", qos: .userInitiated)
    private var activeStream: SCStream?

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
        config.width = scDisplay.width
        config.height = scDisplay.height

        // Audio only stream (video is captured by CGDisplayStream).
        // To silence the 'stream output NOT found' log spam, we add a dummy
        // video output that just drops the frames.
        config.capturesAudio = true
        config.sampleRate = Int(ArgusAudioSpec.sampleRate)
        config.channelCount = Int(ArgusAudioSpec.channels)
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        
        var started = false
        var lastError: Error?
        for _ in 0..<5 {
            do {
                try await stream.startCapture()
                started = true
                break
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        
        if !started {
            if let lastError = lastError { throw lastError }
            else { throw NSError(domain: "Argus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start SCStream"]) }
        }
        
        self.activeStream = stream
        NSLog("[Argus] ScreenCaptureKit started on display \(targetDisplayID) (audio only).")
    }

    func stop() async {
        if let stream = activeStream {
            do { try await stream.stopCapture() } catch {}
            self.activeStream = nil
        }
    } // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .audio {
            onAudioSample?(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Argus] SCStream stopped with error: \(error.localizedDescription)")
    }
}

// MARK: - CGDisplayStreamManager

final class CGDisplayStreamManager {
    /// Called on the serial video queue with each complete NV12 frame.
    var onVideoFrame: ((CVPixelBuffer, CMTime) -> Void)?
    
    private var stream: CGDisplayStream?
    private let videoQueue = DispatchQueue(label: "com.argus.capture.video", qos: .userInteractive)
    private let captureCount = OSAllocatedUnfairLock(initialState: 0)
    
    private let targetDisplayID: CGDirectDisplayID
    private let captureWidth: Int
    private let captureHeight: Int
    private let fps: Int
    
    /// Read & reset the capture frame counter (for diagnostics).
    func takeCaptureCount() -> Int {
        captureCount.withLock { c in let v = c; c = 0; return v }
    }
    
    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) {
        self.targetDisplayID = displayID
        self.captureWidth = width
        self.captureHeight = height
        self.fps = fps
    }
    
    func start() {
        let properties: [CFString: Any] = [
            CGDisplayStream.showCursor: true,
            CGDisplayStream.colorSpace: CGColorSpaceCreateDeviceRGB(),
            CGDisplayStream.yCbCrMatrix: CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        ]
        
        let handler: CGDisplayStreamFrameAvailableHandler = { [weak self] status, displayTime, surface, update in
            guard let self = self else { return }
            guard status == .frameComplete, let surface = surface else { return }
            
            var unmanagedPB: Unmanaged<CVPixelBuffer>?
            let result = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &unmanagedPB)
            guard result == kCVReturnSuccess, let pb = unmanagedPB?.takeRetainedValue() else { return }
            
            // Convert Mach absolute time to CMTime
            var timebaseInfo = mach_timebase_info_data_t()
            mach_timebase_info(&timebaseInfo)
            let nanos = displayTime * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
            let pts = CMTime(value: Int64(nanos), timescale: 1_000_000_000)
            
            self.captureCount.withLock { $0 += 1 }
            self.onVideoFrame?(pb, pts)
        }
        
        guard let displayStream = CGDisplayStream(
            dispatchQueueDisplay: targetDisplayID,
            outputWidth: captureWidth,
            outputHeight: captureHeight,
            pixelFormat: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            properties: properties as CFDictionary,
            queue: videoQueue,
            handler: handler
        ) else {
            NSLog("[Argus] Failed to create CGDisplayStream for display \(targetDisplayID)")
            return
        }
        
        self.stream = displayStream
        let err = displayStream.start()
        if err != .success {
            NSLog("[Argus] Failed to start CGDisplayStream: error \(err.rawValue)")
            return
        }
        NSLog("[Argus] CGDisplayStream started on display \(targetDisplayID) (\(captureWidth)x\(captureHeight)).")
    }
    
    func stop() {
        stream?.stop()
        stream = nil
    }
}

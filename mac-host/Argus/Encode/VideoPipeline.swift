//
//  VideoPipeline.swift
//  Argus
//
//  The hot path: capture -> encode -> send. Deliberately NOT main-actor
//  isolated. ScreenCaptureKit delivers frames on a serial capture queue;
//  encoding and socket writes happen there / on VideoToolbox's own callback
//  thread. The main thread is never on this path (that was the Phase-1
//  latency bug).
//

import Foundation
import CoreMedia
import CoreVideo
import os

final class VideoPipeline {
    private let encoder: VideoEncoder
    private let server: FrameSocketServer
    private let frameRate: Int32

    private struct State {
        var needsKeyframe = true
        var frameCount = 0
        var streaming = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())


    // Throttle for drop-triggered recovery keyframes (avoid keyframe storms
    // when USB is steadily saturated).
    private let lastKeyframeNanos = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let keyframeThrottleNanos: UInt64 = 2_500_000_000  // 2.5s

    /// Fired (off-main) the first time a frame is sent to a connected client.
    var onStreamingStarted: (() -> Void)?

    init(encoder: VideoEncoder, server: FrameSocketServer, frameRate: Int) {
        self.encoder = encoder
        self.server = server
        self.frameRate = Int32(frameRate)

        encoder.onEncodedFrame = { [weak self] frame, isKeyframe in
            guard let self else { return }
            self.server.send(frame: frame)
            if isKeyframe {
                self.lastKeyframeNanos.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
            }
            let hasClient = self.server.hasClient
            let fireStreaming = self.state.withLock { s -> Bool in
                s.frameCount += 1
                if !s.streaming && hasClient {
                    s.streaming = true
                    return true
                }
                return false
            }
            if fireStreaming { self.onStreamingStarted?() }
        }

        // A dropped frame breaks the P-frame reference chain; recover with a
        // keyframe, but throttle so steady saturation doesn't storm IDRs.
        server.onFrameDropped = { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let last = self.lastKeyframeNanos.withLock { $0 }
            if now &- last > self.keyframeThrottleNanos {
                self.requestKeyframe()
            }
        }
    }

    /// Called on the serial capture queue for each captured frame.
    func process(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let force = state.withLock { s -> Bool in
            let f = s.needsKeyframe
            s.needsKeyframe = false
            return f
        }
        // Use the real capture timestamp (not a synthetic counter) so the
        // tablet can reconstruct true motion timing and pace presentation.
        encoder.encode(pixelBuffer, pts: pts, forceKeyframe: force)
    }

    /// Force the next frame to be an IDR (called when a client (re)connects).
    func requestKeyframe() {
        state.withLock { $0.needsKeyframe = true }
    }

    /// Read & reset the encoded-frame counter (for the FPS HUD).
    func takeFrameCount() -> Int {
        state.withLock { s in
            let c = s.frameCount
            s.frameCount = 0
            return c
        }
    }
}

//
//  StreamCoordinator.swift
//  Argus
//
//  Orchestrates the full pipeline:
//    virtual display -> ScreenCaptureKit -> VideoToolbox -> socket 7175
//    socket 7176 -> InputInjector
//    system audio -> AAC -> socket 7177
//

import Foundation
import CoreMedia
import CoreVideo

@MainActor
final class StreamCoordinator: ScreenCaptureDelegate, AudioCaptureDelegate {
    private let state: AppState
    private let adb = ADBManager()
    private let virtualDisplay = VirtualDisplayManager()

    private var capture: ScreenCaptureManager?
    private var encoder: VideoEncoder?
    private var audio: AudioCapture?
    private var injector: InputInjector?

    private var videoServer: FrameSocketServer?
    private var audioServer: FrameSocketServer?
    private var inputServer: LineSocketServer?

    private var needsKeyframe = true

    // FPS accounting (encoder output rate).
    private var frameCounter = 0
    private var fpsTimer: Timer?
    private var ptsCounter: Int64 = 0

    init(state: AppState) {
        self.state = state
        state.coordinator = self
    }

    // MARK: - Lifecycle

    func connect() {
        state.lastError = nil

        // 1. adb availability
        guard adb.locate() != nil else {
            state.adbAvailable = false
            state.lastError = "adb not found. Install with: brew install android-platform-tools"
            return
        }
        state.adbAvailable = true
        state.adbPath = adb.adbPath ?? "adb"

        // 2. Virtual display
        guard let displayID = virtualDisplay.start() else {
            state.lastError = "Failed to create virtual display (private API)."
            return
        }

        // 3. Sockets
        startServers()

        // 4. adb reverse
        _ = adb.setupReverseTunnels()

        // 5. Encoder
        let enc = VideoEncoder(width: Int32(ArgusDisplaySpec.pixelsWide),
                               height: Int32(ArgusDisplaySpec.pixelsHigh),
                               bitrate: Int(state.bitrateSetting * 1_000_000))
        enc.onEncodedFrame = { [weak self] frame, isKey in
            self?.handleEncodedFrame(frame, isKeyframe: isKey)
        }
        guard enc.start() else {
            state.lastError = "Failed to start video encoder."
            return
        }
        encoder = enc

        // 6. Input injector
        let inj = InputInjector(displayID: displayID)
        inj.enablePressure = state.enablePressure
        inj.enableTilt = state.enableTilt
        inj.enableHover = state.enableHover
        inj.onInputModeChange = { [weak self] mode, pressure in
            Task { @MainActor in self?.state.update(inputMode: mode, pressure: pressure) }
        }
        inj.start()
        injector = inj
        inputServer?.onLine = { [weak inj] line in inj?.handle(line: line) }

        // 7. Capture
        let cap = ScreenCaptureManager(displayID: displayID)
        cap.delegate = self
        capture = cap

        // 8. Audio
        let aud = AudioCapture(displayID: displayID)
        aud.delegate = self
        audio = aud

        Task {
            do {
                try await cap.start()
                try await aud.start()
                await MainActor.run { self.state.update(status: .connected) }
            } catch {
                await MainActor.run {
                    self.state.lastError = "Capture start failed: \(error.localizedDescription)"
                }
            }
        }

        startFPSTimer()
        state.update(status: .connected)
    }

    func disconnect() {
        fpsTimer?.invalidate(); fpsTimer = nil

        Task {
            await capture?.stop()
            await audio?.stop()
        }
        encoder?.stop(); encoder = nil
        injector?.stop(); injector = nil
        capture = nil; audio = nil

        videoServer?.stop(); audioServer?.stop(); inputServer?.stop()
        videoServer = nil; audioServer = nil; inputServer = nil

        adb.removeReverseTunnels()
        virtualDisplay.stop()

        state.update(status: .disconnected)
        state.update(fps: 0)
        state.update(inputMode: .none)
    }

    func applyBitrate(_ mbps: Double) {
        state.bitrateSetting = mbps
        state.bitrateMbps = mbps
        encoder?.updateBitrate(Int(mbps * 1_000_000))
    }

    // MARK: - Servers

    private func startServers() {
        let video = FrameSocketServer(port: ArgusPorts.video, label: "video")
        video.onClientConnected = { [weak self] in
            // Force a keyframe so the freshly-connected decoder configures.
            self?.needsKeyframe = true
        }
        _ = video.start()
        videoServer = video

        let audioSrv = FrameSocketServer(port: ArgusPorts.audio, label: "audio")
        _ = audioSrv.start()
        audioServer = audioSrv

        let input = LineSocketServer(port: ArgusPorts.input, label: "input")
        _ = input.start()
        inputServer = input
    }

    // MARK: - ScreenCaptureDelegate

    nonisolated func didCapture(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        Task { @MainActor in
            guard let encoder = self.encoder else { return }
            let force = self.needsKeyframe
            if force { self.needsKeyframe = false }
            let stampedPTS = CMTime(value: self.ptsCounter, timescale: 60)
            self.ptsCounter += 1
            encoder.encode(pixelBuffer, pts: stampedPTS, forceKeyframe: force)
        }
    }

    private func handleEncodedFrame(_ frame: Data, isKeyframe: Bool) {
        videoServer?.send(frame: frame)
        frameCounter += 1
        if state.status == .connected, videoServer?.hasClient == true {
            state.update(status: .streaming)
        }
    }

    // MARK: - AudioCaptureDelegate

    nonisolated func didEncodeAudio(_ frame: Data) {
        Task { @MainActor in self.audioServer?.send(frame: frame) }
    }

    // MARK: - FPS

    private func startFPSTimer() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.state.update(fps: self.frameCounter)
                self.frameCounter = 0
            }
        }
    }
}

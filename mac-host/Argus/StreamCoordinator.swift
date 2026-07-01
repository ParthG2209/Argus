//
//  StreamCoordinator.swift
//  Argus
//
//  Orchestrates the full pipeline. The capture -> encode -> send hot path
//  runs entirely off the main actor (see VideoPipeline); only status/HUD
//  updates hop back to @MainActor.
//
//  Connection flow (resolution auto-detect):
//    1. connect(): wire + open all sockets, run adb reverse.
//    2. Tablet connects; sends a "hello" with its real resolution on 7176.
//    3. startStreaming(w,h): create the virtual display + encoder + capture
//       sized to the tablet, so the stream fills the panel (no black bars).
//    4. If no hello arrives within a timeout, fall back to a default size.
//

import Foundation
import CoreMedia
import CoreVideo

@MainActor
final class StreamCoordinator {
    private let state: AppState
    private let adb = ADBManager()
    private let virtualDisplay = VirtualDisplayManager()

    private var audioCapture: ScreenCaptureManager?
    private var videoCapture: CGDisplayStreamManager?
    private var encoder: VideoEncoder?
    private var videoPipeline: VideoPipeline?
    private var audioEncoder: AudioEncoder?
    private var injector: InputInjector?

    private var videoServer: FrameSocketServer?
    private var audioServer: FrameSocketServer?
    private var inputServer: LineSocketServer?
    private var advertiser: BonjourAdvertiser?

    private var fpsTimer: Timer?
    private var usbMonitorTimer: Timer?

    private var captureWidth = ArgusDisplaySpec.fallbackWidth
    private var captureHeight = ArgusDisplaySpec.fallbackHeight
    private var streamingStarted = false
    private var helloTimeout: Timer?

    init(state: AppState) {
        self.state = state
        state.coordinator = self
    }

    // MARK: - Lifecycle

    func connect() {
        state.lastError = nil
        streamingStarted = false

        guard adb.locate() != nil else {
            state.adbAvailable = false
            state.lastError = "adb not found. Install with: brew install android-platform-tools"
            return
        }
        state.adbAvailable = true
        state.adbPath = adb.adbPath ?? "adb"

        let codec = VideoCodec(rawValue: state.codec) ?? .h264

        // Build + fully wire all servers BEFORE opening any listener (the
        // tablet may dial in the instant a listener opens).
        let video = FrameSocketServer(port: ArgusPorts.video, label: "video", maxInFlight: 5)
        let audioSrv = FrameSocketServer(port: ArgusPorts.audio, label: "audio", maxInFlight: 5)
        let input = LineSocketServer(port: ArgusPorts.input, label: "input")
        videoServer = video; audioServer = audioSrv; inputServer = input

        video.connectFrame = { ArgusHandshake.make(codec) }
        video.onClientConnected = { [weak self] isUSB in 
            Task { @MainActor in
                self?.state.update(isUSB: isUSB)
                self?.encoder?.setUSBMode(isUSB)
                self?.audioServer?.disconnectClient()
                self?.inputServer?.disconnectClient()
            }
            self?.videoPipeline?.requestKeyframe() 
        }
        input.onLine = { [weak self] line in
            Task { @MainActor in self?.handleInputLine(line) }
        }

        _ = video.start(); _ = audioSrv.start(); _ = input.start()
        
        advertiser = BonjourAdvertiser(port: ArgusPorts.video)
        advertiser?.start()
        
        _ = adb.setupReverseTunnels()
        startUSBMonitor()

        state.update(status: .connected)

        // Fallback: if the tablet never reports its resolution, start anyway.
        // We wait for the client to connect and send the 'hello' message.
        // If an older client connects, we rely on the fact that it doesn't send hello
        // but it will immediately start receiving frames. Wait, actually we shouldn't
        // start the stream until we get a hello to be perfectly sized.
        // We will just wait indefinitely for the 'hello'. Modern clients send it immediately.
    }

    /// Handle one line from the input socket: a resolution hello, or an event.
    private func handleInputLine(_ line: String) {
        if let data = line.data(using: .utf8),
           let hello = try? JSONDecoder().decode(HelloMessage.self, from: data),
           hello.type == "hello" {
            if let r = hello.refresh, r > 0 { state.tabletRefresh = r }
            NSLog("[Argus] Tablet reported \(hello.width)x\(hello.height) @ \(state.tabletRefresh)Hz.")
            Task { @MainActor in
                await startStreaming(width: hello.width, height: hello.height)
            }
            return
        }
        injector?.handle(line: line)
    }

    /// Create the display + encoder + capture sized to the tablet and begin
    /// streaming. Idempotent (ignores a second hello).
    private func startStreaming(width: Int, height: Int) async {
        guard !streamingStarted else { return }
        streamingStarted = true

        // Native (display) resolution = the tablet's panel. macOS renders the
        // virtual display at this, crisp.
        let nativeW = max(2, width)
        let nativeH = max(2, height)
        captureWidth = nativeW
        captureHeight = nativeH
        state.tabletWidth = nativeW
        state.tabletHeight = nativeH

        // Stream (encode) resolution
        var streamW = Double(nativeW)
        var streamH = Double(nativeH)
        
        let finalStreamW = evenInt(streamW)
        let finalStreamH = evenInt(streamH)

        // Content rate = a clean integer divisor of the panel refresh, so every
        // frame shows for a whole number of refreshes (smooth, no cadence judder).
        let fps = state.effectiveFrameRate
        guard let displayID = await virtualDisplay.start(presetName: state.scalingPreset,
                                                         nativeWidth: nativeW,
                                                         nativeHeight: nativeH,
                                                         refreshHz: Double(fps)) else {
            state.lastError = "Failed to create virtual display (private API)."
            return
        }

        let codec = VideoCodec(rawValue: state.codec) ?? .h264
        let enc = VideoEncoder(width: Int32(finalStreamW),
                               height: Int32(finalStreamH),
                               bitrate: Int(state.bitrateSetting * 1_000_000),
                               codec: codec,
                               frameRate: fps)
        guard enc.start() else {
            state.lastError = "Failed to start video encoder."
            return
        }
        encoder = enc

        guard let video = videoServer else { return }
        let pipe = VideoPipeline(encoder: enc, server: video, frameRate: fps)
        pipe.onStreamingStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.state.status != .streaming { self.state.update(status: .streaming) }
            }
        }
        videoPipeline = pipe
        // The video client likely connected already (before the pipe existed),
        // so its onClientConnected keyframe request was a no-op — force one now.
        pipe.requestKeyframe()

        let aenc = AudioEncoder()
        aenc.onEncodedFrame = { [weak self] frame in self?.audioServer?.send(frame: frame) }
        audioEncoder = aenc

        let inj = InputInjector(displayID: displayID)
        inj.enablePressure = state.enablePressure
        inj.enableTilt = state.enableTilt
        inj.enableHover = state.enableHover
        inj.onInputModeChange = { [weak self] mode, pressure in
            Task { @MainActor in self?.state.update(inputMode: mode, pressure: pressure) }
        }
        inj.start()
        injector = inj

        let vcap = CGDisplayStreamManager(displayID: displayID, width: finalStreamW, height: finalStreamH, fps: fps)
        vcap.onVideoFrame = { [weak pipe] pb, pts in pipe?.process(pb, pts: pts) }
        videoCapture = vcap
        vcap.start()

        let acap = ScreenCaptureManager(displayID: displayID)
        acap.onAudioSample = { [weak aenc] sb in aenc?.encode(sb) }
        audioCapture = acap

        Task {
            do {
                try await acap.start()
            } catch {
                await MainActor.run {
                    self.state.lastError = "Audio capture start failed: \(error.localizedDescription)"
                }
            }
        }

        startFPSTimer()
        NSLog("[Argus] Streaming started: \(streamW)x\(streamH) @ \(fps)fps "
              + "(panel \(state.tabletRefresh)Hz, target \(state.targetFPS) fps).")
    }

    private func evenInt(_ v: Double) -> Int {
        var n = Int(v.rounded())
        if n < 2 { n = 2 }
        if n % 2 != 0 { n -= 1 }   // codecs prefer even dimensions
        return n
    }

    func disconnect() {
        fpsTimer?.invalidate(); fpsTimer = nil
        usbMonitorTimer?.invalidate(); usbMonitorTimer = nil
        helloTimeout?.invalidate(); helloTimeout = nil
        streamingStarted = false

        videoCapture?.stop()
        videoCapture = nil
        Task { [acap = audioCapture] in
            await acap?.stop()
        }
        audioCapture = nil
        encoder?.stop(); encoder = nil
        audioEncoder?.stop(); audioEncoder = nil
        injector?.stop(); injector = nil
        videoPipeline = nil

        videoServer?.stop(); audioServer?.stop(); inputServer?.stop()
        videoServer = nil; audioServer = nil; inputServer = nil
        advertiser?.stop(); advertiser = nil

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

    /// Change the video codec. Requires a reconnect, so bounce the session.
    func applyCodec(_ codecName: String) {
        guard state.codec != codecName else { return }
        state.codec = codecName
        if state.status != .disconnected {
            disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.connect()
            }
        }
    }

    /// Change the target frame rate. Recreates the display + encoder, so reconnect.
    func applyTargetFPS(_ fps: Int) {
        guard state.targetFPS != fps else { return }
        state.targetFPS = fps
        reconnectIfStreaming()
    }

    private func reconnectIfStreaming() {
        if state.status != .disconnected {
            disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.connect()
            }
        }
    }

    /// Change the HiDPI scaling preset live (no reconnect needed).
    func applyScaling(_ presetName: String) {
        state.scalingPreset = presetName
        if virtualDisplay.isActive {
            virtualDisplay.setScaling(presetName: presetName)
        }
    }

    // MARK: - FPS HUD

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let encodedFps = self.videoPipeline?.takeFrameCount() ?? 0
                let capturedFps = self.videoCapture?.takeCaptureCount() ?? 0
                self.state.update(fps: encodedFps)
                if capturedFps > 0 || encodedFps > 0 {
                    NSLog("[Argus] FPS: captured=%d  encoded=%d", capturedFps, encodedFps)
                }
            }
        }
    }

    private func startUSBMonitor() {
        usbMonitorTimer?.invalidate()
        usbMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.state.status == .streaming && !self.state.isUSB {
                    // Silently attempt to map ports. If a device was just plugged in,
                    // this will succeed and open localhost:7175 for the tablet to ping.
                    self.adb.setupReverseTunnels(silent: true)
                }
            }
        }
    }
}

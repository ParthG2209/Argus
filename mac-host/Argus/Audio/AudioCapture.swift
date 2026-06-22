//
//  AudioCapture.swift
//  Argus
//
//  Captures system audio via ScreenCaptureKit (capturesAudio) and encodes it
//  to AAC-LC (48 kHz, stereo, 128 kbps) with AudioToolbox, emitting raw AAC
//  access units for the transport layer to length-prefix and send on 7177.
//
//  ScreenCaptureKit's audio path is used instead of a raw CoreAudio process
//  tap because it captures the system mix directly and avoids building an
//  aggregate tap device. Note: like a CoreAudio tap, it follows the default
//  output device — Bluetooth outputs may not be captured.
//

import Foundation
import ScreenCaptureKit
import AudioToolbox
import AVFoundation

protocol AudioCaptureDelegate: AnyObject {
    func didEncodeAudio(_ frame: Data)
}

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var delegate: AudioCaptureDelegate?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.argus.audio", qos: .userInitiated)
    private let displayID: CGDirectDisplayID

    private var converter: AudioConverterRef?
    private var inputASBD = AudioStreamBasicDescription()
    private var outputASBD = AudioStreamBasicDescription()

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            throw NSError(domain: "Argus", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display for audio capture."])
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(ArgusAudioSpec.sampleRate)
        config.channelCount = Int(ArgusAudioSpec.channels)
        config.excludesCurrentProcessAudio = true
        // Minimal video config is still required; keep it tiny.
        config.width = 2
        config.height = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        NSLog("[Argus] Audio capture started.")
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        if let converter { AudioConverterDispose(converter); self.converter = nil }
        inputBuffer?.deallocate(); inputBuffer = nil; inputConsumed = true
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        if converter == nil {
            setupConverter(inputFormat: asbd.pointee)
        }
        encode(sampleBuffer)
    }

    // MARK: - AAC converter

    private func setupConverter(inputFormat: AudioStreamBasicDescription) {
        inputASBD = inputFormat

        var out = AudioStreamBasicDescription()
        out.mSampleRate = ArgusAudioSpec.sampleRate
        out.mFormatID = kAudioFormatMPEG4AAC
        out.mChannelsPerFrame = ArgusAudioSpec.channels
        out.mFramesPerPacket = 1024
        outputASBD = out

        var conv: AudioConverterRef?
        let status = AudioConverterNew(&inputASBD, &outputASBD, &conv)
        guard status == noErr, let conv else {
            NSLog("[Argus] AudioConverterNew failed: \(status)")
            return
        }
        var bitrate = UInt32(ArgusAudioSpec.bitrate)
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrate)
        converter = conv
    }

    // Pull-style encode: feed exactly the frames from one sample buffer.
    // The input PCM lives in a stable heap buffer (NOT a closure-scoped
    // pointer) because the converter reads it via the input-data callback,
    // which may run after the enclosing closure returns.
    private var inputBuffer: UnsafeMutableRawBufferPointer?
    private var inputConsumed = true

    private func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let converter else { return }

        // Extract interleaved PCM into a contiguous buffer.
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let buf = audioBufferList.mBuffers.mData else { return }

        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        guard byteCount > 0 else { return }

        // Copy the PCM into a stable buffer that outlives this closure.
        inputBuffer?.deallocate()
        let stable = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount,
                                                            alignment: 16)
        stable.copyMemory(from: UnsafeRawBufferPointer(start: buf, count: byteCount))
        inputBuffer = stable
        inputConsumed = false

        // Output buffer for one AAC packet.
        let maxPacketSize = 1536
        var outData = Data(count: maxPacketSize)
        var packetDesc = AudioStreamPacketDescription()

        var encodedSize = 0
        outData.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var outList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: ArgusAudioSpec.channels,
                                      mDataByteSize: UInt32(maxPacketSize),
                                      mData: raw.baseAddress))
            var ioPackets: UInt32 = 1
            let convStatus = AudioConverterFillComplexBuffer(
                converter,
                Self.inputDataProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &ioPackets,
                &outList,
                &packetDesc)

            if (convStatus == noErr || convStatus == 1) && ioPackets > 0 {
                encodedSize = Int(outList.mBuffers.mDataByteSize)
            }
        }

        // Read outData outside the exclusive-access closure.
        if encodedSize > 0 {
            delegate?.didEncodeAudio(Data(outData.prefix(encodedSize)))
        }
    }

    // C callback supplying PCM input to the converter.
    private static let inputDataProc: AudioConverterComplexInputDataProc = {
        (_, ioNumberDataPackets, ioData, _, inUserData) -> OSStatus in
        guard let inUserData else { ioNumberDataPackets.pointee = 0; return -1 }
        let me = Unmanaged<AudioCapture>.fromOpaque(inUserData).takeUnretainedValue()
        guard let buffer = me.inputBuffer, !me.inputConsumed, buffer.count > 0,
              let base = buffer.baseAddress else {
            ioNumberDataPackets.pointee = 0
            return -1   // no more data this cycle
        }
        let bytesPerFrame = max(1, Int(me.inputASBD.mBytesPerFrame))
        ioNumberDataPackets.pointee = UInt32(buffer.count / bytesPerFrame)

        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = me.inputASBD.mChannelsPerFrame
        ioData.pointee.mBuffers.mDataByteSize = UInt32(buffer.count)
        ioData.pointee.mBuffers.mData = base   // stable: lives in `me.inputBuffer`

        me.inputConsumed = true
        return noErr
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Argus] Audio SCStream stopped: \(error.localizedDescription)")
    }
}

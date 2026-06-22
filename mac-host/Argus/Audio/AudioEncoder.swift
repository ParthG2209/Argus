//
//  AudioEncoder.swift
//  Argus
//
//  Encodes PCM audio sample buffers (delivered by the shared ScreenCaptureKit
//  stream) to AAC-LC (48 kHz, stereo, 128 kbps) with AudioToolbox, emitting
//  raw AAC access units. No SCStream of its own — it is fed by
//  ScreenCaptureManager.onAudioSample on the capture's serial audio queue.
//

import Foundation
import AudioToolbox
import CoreMedia

final class AudioEncoder {
    /// Emits one raw AAC access unit (on the audio capture queue).
    var onEncodedFrame: ((Data) -> Void)?

    private var converter: AudioConverterRef?
    private var inputASBD = AudioStreamBasicDescription()
    private var outputASBD = AudioStreamBasicDescription()

    // Stable heap buffer for the converter's input callback (must outlive the
    // enclosing closure — the callback may run after it returns).
    private var inputBuffer: UnsafeMutableRawBufferPointer?
    private var inputConsumed = true

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        if converter == nil { setupConverter(inputFormat: asbd.pointee) }
        guard let converter else { return }

        // Extract interleaved PCM.
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

        inputBuffer?.deallocate()
        let stable = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 16)
        stable.copyMemory(from: UnsafeRawBufferPointer(start: buf, count: byteCount))
        inputBuffer = stable
        inputConsumed = false

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

        if encodedSize > 0 {
            onEncodedFrame?(Data(outData.prefix(encodedSize)))
        }
    }

    func stop() {
        if let converter { AudioConverterDispose(converter); self.converter = nil }
        inputBuffer?.deallocate(); inputBuffer = nil; inputConsumed = true
    }

    // MARK: - Converter setup

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

    private static let inputDataProc: AudioConverterComplexInputDataProc = {
        (_, ioNumberDataPackets, ioData, _, inUserData) -> OSStatus in
        guard let inUserData else { ioNumberDataPackets.pointee = 0; return -1 }
        let me = Unmanaged<AudioEncoder>.fromOpaque(inUserData).takeUnretainedValue()
        guard let buffer = me.inputBuffer, !me.inputConsumed, buffer.count > 0,
              let base = buffer.baseAddress else {
            ioNumberDataPackets.pointee = 0
            return -1
        }
        let bytesPerFrame = max(1, Int(me.inputASBD.mBytesPerFrame))
        ioNumberDataPackets.pointee = UInt32(buffer.count / bytesPerFrame)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = me.inputASBD.mChannelsPerFrame
        ioData.pointee.mBuffers.mDataByteSize = UInt32(buffer.count)
        ioData.pointee.mBuffers.mData = base
        me.inputConsumed = true
        return noErr
    }
}

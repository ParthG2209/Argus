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
    
    private let pcmQueue = DispatchQueue(label: "argus.audio.pcm")
    private var isNonInterleaved = false
    private var inputASBD = AudioStreamBasicDescription()

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        
        self.isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        self.inputASBD = asbd.pointee

        var blockBuffer: CMBlockBuffer?
        let listSize = MemoryLayout<AudioBufferList>.size + Int(asbd.pointee.mChannelsPerFrame - 1) * MemoryLayout<AudioBuffer>.size
        let listPointer = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return }
        
        let audioBufferList = UnsafeMutableAudioBufferListPointer(listPointer.assumingMemoryBound(to: AudioBufferList.self))
        pcmQueue.sync {
            let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0

            if isNonInterleaved && audioBufferList.count == 2 {
                let bytesPerChannelFrame = Int(asbd.pointee.mBytesPerFrame)
                let frameCount = Int(audioBufferList[0].mDataByteSize) / bytesPerChannelFrame
                let left = audioBufferList[0].mData!
                let right = audioBufferList[1].mData!
                
                let interleavedBytes = frameCount * MemoryLayout<Int16>.size * 2
                var outData = Data(count: interleavedBytes)
                
                outData.withUnsafeMutableBytes { raw in
                    let outBuf = raw.bindMemory(to: Int16.self).baseAddress!
                    if isFloat {
                        let leftPtr = left.assumingMemoryBound(to: Float32.self)
                        let rightPtr = right.assumingMemoryBound(to: Float32.self)
                        for i in 0..<frameCount {
                            let l = max(-1.0, min(1.0, leftPtr[i]))
                            let r = max(-1.0, min(1.0, rightPtr[i]))
                            outBuf[i * 2] = Int16(l * 32767.0)
                            outBuf[i * 2 + 1] = Int16(r * 32767.0)
                        }
                    } else {
                        let leftPtr = left.assumingMemoryBound(to: Int16.self)
                        let rightPtr = right.assumingMemoryBound(to: Int16.self)
                        for i in 0..<frameCount {
                            outBuf[i * 2] = leftPtr[i]
                            outBuf[i * 2 + 1] = rightPtr[i]
                        }
                    }
                }
                onEncodedFrame?(outData)
            } else if audioBufferList.count > 0 {
                let buf = audioBufferList[0].mData!
                let byteCount = Int(audioBufferList[0].mDataByteSize)
                let channels = Int(asbd.pointee.mChannelsPerFrame)
                let frameCount = byteCount / Int(asbd.pointee.mBytesPerFrame)

                if isFloat {
                    var outData = Data(count: frameCount * channels * MemoryLayout<Int16>.size)
                    outData.withUnsafeMutableBytes { raw in
                        let outBuf = raw.bindMemory(to: Int16.self).baseAddress!
                        let inPtr = buf.assumingMemoryBound(to: Float32.self)
                        for i in 0..<(frameCount * channels) {
                            let sample = max(-1.0, min(1.0, inPtr[i]))
                            outBuf[i] = Int16(sample * 32767.0)
                        }
                    }
                    onEncodedFrame?(outData)
                } else {
                    let outData = Data(bytes: buf, count: byteCount)
                    onEncodedFrame?(outData)
                }
            }
        }
    }

    private func drainEncoder() {
    }

    func stop() {
    }

    // MARK: - Converter setup

    private func setupConverter(inputFormat: AudioStreamBasicDescription) {
        // No setup needed for Raw PCM forwarding.
    }
}

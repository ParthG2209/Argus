//
//  AudioEncoder.swift
//  Argus
//

import Foundation
import CoreMedia
import AVFoundation
import os

final class AudioEncoder {
    var onEncodedFrame: ((Data) -> Void)?
    private let pcmQueue = DispatchQueue(label: "argus.audio.pcm")
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var outFormat: AVAudioFormat?
    private let targetSampleRate: Double = 48000
    private let targetChannels: AVAudioChannelCount = 2

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        
        pcmQueue.sync {
            let currentInFormat = AVAudioFormat(streamDescription: asbdPtr)
            guard let currentInFormat = currentInFormat else {
                NSLog("[ArgusAudio] Failed to create AVAudioFormat from ASBD")
                return
            }
            
            if converter == nil || inFormat != currentInFormat {
                self.inFormat = currentInFormat
                self.outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: targetSampleRate,
                                               channels: targetChannels,
                                               interleaved: true)
                guard let outF = self.outFormat else { return }
                self.converter = AVAudioConverter(from: currentInFormat, to: outF)
                if self.converter == nil {
                    NSLog("[ArgusAudio] Failed to create AVAudioConverter")
                }
            }
            
            guard let converter = converter, let outFormat = outFormat else { return }
            
            var blockBuffer: CMBlockBuffer?
            let listSize = MemoryLayout<AudioBufferList>.size + Int(asbdPtr.pointee.mChannelsPerFrame - 1) * MemoryLayout<AudioBuffer>.size
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
            
            guard status == noErr else {
                NSLog("[ArgusAudio] GetAudioBufferList failed: \(status)")
                return
            }
            
            let numFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard numFrames > 0 else { return }
            
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: currentInFormat, frameCapacity: numFrames) else {
                NSLog("[ArgusAudio] Failed to create inBuffer")
                return
            }
            inBuffer.frameLength = numFrames
            
            let srcBuffers = UnsafeMutableAudioBufferListPointer(listPointer.assumingMemoryBound(to: AudioBufferList.self))
            let dstBuffers = UnsafeMutableAudioBufferListPointer(inBuffer.mutableAudioBufferList)
            
            for i in 0..<min(srcBuffers.count, dstBuffers.count) {
                if let srcData = srcBuffers[i].mData, let dstData = dstBuffers[i].mData {
                    memcpy(dstData, srcData, Int(srcBuffers[i].mDataByteSize))
                }
            }
            
            let ratio = targetSampleRate / currentInFormat.sampleRate
            let outFrameCapacity = AVAudioFrameCount(Double(numFrames) * ratio) + 4096
            
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrameCapacity) else {
                NSLog("[ArgusAudio] Failed to create outBuffer")
                return
            }
            
            var provided = false
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            
            var error: NSError? = nil
            let convStatus = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            
            if convStatus == .error {
                NSLog("[ArgusAudio] Converter error: \(String(describing: error))")
                return
            }
            
            let frameLength = Int(outBuffer.frameLength)
            if frameLength > 0 {
                let byteLength = frameLength * Int(targetChannels) * MemoryLayout<Int16>.size
                if let int16ChannelData = outBuffer.int16ChannelData {
                    let outData = Data(bytes: int16ChannelData[0], count: byteLength)
                    onEncodedFrame?(outData)
                } else {
                    NSLog("[ArgusAudio] int16ChannelData is nil")
                }
            }
        }
    }

    func stop() {
        pcmQueue.sync {
            converter?.reset()
        }
    }
}

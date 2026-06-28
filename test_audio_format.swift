import Foundation
import CoreMedia
import ScreenCaptureKit

let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { exit(1) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        
        class Delegate: NSObject, SCStreamOutput, SCStreamDelegate {
            func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
                if type == .audio {
                    if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                        print("mFormatID: \(asbd.pointee.mFormatID)")
                        print("mFormatFlags: \(asbd.pointee.mFormatFlags)")
                        print("mBytesPerPacket: \(asbd.pointee.mBytesPerPacket)")
                        print("mFramesPerPacket: \(asbd.pointee.mFramesPerPacket)")
                        print("mBytesPerFrame: \(asbd.pointee.mBytesPerFrame)")
                        print("mChannelsPerFrame: \(asbd.pointee.mChannelsPerFrame)")
                        print("mBitsPerChannel: \(asbd.pointee.mBitsPerChannel)")
                        
                        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
                        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                        print("Is Non-Interleaved: \(isNonInterleaved)")
                        print("Is Float: \(isFloat)")
                    }
                    exit(0)
                }
            }
        }
        
        let delegate = Delegate()
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: DispatchQueue.main)
        try await stream.startCapture()
    } catch {
        print(error)
        exit(1)
    }
}

semaphore.wait(timeout: .now() + 5.0)

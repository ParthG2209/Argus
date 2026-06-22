//
//  VideoEncoder.swift
//  Argus
//
//  VideoToolbox H.264 encoder. Consumes CVPixelBuffers from ScreenCaptureKit
//  and emits Annex B access units (SPS/PPS inlined on keyframes) via a
//  callback. The transport layer is responsible for the 4-byte length prefix.
//

import Foundation
import VideoToolbox
import CoreMedia

final class VideoEncoder {
    /// Called for each encoded access unit. `isKeyframe` true on IDR frames.
    var onEncodedFrame: ((Data, _ isKeyframe: Bool) -> Void)?

    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private var bitrate: Int

    // Annex B start code.
    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    init(width: Int32, height: Int32, bitrate: Int) {
        self.width = width
        self.height = height
        self.bitrate = bitrate
    }

    func start() -> Bool {
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)

        guard status == noErr, let session else {
            NSLog("[Argus] VTCompressionSessionCreate failed: \(status)")
            return false
        }

        configure(session)
        VTCompressionSessionPrepareToEncodeFrames(session)
        NSLog("[Argus] VideoEncoder started \(width)x\(height) @ \(bitrate) bps")
        return true
    }

    private func configure(_ session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        // Data-rate cap (bytes over 1s window) keeps spikes bounded.
        let cap = [bitrate / 8, 1] as [NSNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: cap as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode,
                             value: kVTH264EntropyMode_CABAC)
    }

    /// Live bitrate change (from the Settings slider).
    func updateBitrate(_ bps: Int) {
        bitrate = bps
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        let cap = [bps / 8, 1] as [NSNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: cap as CFArray)
    }

    /// Encode one frame. Optionally force a keyframe (used on first connect).
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false) {
        guard let session else { return }
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
                guard let self, status == noErr, let sampleBuffer else { return }
                self.handleEncoded(sampleBuffer)
            }
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - Encoded sample -> Annex B

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        let isKeyframe = Self.isKeyframe(sampleBuffer)
        var out = Data()

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Inline SPS/PPS ahead of the IDR so the decoder can configure.
            for ps in Self.parameterSets(from: format) {
                out.append(contentsOf: Self.startCode)
                out.append(ps)
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let st = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                             lengthAtOffsetOut: &lengthAtOffset,
                                             totalLengthOut: &totalLength,
                                             dataPointerOut: &dataPointer)
        guard st == noErr, let dataPointer else { return }

        // The buffer is AVCC: [4-byte big-endian NAL length][NAL]... Convert
        // each NAL to Annex B.
        var offset = 0
        let base = UnsafeRawPointer(dataPointer)
        while offset + 4 <= totalLength {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, base + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4
            if offset + Int(nalLength) > totalLength { break }
            out.append(contentsOf: Self.startCode)
            out.append(Data(bytes: base + offset, count: Int(nalLength)))
            offset += Int(nalLength)
        }

        onEncodedFrame?(out, isKeyframe)
    }

    private static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        // If NotSync is absent or false, this is a sync (key) frame.
        if let raw = CFDictionaryGetValue(dict as CFDictionary, key) {
            let notSync = unsafeBitCast(raw, to: CFBoolean.self)
            return !CFBooleanGetValue(notSync)
        }
        return true
    }

    private static func parameterSets(from format: CMFormatDescription) -> [Data] {
        var sets: [Data] = []
        var count = 0
        // Probe count.
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if st == noErr, let ptr {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }
}

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
    private let codec: VideoCodec
    private let frameRate: Int

    // Annex B start code.
    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    private var loggedFirstKeyframe = false

    init(width: Int32, height: Int32, bitrate: Int, codec: VideoCodec, frameRate: Int) {
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.codec = codec
        self.frameRate = frameRate
    }

    func start() -> Bool {
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codec.cmType,
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
        NSLog("[Argus] VideoEncoder started \(width)x\(height) @ \(bitrate) bps (\(codec.rawValue))")
        return true
    }

    private func configure(_ session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        let profile = codec == .h264
            ? kVTProfileLevel_H264_High_AutoLevel
            : kVTProfileLevel_HEVC_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // No lookahead — emit each frame as soon as it's encoded (low latency).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        // Keyframes are expensive (~10x a P-frame) and briefly saturate USB,
        // causing fps dips. The transport is reliable TCP, so we only need
        // periodic keyframes as a backstop (every 5s); the pipeline also asks
        // for one whenever a frame is actually dropped (see VideoPipeline).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: (frameRate * 5) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        // Generous data-rate cap (1.5x over 1s) so motion bursts aren't stalled
        // to meet a tight limit; AverageBitRate is the real target. A too-tight
        // cap makes VideoToolbox delay frames during Mission Control etc.
        applyDataRateCap(session, bps: bitrate)
        if codec == .h264 {   // CABAC is an H.264-only property
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode,
                                 value: kVTH264EntropyMode_CABAC)
        }
    }

    private func applyDataRateCap(_ session: VTCompressionSession, bps: Int) {
        let bytesPerSec = Int(Double(bps) * 1.5 / 8.0)
        let cap = [bytesPerSec, 1] as [NSNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: cap as CFArray)
    }

    /// Live bitrate change (from the Settings slider).
    func updateBitrate(_ bps: Int) {
        bitrate = bps
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        applyDataRateCap(session, bps: bps)
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

        // Prefix the frame with its capture timestamp (µs) so the tablet can
        // pace presentation to the true motion timing (smooth playback).
        let ptsTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let us: Int64 = ptsTime.isValid ? Int64((ptsTime.seconds * 1_000_000).rounded()) : 0
        var beTs = us.bigEndian
        withUnsafeBytes(of: &beTs) { out.append(contentsOf: $0) }

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Inline parameter sets (H.264: SPS/PPS; HEVC: VPS/SPS/PPS) ahead
            // of the IDR so the decoder can configure.
            let sets = parameterSets(from: format)
            for ps in sets {
                out.append(contentsOf: Self.startCode)
                out.append(ps)
            }
            if !loggedFirstKeyframe {
                loggedFirstKeyframe = true
                let sizes = sets.map { $0.count }
                NSLog("[Argus] First keyframe (\(codec.rawValue)): \(sets.count) param sets "
                      + "sizes=\(sizes). Expected \(codec == .h265 ? 3 : 2).")
                if sets.isEmpty {
                    NSLog("[Argus] WARNING: no parameter sets extracted — decoder will show black.")
                }
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

    private func parameterSets(from format: CMFormatDescription) -> [Data] {
        var sets: [Data] = []
        var count = 0
        // Probe count (HEVC reports 3: VPS, SPS, PPS; H.264 reports 2).
        if codec == .h265 {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st: OSStatus = codec == .h265
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
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

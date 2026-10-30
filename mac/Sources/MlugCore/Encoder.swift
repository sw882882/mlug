import CoreMedia
import Foundation
import VideoToolbox

/// Hardware H.264 encoder tuned for latency over quality-per-bit:
/// no B-frames, low-latency rate control, Annex-B output.
final class Encoder {
    private var session: VTCompressionSession?
    private let onFrame: (_ annexB: Data, _ keyframe: Bool, _ ptsMicros: UInt64) -> Void
    private var forceKeyframe = true
    private let lock = NSLock()

    init(width: Int, height: Int, bitrate: Int, fps: Int,
         onFrame: @escaping (Data, Bool, UInt64) -> Void) throws {
        self.onFrame = onFrame
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw NSError(domain: "mlug.encoder", code: Int(status)) }
        session = s
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            kVTCompressionPropertyKey_MaximizePowerEfficiency: false,
            // Screen content is mostly static; keyframes are requested on demand instead.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 10,
        ]
        for (k, v) in props { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func requestKeyframe() { lock.withLock { forceKeyframe = true } }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        let key = lock.withLock { () -> Bool in defer { forceKeyframe = false }; return forceKeyframe }
        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let start = Stats.nowMs
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            Stats.shared.add("encode", Stats.nowMs - start)
            self.emit(sample)
        }
    }

    private func emit(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                if let ptr { out.append(contentsOf: startCode); out.append(ptr, count: size) }
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &base) == noErr,
              let base else { return }
        // AVCC (4-byte big-endian length prefixes) -> Annex-B start codes.
        base.withMemoryRebound(to: UInt8.self, capacity: length) { p in
            var off = 0
            while off + 4 <= length {
                let nalLen = Int(p[off]) << 24 | Int(p[off + 1]) << 16 | Int(p[off + 2]) << 8 | Int(p[off + 3])
                off += 4
                guard off + nalLen <= length else { break }
                out.append(contentsOf: startCode)
                out.append(p + off, count: nalLen)
                off += nalLen
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = pts.isValid ? UInt64(max(0, pts.seconds * 1_000_000)) : 0
        onFrame(out, isKey, micros)
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit { invalidate() }
}

import CoreMedia
import Foundation
import ScreenCaptureKit

/// Streams frames of one display via ScreenCaptureKit.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "mlug.capture", qos: .userInteractive)
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    private let onStop: (Error?) -> Void

    init(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void, onStop: @escaping (Error?) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        // A freshly created virtual display can take a moment to show up in SCShareableContent.
        var target: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let target else { throw NSError(domain: "mlug.capture", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: "virtual display not visible to ScreenCaptureKit"]) }

        let filter = SCContentFilter(display: target, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 4
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        if Stats.enabled, let display = attachments.first?[.displayTime] as? UInt64 {
            Stats.shared.add("capture", Stats.nowMs - Stats.machToMs(display))
        }
        onFrame(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sample))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(error) }
}

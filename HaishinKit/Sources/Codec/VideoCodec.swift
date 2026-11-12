import AVFoundation
import CoreFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

final class VideoCodec {
    static let frameInterval: Double = 0.0

    var settings: VideoCodecSettings = .default {
        didSet {
            let invalidateSession = settings.invalidateSession(oldValue)
            if invalidateSession {
                self.invalidateSession = invalidateSession
            } else {
                settings.apply(self, rhs: oldValue)
            }
        }
    }
    var passthrough = true
    var outputStream: AsyncStream<CMSampleBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    var frameInterval = VideoCodec.frameInterval
    private var startedAt: CMTime = .zero
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var invalidateSession = true
    private var needsKeyFrame = false
    private var presentationTimeStamp: CMTime = .zero
    // Quiet diagnostics: frames rejected for a non-monotonic PTS (they overtook a sibling on the way
    // here) are counted and reported at most once per `anomalyReportInterval`. Healthy flow logs nothing.
    private static let anomalyReportInterval: CFAbsoluteTime = 5
    private var rejectedOutOfOrder = 0
    private var maxBackwardStepMs = 0.0
    private var lastAnomalyReport: CFAbsoluteTime = 0
    private(set) var isRunning = false
    private(set) var inputFormat: CMFormatDescription? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            invalidateSession = true
            outputFormat = nil
        }
    }
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
            invalidateSession = false
        }
    }
    private(set) var outputFormat: CMFormatDescription?

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        do {
            inputFormat = sampleBuffer.formatDescription
            if invalidateSession {
                if sampleBuffer.formatDescription?.isCompressed == true {
                    session = try VTSessionMode.decompression.makeSession(self)
                } else {
                    session = try VTSessionMode.compression.makeSession(self)
                }
            }
            guard let session, let continuation else {
                return
            }
            if sampleBuffer.formatDescription?.isCompressed == true {
                try session.convert(sampleBuffer, frameProperties: nil, continuation: continuation)
            } else {
                if useFrame(sampleBuffer.presentationTimeStamp) {
                    let frameProperties: CFDictionary? = needsKeyFrame ? makeForceKeyFrameProperties() : nil
                    try session.convert(sampleBuffer, frameProperties: frameProperties, continuation: continuation)
                    // Consume the request only for a frame that was actually submitted to the encoder.
                    needsKeyFrame = false
                    presentationTimeStamp = sampleBuffer.presentationTimeStamp
                }
            }
        } catch {
            logger.warn(error)
        }
    }

    /// Requests the encoder to emit a key frame for the next submitted frame.
    func requestKeyFrame() {
        needsKeyFrame = true
    }

    func makeImageBufferAttributes(_ mode: VTSessionMode) -> [NSString: AnyObject]? {
        switch mode {
        case .compression:
            var attributes: [NSString: AnyObject] = [:]
            if let inputFormat {
                // Specify the pixel format of the uncompressed video.
                attributes[kCVPixelBufferPixelFormatTypeKey] = inputFormat.mediaType.rawValue as CFNumber
            }
            return attributes.isEmpty ? nil : attributes
        case .decompression:
            return [
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
            ]
        }
    }

    private func makeForceKeyFrameProperties() -> CFDictionary {
        let properties: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
        return properties as CFDictionary
    }

    private func useFrame(_ presentationTimeStamp: CMTime) -> Bool {
        guard startedAt <= presentationTimeStamp else {
            return false
        }
        guard self.presentationTimeStamp < presentationTimeStamp else {
            noteOutOfOrder(presentationTimeStamp)
            return false
        }
        guard Self.frameInterval < frameInterval else {
            return true
        }
        return frameInterval <= presentationTimeStamp.seconds - self.presentationTimeStamp.seconds
    }

    private func noteOutOfOrder(_ pts: CMTime) {
        rejectedOutOfOrder += 1
        maxBackwardStepMs = max(maxBackwardStepMs, (presentationTimeStamp - pts).seconds * 1000)
        let now = CFAbsoluteTimeGetCurrent()
        guard Self.anomalyReportInterval <= now - lastAnomalyReport else {
            return
        }
        logger.warn("dropped \(rejectedOutOfOrder) out-of-order video frame(s) since last report, max \(Int(maxBackwardStepMs)) ms behind")
        rejectedOutOfOrder = 0
        maxBackwardStepMs = 0
        lastAnomalyReport = now
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @objc
    private func applicationWillEnterForeground(_ notification: Notification) {
        invalidateSession = true
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            invalidateSession = true
        default:
            break
        }
    }
    #endif
}

extension VideoCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
        startedAt = passthrough ? .zero : CMClockGetTime(CMClockGetHostTimeClock())
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        session = nil
        invalidateSession = true
        needsKeyFrame = false
        inputFormat = nil
        outputFormat = nil
        presentationTimeStamp = .zero
        continuation?.finish()
        startedAt = .zero
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}

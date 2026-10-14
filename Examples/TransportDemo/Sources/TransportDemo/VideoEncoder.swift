import CoreMedia
import Foundation
import VideoToolbox

/// The app's own H.264/HEVC encoder built directly on VideoToolbox.
///
/// Produces compressed `CMSampleBuffer`s (AVCC/HVCC payload, format description with `avcC`/`hvcC`,
/// key frames without the `NotSync` attachment), which is exactly what a HaishinKit stream expects in transport mode.
final class VideoEncoder: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        var width: Int32 = 1280
        var height: Int32 = 720
        var bitRate: Int = 2_500_000
        var useHEVC = false
        var frameRate: Double = 30
        var keyFrameIntervalSeconds: Int = 2
    }

    enum Error: Swift.Error {
        case failedToCreateSession(OSStatus)
        case failedToEncode(OSStatus)
    }

    /// Called from VideoToolbox's callback thread with each encoded frame.
    var output: (@Sendable (CMSampleBuffer) -> Void)?

    private let queue = DispatchQueue(label: "com.haishinkit.TransportDemo.videoEncoder")
    private var session: VTCompressionSession?
    private var configuration = Configuration()
    private var needsKeyFrame = true

    func configure(_ configuration: Configuration) {
        queue.sync {
            guard self.configuration != configuration || session == nil else {
                return
            }
            self.configuration = configuration
            invalidateSession()
        }
    }

    /// Changes the bitrate without recreating the session.
    func setBitRate(_ bitRate: Int) {
        queue.sync {
            configuration.bitRate = bitRate
            if let session {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitRate))
            }
        }
    }

    /// The next encoded frame will be an IDR frame. Call it when a stream starts publishing.
    func requestKeyFrame() {
        queue.async {
            self.needsKeyFrame = true
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            self.encodeOnQueue(sampleBuffer)
        }
    }

    func invalidate() {
        queue.sync {
            invalidateSession()
        }
    }

    private func encodeOnQueue(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }
        if session == nil {
            do {
                session = try makeSession()
            } catch {
                return
            }
        }
        guard let session else {
            return
        }
        var frameProperties: CFDictionary?
        if needsKeyFrame {
            let properties: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
            frameProperties = properties as CFDictionary
            needsKeyFrame = false
        }
        var flags: VTEncodeInfoFlags = []
        let output = self.output
        _ = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration,
            frameProperties: frameProperties,
            infoFlagsOut: &flags,
            outputHandler: { status, _, encoded in
                guard status == noErr, let encoded else {
                    return
                }
                output?(encoded)
            }
        )
    }

    private func makeSession() throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: configuration.width,
            height: configuration.height,
            codecType: configuration.useHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw Error.failedToCreateSession(status)
        }
        let profileLevel: CFString = configuration.useHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: profileLevel,
            kVTCompressionPropertyKey_AverageBitRate: configuration.bitRate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: configuration.keyFrameIntervalSeconds,
            kVTCompressionPropertyKey_ExpectedFrameRate: configuration.frameRate,
            // No B-frames: keeps PTS == DTS, which is simpler for RTMP composition time.
            kVTCompressionPropertyKey_AllowFrameReordering: false
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
        needsKeyFrame = true
        return session
    }

    private func invalidateSession() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }
}

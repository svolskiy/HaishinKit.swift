@preconcurrency import AVFoundation

/// An actor that encodes audio and video once and fans the encoded buffers out to multiple streams.
///
/// Attaching several streams directly to a ``MediaMixer`` makes every stream run its own encoders, so the same
/// content is compressed N times. Put a `MediaEncoder` between the mixer and the streams instead: it owns a single
/// pair of audio/video encoders and delivers the already compressed buffers to every attached stream.
///
/// ```swift
/// let mixer = MediaMixer()
/// let encoder = MediaEncoder()
/// try await encoder.setVideoSettings(.init(videoSize: .init(width: 1280, height: 720), bitRate: 2_500_000))
/// await mixer.addOutput(encoder)
///
/// let stream1 = RTMPStream(connection: connection1)
/// let stream2 = RTMPStream(connection: connection2)
/// try await encoder.addOutput(stream1)
/// try await encoder.addOutput(stream2)
/// await encoder.startRunning()
/// await mixer.startRunning()
/// ```
///
/// - Note: The codec settings are shared by every attached stream. Setting them on any attached stream
///   (for example through a ``StreamBitRateStrategy``) changes them for the encoder and therefore for all streams.
/// - Note: Attach a stream either to the mixer or to the encoder, never to both.
public final actor MediaEncoder {
    /// The error domain codes.
    public enum Error: Swift.Error {
        /// One of the attached streams can't transport the requested codec.
        case unsupportedCodec
    }

    public private(set) var isRunning = false
    public private(set) var videoTrackId: UInt8? = UInt8.max
    public private(set) var audioTrackId: UInt8? = UInt8.max

    /// The audio compression properties.
    public var audioSettings: AudioCodecSettings {
        outgoing.audioSettings
    }

    /// The video compression properties.
    public var videoSettings: VideoCodecSettings {
        outgoing.videoSettings
    }

    /// The raw audio input format, available once the first audio buffer has been appended.
    public var audioInputFormat: CMFormatDescription? {
        outgoing.audioInputFormat
    }

    /// The raw video input format, available once the first video buffer has been appended.
    public var videoInputFormat: CMFormatDescription? {
        outgoing.videoInputFormat
    }

    /// The streams receiving the encoded buffers.
    public private(set) var outputs: [any StreamConvertible] = []

    private let outgoing = OutgoingStream()
    private var tasks: [Task<Void, Never>] = []
    // Outputs that joined mid-GOP and must not receive video until the next key frame.
    private var outputsWaitingForKeyFrame: Set<ObjectIdentifier> = []

    /// Creates a new instance.
    public init() {
    }

    /// Sets the audio compression properties for every attached stream.
    public func setAudioSettings(_ audioSettings: AudioCodecSettings) async throws {
        guard audioSettings != outgoing.audioSettings else {
            return
        }
        try validate(audioSettings, outputs: outputs)
        outgoing.audioSettings = audioSettings
        for output in outputs {
            try? await output.setAudioSettings(audioSettings)
        }
    }

    /// Sets the video compression properties for every attached stream.
    public func setVideoSettings(_ videoSettings: VideoCodecSettings) async throws {
        guard videoSettings != outgoing.videoSettings else {
            return
        }
        try validate(videoSettings, outputs: outputs)
        outgoing.videoSettings = videoSettings
        for output in outputs {
            try? await output.setVideoSettings(videoSettings)
        }
    }

    /// Sets the video input buffer counts.
    public func setVideoInputBufferCounts(_ videoInputBufferCounts: Int) {
        outgoing.videoInputBufferCounts = videoInputBufferCounts
    }

    /// Adds a stream that receives the encoded buffers.
    ///
    /// The current codec settings are mirrored to the stream. Throws ``Error/unsupportedCodec`` when the stream
    /// can't transport the current audio or video codec.
    public func addOutput(_ output: some StreamConvertible) async throws {
        guard !outputs.contains(where: { $0 === output }) else {
            return
        }
        try validate(outgoing.audioSettings, outputs: [output])
        try validate(outgoing.videoSettings, outputs: [output])
        // Mirror the settings before attaching so that the stream doesn't forward them back.
        try await output.setAudioSettings(outgoing.audioSettings)
        try await output.setVideoSettings(outgoing.videoSettings)
        if let stream = output as? any _Stream {
            await stream.attachEncoder(self)
        }
        outputs.append(output)
        if isRunning {
            // A late joiner must start with a key frame; ask for one as soon as possible.
            outputsWaitingForKeyFrame.insert(ObjectIdentifier(output))
            outgoing.requestKeyFrame()
        }
    }

    /// Removes a stream.
    public func removeOutput(_ output: some StreamConvertible) async {
        guard let index = outputs.firstIndex(where: { $0 === output }) else {
            return
        }
        outputs.remove(at: index)
        outputsWaitingForKeyFrame.remove(ObjectIdentifier(output))
        if let stream = output as? any _Stream {
            await stream.attachEncoder(nil)
        }
    }

    /// Requests the video encoder to emit a key frame as soon as possible.
    public func requestKeyFrame() {
        outgoing.requestKeyFrame()
    }

    /// Appends a raw video sample buffer for encoding.
    ///
    /// Raw audio must be appended with ``append(_:when:)``.
    public func append(_ sampleBuffer: CMSampleBuffer) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            guard sampleBuffer.formatDescription?.isCompressed == false else {
                return
            }
            outgoing.append(sampleBuffer)
        default:
            break
        }
    }

    /// Appends a raw audio buffer for encoding.
    public func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        guard audioBuffer is AVAudioPCMBuffer else {
            return
        }
        outgoing.append(audioBuffer, when: when)
    }

    private func validate(_ audioSettings: AudioCodecSettings, outputs: [any StreamConvertible]) throws {
        for output in outputs {
            guard let stream = output as? any _Stream else {
                continue
            }
            guard type(of: stream).supportedAudioCodecs.contains(audioSettings.format) else {
                throw Error.unsupportedCodec
            }
        }
    }

    private func validate(_ videoSettings: VideoCodecSettings, outputs: [any StreamConvertible]) throws {
        for output in outputs {
            guard let stream = output as? any _Stream else {
                continue
            }
            guard type(of: stream).supportedVideoCodecs.contains(videoSettings.format) else {
                throw Error.unsupportedCodec
            }
        }
    }
}

extension MediaEncoder: AsyncRunner {
    // MARK: AsyncRunner
    public func startRunning() async {
        guard !isRunning else {
            return
        }
        isRunning = true
        outgoing.startRunning()
        tasks.append(Task {
            for await video in outgoing.videoInputStream {
                outgoing.append(video: video)
            }
        })
        tasks.append(Task {
            // Deliver sequentially to keep the frame order per stream.
            for await video in outgoing.videoOutputStream {
                for output in outputs {
                    let id = ObjectIdentifier(output)
                    if outputsWaitingForKeyFrame.contains(id) {
                        guard !video.isNotSync else {
                            continue
                        }
                        outputsWaitingForKeyFrame.remove(id)
                    }
                    await output.append(video)
                }
            }
        })
        tasks.append(Task {
            for await audio in outgoing.audioOutputStream {
                for output in outputs {
                    await output.append(audio.0, when: audio.1)
                }
            }
        })
    }

    public func stopRunning() async {
        guard isRunning else {
            return
        }
        // Finishes the codec output streams, so the delivery tasks end by themselves.
        outgoing.stopRunning()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        outputsWaitingForKeyFrame.removeAll()
        isRunning = false
    }
}

extension MediaEncoder: MediaMixerOutput {
    // MARK: MediaMixerOutput
    public func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) {
        switch mediaType {
        case .audio:
            audioTrackId = id
        case .video:
            videoTrackId = id
        default:
            break
        }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        Task { await append(sampleBuffer) }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        Task { await append(buffer, when: when) }
    }
}

@preconcurrency import AVFoundation
import Combine
import Foundation
import HaishinKit
import libsrt

/// Publishes or plays an MPEG-2 transport stream over an SRT connection.
public actor SRTStream {
    package static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac]
    package static let supportedVideoCodecs: [VideoCodecSettings.Format] = VideoCodecSettings.Format.allCases

    /// The media types expected in the outgoing transport stream.
    public var expectedMedias: Set<AVMediaType> {
        writer.expectedMedias
    }

    /// The current publishing or playback state.
    @Published public private(set) var readyState: StreamReadyState = .idle
    /// The selected mixer video track. `UInt8.max` selects mixed output; `nil` disables video delivery.
    public private(set) var videoTrackId: UInt8? = UInt8.max
    /// The selected mixer audio track. `UInt8.max` selects mixed output; `nil` disables audio delivery.
    public private(set) var audioTrackId: UInt8? = UInt8.max
    package var outputs: [any StreamOutput] = []
    package var bitRateStrategy: (any StreamBitRateStrategy)?
    private lazy var writer = TSWriter()
    private lazy var reader = TSReader()
    package lazy var incoming = IncomingStream(self)
    package lazy var outgoing = OutgoingStream()
    /// The shared encoder feeding this stream with encoded buffers (nil when the stream encodes by itself).
    package weak var encoder: MediaEncoder?
    private weak var connection: SRTConnection?
    private var isWaitingForKeyFrame = true
    // Formats of the encoded buffers received from a MediaEncoder. Used for expectedMedias.
    private var encodedVideoFormat: CMFormatDescription?
    private var encodedAudioFormat: CMFormatDescription?

    /// Errors that can occur when configuring the stream.
    public enum Error: Swift.Error {
        /// The requested audio or video codec is not supported.
        case unsupportedCodec
    }

    /// Creates a stream associated with an SRT connection.
    ///
    /// - Parameter connection: The connection used to send or receive media.
    public init(connection: SRTConnection) {
        self.connection = connection
        Task { await connection.addStream(self) }
    }

    deinit {
        outputs.removeAll()
    }

    /// Starts publishing media over the connection.
    ///
    /// The connection must already be established; otherwise, this method has no effect.
    /// If no input formats are available yet, call `setExpectedMedias(_:)` before publishing.
    ///
    /// - Parameter name: Pass `nil` to stop active publishing. A non-`nil` value starts
    ///   publishing; the string itself is not used as a stream name.
    public func publish(_ name: String? = "") async {
        guard let connection, await connection.connected else {
            return
        }
        guard name != nil else {
            switch readyState {
            case .publishing:
                await close()
            default:
                break
            }
            return
        }
        if let encoder {
            // The encoder may not have delivered a buffer yet; ask it what it is going to encode.
            if let videoInputFormat = await encoder.videoInputFormat {
                encodedVideoFormat = videoInputFormat
            }
            if let audioInputFormat = await encoder.audioInputFormat {
                encodedAudioFormat = audioInputFormat
            }
        }
        isWaitingForKeyFrame = true
        readyState = .publishing
        outgoing.startRunning()
        if outgoing.videoInputFormat != nil || encodedVideoFormat != nil {
            writer.expectedMedias.insert(.video)
        }
        if outgoing.audioInputFormat != nil || encodedAudioFormat != nil {
            writer.expectedMedias.insert(.audio)
        }
        if writer.expectedMedias.isEmpty {
            logger.error("Please set expected media.")
        }
        if let encoder {
            // Start the stream with a key frame instead of waiting for the next GOP.
            Task { await encoder.requestKeyFrame() }
        }
        Task {
            for await buffer in outgoing.videoOutputStream {
                append(buffer)
            }
        }
        Task {
            for await buffer in outgoing.audioOutputStream {
                append(buffer.0, when: buffer.1)
            }
        }
        Task {
            for await buffer in outgoing.videoInputStream {
                outgoing.append(video: buffer)
            }
        }
        Task {
            for await data in writer.output {
                await connection.send(data)
            }
        }
    }

    /// Starts receiving and playing media from the connection.
    ///
    /// The connection must already be established; otherwise, this method has no effect.
    ///
    /// - Parameter name: Pass `nil` to stop active playback. A non-`nil` value starts
    ///   playback; the string itself is not used as a stream name.
    public func play(_ name: String? = "") async {
        guard let connection, await connection.connected else {
            return
        }
        guard name != nil else {
            switch readyState {
            case .playing:
                await close()
            default:
                break
            }
            return
        }
        await connection.recv()
        Task {
            await incoming.startRunning()
            for await buffer in reader.output {
                await incoming.append(buffer.1)
            }
        }
        readyState = .playing
    }

    /// Stops publishing or playback, clears media buffers, and returns to the idle state.
    ///
    /// The associated SRT connection remains open.
    public func close() async {
        guard readyState != .idle else {
            return
        }
        writer.clear()
        reader.clear()
        outgoing.stopRunning()
        Task { await incoming.stopRunning() }
        readyState = .idle
    }

    /// Sets the media types included in the outgoing transport stream.
    ///
    /// Use `[.audio]`, `[.video]`, or `[.audio, .video]`. Publishing also adds media types
    /// for which input formats are already available. Set this explicitly when starting
    /// to publish before supplying media buffers.
    ///
    /// - Parameter expectedMedias: The media types the transport stream should contain.
    public func setExpectedMedias(_ expectedMedias: Set<AVMediaType>) {
        writer.expectedMedias = expectedMedias
    }

    func doInput(_ data: Data) {
        _ = reader.read(data)
    }
}

extension SRTStream: _Stream {
    /// Sets the audio encoding settings.
    ///
    /// - Parameter audioSettings: Settings that select AAC encoding.
    /// - Throws: `Error.unsupportedCodec` if the format is not AAC.
    public func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        guard Self.supportedAudioCodecs.contains(audioSettings.format) else {
            throw Error.unsupportedCodec
        }
        let oldValue = outgoing.audioSettings
        outgoing.audioSettings = audioSettings
        forwardToEncoder(audioSettings, oldValue: oldValue)
    }

    /// Sets the video encoding settings.
    ///
    /// - Parameter videoSettings: Settings that select H.264 or HEVC encoding.
    /// - Throws: `Error.unsupportedCodec` if the selected codec is not supported.
    public func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        guard Self.supportedVideoCodecs.contains(videoSettings.format) else {
            throw Error.unsupportedCodec
        }
        let oldValue = outgoing.videoSettings
        outgoing.videoSettings = videoSettings
        forwardToEncoder(videoSettings, oldValue: oldValue)
    }

    /// Supplies a video sample buffer for publishing.
    ///
    /// Uncompressed video is queued for encoding and delivered to stream outputs.
    /// Compressed video is passed to the transport stream writer. Other media types are ignored.
    ///
    /// - Parameter sampleBuffer: The video sample buffer to append.
    public func append(_ sampleBuffer: CMSampleBuffer) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            if sampleBuffer.formatDescription?.isCompressed == true {
                encodedVideoFormat = sampleBuffer.formatDescription
                // A shared encoder keeps delivering while this stream isn't publishing.
                guard readyState == .publishing else {
                    return
                }
                // The first video access unit after publish must be a key frame.
                if isWaitingForKeyFrame {
                    guard !sampleBuffer.isNotSync else {
                        return
                    }
                    isWaitingForKeyFrame = false
                }
                writer.videoFormat = sampleBuffer.formatDescription
                writer.append(sampleBuffer)
            } else {
                if encoder == nil {
                    outgoing.append(sampleBuffer)
                }
                outputs.forEach { $0.stream(self, didOutput: sampleBuffer) }
            }
        case .audio:
            // Transport mode: the app encoded the audio (AAC packets in a CMSampleBuffer).
            guard sampleBuffer.formatDescription?.isCompressed == true else {
                return
            }
            for (audioBuffer, when) in sampleBuffer.makeCompressedAudioBuffers() {
                append(audioBuffer, when: when)
            }
        default:
            break
        }
    }

    /// Supplies an audio buffer for publishing.
    ///
    /// PCM audio is queued for encoding and delivered to stream outputs.
    /// Compressed audio is passed to the transport stream writer.
    ///
    /// - Parameters:
    ///   - audioBuffer: The PCM or compressed audio buffer.
    ///   - when: The timestamp associated with the buffer.
    public func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        switch audioBuffer {
        case let audioBuffer as AVAudioPCMBuffer:
            if encoder == nil {
                outgoing.append(audioBuffer, when: when)
            }
            outputs.forEach { $0.stream(self, didOutput: audioBuffer, when: when) }
        case let audioBuffer as AVAudioCompressedBuffer:
            encodedAudioFormat = audioBuffer.format.formatDescription
            guard readyState == .publishing else {
                return
            }
            writer.audioFormat = audioBuffer.format
            writer.append(audioBuffer, when: when)
        default:
            break
        }
    }

    /// Passes a network monitoring event to the configured bit rate strategy.
    public func dispatch(_ event: NetworkMonitorEvent) async {
        await bitRateStrategy?.adjustBitrate(event, stream: self)
    }
}

extension SRTStream: MediaMixerOutput {
    // MARK: MediaMixerOutput
    /// Selects a mixer track for the specified media type.
    ///
    /// - Parameters:
    ///   - id: The track ID, `UInt8.max` for mixed output, or `nil` to disable delivery.
    ///   - mediaType: The audio or video media type to configure. Other types are ignored.
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

    /// Receives a video buffer from a mixer and schedules it for processing by the stream.
    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        Task { await append(sampleBuffer) }
    }

    /// Receives a PCM audio buffer and its timestamp from a mixer and schedules them for processing.
    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        Task { await append(buffer, when: when) }
    }
}

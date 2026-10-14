@preconcurrency import AVFoundation
import Combine
import Foundation
import HaishinKit
import libsrt

/// An actor that provides the interface to control a one-way channel over a SRTConnection.
public actor SRTStream {
    package static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac]
    package static let supportedVideoCodecs: [VideoCodecSettings.Format] = VideoCodecSettings.Format.allCases

    /// The expected medias for transport stream.
    public var expectedMedias: Set<AVMediaType> {
        writer.expectedMedias
    }

    @Published public private(set) var readyState: StreamReadyState = .idle
    public private(set) var videoTrackId: UInt8? = UInt8.max
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

    /// The error domain codes.
    public enum Error: Swift.Error {
        // An unsupported codec.
        case unsupportedCodec
    }

    /// Creates a new stream object.
    public init(connection: SRTConnection) {
        self.connection = connection
        Task { await connection.addStream(self) }
    }

    deinit {
        outputs.removeAll()
    }

    /// Sends streaming audio and video from client.
    ///
    /// - Warning: As a prerequisite, SRTConnection must be connected. In the future, an exception will be thrown.
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

    /// Playback streaming audio and video from server.
    ///
    /// - Warning: As a prerequisite, SRTConnection must be connected. In the future, an exception will be thrown.
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

    /// Stops playing or publishing and makes available other uses.
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

    /// Sets the expected media.
    ///
    /// This sets whether the stream contains audio only, video only, or both. Normally, this is automatically set through the append method.
    /// If you cannot call the append method before publishing, please use this method to explicitly specify the contents of the stream.
    public func setExpectedMedias(_ expectedMedias: Set<AVMediaType>) {
        writer.expectedMedias = expectedMedias
    }

    func doInput(_ data: Data) {
        _ = reader.read(data)
    }
}

extension SRTStream: _Stream {
    public func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        guard Self.supportedAudioCodecs.contains(audioSettings.format) else {
            throw Error.unsupportedCodec
        }
        let oldValue = outgoing.audioSettings
        outgoing.audioSettings = audioSettings
        forwardToEncoder(audioSettings, oldValue: oldValue)
    }

    public func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        guard Self.supportedVideoCodecs.contains(videoSettings.format) else {
            throw Error.unsupportedCodec
        }
        let oldValue = outgoing.videoSettings
        outgoing.videoSettings = videoSettings
        forwardToEncoder(videoSettings, oldValue: oldValue)
    }

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

    public func dispatch(_ event: NetworkMonitorEvent) async {
        await bitRateStrategy?.adjustBitrate(event, stream: self)
    }
}

extension SRTStream: MediaMixerOutput {
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

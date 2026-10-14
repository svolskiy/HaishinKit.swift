import AVFoundation
import HaishinKit
import libdatachannel

public actor RTCStream {
    enum Error: Swift.Error {
        case unsupportedCodec
    }

    package static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.opus]
    package static let supportedVideoCodecs: [VideoCodecSettings.Format] = [.h264]

    let id: String = UUID().uuidString
    private(set) var tracks: [RTCSendableStreamTrack] = []
    public private(set) var readyState: StreamReadyState = .idle
    public private(set) var videoTrackId: UInt8? = UInt8.max
    public private(set) var audioTrackId: UInt8? = UInt8.max
    package lazy var incoming = IncomingStream(self)
    package lazy var outgoing: OutgoingStream = {
        var stream = OutgoingStream()
        stream.audioSettings = .init(channelMap: [0, 0], format: .opus)
        return stream
    }()
    package var outputs: [any StreamOutput] = []
    package var bitRateStrategy: (any StreamBitRateStrategy)?
    /// The shared encoder feeding this stream with encoded buffers (nil when the stream encodes by itself).
    package weak var encoder: MediaEncoder?
    private var direction: RTCDirection = .sendonly

    public init() {
    }

    public func setDirection(_ direction: RTCDirection) {
        self.direction = direction
        switch direction {
        case .recvonly:
            Task {
                await incoming.startRunning()
            }
        case .sendonly, .sendrecv:
            if let encoder {
                // Start the stream with a key frame instead of waiting for the next GOP.
                Task { await encoder.requestKeyFrame() }
            }
            outgoing.startRunning()
            Task {
                for await audio in outgoing.audioOutputStream {
                    append(audio.0, when: audio.1)
                }
            }
            Task {
                for await video in outgoing.videoOutputStream {
                    append(video)
                }
            }
            Task {
                for await video in outgoing.videoInputStream {
                    outgoing.append(video: video)
                }
            }
        default:
            break
        }
    }

    public func close() async {
        tracks.removeAll()
        switch direction {
        case .sendonly:
            outgoing.stopRunning()
        case .recvonly:
            Task {
                await incoming.stopRunning()
            }
        default:
            break
        }
    }

    func addTrack(_ track: RTCSendableStreamTrack) async {
        await track.setDelegate(self)
        tracks.append(track)
    }
}

extension RTCStream: _Stream {
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
                Task {
                    for track in tracks {
                        await track.send(sampleBuffer)
                    }
                }
            } else {
                if encoder == nil {
                    outgoing.append(sampleBuffer)
                }
                outputs.forEach { $0.stream(self, didOutput: sampleBuffer) }
            }
        case .audio:
            if sampleBuffer.formatDescription?.isCompressed == true {
                Task { await incoming.append(sampleBuffer) }
            } else if encoder == nil {
                outgoing.append(sampleBuffer)
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
            Task {
                for track in tracks {
                    await track.send(audioBuffer, when: when)
                }
            }
        default:
            break
        }
    }

    public func dispatch(_ event: NetworkMonitorEvent) async {
        await bitRateStrategy?.adjustBitrate(event, stream: self)
    }
}

extension RTCStream: RTCTrackDelegate {
    // MARK: RTCTrackDelegate
    nonisolated func track(_ track: RTCTrack, readyStateChanged readyState: RTCTrack.ReadyState) {
    }

    nonisolated func track(_ track: RTCTrack, didOutput buffer: CMSampleBuffer) {
        Task {
            await incoming.append(buffer)
        }
    }

    nonisolated func track(_ track: RTCTrack, didOutput buffer: AVAudioCompressedBuffer, when: AVAudioTime) {
        Task {
            await incoming.append(buffer, when: when)
        }
    }
}

extension RTCStream: MediaMixerOutput {
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

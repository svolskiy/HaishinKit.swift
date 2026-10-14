@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

/// A minimal stream that only records the encoded buffers it receives.
private final actor StubStream: _Stream {
    static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac]
    static let supportedVideoCodecs: [VideoCodecSettings.Format] = [.h264]

    private(set) var readyState: StreamReadyState = .publishing
    private(set) var videoTrackId: UInt8? = UInt8.max
    private(set) var audioTrackId: UInt8? = UInt8.max
    private(set) var videoBuffers: [CMSampleBuffer] = []
    private(set) var audioBuffers: [AVAudioBuffer] = []
    lazy var incoming = IncomingStream(self)
    lazy var outgoing = OutgoingStream()
    var outputs: [any StreamOutput] = []
    var bitRateStrategy: (any StreamBitRateStrategy)?
    weak var encoder: MediaEncoder?

    func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        outgoing.audioSettings = audioSettings
    }

    func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        outgoing.videoSettings = videoSettings
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.formatDescription?.isCompressed == true else {
            return
        }
        videoBuffers.append(sampleBuffer)
    }

    func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        guard audioBuffer is AVAudioCompressedBuffer else {
            return
        }
        audioBuffers.append(audioBuffer)
    }

    func dispatch(_ event: NetworkMonitorEvent) async {
    }

    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) {
    }

    nonisolated func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
    }

    nonisolated func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
    }
}

@Suite struct MediaEncoderTests {
    private static func makeVideoSettings() -> VideoCodecSettings {
        var settings = VideoCodecSettings(videoSize: .init(width: 320, height: 240), bitRate: 300 * 1000)
        // CI machines usually have no hardware encoder.
        settings.isHardwareAcceleratedEnabled = false
        settings.maxKeyFrameIntervalDuration = 1
        return settings
    }

    private static func appendVideo(_ encoder: MediaEncoder, frames: Range<Int>) async {
        for i in frames {
            if let sampleBuffer = CMVideoSampleBufferFactory.makeSampleBuffer(
                width: 320,
                height: 240,
                presentationTimeStamp: CMTime(value: CMTimeValue(i + 1), timescale: 30)
            ) {
                await encoder.append(sampleBuffer)
            }
            // Let the input/output tasks run between frames.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func waitUntil(timeout: UInt64 = 3_000_000_000, _ condition: () async -> Bool) async {
        let started = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - started < timeout {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test(.disabled(if: TestEnvironment.isCI))
    func video_fanOut() async throws {
        let encoder = MediaEncoder()
        try await encoder.setVideoSettings(Self.makeVideoSettings())
        let stream1 = StubStream()
        let stream2 = StubStream()
        try await encoder.addOutput(stream1)
        try await encoder.addOutput(stream2)
        await encoder.startRunning()

        await Self.appendVideo(encoder, frames: 0..<30)
        await Self.waitUntil {
            await stream1.videoBuffers.count >= 10 && stream2.videoBuffers.count >= 10
        }
        await encoder.stopRunning()
        // Let the delivery task drain the frames that were already encoded.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let buffers1 = await stream1.videoBuffers
        let buffers2 = await stream2.videoBuffers
        #expect(!buffers1.isEmpty)
        #expect(buffers1.count == buffers2.count)
        #expect(buffers1.first?.isNotSync == false)
        #expect(buffers2.first?.isNotSync == false)
        #expect(buffers1.allSatisfy { $0.formatDescription?.isCompressed == true })
    }

    @Test(.disabled(if: TestEnvironment.isCI))
    func lateJoiner_startsWithKeyFrame() async throws {
        let encoder = MediaEncoder()
        try await encoder.setVideoSettings(Self.makeVideoSettings())
        let stream1 = StubStream()
        try await encoder.addOutput(stream1)
        await encoder.startRunning()

        await Self.appendVideo(encoder, frames: 0..<15)
        await Self.waitUntil {
            await stream1.videoBuffers.count >= 5
        }

        // Joins in the middle of a GOP; addOutput requests a key frame.
        let stream2 = StubStream()
        try await encoder.addOutput(stream2)
        await Self.appendVideo(encoder, frames: 15..<45)
        await Self.waitUntil {
            await stream2.videoBuffers.count >= 5
        }
        await encoder.stopRunning()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let buffers2 = await stream2.videoBuffers
        #expect(!buffers2.isEmpty)
        // The first frame a late joiner gets is a key frame (forced by addOutput).
        #expect(buffers2.first?.isNotSync == false)
        #expect(await stream1.videoBuffers.count > buffers2.count)
    }

    @Test func audio_fanOut() async throws {
        let encoder = MediaEncoder()
        let stream1 = StubStream()
        let stream2 = StubStream()
        try await encoder.addOutput(stream1)
        try await encoder.addOutput(stream2)
        await encoder.startRunning()

        for _ in 0..<20 {
            if let buffer = AVAudioPCMBufferFactory.makeSinWave(44100, numSamples: 1024) {
                await encoder.append(buffer, when: .init())
            }
        }
        await Self.waitUntil {
            await !stream1.audioBuffers.isEmpty && !stream2.audioBuffers.isEmpty
        }
        await encoder.stopRunning()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let buffers1 = await stream1.audioBuffers
        let buffers2 = await stream2.audioBuffers
        #expect(!buffers1.isEmpty)
        #expect(buffers1.count == buffers2.count)
        #expect(buffers1.allSatisfy { $0 is AVAudioCompressedBuffer })
        #expect(await encoder.audioInputFormat != nil)
    }

    @Test func settings_areValidatedAndMirrored() async throws {
        let encoder = MediaEncoder()
        let stream = StubStream()
        try await encoder.addOutput(stream)

        // The stub transports AAC only.
        await #expect(throws: MediaEncoder.Error.self) {
            try await encoder.setAudioSettings(.init(format: .opus))
        }
        #expect(await encoder.audioSettings.format == .aac)

        var videoSettings = await encoder.videoSettings
        videoSettings.bitRate = 1_234_000
        try await encoder.setVideoSettings(videoSettings)
        #expect(await stream.videoSettings.bitRate == 1_234_000)

        // Changing the settings on an attached stream changes the shared encoder.
        var streamVideoSettings = await stream.videoSettings
        streamVideoSettings.bitRate = 2_345_000
        try await stream.setVideoSettings(streamVideoSettings)
        await Self.waitUntil {
            await encoder.videoSettings.bitRate == 2_345_000
        }
        #expect(await encoder.videoSettings.bitRate == 2_345_000)

        await encoder.removeOutput(stream)
        #expect(await encoder.outputs.isEmpty)
        #expect(await stream.encoder == nil)
    }

    @Test func addOutput_rejectsUnsupportedCodec() async throws {
        let encoder = MediaEncoder()
        try await encoder.setAudioSettings(.init(format: .opus))
        let stream = StubStream()
        await #expect(throws: MediaEncoder.Error.self) {
            try await encoder.addOutput(stream)
        }
        #expect(await encoder.outputs.isEmpty)
    }

    @Test func release() async {
        weak var weakEncoder: MediaEncoder?
        _ = await {
            let encoder = MediaEncoder()
            await encoder.startRunning()
            try? await Task.sleep(nanoseconds: 1)
            await encoder.stopRunning()
            try? await Task.sleep(nanoseconds: 1)
            weakEncoder = encoder
        }()
        #expect(weakEncoder == nil)
    }
}

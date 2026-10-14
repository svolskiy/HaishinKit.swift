@preconcurrency import AVFoundation
import Foundation
import HaishinKit
import RTMPHaishinKit
import SwiftUI
import VideoToolbox

/// Drives the demo: one MediaMixer, one MediaEncoder and N RTMP destinations.
@MainActor
final class DemoViewModel: ObservableObject {
    /// Which pipeline publishes the destinations. Switchable only while nothing is publishing.
    enum PipelineMode: String, CaseIterable, Identifiable {
        /// MediaMixer -> MediaEncoder -> N RTMPStreams. One VTCompressionSession in total.
        case sharedEncoder = "Shared encoder (MediaEncoder)"
        /// MediaMixer -> N RTMPStreams. One VTCompressionSession per stream.
        case encoderPerStream = "Encoder per stream (legacy)"

        var id: String { rawValue }
    }

    struct VideoPreset: Identifiable, Hashable {
        let id: String
        let size: CGSize

        static let all: [VideoPreset] = [
            .init(id: "640x360", size: .init(width: 640, height: 360)),
            .init(id: "854x480", size: .init(width: 854, height: 480)),
            .init(id: "1280x720", size: .init(width: 1280, height: 720)),
            .init(id: "1920x1080", size: .init(width: 1920, height: 1080))
        ]
    }

    @Published var mode: PipelineMode = .sharedEncoder
    @Published var destinations: [Destination] = [
        .init(name: "Service A", url: "rtmp://localhost/live", streamKey: "stream1"),
        .init(name: "Service B", url: "rtmp://localhost/live", streamKey: "stream2"),
        .init(name: "Service C", url: "rtmp://localhost/live", streamKey: "stream3")
    ]
    @Published var preset: VideoPreset = VideoPreset.all[2]
    @Published var videoBitRateKbps: Double = 2500
    @Published var audioBitRateKbps: Double = 128
    @Published var useHEVC = false
    @Published private(set) var isCapturing = false
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var encoderVideoSettings: VideoCodecSettings = .default
    @Published private(set) var log: [String] = []
    @Published var errorMessage: String?

    let mixer = MediaMixer()
    let encoder = MediaEncoder()

    var isAnyPublishing: Bool {
        destinations.contains { $0.state.isActive }
    }

    private struct Publisher {
        let connection: RTMPConnection
        let stream: RTMPStream
        var statusTask: Task<Void, Never>?
    }

    private var publishers: [UUID: Publisher] = [:]
    private var statsTask: Task<Void, Never>?
    private var previewView: MTHKView?

    // MARK: Capture

    func startCapturing() {
        guard !isCapturing else {
            return
        }
        Task {
            do {
                try await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
            } catch {
                report("attachAudio failed: \(error)")
            }
            do {
                try await mixer.attachVideo(AVCaptureDevice.default(for: .video))
            } catch {
                report("attachVideo failed: \(error)")
            }
            if let previewView {
                await mixer.addOutput(previewView)
            }
            await applyEncoderSettings()
            await mixer.startRunning()
            isCapturing = true
            startStats()
            append("Capture started")
        }
    }

    func stopCapturing() {
        Task {
            for destination in destinations where destination.state.isActive {
                await disconnect(destination.id)
            }
            await encoder.stopRunning()
            await mixer.removeOutput(encoder)
            await mixer.stopRunning()
            try? await mixer.attachAudio(nil)
            try? await mixer.attachVideo(nil)
            stopStats()
            isCapturing = false
            append("Capture stopped")
        }
    }

    // MARK: Destinations

    func addDestination() {
        let index = destinations.count + 1
        destinations.append(.init(name: "Service \(index)", url: "rtmp://localhost/live", streamKey: "stream\(index)"))
    }

    func removeDestination(_ id: UUID) {
        Task {
            await disconnect(id)
            destinations.removeAll { $0.id == id }
        }
    }

    func connect(_ id: UUID) {
        guard isCapturing, let index = destinations.firstIndex(where: { $0.id == id }), publishers[id] == nil else {
            return
        }
        let destination = destinations[index]
        destinations[index].state = .connecting
        Task {
            let connection = RTMPConnection()
            let stream = RTMPStream(connection: connection, fcPublishName: destination.streamKey)
            var publisher = Publisher(connection: connection, stream: stream)
            publisher.statusTask = Task { @MainActor [weak self] in
                for await status in await connection.status {
                    guard let self else {
                        return
                    }
                    self.append("[\(destination.name)] \(status.code)")
                    if status.code == RTMPConnection.Code.connectClosed.rawValue {
                        self.setState(id, .failed("connection closed"))
                    }
                }
            }
            publishers[id] = publisher
            do {
                switch mode {
                case .sharedEncoder:
                    // The stream receives already encoded buffers; codec settings are mirrored from the encoder.
                    try await encoder.addOutput(stream)
                    let isEncoderRunning = await encoder.isRunning
                    if !isEncoderRunning {
                        await mixer.addOutput(encoder)
                        await encoder.startRunning()
                    }
                case .encoderPerStream:
                    // The stream encodes the raw mixer output by itself.
                    try await stream.setVideoSettings(makeVideoSettings())
                    try await stream.setAudioSettings(makeAudioSettings())
                    await mixer.addOutput(stream)
                }
                _ = try await connection.connect(destination.url)
                _ = try await stream.publish(destination.streamKey)
                setState(id, .publishing)
                append("[\(destination.name)] publishing to \(destination.url)/\(destination.streamKey) (\(mode.rawValue))")
            } catch {
                setState(id, .failed("\(error)"))
                report("[\(destination.name)] \(error)")
                await disconnect(id)
            }
        }
    }

    func disconnect(_ id: UUID) async {
        guard let publisher = publishers.removeValue(forKey: id) else {
            return
        }
        publisher.statusTask?.cancel()
        await encoder.removeOutput(publisher.stream)
        await mixer.removeOutput(publisher.stream)
        _ = try? await publisher.stream.close()
        try? await publisher.connection.close()
        if let index = destinations.firstIndex(where: { $0.id == id }) {
            // Keep a failure visible; otherwise go back to idle.
            if destinations[index].state.isActive {
                destinations[index].state = .idle
            }
            destinations[index].bytesPerSecond = 0
            destinations[index].fps = 0
        }
        let isEncoderRunning = await encoder.isRunning
        if publishers.isEmpty && isEncoderRunning {
            await encoder.stopRunning()
            await mixer.removeOutput(encoder)
        }
    }

    func disconnectAsync(_ id: UUID) {
        Task { await disconnect(id) }
    }

    // MARK: Codec settings

    func makeVideoSettings() -> VideoCodecSettings {
        var settings = VideoCodecSettings(
            videoSize: preset.size,
            bitRate: Int(videoBitRateKbps) * 1000,
            profileLevel: useHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel as String : kVTProfileLevel_H264_High_AutoLevel as String
        )
        settings.maxKeyFrameIntervalDuration = 2
        settings.expectedFrameRate = 30
        return settings
    }

    func makeAudioSettings() -> AudioCodecSettings {
        .init(bitRate: Int(audioBitRateKbps) * 1000, format: .aac)
    }

    /// Applies the UI settings to the encoder (shared mode) or to every stream (legacy mode).
    func applyEncoderSettings() async {
        let videoSettings = makeVideoSettings()
        let audioSettings = makeAudioSettings()
        do {
            switch mode {
            case .sharedEncoder:
                try await encoder.setVideoSettings(videoSettings)
                try await encoder.setAudioSettings(audioSettings)
            case .encoderPerStream:
                for publisher in publishers.values {
                    try await publisher.stream.setVideoSettings(videoSettings)
                    try await publisher.stream.setAudioSettings(audioSettings)
                }
            }
            encoderVideoSettings = await encoder.videoSettings
            append("Applied \(Int(videoSettings.videoSize.width))x\(Int(videoSettings.videoSize.height)) @ \(videoSettings.bitRate / 1000) kbps, \(useHEVC ? "HEVC" : "H.264")")
        } catch {
            report("setVideoSettings failed: \(error)")
        }
    }

    func applyEncoderSettingsAsync() {
        Task { await applyEncoderSettings() }
    }

    /// Changes the bitrate through the first attached stream, to show that stream settings are
    /// forwarded to the shared encoder.
    func setBitRateThroughFirstStream() {
        guard let publisher = publishers.values.first else {
            return
        }
        Task {
            var settings = await publisher.stream.videoSettings
            settings.bitRate = Int(videoBitRateKbps) * 1000
            try? await publisher.stream.setVideoSettings(settings)
            try? await Task.sleep(nanoseconds: 100_000_000)
            encoderVideoSettings = await encoder.videoSettings
            append("stream.setVideoSettings(bitRate: \(settings.bitRate / 1000) kbps) -> encoder bitRate is now \(encoderVideoSettings.bitRate / 1000) kbps")
        }
    }

    func requestKeyFrame() {
        Task {
            await encoder.requestKeyFrame()
            append("Key frame requested")
        }
    }

    // MARK: Stats

    private func startStats() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else {
                    return
                }
                await self.updateStats()
            }
        }
    }

    private func stopStats() {
        statsTask?.cancel()
        statsTask = nil
        cpuUsage = 0
    }

    private func updateStats() async {
        cpuUsage = CPUUsage.current()
        encoderVideoSettings = await encoder.videoSettings
        for (id, publisher) in publishers {
            let info = await publisher.stream.info
            let fps = await publisher.stream.currentFPS
            if let index = destinations.firstIndex(where: { $0.id == id }) {
                destinations[index].bytesPerSecond = info.currentBytesPerSecond
                destinations[index].totalBytes = info.byteCount
                destinations[index].fps = fps
            }
        }
    }

    // MARK: Helpers

    private func setState(_ id: UUID, _ state: Destination.State) {
        if let index = destinations.firstIndex(where: { $0.id == id }) {
            destinations[index].state = state
        }
    }

    private func append(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append("\(formatter.string(from: Date())) \(line)")
        if log.count > 200 {
            log.removeFirst(log.count - 200)
        }
    }

    private func report(_ message: String) {
        errorMessage = message
        append("ERROR \(message)")
    }
}

extension DemoViewModel: MTHKViewRepresentable.PreviewSource {
    nonisolated func connect(to view: MTHKView) {
        Task { @MainActor in
            previewView = view
            if isCapturing {
                await mixer.addOutput(view)
            }
        }
    }
}

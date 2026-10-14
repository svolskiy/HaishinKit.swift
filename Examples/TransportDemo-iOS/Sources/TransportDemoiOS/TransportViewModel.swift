@preconcurrency import AVFoundation
import Foundation
import HaishinKit
import RTMPHaishinKit
import SwiftUI
import UIKit

/// Wires the app's capture and encoders to an RTMPStream used purely as a transport.
@MainActor
final class TransportViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case publishing
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "Idle"
            case .connecting:
                return "Connecting…"
            case .publishing:
                return "Publishing"
            case .failed(let message):
                return "Failed: \(message)"
            }
        }

        var isActive: Bool {
            self == .connecting || self == .publishing
        }
    }

    struct VideoPreset: Identifiable, Hashable {
        let id: String
        let width: Int32
        let height: Int32

        // Portrait: the capture connection rotates the frames to 720x1280 before encoding.
        static let all: [VideoPreset] = [
            .init(id: "360x640", width: 360, height: 640),
            .init(id: "540x960", width: 540, height: 960),
            .init(id: "720x1280", width: 720, height: 1280)
        ]
    }

    @Published var url = "rtmp://192.168.1.10/live"
    @Published var streamKey = "transport"
    @Published var preset: VideoPreset = VideoPreset.all[2]
    @Published var videoBitRateKbps: Double = 2500
    @Published var audioBitRateKbps: Double = 128
    @Published var useHEVC = false
    @Published private(set) var isCapturing = false
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var encodedVideoFPS = 0
    @Published private(set) var encodedAudioPPS = 0
    @Published private(set) var sentFPS: UInt16 = 0
    @Published private(set) var sentKbps = 0
    @Published private(set) var totalMegabytes: Double = 0
    @Published private(set) var log: [String] = []
    @Published var errorMessage: String?

    let capture = CaptureService()
    private let videoEncoder = VideoEncoder()
    private let audioEncoder = AudioEncoder()

    private var connection: RTMPConnection?
    private var rtmpStream: RTMPStream?
    private var statusTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var encodedContinuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var videoFrameCounter = 0
    private var audioPacketCounter = 0
    private var cameraPosition: AVCaptureDevice.Position = .back

    // MARK: Capture + encode

    func startCapturing() {
        guard !isCapturing else {
            return
        }
        videoEncoder.configure(makeVideoConfiguration())
        audioEncoder.setBitRate(Int(audioBitRateKbps) * 1000)

        // Encoded buffers from both encoders go through one ordered channel into the stream.
        let (encoded, continuation) = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .bufferingNewest(240))
        encodedContinuation = continuation
        videoEncoder.output = { continuation.yield($0) }
        audioEncoder.output = { continuation.yield($0) }
        audioEncoder.onError = { [weak self] message in
            Task { @MainActor in
                self?.report("Audio encoder: \(message). Publishing video only.")
            }
        }
        deliveryTask = Task { [weak self] in
            for await sampleBuffer in encoded {
                guard let self else {
                    return
                }
                self.count(sampleBuffer)
                if let rtmpStream = self.rtmpStream {
                    // Transport mode: the stream only packetizes and sends the compressed buffer.
                    await rtmpStream.append(sampleBuffer)
                }
            }
        }

        let videoEncoder = self.videoEncoder
        let audioEncoder = self.audioEncoder
        capture.videoHandler = { videoEncoder.encode($0) }
        capture.audioHandler = { audioEncoder.encode($0) }
        do {
            try capture.start(position: cameraPosition)
            isCapturing = true
            UIApplication.shared.isIdleTimerDisabled = true
            startStats()
            append("Capture started: AVCaptureSession → VTCompressionSession + AVAudioConverter")
        } catch {
            report("Capture failed: \(error)")
        }
    }

    func stopCapturing() {
        Task {
            await disconnect()
            capture.stop()
            capture.videoHandler = nil
            capture.audioHandler = nil
            videoEncoder.invalidate()
            audioEncoder.reset()
            encodedContinuation?.finish()
            encodedContinuation = nil
            deliveryTask?.cancel()
            deliveryTask = nil
            stopStats()
            isCapturing = false
            UIApplication.shared.isIdleTimerDisabled = false
            append("Capture stopped")
        }
    }

    func flipCamera() {
        cameraPosition = cameraPosition == .back ? .front : .back
        guard isCapturing else {
            return
        }
        do {
            try capture.setCamera(position: cameraPosition)
            // A new camera means new frames; start the next GOP with an IDR.
            videoEncoder.requestKeyFrame()
            append("Camera: \(cameraPosition == .front ? "front" : "back")")
        } catch {
            report("Camera switch failed: \(error)")
        }
    }

    // MARK: Transport

    func connect() {
        guard isCapturing, !connectionState.isActive else {
            return
        }
        connectionState = .connecting
        let url = url
        let streamKey = streamKey
        Task {
            let connection = RTMPConnection()
            let stream = RTMPStream(connection: connection, fcPublishName: streamKey)
            self.connection = connection
            statusTask = Task { @MainActor [weak self] in
                for await status in await connection.status {
                    guard let self else {
                        return
                    }
                    self.append("[RTMP] \(status.code)")
                    if status.code == RTMPConnection.Code.connectClosed.rawValue {
                        self.connectionState = .failed("connection closed")
                    }
                }
            }
            do {
                // Optional: lets onMetaData carry the real bitrate hints. The stream's own encoders stay idle.
                var videoSettings = await stream.videoSettings
                videoSettings.videoSize = .init(width: Int(preset.width), height: Int(preset.height))
                videoSettings.bitRate = Int(videoBitRateKbps) * 1000
                videoSettings.expectedFrameRate = 30
                try await stream.setVideoSettings(videoSettings)
                var audioSettings = await stream.audioSettings
                audioSettings.bitRate = Int(audioBitRateKbps) * 1000
                try await stream.setAudioSettings(audioSettings)

                _ = try await connection.connect(url)
                _ = try await stream.publish(streamKey)
                // Start delivering and make the first delivered frame an IDR.
                rtmpStream = stream
                videoEncoder.requestKeyFrame()
                connectionState = .publishing
                append("Publishing to \(url)/\(streamKey)")
            } catch {
                connectionState = .failed("\(error)")
                report("\(error)")
                await disconnect()
            }
        }
    }

    func disconnect() async {
        let stream = rtmpStream
        // Stop delivering before closing, so no buffer reaches a closed stream.
        rtmpStream = nil
        statusTask?.cancel()
        statusTask = nil
        if let stream {
            _ = try? await stream.close()
        }
        if let connection {
            try? await connection.close()
        }
        connection = nil
        if connectionState.isActive {
            connectionState = .idle
        }
        sentFPS = 0
        sentKbps = 0
    }

    func disconnectAsync() {
        Task { await disconnect() }
    }

    // MARK: Encoder settings

    func applyVideoSettings() {
        videoEncoder.configure(makeVideoConfiguration())
        videoEncoder.requestKeyFrame()
        audioEncoder.setBitRate(Int(audioBitRateKbps) * 1000)
        append("Encoder: \(preset.id) @ \(Int(videoBitRateKbps)) kbps \(useHEVC ? "HEVC" : "H.264"), audio \(Int(audioBitRateKbps)) kbps")
    }

    func applyBitRateLive() {
        videoEncoder.setBitRate(Int(videoBitRateKbps) * 1000)
        append("Video bitrate → \(Int(videoBitRateKbps)) kbps (live, same VTCompressionSession)")
    }

    func requestKeyFrame() {
        videoEncoder.requestKeyFrame()
        append("Key frame requested from the app encoder")
    }

    private func makeVideoConfiguration() -> VideoEncoder.Configuration {
        var configuration = VideoEncoder.Configuration()
        configuration.width = preset.width
        configuration.height = preset.height
        configuration.bitRate = Int(videoBitRateKbps) * 1000
        configuration.useHEVC = useHEVC
        return configuration
    }

    // MARK: Stats

    private func count(_ sampleBuffer: CMSampleBuffer) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            videoFrameCounter += 1
        case .audio:
            audioPacketCounter += 1
        default:
            break
        }
    }

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
        encodedVideoFPS = 0
        encodedAudioPPS = 0
    }

    private func updateStats() async {
        encodedVideoFPS = videoFrameCounter
        encodedAudioPPS = audioPacketCounter
        videoFrameCounter = 0
        audioPacketCounter = 0
        guard let rtmpStream else {
            return
        }
        let info = await rtmpStream.info
        sentFPS = await rtmpStream.currentFPS
        sentKbps = info.currentBytesPerSecond * 8 / 1000
        totalMegabytes = Double(info.byteCount) / 1_000_000
    }

    // MARK: Helpers

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

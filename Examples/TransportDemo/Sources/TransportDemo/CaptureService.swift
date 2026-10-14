@preconcurrency import AVFoundation
import Foundation

/// Captures camera and microphone with a plain AVCaptureSession and hands the raw sample buffers to the app's encoders.
///
/// HaishinKit is not involved here on purpose: in transport mode the app owns capture and encoding.
final class CaptureService: NSObject, @unchecked Sendable {
    /// Raw video frames (pixel buffers), called on the capture queue.
    var videoHandler: (@Sendable (CMSampleBuffer) -> Void)?
    /// Raw PCM audio, called on the capture queue.
    var audioHandler: (@Sendable (CMSampleBuffer) -> Void)?

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let queue = DispatchQueue(label: "com.haishinkit.TransportDemo.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var isConfigured = false

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        super.init()
    }

    func start() throws {
        if !isConfigured {
            try configure()
            isConfigured = true
        }
        guard !session.isRunning else {
            return
        }
        session.startRunning()
    }

    func stop() {
        guard session.isRunning else {
            return
        }
        session.stopRunning()
    }

    private func configure() throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        session.sessionPreset = .high
        if let camera = AVCaptureDevice.default(for: .video) {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        }
        if let microphone = AVCaptureDevice.default(for: .audio) {
            let input = try AVCaptureDeviceInput(device: microphone)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }
    }
}

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            videoHandler?(sampleBuffer)
        } else if output === audioOutput {
            audioHandler?(sampleBuffer)
        }
    }
}

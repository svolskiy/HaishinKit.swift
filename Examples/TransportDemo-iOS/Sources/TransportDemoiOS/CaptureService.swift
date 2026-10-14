@preconcurrency import AVFoundation
import Foundation

/// Captures camera and microphone with a plain AVCaptureSession and hands the raw sample buffers to the app's encoders.
///
/// HaishinKit is not involved here on purpose: in transport mode the app owns capture and encoding.
final class CaptureService: NSObject, @unchecked Sendable {
    /// Raw video frames (pixel buffers, portrait), called on the capture queue.
    var videoHandler: (@Sendable (CMSampleBuffer) -> Void)?
    /// Raw PCM audio, called on the capture queue.
    var audioHandler: (@Sendable (CMSampleBuffer) -> Void)?

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let queue = DispatchQueue(label: "com.haishinkit.TransportDemo.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    func start(position: AVCaptureDevice.Position) throws {
        if !isConfigured {
            try configure(position: position)
            isConfigured = true
        }
        guard !session.isRunning else {
            return
        }
        // startRunning blocks; keep it off the main thread.
        queue.async {
            self.session.startRunning()
        }
    }

    func stop() {
        guard session.isRunning else {
            return
        }
        queue.async {
            self.session.stopRunning()
        }
    }

    /// Switches between the front and back camera while running.
    func setCamera(position: AVCaptureDevice.Position) throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            return
        }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        if let videoInput {
            session.removeInput(videoInput)
        }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        applyRotation(mirrored: position == .front)
    }

    private func configure(position: AVCaptureDevice.Position) throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        session.sessionPreset = .hd1280x720
        if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
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
        applyRotation(mirrored: position == .front)
    }

    /// Rotates the delivered frames to portrait so the encoder gets upright 720x1280 buffers.
    private func applyRotation(mirrored: Bool) {
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
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

import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var viewModel: TransportViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    CapturePreview(layer: viewModel.capture.previewLayer)
                        .background(Color.black)
                    Text("Encoded: \(viewModel.encodedVideoFPS) fps · \(viewModel.encodedAudioPPS) audio pkt/s")
                        .font(.caption.monospacedDigit())
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
                .frame(height: 300)
                List {
                    pipelineSection
                    encoderSection
                    transportSection
                    logSection
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Transport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.flipCamera()
                    } label: {
                        Image(systemName: "camera.rotate")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isCapturing {
                        Button("Stop", role: .destructive) { viewModel.stopCapturing() }
                    } else {
                        Button("Start") { viewModel.startCapturing() }
                    }
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var pipelineSection: some View {
        Section("Pipeline") {
            Text("AVCaptureSession → app VTCompressionSession / AVAudioConverter → compressed CMSampleBuffer → RTMPStream.append")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("HaishinKit is used as a transport only: no MediaMixer, no MediaEncoder, the stream's own codecs stay idle.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var encoderSection: some View {
        Section("App encoder") {
            Picker("Resolution", selection: $viewModel.preset) {
                ForEach(TransportViewModel.VideoPreset.all) { preset in
                    Text(preset.id).tag(preset)
                }
            }
            Toggle("HEVC", isOn: $viewModel.useHEVC)
                .disabled(viewModel.connectionState.isActive)
            VStack(alignment: .leading) {
                Text("Video \(Int(viewModel.videoBitRateKbps)) kbps").font(.caption)
                Slider(value: $viewModel.videoBitRateKbps, in: 300...8000, step: 100)
            }
            VStack(alignment: .leading) {
                Text("Audio \(Int(viewModel.audioBitRateKbps)) kbps").font(.caption)
                Slider(value: $viewModel.audioBitRateKbps, in: 32...320, step: 16)
            }
            Button("Apply (recreate session)") { viewModel.applyVideoSettings() }
                .disabled(!viewModel.isCapturing)
            Button("Bitrate live") { viewModel.applyBitRateLive() }
                .disabled(!viewModel.isCapturing)
            Button("Request key frame") { viewModel.requestKeyFrame() }
                .disabled(!viewModel.isCapturing)
        }
    }

    private var transportSection: some View {
        Section("RTMP transport") {
            TextField("rtmp://host/app", text: $viewModel.url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(viewModel.connectionState.isActive)
            TextField("stream key", text: $viewModel.streamKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(viewModel.connectionState.isActive)
            HStack {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(viewModel.connectionState.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if viewModel.connectionState == .publishing {
                    Text("\(viewModel.sentFPS) fps · \(viewModel.sentKbps) kbps · \(String(format: "%.1f", viewModel.totalMegabytes)) MB")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if viewModel.connectionState.isActive {
                Button("Disconnect", role: .destructive) { viewModel.disconnectAsync() }
            } else {
                Button("Connect") { viewModel.connect() }
                    .disabled(!viewModel.isCapturing)
            }
        }
    }

    private var logSection: some View {
        Section("Log") {
            ForEach(Array(viewModel.log.suffix(30).enumerated()), id: \.offset) { entry in
                Text(entry.element)
                    .font(.system(.caption2, design: .monospaced))
            }
        }
    }

    private var stateColor: Color {
        switch viewModel.connectionState {
        case .idle:
            return .gray
        case .connecting:
            return .yellow
        case .publishing:
            return .green
        case .failed:
            return .red
        }
    }
}

/// Shows the AVCaptureVideoPreviewLayer of the app's own capture session.
private struct CapturePreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    final class PreviewView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.first?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        layer.frame = uiView.bounds
    }
}

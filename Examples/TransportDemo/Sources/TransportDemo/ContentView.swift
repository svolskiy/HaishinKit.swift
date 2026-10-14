import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: TransportViewModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                CapturePreview(layer: viewModel.capture.previewLayer)
                    .background(Color.black)
                HStack {
                    if viewModel.isCapturing {
                        Button("Stop capture", role: .destructive) { viewModel.stopCapturing() }
                    } else {
                        Button("Start capture") { viewModel.startCapturing() }
                            .keyboardShortcut(.defaultAction)
                    }
                    Spacer()
                    Text("Encoded: \(viewModel.encodedVideoFPS) fps · \(viewModel.encodedAudioPPS) audio pkt/s")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .frame(minWidth: 460)
            VStack(alignment: .leading, spacing: 12) {
                pipelineSection
                Divider()
                encoderSection
                Divider()
                transportSection
                Divider()
                logSection
            }
            .padding()
            .frame(minWidth: 480)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Pipeline").font(.headline)
            Text("AVCaptureSession → app VTCompressionSession / AVAudioConverter → compressed CMSampleBuffer → RTMPStream.append")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("HaishinKit is used as a transport only: no MediaMixer, no MediaEncoder, the stream's own codecs stay idle.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var encoderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("App encoder").font(.headline)
            HStack {
                Picker("Resolution", selection: $viewModel.preset) {
                    ForEach(TransportViewModel.VideoPreset.all) { preset in
                        Text(preset.id).tag(preset)
                    }
                }
                .frame(width: 200)
                Toggle("HEVC", isOn: $viewModel.useHEVC)
                    .disabled(viewModel.connectionState.isActive)
            }
            HStack {
                Text("Video")
                Slider(value: $viewModel.videoBitRateKbps, in: 300...8000, step: 100)
                Text("\(Int(viewModel.videoBitRateKbps)) kbps").monospacedDigit().frame(width: 90, alignment: .trailing)
            }
            HStack {
                Text("Audio")
                Slider(value: $viewModel.audioBitRateKbps, in: 32...320, step: 16)
                Text("\(Int(viewModel.audioBitRateKbps)) kbps").monospacedDigit().frame(width: 90, alignment: .trailing)
            }
            HStack {
                Button("Apply (recreate session)") { viewModel.applyVideoSettings() }
                    .disabled(!viewModel.isCapturing)
                Button("Bitrate live") { viewModel.applyBitRateLive() }
                    .disabled(!viewModel.isCapturing)
                Button("Request key frame") { viewModel.requestKeyFrame() }
                    .disabled(!viewModel.isCapturing)
            }
        }
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RTMP transport").font(.headline)
            HStack {
                TextField("rtmp://host/app", text: $viewModel.url)
                TextField("stream key", text: $viewModel.streamKey)
                    .frame(width: 140)
            }
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
                    Text("sent \(viewModel.sentFPS) fps · \(viewModel.sentKbps) kbps · \(String(format: "%.1f", viewModel.totalMegabytes)) MB")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if viewModel.connectionState.isActive {
                    Button("Disconnect") { viewModel.disconnectAsync() }
                } else {
                    Button("Connect") { viewModel.connect() }
                        .disabled(!viewModel.isCapturing)
                }
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(viewModel.log.enumerated()), id: \.offset) { entry in
                            Text(entry.element)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(entry.offset)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: viewModel.log.count) { _, count in
                    proxy.scrollTo(count - 1)
                }
            }
            .frame(minHeight: 140)
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
private struct CapturePreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        layer.frame = nsView.bounds
    }
}

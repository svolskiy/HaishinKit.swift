import HaishinKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: DemoViewModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                MTHKViewRepresentable(previewSource: viewModel, videoGravity: .resizeAspect)
                    .background(Color.black)
                captureBar
            }
            .frame(minWidth: 480)
            VStack(alignment: .leading, spacing: 12) {
                pipelineSection
                Divider()
                encoderSection
                Divider()
                destinationsSection
                Divider()
                logSection
            }
            .padding()
            .frame(minWidth: 520)
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

    private var captureBar: some View {
        HStack {
            if viewModel.isCapturing {
                Button("Stop capture", role: .destructive) { viewModel.stopCapturing() }
            } else {
                Button("Start capture") { viewModel.startCapturing() }
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
            Label(String(format: "CPU %.0f%%", viewModel.cpuUsage), systemImage: "cpu")
                .monospacedDigit()
                .help("CPU usage of this process. Compare the two pipeline modes with the same number of destinations.")
        }
        .padding(8)
    }

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pipeline").font(.headline)
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(DemoViewModel.PipelineMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(viewModel.isAnyPublishing)
            Text(viewModel.mode == .sharedEncoder
                 ? "MediaMixer → MediaEncoder → N × RTMPStream. Audio and video are encoded once."
                 : "MediaMixer → N × RTMPStream. Every stream runs its own encoders (N × encoding).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var encoderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Encoder settings").font(.headline)
            HStack {
                Picker("Resolution", selection: $viewModel.preset) {
                    ForEach(DemoViewModel.VideoPreset.all) { preset in
                        Text(preset.id).tag(preset)
                    }
                }
                .frame(width: 200)
                Toggle("HEVC", isOn: $viewModel.useHEVC)
                    .disabled(viewModel.isAnyPublishing)
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
                Button("Apply") { viewModel.applyEncoderSettingsAsync() }
                Button("Set bitrate via stream 1") { viewModel.setBitRateThroughFirstStream() }
                    .disabled(viewModel.mode != .sharedEncoder || !viewModel.isAnyPublishing)
                    .help("Calls setVideoSettings on the first RTMPStream; the change is forwarded to the shared encoder.")
                Button("Request key frame") { viewModel.requestKeyFrame() }
                    .disabled(viewModel.mode != .sharedEncoder || !viewModel.isAnyPublishing)
            }
            Text("Encoder: \(Int(viewModel.encoderVideoSettings.videoSize.width))x\(Int(viewModel.encoderVideoSettings.videoSize.height)) @ \(viewModel.encoderVideoSettings.bitRate / 1000) kbps")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Destinations").font(.headline)
                Spacer()
                Button {
                    viewModel.addDestination()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($viewModel.destinations) { $destination in
                        DestinationRow(destination: $destination)
                    }
                }
            }
            .frame(minHeight: 180)
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
            .frame(minHeight: 120)
        }
    }
}

private struct DestinationRow: View {
    @EnvironmentObject private var viewModel: DemoViewModel
    @Binding var destination: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Name", text: $destination.name)
                    .frame(width: 110)
                TextField("rtmp://host/app", text: $destination.url)
                TextField("stream key", text: $destination.streamKey)
                    .frame(width: 120)
            }
            .disabled(destination.state.isActive)
            HStack {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(destination.state.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if destination.state == .publishing {
                    Text("\(destination.fps) fps · \(destination.kilobitsPerSecond) kbps · \(String(format: "%.1f", destination.totalMegabytes)) MB")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if destination.state.isActive {
                    Button("Disconnect") { viewModel.disconnectAsync(destination.id) }
                } else {
                    Button("Connect") { viewModel.connect(destination.id) }
                        .disabled(!viewModel.isCapturing)
                }
                Button {
                    viewModel.removeDestination(destination.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private var stateColor: Color {
        switch destination.state {
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

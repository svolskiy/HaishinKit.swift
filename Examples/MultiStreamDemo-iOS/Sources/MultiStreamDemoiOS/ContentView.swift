import HaishinKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: DemoViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    MTHKViewRepresentable(previewSource: viewModel, videoGravity: .resizeAspectFill)
                        .background(Color.black)
                    Label(String(format: "CPU %.0f%%", viewModel.cpuUsage), systemImage: "cpu")
                        .font(.caption.monospacedDigit())
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
                .frame(height: 300)
                List {
                    pipelineSection
                    encoderSection
                    destinationsSection
                    logSection
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("MultiStream")
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
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(DemoViewModel.PipelineMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isAnyPublishing)
            Text(viewModel.mode == .sharedEncoder
                 ? "MediaMixer → MediaEncoder → N × RTMPStream. Audio and video are encoded once."
                 : "MediaMixer → N × RTMPStream. Every stream runs its own encoders (N × encoding).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var encoderSection: some View {
        Section("Encoder settings") {
            Picker("Resolution", selection: $viewModel.preset) {
                ForEach(DemoViewModel.VideoPreset.all) { preset in
                    Text(preset.id).tag(preset)
                }
            }
            Toggle("HEVC", isOn: $viewModel.useHEVC)
                .disabled(viewModel.isAnyPublishing)
            VStack(alignment: .leading) {
                Text("Video \(Int(viewModel.videoBitRateKbps)) kbps").font(.caption)
                Slider(value: $viewModel.videoBitRateKbps, in: 300...8000, step: 100)
            }
            VStack(alignment: .leading) {
                Text("Audio \(Int(viewModel.audioBitRateKbps)) kbps").font(.caption)
                Slider(value: $viewModel.audioBitRateKbps, in: 32...320, step: 16)
            }
            Button("Apply") { viewModel.applyEncoderSettingsAsync() }
            Button("Set bitrate via stream 1") { viewModel.setBitRateThroughFirstStream() }
                .disabled(viewModel.mode != .sharedEncoder || !viewModel.isAnyPublishing)
            Button("Request key frame") { viewModel.requestKeyFrame() }
                .disabled(viewModel.mode != .sharedEncoder || !viewModel.isAnyPublishing)
            Text("Encoder: \(Int(viewModel.encoderVideoSettings.videoSize.width))x\(Int(viewModel.encoderVideoSettings.videoSize.height)) @ \(viewModel.encoderVideoSettings.bitRate / 1000) kbps")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var destinationsSection: some View {
        Section {
            ForEach($viewModel.destinations) { $destination in
                DestinationRow(destination: $destination)
            }
            Button {
                viewModel.addDestination()
            } label: {
                Label("Add destination", systemImage: "plus")
            }
        } header: {
            Text("Destinations")
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
}

private struct DestinationRow: View {
    @EnvironmentObject private var viewModel: DemoViewModel
    @Binding var destination: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $destination.name)
                .font(.headline)
            TextField("rtmp://host/app", text: $destination.url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("stream key", text: $destination.streamKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(destination.state.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if destination.state == .publishing {
                    Text("\(destination.fps) fps · \(destination.kilobitsPerSecond) kbps")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if destination.state.isActive {
                    Button("Disconnect") { viewModel.disconnectAsync(destination.id) }
                        .buttonStyle(.bordered)
                } else {
                    Button("Connect") { viewModel.connect(destination.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.isCapturing)
                }
                Spacer()
                Button(role: .destructive) {
                    viewModel.removeDestination(destination.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
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

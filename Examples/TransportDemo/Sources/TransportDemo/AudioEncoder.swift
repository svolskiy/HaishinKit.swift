@preconcurrency import AVFoundation
import Foundation

/// The app's own AAC-LC encoder built on AVAudioConverter.
///
/// Takes the PCM `CMSampleBuffer`s of an `AVCaptureAudioDataOutput` and emits one compressed `CMSampleBuffer`
/// per AAC packet, with packet descriptions and a presentation time stamp on the capture timeline.
final class AudioEncoder: @unchecked Sendable {
    /// Sample rates the Apple AAC encoder accepts as output; other input rates are resampled to 48 kHz.
    private static let supportedSampleRates: [Double] = [48000, 44100, 32000, 24000, 22050, 16000]

    /// Called on the encoder queue with each AAC packet.
    var output: (@Sendable (CMSampleBuffer) -> Void)?
    /// Called on the encoder queue when the converter can't be created for the input format.
    var onError: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "com.haishinkit.TransportDemo.audioEncoder")
    private var bitRate = 128_000
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var failedFormatDescription: CMFormatDescription?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var anchorTime: CMTime = .invalid
    private var packetCount: Int64 = 0

    func setBitRate(_ bitRate: Int) {
        queue.async {
            self.bitRate = bitRate
            if let converter = self.converter {
                self.applyBitRate(converter)
            }
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            self.encodeOnQueue(sampleBuffer)
        }
    }

    func reset() {
        queue.sync {
            converter = nil
            inputFormat = nil
            outputFormat = nil
            failedFormatDescription = nil
            pendingBuffers.removeAll()
            anchorTime = .invalid
            packetCount = 0
        }
    }

    private func encodeOnQueue(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = sampleBuffer.formatDescription else {
            return
        }
        if inputFormat?.formatDescription != formatDescription {
            // Don't retry (and spam the log) for a format that already failed.
            guard failedFormatDescription != formatDescription else {
                return
            }
            guard makeConverter(formatDescription) else {
                failedFormatDescription = formatDescription
                return
            }
        }
        guard
            let converter,
            let inputFormat,
            let outputFormat,
            0 < converter.maximumOutputPacketSize,
            let pcmBuffer = makePCMBuffer(sampleBuffer, format: inputFormat) else {
            return
        }
        if anchorTime == .invalid {
            anchorTime = sampleBuffer.presentationTimeStamp
        }
        pendingBuffers.append(pcmBuffer)

        // Pull packets out of the converter until it needs more input. It keeps partial frames internally.
        while true {
            let packet = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: packet, error: &error) { [weak self] _, inputStatus in
                guard let self, !self.pendingBuffers.isEmpty else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.pendingBuffers.removeFirst()
            }
            guard status == .haveData else {
                return
            }
            let sampleRate = outputFormat.sampleRate
            let presentationTimeStamp = CMTimeAdd(
                anchorTime,
                CMTime(value: packetCount * 1024, timescale: CMTimeScale(sampleRate))
            )
            packetCount += 1
            if let encoded = makeSampleBuffer(packet, format: outputFormat, presentationTimeStamp: presentationTimeStamp) {
                output?(encoded)
            }
        }
    }

    private func makeConverter(_ formatDescription: CMFormatDescription) -> Bool {
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        // Bluetooth headsets and some USB devices capture at 8/16 kHz or in odd layouts; AAC-LC wants a standard rate.
        let sampleRate = Self.supportedSampleRates.contains(inputFormat.sampleRate) ? inputFormat.sampleRate : 48000
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: min(max(inputFormat.channelCount, 1), 2),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let outputFormat = AVAudioFormat(streamDescription: &asbd) else {
            onError?("AAC output format rejected for input \(inputFormat)")
            return false
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat), 0 < converter.maximumOutputPacketSize else {
            onError?("AVAudioConverter can't encode \(inputFormat) to AAC \(Int(sampleRate)) Hz")
            return false
        }
        applyBitRate(converter)
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        pendingBuffers.removeAll()
        return true
    }

    /// Clamps the requested bitrate to what the encoder accepts for this format (as HaishinKit's AudioCodec does).
    private func applyBitRate(_ converter: AVAudioConverter) {
        let applicable = converter.applicableEncodeBitRates?.map(\.intValue) ?? []
        guard let minimum = applicable.min(), let maximum = applicable.max() else {
            converter.bitRate = bitRate
            return
        }
        converter.bitRate = min(maximum, max(minimum, bitRate))
    }

    private func makePCMBuffer(_ sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard 0 < frameCount, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    /// Wraps one AAC packet into a CMSampleBuffer, the shape a HaishinKit stream accepts in transport mode.
    private func makeSampleBuffer(_ packet: AVAudioCompressedBuffer, format: AVAudioFormat, presentationTimeStamp: CMTime) -> CMSampleBuffer? {
        let byteCount = Int(packet.byteLength)
        guard 0 < byteCount else {
            return nil
        }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return nil
        }
        guard CMBlockBufferReplaceDataBytes(
            with: packet.data,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        ) == noErr else {
            return nil
        }
        var packetDescription = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(byteCount))
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: 1,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: &packetDescription,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }
}

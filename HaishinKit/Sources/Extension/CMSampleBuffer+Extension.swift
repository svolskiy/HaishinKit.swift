import Accelerate
import AVFoundation
import CoreMedia

package extension CMSampleBuffer {
    @inlinable @inline(__always) var isNotSync: Bool {
        get {
            guard !sampleAttachments.isEmpty else {
                return false
            }
            return sampleAttachments[0][.notSync] != nil
        }
        set {
            guard !sampleAttachments.isEmpty else {
                return
            }
            sampleAttachments[0][.notSync] = newValue ? 1 : nil
        }
    }

    /// Splits a compressed audio sample buffer (AAC, Opus, ... packets produced by an external encoder)
    /// into one AVAudioCompressedBuffer per packet, with the matching AVAudioTime.
    ///
    /// The returned times carry both a host time derived from the presentation time stamp and a sample time,
    /// so they work with the RTMP timestamp logic as well as with the TS writer.
    func makeCompressedAudioBuffers() -> [(AVAudioCompressedBuffer, AVAudioTime)] {
        guard
            let formatDescription,
            formatDescription.mediaType == .audio,
            let asbd = formatDescription.audioStreamBasicDescription,
            asbd.mFormatID != kAudioFormatLinearPCM,
            let dataBuffer,
            let format = AVAudioFormat(cmAudioFormatDescription: formatDescription) else {
            return []
        }
        let sampleRate = asbd.mSampleRate
        let framesPerPacket = asbd.mFramesPerPacket == 0 ? 1024 : asbd.mFramesPerPacket
        var result: [(AVAudioCompressedBuffer, AVAudioTime)] = []
        var offset = 0
        var presentationTimeStamp = self.presentationTimeStamp
        for index in 0..<max(numSamples, 1) {
            var byteCount = CMSampleBufferGetSampleSize(self, at: index)
            if byteCount == 0 && numSamples <= 1 {
                byteCount = dataBuffer.dataLength
            }
            guard 0 < byteCount else {
                continue
            }
            let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: byteCount)
            buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(byteCount)
            )
            buffer.packetCount = 1
            buffer.byteLength = UInt32(byteCount)
            guard CMBlockBufferCopyDataBytes(dataBuffer, atOffset: offset, dataLength: byteCount, destination: buffer.data) == noErr else {
                break
            }
            let seconds = presentationTimeStamp.seconds
            let when = AVAudioTime(
                hostTime: AVAudioTime.hostTime(forSeconds: seconds),
                sampleTime: AVAudioFramePosition((seconds * sampleRate).rounded()),
                atRate: sampleRate
            )
            result.append((buffer, when))
            offset += byteCount
            presentationTimeStamp = CMTimeAdd(
                presentationTimeStamp,
                CMTime(value: CMTimeValue(framesPerPacket), timescale: CMTimeScale(sampleRate))
            )
        }
        return result
    }
}

#if hasAttribute(retroactive)
extension CMSampleBuffer: @retroactive @unchecked Sendable {}
#else
extension CMSampleBuffer: @unchecked Sendable {}
#endif

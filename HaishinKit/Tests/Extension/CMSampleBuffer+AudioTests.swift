import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite struct CMSampleBufferAudioTests {
    @Test func makeCompressedAudioBuffers_splitsPackets() throws {
        let packets: [[UInt8]] = [[0x01, 0x02, 0x03], [0x04, 0x05], [0x06, 0x07, 0x08, 0x09]]
        let sampleBuffer = try #require(CMAudioSampleBufferFactory.makeAAC(
            packets: packets,
            sampleRate: 48000,
            presentationTimeStamp: CMTime(value: 48000, timescale: 48000)
        ))
        #expect(sampleBuffer.formatDescription?.isCompressed == true)

        let buffers = sampleBuffer.makeCompressedAudioBuffers()
        #expect(buffers.count == 3)
        for (index, (buffer, when)) in buffers.enumerated() {
            #expect(buffer.packetCount == 1)
            #expect(Int(buffer.byteLength) == packets[index].count)
            let bytes = Array(UnsafeBufferPointer(start: buffer.data.assumingMemoryBound(to: UInt8.self), count: Int(buffer.byteLength)))
            #expect(bytes == packets[index])
            #expect(buffer.format.formatDescription.mediaSubType == .mpeg4AAC)
            // 1.0 s + index * 1024 / 48000
            let expected = 1.0 + Double(index) * 1024.0 / 48000.0
            #expect(abs(AVAudioTime.seconds(forHostTime: when.hostTime) - expected) < 0.001)
            #expect(when.sampleRate == 48000)
        }
    }

    @Test func makeCompressedAudioBuffers_ignoresPCM() throws {
        let sampleBuffer = try #require(CMAudioSampleBufferFactory.makeSilence(44100, numSamples: 1024, channels: 1))
        #expect(sampleBuffer.formatDescription?.isCompressed == false)
        #expect(sampleBuffer.makeCompressedAudioBuffers().isEmpty)
    }
}

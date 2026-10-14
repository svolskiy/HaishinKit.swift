import AVFoundation
import CoreMedia
import Foundation

protocol RTMPTimeConvertible {
    var seconds: TimeInterval { get }
}

private let kRTMPTimestamp_defaultTimeInterval: TimeInterval = 0

struct RTMPTimestamp<T: RTMPTimeConvertible> {
    enum Error: Swift.Error {
        case invalidSequence
    }

    private var isStarted = false
    private var startedAt = kRTMPTimestamp_defaultTimeInterval
    private var updatedAt = kRTMPTimestamp_defaultTimeInterval
    private var timedeltaFraction: TimeInterval = kRTMPTimestamp_defaultTimeInterval

    mutating func update(_ value: T) throws -> UInt32 {
        // The first value anchors the timeline, whatever it is (an external encoder may start at 0).
        guard isStarted else {
            isStarted = true
            startedAt = value.seconds
            updatedAt = value.seconds
            return 0
        }
        guard updatedAt < value.seconds else {
            throw Error.invalidSequence
        }
        var timedelta = (value.seconds - updatedAt) * 1000
        timedeltaFraction += timedelta.truncatingRemainder(dividingBy: 1)
        if 1 <= timedeltaFraction {
            timedeltaFraction -= 1
            timedelta += 1
        }
        updatedAt = value.seconds
        return UInt32(timedelta)
    }

    mutating func update(_ message: some RTMPMessage, chunkType: RTMPChunkType) {
        switch chunkType {
        case .zero:
            if !isStarted {
                isStarted = true
                startedAt = TimeInterval(message.timestamp) / 1000
                updatedAt = TimeInterval(message.timestamp) / 1000
            } else {
                updatedAt = TimeInterval(message.timestamp) / 1000
            }
        default:
            updatedAt += TimeInterval(message.timestamp) / 1000
        }
    }

    mutating func clear() {
        isStarted = false
        startedAt = kRTMPTimestamp_defaultTimeInterval
        updatedAt = kRTMPTimestamp_defaultTimeInterval
        timedeltaFraction = kRTMPTimestamp_defaultTimeInterval
    }
}

extension AVAudioTime: RTMPTimeConvertible {
    var seconds: TimeInterval {
        AVAudioTime.seconds(forHostTime: hostTime)
    }
}

extension RTMPTimestamp where T == AVAudioTime {
    var value: AVAudioTime {
        return AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: updatedAt))
    }
}

extension CMTime: RTMPTimeConvertible {
}

extension RTMPTimestamp where T == CMTime {
    var value: CMTime {
        return CMTime(seconds: updatedAt, preferredTimescale: 1000)
    }
}

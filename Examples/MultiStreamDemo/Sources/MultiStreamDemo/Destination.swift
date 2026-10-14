import Foundation

/// One RTMP target (service) the same encoded stream is published to.
struct Destination: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case idle
        case connecting
        case publishing
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "Idle"
            case .connecting:
                return "Connecting…"
            case .publishing:
                return "Publishing"
            case .failed(let message):
                return "Failed: \(message)"
            }
        }

        var isActive: Bool {
            switch self {
            case .connecting, .publishing:
                return true
            default:
                return false
            }
        }
    }

    let id: UUID
    var name: String
    /// `rtmp://host/app`
    var url: String
    var streamKey: String
    var state: State = .idle
    var bytesPerSecond: Int = 0
    var fps: UInt16 = 0
    var totalBytes: Int = 0

    init(id: UUID = UUID(), name: String, url: String, streamKey: String) {
        self.id = id
        self.name = name
        self.url = url
        self.streamKey = streamKey
    }

    var kilobitsPerSecond: Int {
        bytesPerSecond * 8 / 1000
    }

    var totalMegabytes: Double {
        Double(totalBytes) / 1_000_000
    }
}

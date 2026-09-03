import Foundation

/// Tracks the progress of an email scan/sync operation
public struct ScanProgress: Sendable {
    public var total: Int
    public var fetched: Int
    public var status: ScanStatus

    public init(total: Int, fetched: Int, status: ScanStatus) {
        self.total = total
        self.fetched = fetched
        self.status = status
    }
}

/// Status of a scan operation
public enum ScanStatus: Sendable {
    case connecting
    case fetchingList
    case fetchingMetadata
    case completed
    case failed(String)

    public var description: String {
        switch self {
        case .connecting: return "Connecting to account..."
        case .fetchingList: return "Fetching email list..."
        case .fetchingMetadata: return "Downloading email metadata..."
        case .completed: return "Scan complete"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }
}

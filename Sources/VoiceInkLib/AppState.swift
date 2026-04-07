import Foundation

public enum AppState: Equatable {
    case idle
    case recording
    case transcribing
    case postProcessing
    case error(String)

    public var description: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .postProcessing: return "Processing..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

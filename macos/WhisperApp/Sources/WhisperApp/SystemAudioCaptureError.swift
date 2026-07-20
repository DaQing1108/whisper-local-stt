import Foundation

enum SystemAudioCaptureError: LocalizedError, Equatable {
    case streamStopped(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .streamStopped(let message): "System audio capture stopped: \(message)"
        case .conversionFailed(let message): "System audio conversion failed: \(message)"
        }
    }
}

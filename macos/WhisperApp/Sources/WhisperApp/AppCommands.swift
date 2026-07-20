import Foundation

extension Notification.Name {
    static let whisperImportAudio = Notification.Name("whisper.command.importAudio")
    static let whisperToggleRecording = Notification.Name("whisper.command.toggleRecording")
    static let whisperCopyResult = Notification.Name("whisper.command.copyResult")
    static let whisperClearWorkspace = Notification.Name("whisper.command.clearWorkspace")
}

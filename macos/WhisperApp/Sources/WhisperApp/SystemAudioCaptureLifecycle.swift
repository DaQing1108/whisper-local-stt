import Foundation

@MainActor
protocol SystemAudioCaptureBackend: AnyObject {
    func start() async throws
    func stop() async throws
    func setErrorHandler(_ handler: @escaping @MainActor @Sendable (Error) -> Void)
    func setPCMHandler(_ handler: @escaping @Sendable (Data) -> Void)
}

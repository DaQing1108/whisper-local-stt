import Foundation

final class SystemAudioWAVSession: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: PCM16WAVWriter
    let url: URL
    private var finalized = false
    private var storedWriteError: Error?

    var writeError: Error? { lock.withLock { storedWriteError } }

    init(url: URL) throws {
        self.url = url
        writer = try PCM16WAVWriter(url: url)
    }

    func append(_ pcm: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard !finalized else { throw WAVWriterError.alreadyFinalized }
            try writer.append(pcm)
        } catch {
            if storedWriteError == nil { storedWriteError = error }
            throw error
        }
    }

    @discardableResult
    func finalize() throws -> URL {
        try lock.withLock {
            guard !finalized else { return url }
            let url = try writer.finalize()
            finalized = true
            if let storedWriteError { throw storedWriteError }
            return url
        }
    }
}

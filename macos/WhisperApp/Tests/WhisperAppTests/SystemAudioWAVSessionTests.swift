import Foundation
import Testing
@testable import WhisperApp

struct SystemAudioWAVSessionTests {
    @Test
    func writesCanonicalWAVFromPCMCallbacks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-audio-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try SystemAudioWAVSession(url: url)

        try session.append(Data([0x01, 0x02, 0x03, 0x04]))
        #expect(try session.finalize() == url)
        #expect(try Data(contentsOf: url).count == 48)
    }

    @Test
    func remembersTerminalAppendFailureForTheRecordingController() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-audio-closed-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try SystemAudioWAVSession(url: url)
        _ = try session.finalize()

        #expect(throws: WAVWriterError.alreadyFinalized) {
            try session.append(Data([0x01, 0x02]))
        }
        #expect(session.writeError != nil)
    }
}

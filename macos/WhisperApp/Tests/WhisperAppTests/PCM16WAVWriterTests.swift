import Foundation
import Testing
@testable import WhisperApp

struct PCM16WAVWriterTests {
    @Test
    func writesCanonicalMono16kHzPCMHeaderAndPayload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try PCM16WAVWriter(url: url)
        let samples = Data([0x01, 0x00, 0xFF, 0x7F])

        try writer.append(samples)
        try writer.finalize()
        let wav = try Data(contentsOf: url)

        #expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        #expect(readUInt32(wav, at: 24) == 16_000)
        #expect(readUInt16(wav, at: 22) == 1)
        #expect(readUInt16(wav, at: 34) == 16)
        #expect(readUInt32(wav, at: 40) == 4)
        #expect(wav[44...] == samples)
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

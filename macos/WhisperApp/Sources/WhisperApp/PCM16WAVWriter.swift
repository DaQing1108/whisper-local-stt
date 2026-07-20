import Foundation

enum WAVWriterError: Error {
    case alreadyFinalized
    case dataTooLarge
}

final class PCM16WAVWriter {
    static let sampleRate: UInt32 = 16_000
    static let channelCount: UInt16 = 1
    static let bitsPerSample: UInt16 = 16

    let url: URL
    private let handle: FileHandle
    private var dataByteCount: UInt32 = 0
    private var finalized = false
    var hasAudioData: Bool { dataByteCount > 0 }

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataByteCount: 0))
    }

    func append(_ pcm16LittleEndian: Data) throws {
        guard !finalized else { throw WAVWriterError.alreadyFinalized }
        let (nextCount, overflow) = dataByteCount.addingReportingOverflow(UInt32(pcm16LittleEndian.count))
        guard !overflow else { throw WAVWriterError.dataTooLarge }
        try handle.write(contentsOf: pcm16LittleEndian)
        dataByteCount = nextCount
    }

    @discardableResult
    func finalize() throws -> URL {
        guard !finalized else { throw WAVWriterError.alreadyFinalized }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataByteCount: dataByteCount))
        try handle.close()
        finalized = true
        return url
    }

    private static func header(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.appendLittleEndian(36 + dataByteCount)
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(channelCount * (bitsPerSample / 8))
        data.appendLittleEndian(bitsPerSample)
        data.append("data".data(using: .ascii)!)
        data.appendLittleEndian(dataByteCount)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

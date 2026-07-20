import Foundation

enum PCM16Mixer {
    static func mix(_ first: Data, _ second: Data) -> Data {
        let sampleCount = max(first.count, second.count) / MemoryLayout<Int16>.size
        var output = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
        for index in 0..<sampleCount {
            let left = sample(at: index, in: first)
            let right = sample(at: index, in: second)
            var mixed = Int16(clamping: (Int32(left) + Int32(right)) / 2).littleEndian
            Swift.withUnsafeBytes(of: &mixed) { output.append(contentsOf: $0) }
        }
        return output
    }

    private static func sample(at index: Int, in data: Data) -> Int16 {
        let offset = index * MemoryLayout<Int16>.size
        guard offset + MemoryLayout<Int16>.size <= data.count else { return 0 }
        return data.withUnsafeBytes {
            Int16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int16.self))
        }
    }
}

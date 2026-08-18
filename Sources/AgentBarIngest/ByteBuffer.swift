import Foundation

/// Bytes arrived from a connection, with a read cursor.
///
/// A parser fed by a socket sees a request split at arbitrary points, so it
/// needs to look ahead without consuming and to consume without copying what is
/// left. `Data` can do both, but its slices carry a non-zero `startIndex`, and
/// index arithmetic that silently assumes otherwise is the classic way to read
/// the wrong bytes. This keeps the cursor explicit instead.
struct ByteBuffer {
    /// Reclaim consumed bytes once they are both substantial and the majority,
    /// so a long-lived keep-alive connection does not grow without bound and a
    /// short one never pays for a copy.
    private static let compactionThreshold = 64 * 1024

    private var storage: [UInt8] = []
    private var readIndex = 0

    init() {}

    init(_ data: Data) {
        storage = Array(data)
    }

    var readableBytes: Int { storage.count - readIndex }

    var isEmpty: Bool { readableBytes == 0 }

    mutating func append(_ data: Data) {
        storage.append(contentsOf: data)
    }

    /// The byte `offset` positions past the cursor, without consuming it.
    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < readableBytes else { return nil }
        return storage[readIndex + offset]
    }

    /// Offset of the first occurrence of `needle` relative to the cursor,
    /// searching no further than `limit` bytes in.
    ///
    /// The bounded search is what lets the parser refuse an oversized head
    /// without first buffering all of it.
    func offset(ofFirst needle: [UInt8], searchingAtMost limit: Int) -> Int? {
        guard !needle.isEmpty else { return nil }
        let searchable = min(readableBytes, limit)
        guard searchable >= needle.count else { return nil }
        for offset in 0...(searchable - needle.count) where matches(needle, at: offset) {
            return offset
        }
        return nil
    }

    private func matches(_ needle: [UInt8], at offset: Int) -> Bool {
        for position in 0..<needle.count
        where storage[readIndex + offset + position] != needle[position] {
            return false
        }
        return true
    }

    /// Consumes `count` bytes and returns them.
    mutating func take(_ count: Int) -> Data {
        let taken = min(count, readableBytes)
        let result = Data(storage[readIndex..<(readIndex + taken)])
        discard(taken)
        return result
    }

    mutating func discard(_ count: Int) {
        // Clamped before it is added, not after: `readIndex + count` on a huge
        // count overflows, and an overflow in Swift traps the process.
        readIndex += min(max(0, count), readableBytes)
        compactIfNeeded()
    }

    private mutating func compactIfNeeded() {
        guard readIndex >= ByteBuffer.compactionThreshold, readIndex * 2 >= storage.count else {
            return
        }
        storage.removeFirst(readIndex)
        readIndex = 0
    }
}

import Foundation

/// The sample data of a big-endian 24-bit AIFF, as levels.
///
/// Hand-parsed rather than read through Core Audio because the question is
/// about the *samples*, and `AudioFile` answers questions about the header.
/// `SoundValidator` already covers everything the header can say — container,
/// encoding, duration — and none of it would notice a file at half the level
/// of its neighbours or one clipping against full scale.
///
/// Deliberately narrow: it understands exactly the encoding AgentBar ships
/// (`BEI24@48000`, mono) and returns `nil` for anything else rather than
/// guessing, so a change of format fails the test that uses it instead of
/// silently measuring the wrong bytes.
struct AIFFSamples {
    let peakDecibels: Double
    let rootMeanSquareDecibels: Double
    let seconds: Double

    private static let fullScale = 8_388_608.0
    private static let sampleRate = 48_000.0

    init?(contentsOf url: URL) {
        guard let raw = try? Data(contentsOf: url),
            raw.count > 12,
            raw.prefix(4).elementsEqual(Array("FORM".utf8)),
            raw[8..<12].elementsEqual(Array("AIFF".utf8)),
            let sound = Self.chunk(named: "SSND", in: raw)
        else { return nil }

        // SSND opens with `offset` and `blockSize`, both big-endian UInt32.
        guard sound.count > 8 else { return nil }
        let start = sound.startIndex + 8 + Int(Self.beUInt32(sound, at: sound.startIndex))
        guard start <= sound.endIndex else { return nil }
        let samples = sound[start...]
        let count = samples.count / 3
        guard count > 0 else { return nil }

        var peak = 0.0
        var sumOfSquares = 0.0
        for index in 0..<count {
            let base = samples.startIndex + index * 3
            var value =
                Int32(samples[base]) << 16 | Int32(samples[base + 1]) << 8
                | Int32(samples[base + 2])
            // Sign-extend a 24-bit two's-complement value into 32 bits.
            if value & 0x80_0000 != 0 { value -= 0x100_0000 }
            let scaled = Double(value) / Self.fullScale
            peak = max(peak, abs(scaled))
            sumOfSquares += scaled * scaled
        }

        peakDecibels = 20 * log10(max(peak, 1e-9))
        rootMeanSquareDecibels = 20 * log10(max((sumOfSquares / Double(count)).squareRoot(), 1e-9))
        seconds = Double(count) / Self.sampleRate
    }

    private static func beUInt32(_ data: Data, at index: Data.Index) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[index + $1]) }
    }

    private static func chunk(named name: String, in data: Data) -> Data? {
        let identifier = Array(name.utf8)
        var offset = data.startIndex + 12
        while offset + 8 <= data.endIndex {
            let size = Int(beUInt32(data, at: offset + 4))
            guard size >= 0, offset + 8 + size <= data.endIndex else { return nil }
            if data[offset..<(offset + 4)].elementsEqual(identifier) {
                return data[(offset + 8)..<(offset + 8 + size)]
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }
}

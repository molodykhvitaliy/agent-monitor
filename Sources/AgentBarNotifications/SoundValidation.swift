import AudioToolbox
import Foundation

/// Why a chosen sound cannot be used.
///
/// Every case carries the sentence the user reads. `UNNotificationSound(named:)`
/// answers with a sound object whatever it is given and falls back to the
/// default when the file is not there — silently, which is why every one of
/// these has to be found before the notification is sent rather than after.
public enum SoundProblem: Sendable, Hashable, Error, CustomStringConvertible {
    /// Nothing of that name in either location the notification centre looks in.
    case missing(name: String)
    case unsupportedExtension(name: String, found: String)
    /// Present, and Core Audio would not open it.
    case unreadable(name: String, status: Int)
    case tooLong(name: String, seconds: Double)
    case unsupportedEncoding(name: String, format: String)

    public var description: String {
        switch self {
        case .missing(let name):
            "\(name) is not in your Sounds folder any more"
        case .unsupportedExtension(let name, let found):
            "\(name) is a .\(found) file — notification sounds must be .aiff, .wav or .caf"
        case .unreadable(let name, let status):
            "\(name) could not be read (Core Audio error \(status))"
        case .tooLong(let name, let seconds):
            "\(name) is \(Int(seconds.rounded())) seconds long — the limit is 30"
        case .unsupportedEncoding(let name, let format):
            "\(name) is \(format) — notification sounds must be Linear PCM or IMA4"
        }
    }

    /// The file this problem is about, for matching a problem to a matrix row.
    public var soundName: String {
        switch self {
        case .missing(let name),
            .unsupportedExtension(let name, _),
            .unreadable(let name, _),
            .tooLong(let name, _),
            .unsupportedEncoding(let name, _):
            name
        }
    }
}

/// Checks a candidate sound file against everything the notification centre
/// requires of one, before the notification centre gets a chance to ignore it.
///
/// The rules are Apple's: aiff, wav or caf; Linear PCM or IMA4; **strictly**
/// under thirty seconds. A file that breaks any of them plays as the default
/// sound with no diagnostic anywhere, so this is the only place the difference
/// between "my sound" and "some sound" can still be observed.
public enum SoundValidator {

    /// Container formats `UNNotificationSound` accepts, lowercased.
    public static let allowedExtensions: Set<String> = ["aiff", "aif", "wav", "caf"]

    /// Exclusive: a file of exactly thirty seconds is already too long.
    public static let maximumDuration: Double = 30

    static let allowedFormatIDs: Set<AudioFormatID> = [
        kAudioFormatLinearPCM, kAudioFormatAppleIMA4,
    ]

    /// `nil` when the file at `url` is usable as a notification sound.
    public static func problem(with url: URL) -> SoundProblem? {
        let name = url.lastPathComponent
        let fileExtension = url.pathExtension.lowercased()
        guard allowedExtensions.contains(fileExtension) else {
            return .unsupportedExtension(name: name, found: fileExtension)
        }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .missing(name: name)
        }

        var identifier: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &identifier)
        guard status == noErr, let identifier else {
            return .unreadable(name: name, status: Int(status))
        }
        defer { AudioFileClose(identifier) }

        if let format = format(of: identifier), !allowedFormatIDs.contains(format) {
            return .unsupportedEncoding(name: name, format: fourCharacterCode(format))
        }
        if let seconds = duration(of: identifier), seconds >= maximumDuration {
            return .tooLong(name: name, seconds: seconds)
        }
        return nil
    }

    /// `nil` rather than a problem when Core Audio will not answer: a property
    /// this build of the OS declines to report is not evidence the file is bad,
    /// and refusing a usable sound is the worse of the two mistakes.
    private static func duration(of file: AudioFileID) -> Double? {
        var seconds = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioFileGetProperty(
            file, kAudioFilePropertyEstimatedDuration, &size, &seconds)
        guard status == noErr else { return nil }
        return Double(seconds)
    }

    private static func format(of file: AudioFileID) -> AudioFormatID? {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioFileGetProperty(
            file, kAudioFilePropertyDataFormat, &size, &description)
        guard status == noErr else { return nil }
        return description.mFormatID
    }

    /// Core Audio names formats with a packed four-character code. Rendering it
    /// back means the message says `mp4a` rather than `1836069985`.
    private static func fourCharacterCode(_ value: AudioFormatID) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        let characters = bytes.map { byte -> Character in
            let scalar = UnicodeScalar(byte)
            return scalar.isASCII && !scalar.properties.isDefaultIgnorableCodePoint
                && byte >= 0x20 ? Character(scalar) : "?"
        }
        return String(characters)
    }
}

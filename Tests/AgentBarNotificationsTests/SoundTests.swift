import AVFoundation
import AgentBarCore
import AppKit
import Foundation
import Testing

@testable import AgentBarNotifications

/// The sound rules are Apple's, and every one of them fails **silently** when
/// broken: the notification plays the default sound and nothing anywhere says
/// why. These suites use real files on disk, because a mocked validator would
/// only assert that the mock agrees with itself.
@Suite("Sound validation")
struct SoundValidationTests {

    @Test("A short Linear PCM wav is accepted")
    func acceptsWave() throws {
        let scratch = try SoundScratch()
        let url = try scratch.writeWave("chime.wav", seconds: 0.5)
        #expect(SoundValidator.problem(with: url) == nil)
    }

    /// The authored files, read from the repository rather than from a bundle:
    /// `swift test` has no app bundle, and these are the same bytes the app
    /// ships.
    static var shippedSoundsDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Apps/AgentBar/Sounds", directoryHint: .isDirectory)
    }

    @Test("The bundled sounds are all valid")
    func bundledSoundsAreValid() throws {
        for sound in BundledSound.allCases {
            let url = Self.shippedSoundsDirectory.appending(path: sound.fileName)
            #expect(
                SoundValidator.problem(with: url) == nil,
                "\(sound.fileName): \(SoundValidator.problem(with: url)?.description ?? "")")
        }
    }

    /// A second reader, because the two disagree about what they accept and
    /// both are on a path the user takes. `SoundValidator` answers for the
    /// notification centre; `NSSound` is what the settings window's play button
    /// auditions with, and a sound that validates but will not load would give
    /// a dead button under a working notification.
    @Test("Every bundled sound loads in the reader the preview button uses")
    func bundledSoundsLoadForPreview() throws {
        for sound in BundledSound.allCases {
            let url = Self.shippedSoundsDirectory.appending(path: sound.fileName)
            #expect(NSSound(contentsOf: url, byReference: true) != nil, "\(sound.fileName)")
        }
    }

    /// The set is authored as one voice at one level, and
    /// `design-spec.md` § *The sound set* states that as a requirement rather
    /// than as trivia: peak headroom below full scale, and four files within
    /// half a decibel of each other in RMS. A notification that clips, or one
    /// that is twice as loud as its neighbours, is the reason a person turns
    /// the feature off.
    ///
    /// Bounds are loose around the measured values — peak −3.0 dBFS at the
    /// loudest, 0.49 dB of RMS spread — because this is a guard against a file
    /// arriving from somewhere else, not a mastering check.
    @Test("The set is levelled as one set")
    func bundledSoundsAreOneSet() throws {
        var levels: [String: AIFFSamples] = [:]
        for sound in BundledSound.allCases {
            let url = Self.shippedSoundsDirectory.appending(path: sound.fileName)
            let samples = try #require(
                AIFFSamples(contentsOf: url), "\(sound.fileName) could not be read as AIFF")
            levels[sound.fileName] = samples
            #expect(
                samples.seconds > 0.2 && samples.seconds < 2,
                "\(sound.fileName) is \(samples.seconds)s")
            // Headroom, so nothing in the set clips.
            #expect(
                samples.peakDecibels <= -2.5,
                "\(sound.fileName) peaks at \(samples.peakDecibels) dBFS")
            // And nothing is so quiet it would be missed — which is what a
            // truncated or wrongly converted file looks like.
            #expect(
                samples.peakDecibels >= -12,
                "\(sound.fileName) peaks at \(samples.peakDecibels) dBFS")
        }

        let loudness = levels.values.map(\.rootMeanSquareDecibels)
        let spread = try #require(loudness.max()) - #require(loudness.min())
        #expect(spread <= 1.5, "RMS spread across the set is \(spread) dB")
    }

    @Test("A file that is not there is reported as missing")
    func missingFile() throws {
        let scratch = try SoundScratch()
        let url = scratch.directory.appending(path: "gone.wav")
        #expect(SoundValidator.problem(with: url) == .missing(name: "gone.wav"))
    }

    @Test("An unsupported container is refused by extension alone")
    func unsupportedExtension() throws {
        let scratch = try SoundScratch()
        let url = try scratch.writeGarbage("theme.mp3")
        #expect(
            SoundValidator.problem(with: url)
                == .unsupportedExtension(name: "theme.mp3", found: "mp3"))
    }

    @Test("A file Core Audio cannot open is reported, not assumed usable")
    func unreadableFile() throws {
        let scratch = try SoundScratch()
        let url = try scratch.writeGarbage("broken.wav")
        let problem = try #require(SoundValidator.problem(with: url))
        guard case .unreadable = problem else {
            Issue.record("expected .unreadable, got \(problem)")
            return
        }
    }

    /// The limit is exclusive: at thirty seconds the system already substitutes
    /// the default.
    @Test("Thirty seconds is already too long")
    func durationLimitIsExclusive() throws {
        let scratch = try SoundScratch()
        let long = try scratch.writeWave("long.wav", seconds: 30.5)
        let problem = try #require(SoundValidator.problem(with: long))
        guard case .tooLong = problem else {
            Issue.record("expected .tooLong, got \(problem)")
            return
        }

        let short = try scratch.writeWave("short.wav", seconds: 29)
        #expect(SoundValidator.problem(with: short) == nil)
    }

    @Test("Every problem renders a sentence naming the file")
    func problemsAreReadable() {
        let problems: [SoundProblem] = [
            .missing(name: "a.aiff"),
            .unsupportedExtension(name: "a.mp3", found: "mp3"),
            .unreadable(name: "a.wav", status: -39),
            .tooLong(name: "a.wav", seconds: 42),
            .unsupportedEncoding(name: "a.caf", format: "mp4a"),
        ]
        for problem in problems {
            #expect(problem.description.contains(problem.soundName))
            #expect(!problem.description.isEmpty)
        }
    }
}

@Suite("Sound library")
struct SoundLibraryTests {

    @Test("User sounds are listed, sorted, and filtered by extension")
    func listsUserSounds() throws {
        let scratch = try SoundScratch()
        try scratch.writeWave("Zebra.wav", seconds: 0.2)
        try scratch.writeWave("apple.wav", seconds: 0.2)
        try scratch.writeGarbage("notes.txt")

        let library = SoundLibrary(userDirectory: scratch.directory)
        let names = library.user().map(\.displayName)
        #expect(names == ["apple", "Zebra"])
    }

    @Test("A missing Sounds folder is an empty list, not an error")
    func absentDirectory() {
        let library = SoundLibrary(
            userDirectory: URL(filePath: "/nonexistent/agentbar", directoryHint: .isDirectory))
        #expect(library.user().isEmpty)
    }

    @Test("A selection naming a file that has gone is reported as missing")
    func reportsMissingSelection() throws {
        let scratch = try SoundScratch()
        let library = SoundLibrary(userDirectory: scratch.directory)
        #expect(library.problem(with: .named("Chime.aiff")) == .missing(name: "Chime.aiff"))
    }

    @Test("Default and silent need no file and have no problem")
    func standardSelectionsAreAlwaysFine() throws {
        let scratch = try SoundScratch()
        let library = SoundLibrary(userDirectory: scratch.directory)
        #expect(library.problem(with: .systemDefault) == nil)
        #expect(library.problem(with: .silent) == nil)
    }

    /// A sound left in `~/Downloads` is a sound that plays as the default, so
    /// importing copies rather than referencing.
    @Test("Importing copies the file into the Sounds folder")
    func installCopies() throws {
        let source = try SoundScratch(name: "source")
        let target = try SoundScratch(name: "target")
        let origin = try source.writeWave("Chime.wav", seconds: 0.4)

        let library = SoundLibrary(userDirectory: target.directory)
        let installed = try library.install(from: origin)

        #expect(installed.name == "Chime.wav")
        #expect(installed.origin == .user)
        #expect(FileManager.default.fileExists(atPath: installed.url.path(percentEncoded: false)))
        // The original is never touched.
        #expect(FileManager.default.fileExists(atPath: origin.path(percentEncoded: false)))
        #expect(library.file(named: "Chime.wav") != nil)
    }

    /// Silently replacing a sound another notification is already using is not
    /// the importer's decision to make.
    @Test("A name collision takes a numbered name rather than overwriting")
    func installDoesNotOverwrite() throws {
        let source = try SoundScratch(name: "source2")
        let target = try SoundScratch(name: "target2")
        try target.writeWave("Chime.wav", seconds: 0.4)
        let origin = try source.writeWave("Chime.wav", seconds: 0.4)

        let library = SoundLibrary(userDirectory: target.directory)
        let second = try library.install(from: origin)
        let third = try library.install(from: origin)
        #expect(second.name == "Chime 2.wav")
        #expect(third.name == "Chime 3.wav")
    }

    @Test("An invalid file is refused before anything is copied")
    func installRefusesInvalid() throws {
        let source = try SoundScratch(name: "source3")
        let target = try SoundScratch(name: "target3")
        let origin = try source.writeGarbage("theme.mp3")

        let library = SoundLibrary(userDirectory: target.directory)
        #expect(throws: SoundProblem.self) { try library.install(from: origin) }
        #expect(library.user().isEmpty)
    }

    /// A default naming a file that is not in the bundle is a build mistake, and
    /// this is where it gets caught rather than at a user's first notification.
    @Test("Every default names a sound AgentBar actually ships")
    func defaultsNameBundledSounds() {
        let bundled = Set(BundledSound.allCases.map(\.fileName))
        for preference in NotificationSettings.defaultPreferences {
            #expect(preference.sound.fileName.map(bundled.contains) == true)
        }
    }
}

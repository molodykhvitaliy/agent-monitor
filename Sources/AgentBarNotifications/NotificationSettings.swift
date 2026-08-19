import AgentBarCore
import Foundation

/// Which sound a notification carries.
///
/// A **name**, not a path: `UNNotificationSound(named:)` resolves a file name
/// against the locations it chooses, and hands back a sound object whatever it
/// finds — including nothing. Storing a path would let a settings file describe
/// a sound the notification centre can never load, so a selection is always a
/// name that `SoundLibrary` has resolved, or one of the two answers that need no
/// file at all.
public enum SoundSelection: Sendable, Hashable, Codable {
    /// Whatever macOS plays for this app by default.
    case systemDefault
    /// No sound. A banner with no voice, which is a legitimate choice for
    /// `finished` and the only alternative to turning the event off entirely.
    case silent
    /// A file name including its extension, as `UNNotificationSoundName` takes
    /// it — `AgentBar Question.aiff`.
    case named(String)

    /// The file name this selection needs on disk, if it needs one.
    public var fileName: String? {
        guard case .named(let name) = self else { return nil }
        return name
    }
}

/// One cell of the provider × event matrix.
///
/// `Codable` by hand rather than synthesised, because `Provider` is a domain
/// type and the domain owns no serialisation: `AgentBarCore` describes sessions,
/// not a settings file's schema, and a conformance added there would be this
/// module's format leaking into it. Encoding the raw values here keeps the
/// stored shape this module's business.
public struct EventPreference: Sendable, Hashable, Codable, Identifiable {
    public let provider: Provider
    public let event: NotificationEvent
    public var isEnabled: Bool
    public var sound: SoundSelection

    public var id: String { "\(provider.rawValue).\(event.rawValue)" }

    public init(
        provider: Provider, event: NotificationEvent, isEnabled: Bool, sound: SoundSelection
    ) {
        self.provider = provider
        self.event = event
        self.isEnabled = isEnabled
        self.sound = sound
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case event
        case isEnabled
        case sound
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let providerName = try container.decode(String.self, forKey: .provider)
        let eventName = try container.decode(String.self, forKey: .event)
        guard let provider = Provider(rawValue: providerName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .provider, in: container, debugDescription: "unknown provider")
        }
        guard let event = NotificationEvent(rawValue: eventName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: container, debugDescription: "unknown event")
        }
        self.provider = provider
        self.event = event
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        sound = try container.decode(SoundSelection.self, forKey: .sound)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider.rawValue, forKey: .provider)
        try container.encode(event.rawValue, forKey: .event)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(sound, forKey: .sound)
    }
}

/// A stretch of the day during which nothing is delivered.
///
/// Minutes from local midnight rather than a `Date`, because the window is a
/// property of the clock face and not of any particular day — and because a
/// stored `Date` would drift a year later.
public struct QuietHours: Sendable, Hashable, Codable {
    public static let minutesPerDay = 24 * 60

    public var isEnabled: Bool
    /// Inclusive, `0..<1440`.
    public var startMinute: Int
    /// Exclusive, `0..<1440`. May be **earlier** than `startMinute`, which is
    /// the ordinary case: quiet hours usually cross midnight.
    public var endMinute: Int

    public init(isEnabled: Bool = false, startMinute: Int = 22 * 60, endMinute: Int = 8 * 60) {
        self.isEnabled = isEnabled
        self.startMinute = Self.wrapped(startMinute)
        self.endMinute = Self.wrapped(endMinute)
    }

    /// Whether `date`'s local time falls inside the window.
    ///
    /// A zero-length window — start equal to end — is **never quiet**, not
    /// always quiet. Both readings are defensible from the numbers alone, and
    /// only one of them can silently swallow every notification AgentBar exists
    /// to deliver.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard isEnabled, startMinute != endMinute else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let now = hour * 60 + minute
        guard startMinute < endMinute else {
            // Crosses midnight: quiet from the start until 24:00, and from
            // 00:00 until the end.
            return now >= startMinute || now < endMinute
        }
        return now >= startMinute && now < endMinute
    }

    private static func wrapped(_ minute: Int) -> Int {
        let remainder = minute % minutesPerDay
        return remainder < 0 ? remainder + minutesPerDay : remainder
    }
}

/// An application whose being frontmost silences notifications.
public struct SuppressingApplication: Sendable, Hashable, Codable, Identifiable {
    public let bundleIdentifier: String
    /// Recorded when the app was chosen, so the list stays readable even if the
    /// application is later moved or uninstalled.
    public var name: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

/// Silence notifications while the user is already looking at one of these.
///
/// **Off by default, with an empty list.** A curated set of known editors and
/// terminals turned on out of the box would swallow the single signal the
/// product exists for, in the case that matters most: an agent finishing in one
/// project while the user works in another. AgentBar cannot tell which project a
/// frontmost window belongs to — nothing in a hook payload says so — so it does
/// not pretend to, and leaves the trade to the person who can see both.
public struct FocusSuppression: Sendable, Hashable, Codable {
    public var isEnabled: Bool
    public var applications: [SuppressingApplication]

    public init(isEnabled: Bool = false, applications: [SuppressingApplication] = []) {
        self.isEnabled = isEnabled
        self.applications = applications
    }

    public func suppresses(bundleIdentifier: String?) -> SuppressingApplication? {
        guard isEnabled, let bundleIdentifier else { return nil }
        return applications.first { $0.bundleIdentifier == bundleIdentifier }
    }
}

/// Everything the user gets to decide about notifications.
///
/// One `Codable` value, versioned, and read back defensively: a settings file
/// this version cannot understand degrades to the defaults rather than taking
/// the app down or — worse — silently disabling notifications.
public struct NotificationSettings: Sendable, Hashable, Codable {
    /// Bumped when a change cannot be expressed by adding an optional field.
    public static let currentVersion = 1

    public var version: Int
    /// The global switch. Off means AgentBar posts nothing at all, which is
    /// different from every event being disabled only in that it is one click.
    public var isEnabled: Bool
    public var preferences: [EventPreference]
    public var quietHours: QuietHours
    public var focusSuppression: FocusSuppression

    public init(
        version: Int = NotificationSettings.currentVersion,
        isEnabled: Bool = true,
        preferences: [EventPreference] = NotificationSettings.defaultPreferences,
        quietHours: QuietHours = QuietHours(),
        focusSuppression: FocusSuppression = FocusSuppression()
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.preferences = preferences
        self.quietHours = quietHours
        self.focusSuppression = focusSuppression
    }

    /// Every event on, every provider, each with the sound authored for it.
    ///
    /// The defaults name **bundled** sounds rather than macOS's own. A system
    /// sound is not in either location `UNNotificationSound` looks in, so
    /// defaulting to `Glass.aiff` would ship a matrix whose every cell silently
    /// falls back to the default sound — the exact failure this module is built
    /// to prevent. `SoundLibrary` offers copying a system sound into the user's
    /// own Sounds folder for anyone who wants one.
    public static var defaultPreferences: [EventPreference] {
        Provider.allCases.flatMap { provider in
            NotificationEvent.allCases.map { event in
                EventPreference(
                    provider: provider, event: event, isEnabled: true,
                    sound: .named(BundledSound.forEvent(event).fileName))
            }
        }
    }

    /// The cell for a provider and event, defaulted rather than optional.
    ///
    /// A settings file written before a provider existed has no row for it, and
    /// the honest answer to "should AgentBar notify about Codex?" in that case
    /// is the default — never silence.
    public func preference(
        for provider: Provider, event: NotificationEvent
    ) -> EventPreference {
        preferences.first { $0.provider == provider && $0.event == event }
            ?? EventPreference(
                provider: provider, event: event, isEnabled: true,
                sound: .named(BundledSound.forEvent(event).fileName))
    }

    public mutating func update(_ preference: EventPreference) {
        if let index = preferences.firstIndex(
            where: { $0.provider == preference.provider && $0.event == preference.event })
        {
            preferences[index] = preference
        } else {
            preferences.append(preference)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case isEnabled
        case preferences
        case quietHours
        case focusSuppression
    }

    /// Decoded row by row, so one unrecognised cell costs one cell.
    ///
    /// The synthesised conformance would fail the **whole** value on a single
    /// bad row — a provider a later AgentBar knows about and this one does not —
    /// and `load()` would then replace every preference the user had set with
    /// the defaults. Losing one row to a downgrade is survivable; losing the
    /// matrix is not. Every other field is optional for the same reason: a file
    /// missing a key reads as the default rather than as unreadable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        quietHours =
            try container.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? QuietHours()
        focusSuppression =
            try container.decodeIfPresent(FocusSuppression.self, forKey: .focusSuppression)
            ?? FocusSuppression()
        preferences =
            (try container.decodeIfPresent([LenientPreference].self, forKey: .preferences) ?? [])
            .compactMap(\.value)
    }

    /// A cell that decodes to nothing rather than throwing.
    ///
    /// The whole array still decodes, so the unkeyed container advances past a
    /// row this build cannot read instead of stalling on it.
    private struct LenientPreference: Decodable {
        let value: EventPreference?

        init(from decoder: any Decoder) throws {
            value = try? EventPreference(from: decoder)
        }
    }

    /// Fills in cells a stored file is missing.
    ///
    /// Rows this build could not read are already gone by the time this runs —
    /// see `init(from:)`. What it guarantees is that every provider and event
    /// this build knows about has a cell, defaulted rather than absent.
    public func completed() -> NotificationSettings {
        var result = self
        result.version = Self.currentVersion
        for provider in Provider.allCases {
            for event in NotificationEvent.allCases
            where !preferences.contains(where: { $0.provider == provider && $0.event == event }) {
                result.update(preference(for: provider, event: event))
            }
        }
        return result
    }
}

/// The sounds AgentBar ships in its own bundle.
///
/// Named here rather than discovered, because the defaults have to be
/// expressible before any filesystem has been read — and because a default
/// naming a file that is not in the bundle is a build mistake worth catching in
/// a test rather than at a user's first notification.
public enum BundledSound: String, Sendable, Hashable, CaseIterable {
    case question = "AgentBar Question"
    case waiting = "AgentBar Waiting"
    case finished = "AgentBar Finished"
    case failed = "AgentBar Failed"

    public static let fileExtension = "aiff"

    public var fileName: String { "\(rawValue).\(Self.fileExtension)" }

    public static func forEvent(_ event: NotificationEvent) -> BundledSound {
        switch event {
        case .question: .question
        case .waiting: .waiting
        case .finished: .finished
        case .failed: .failed
        }
    }
}

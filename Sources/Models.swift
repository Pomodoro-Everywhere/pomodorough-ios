import Foundation

struct SSERevisionParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> Int64? {
        if line.isEmpty {
            defer {
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
            }
            guard eventName == nil || eventName == "message" || eventName == "revision" else { return nil }
            let data = dataLines.joined(separator: "\n")
            guard !data.isEmpty else { return nil }
            if let raw = Int64(data.trimmingCharacters(in: .whitespacesAndNewlines)) { return raw }
            return (try? JSONDecoder().decode(RevisionEnvelope.self, from: Data(data.utf8)))?.revision
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            eventName = Self.fieldValue(line, prefixLength: 6)
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.fieldValue(line, prefixLength: 5))
        }
        return nil
    }

    private static func fieldValue(_ line: String, prefixLength: Int) -> String {
        var value = String(line.dropFirst(prefixLength))
        if value.first == " " { value.removeFirst() }
        return value
    }
}

struct RevisionHintCoalescer: Sendable {
    private var latestPendingRevision: Int64?

    mutating func receive(_ revision: Int64, localRevision: Int64, isSyncing: Bool) -> Bool {
        guard revision > localRevision else { return false }
        guard isSyncing else { return true }
        latestPendingRevision = max(latestPendingRevision ?? revision, revision)
        return false
    }

    mutating func consumeFollowUp(localRevision: Int64) -> Bool {
        defer { latestPendingRevision = nil }
        return latestPendingRevision.map { $0 > localRevision } ?? false
    }
}

struct RevisionStreamLifecycle: Sendable {
    private(set) var isActive = false
    private var currentID: UUID?

    mutating func setActive(_ active: Bool) {
        isActive = active
        if !active { currentID = nil }
    }

    mutating func begin() -> UUID? {
        guard isActive, currentID == nil else { return nil }
        let id = UUID()
        currentID = id
        return id
    }

    func owns(_ id: UUID?) -> Bool {
        isActive && id != nil && currentID == id
    }

    mutating func end(_ id: UUID) {
        if currentID == id { currentID = nil }
    }

    mutating func cancelCurrent() {
        currentID = nil
    }
}

struct SyncOwnership: Sendable {
    private var ownerID: UUID?
    private var requestedGeneration: Int?

    mutating func begin(generation: Int) -> UUID? {
        guard ownerID == nil else {
            requestedGeneration = max(requestedGeneration ?? generation, generation)
            return nil
        }
        let id = UUID()
        ownerID = id
        return id
    }

    mutating func invalidate() {
        ownerID = nil
        requestedGeneration = nil
    }

    mutating func finish(_ id: UUID, currentGeneration: Int) -> Bool? {
        guard ownerID == id else { return nil }
        ownerID = nil
        defer { requestedGeneration = nil }
        return requestedGeneration == currentGeneration
    }

    func isOwned(by id: UUID?) -> Bool {
        id != nil && ownerID == id
    }
}

enum RevisionStreamResponse {
    static func isValid(statusCode: Int, contentType: String?) -> Bool {
        guard statusCode == 200, let contentType else { return false }
        let mediaType = contentType.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return mediaType.caseInsensitiveCompare("text/event-stream") == .orderedSame
    }
}

private struct RevisionEnvelope: Decodable {
    let revision: Int64
}

struct User: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let name: String
    let avatarUrl: String
}

struct MeResponse: Codable, Sendable {
    let user: User
    let csrfToken: String
}

struct NativeChallenge: Codable, Sendable {
    let challenge: String
    let nonce: String
    let expiresAt: Date
}

struct TokenPair: Codable, Sendable {
    let accessToken: String
    let accessTokenExpiresAt: Date
    let refreshToken: String
    let refreshTokenExpiresAt: Date
}

struct NativeExchangeRequest: Encodable, Sendable {
    let idToken: String
    let challenge: String
    let deviceId: String
    let platform: String
}

struct RefreshRequest: Encodable, Sendable { let refreshToken: String }

enum TimerPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case focus
    case shortBreak = "short_break"
    case longBreak = "long_break"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    var routeLabel: String {
        switch self {
        case .focus: "Work"
        case .shortBreak: "Reset"
        case .longBreak: "Recover"
        }
    }

    var abbreviation: String {
        switch self {
        case .focus: "F"
        case .shortBreak: "SB"
        case .longBreak: "LB"
        }
    }

    var defaultMinutes: Int {
        switch self {
        case .focus: 25
        case .shortBreak: 5
        case .longBreak: 15
        }
    }
}

struct TimerSettings: Codable, Equatable, Sendable {
    var selectedPhase: TimerPhase = .focus
    var focusMinutes = TimerPhase.focus.defaultMinutes
    var shortBreakMinutes = TimerPhase.shortBreak.defaultMinutes
    var longBreakMinutes = TimerPhase.longBreak.defaultMinutes
    var autoStartBreaks = false

    func minutes(for phase: TimerPhase) -> Int {
        switch phase {
        case .focus: focusMinutes
        case .shortBreak: shortBreakMinutes
        case .longBreak: longBreakMinutes
        }
    }

    mutating func setMinutes(_ minutes: Int, for phase: TimerPhase) {
        let clamped = min(180, max(1, minutes))
        switch phase {
        case .focus: focusMinutes = clamped
        case .shortBreak: shortBreakMinutes = clamped
        case .longBreak: longBreakMinutes = clamped
        }
    }
}

enum CommandType: String, Codable, Sendable {
    case start, pause, resume, finish, cancel, clear
}

struct TimerCommand: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let deviceSequence: Int64
    let timerId: String
    let type: CommandType
    let phase: TimerPhase
    let plannedDurationMs: Int64
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64
    let observedElapsedMs: Int64
}

struct SyncRequest: Encodable, Sendable {
    let deviceId: String
    let lastRevision: Int64
    let commands: [TimerCommand]
}

struct Acknowledgement: Codable, Equatable, Sendable {
    let commandId: String
    let outcome: String
    let reason: String
}

struct TimerIntent: Codable, Equatable, Sendable {
    let type: CommandType
    let commandId: String
    let occurredAt: Date
}

struct CanonicalTimer: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case running, paused, completed, cancelled, superseded
    }

    let id: String
    let phase: TimerPhase
    let status: Status
    let plannedDurationMs: Int64
    let elapsedAtAnchorMs: Int64
    let anchorAt: Date
    let lastIntent: TimerIntent?

    var plannedDuration: TimeInterval { TimeInterval(plannedDurationMs) / 1_000 }

    func elapsed(at date: Date) -> TimeInterval {
        let anchored = TimeInterval(elapsedAtAnchorMs) / 1_000
        guard status == .running else { return min(plannedDuration, anchored) }
        return min(plannedDuration, anchored + max(0, date.timeIntervalSince(anchorAt)))
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, plannedDuration - elapsed(at: date))
    }
}

struct HistoryItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let timerId: String
    let commandId: String?
    let phase: TimerPhase
    let status: String
    let plannedDurationMs: Int64
    let completedAt: Date?
    let endedAt: Date?

    var date: Date? { completedAt ?? endedAt }
    var minutes: Int { max(1, Int((plannedDurationMs + 59_999) / 60_000)) }
}

struct SyncResponse: Decodable, Sendable {
    let acknowledgements: [Acknowledgement]
    let revision: Int64
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let serverTime: Date
    let serverHlcWallMs: Int64
}

struct HistoryResponse: Decodable, Sendable { let history: [HistoryItem] }

struct PersistedTimerState: Codable, Equatable, Sendable {
    var deviceId: String
    var nextSequence: Int64
    var revision: Int64
    var hlcWallMs: Int64
    var hlcCounter: Int64
    var pendingCommands: [TimerCommand]
    var canonicalTimer: CanonicalTimer?
    var history: [HistoryItem]
    var settings: TimerSettings
    var cachedUser: User?

    static func fresh() -> Self {
        Self(
            deviceId: "device-\(UUID().uuidString.lowercased())",
            nextSequence: 1,
            revision: 0,
            hlcWallMs: 0,
            hlcCounter: 0,
            pendingCommands: [],
            canonicalTimer: nil,
            history: [],
            settings: TimerSettings(),
            cachedUser: nil
        )
    }

    mutating func prepare(for authenticatedUser: User) {
        if let previousUser = cachedUser, previousUser.id != authenticatedUser.id {
            let existingDeviceID = deviceId
            let existingSettings = settings
            self = .fresh()
            deviceId = existingDeviceID
            settings = existingSettings
        }
        cachedUser = authenticatedUser
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, nextSequence, revision, hlcWallMs, hlcCounter
        case pendingCommands, canonicalTimer, history, settings, cachedUser
    }

    init(
        deviceId: String,
        nextSequence: Int64,
        revision: Int64,
        hlcWallMs: Int64,
        hlcCounter: Int64,
        pendingCommands: [TimerCommand],
        canonicalTimer: CanonicalTimer?,
        history: [HistoryItem],
        settings: TimerSettings,
        cachedUser: User?
    ) {
        self.deviceId = deviceId
        self.nextSequence = nextSequence
        self.revision = revision
        self.hlcWallMs = hlcWallMs
        self.hlcCounter = hlcCounter
        self.pendingCommands = pendingCommands
        self.canonicalTimer = canonicalTimer
        self.history = history
        self.settings = settings
        self.cachedUser = cachedUser
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        nextSequence = try values.decode(Int64.self, forKey: .nextSequence)
        revision = try values.decode(Int64.self, forKey: .revision)
        hlcWallMs = try values.decodeIfPresent(Int64.self, forKey: .hlcWallMs) ?? 0
        hlcCounter = try values.decodeIfPresent(Int64.self, forKey: .hlcCounter) ?? 0
        pendingCommands = try values.decode([TimerCommand].self, forKey: .pendingCommands)
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        settings = try values.decodeIfPresent(TimerSettings.self, forKey: .settings) ?? TimerSettings()
        cachedUser = try values.decodeIfPresent(User.self, forKey: .cachedUser)
    }
}

enum TimerReducer {
    static func breakPhase(afterCompletedFocusCount count: Int) -> TimerPhase {
        count > 0 && count.isMultiple(of: 4) ? .longBreak : .shortBreak
    }

    static func applying(
        _ commands: [TimerCommand],
        to canonical: CanonicalTimer?,
        history canonicalHistory: [HistoryItem]
    ) -> (timer: CanonicalTimer?, history: [HistoryItem]) {
        commands.sorted { $0.deviceSequence < $1.deviceSequence }.reduce(into: (canonical, canonicalHistory)) { result, command in
            result = apply(command, to: result.0, history: result.1)
        }
    }

    static func apply(
        _ command: TimerCommand,
        to timer: CanonicalTimer?,
        history: [HistoryItem]
    ) -> (CanonicalTimer?, [HistoryItem]) {
        let intent = TimerIntent(type: command.type, commandId: command.id, occurredAt: command.occurredAt)
        switch command.type {
        case .start:
            return (
                CanonicalTimer(
                    id: command.timerId,
                    phase: command.phase,
                    status: .running,
                    plannedDurationMs: command.plannedDurationMs,
                    elapsedAtAnchorMs: 0,
                    anchorAt: command.occurredAt,
                    lastIntent: intent
                ),
                history
            )
        case .pause:
            guard let timer, timer.id == command.timerId, timer.status == .running else { return (timer, history) }
            return (updated(timer, status: .paused, elapsed: command.observedElapsedMs, at: command.occurredAt, intent: intent), history)
        case .resume:
            guard let timer, timer.id == command.timerId, timer.status == .paused else { return (timer, history) }
            return (updated(timer, status: .running, elapsed: command.observedElapsedMs, at: command.occurredAt, intent: intent), history)
        case .finish:
            guard let timer, timer.id == command.timerId, timer.status == .running || timer.status == .paused else { return (timer, history) }
            let finished = updated(timer, status: .completed, elapsed: timer.plannedDurationMs, at: command.occurredAt, intent: intent)
            guard !history.contains(where: { $0.commandId == command.id }) else { return (finished, history) }
            let item = HistoryItem(
                id: command.timerId,
                timerId: command.timerId,
                commandId: command.id,
                phase: command.phase,
                status: "completed",
                plannedDurationMs: command.plannedDurationMs,
                completedAt: command.occurredAt,
                endedAt: nil
            )
            return (finished, [item] + history)
        case .cancel:
            guard let timer, timer.id == command.timerId, timer.status == .running || timer.status == .paused else { return (timer, history) }
            let cancelled = updated(timer, status: .cancelled, elapsed: command.observedElapsedMs, at: command.occurredAt, intent: intent)
            guard !history.contains(where: { $0.commandId == command.id }) else { return (cancelled, history) }
            let item = HistoryItem(
                id: command.timerId,
                timerId: command.timerId,
                commandId: command.id,
                phase: command.phase,
                status: "cancelled",
                plannedDurationMs: command.plannedDurationMs,
                completedAt: nil,
                endedAt: command.occurredAt
            )
            return (cancelled, [item] + history)
        case .clear:
            guard let timer, timer.id == command.timerId, timer.status != .running, timer.status != .paused else { return (timer, history) }
            return (nil, history)
        }
    }

    private static func updated(
        _ timer: CanonicalTimer,
        status: CanonicalTimer.Status,
        elapsed: Int64,
        at date: Date,
        intent: TimerIntent
    ) -> CanonicalTimer {
        CanonicalTimer(
            id: timer.id,
            phase: timer.phase,
            status: status,
            plannedDurationMs: timer.plannedDurationMs,
            elapsedAtAnchorMs: min(timer.plannedDurationMs, max(0, elapsed)),
            anchorAt: date,
            lastIntent: intent
        )
    }
}

enum AppError: LocalizedError {
    case configuration
    case missingPresentationAnchor
    case missingIDToken
    case unauthorized
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .configuration: "Google Sign-In is not configured for this build."
        case .missingPresentationAnchor: "No window is available for Google Sign-In."
        case .missingIDToken: "Google did not return an identity token."
        case .unauthorized: "Session expired. Sign in again."
        case .server(let message): message
        case .invalidResponse: "Server returned an invalid response."
        }
    }
}

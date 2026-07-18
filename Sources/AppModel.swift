import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum SessionState: Equatable {
        case restoring
        case signedOut
        case signedIn(User)
    }

    private let api: APIClient
    private let defaults: UserDefaults
    private var timerState: PersistedTimerState
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var completionQueuedFor: String?
    @ObservationIgnored private var sessionGeneration = 0

    private(set) var sessionState: SessionState = .restoring
    private(set) var canonicalTimer: CanonicalTimer?
    private(set) var history: [HistoryItem] = []
    private(set) var isWorking = false
    private(set) var isSyncing = false
    private(set) var conflictMessage: String?
    var errorMessage: String?

    init(api: APIClient = APIClient(), defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        let storedData = defaults.data(forKey: Self.storageKey) ?? defaults.data(forKey: "timer-state")
        if let data = storedData,
           let state = try? JSONDecoder.api.decode(PersistedTimerState.self, from: data) {
            timerState = state
        } else {
            timerState = .fresh()
        }
        rebuildOptimisticState()
    }

    deinit { retryTask?.cancel() }

    var isSignedIn: Bool {
        if case .signedIn = sessionState { true } else { false }
    }

    var user: User? {
        if case .signedIn(let user) = sessionState { user } else { nil }
    }

    var selectedPhase: TimerPhase {
        get { timerState.settings.selectedPhase }
        set {
            guard !isTimerActive else { return }
            timerState.settings.selectedPhase = newValue
            persist()
        }
    }

    var autoStartBreaks: Bool {
        get { timerState.settings.autoStartBreaks }
        set {
            timerState.settings.autoStartBreaks = newValue
            persist()
        }
    }

    var isTimerActive: Bool {
        canonicalTimer?.status == .running || canonicalTimer?.status == .paused
    }

    var pendingCommandCount: Int { timerState.pendingCommands.count }
    var completedFocusCount: Int { history.count { $0.status == "completed" && $0.phase == .focus } }
    var deviceMark: String { String(timerState.deviceId.suffix(4)).uppercased() }

    var syncLabel: String {
        if isSyncing { return "Syncing" }
        if conflictMessage != nil { return "Review conflict" }
        if pendingCommandCount > 0 { return "\(pendingCommandCount) queued" }
        return "In sync"
    }

    func durationMinutes(for phase: TimerPhase) -> Int { timerState.settings.minutes(for: phase) }

    func setDurationMinutes(_ minutes: Int, for phase: TimerPhase) {
        guard !isTimerActive else { return }
        timerState.settings.setMinutes(minutes, for: phase)
        persist()
    }

    func restore() async {
        guard sessionState == .restoring else { return }
        let generation = sessionGeneration
        do {
            guard try await api.restoreTokens() else {
                guard generation == sessionGeneration else { return }
                sessionState = .signedOut
                return
            }
            guard generation == sessionGeneration else { return }
            if let cachedUser = timerState.cachedUser {
                sessionState = .signedIn(cachedUser)
            }
            let response = try await api.me()
            guard generation == sessionGeneration else { return }
            timerState.prepare(for: response.user)
            sessionState = .signedIn(response.user)
            persist()
            await sync(force: true)
        } catch AppError.unauthorized {
            guard generation == sessionGeneration else { return }
            try? await api.clearTokens()
            sessionState = .signedOut
        } catch {
            guard generation == sessionGeneration else { return }
            if timerState.cachedUser == nil { sessionState = .signedOut }
            errorMessage = "Working locally. \(error.localizedDescription)"
            scheduleRetry()
        }
    }

    func signIn() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let challenge = try await api.challenge()
                let idToken = try await GoogleAuthService.identityToken(nonce: challenge.nonce)
                let me = try await api.exchange(
                    NativeExchangeRequest(
                        idToken: idToken,
                        challenge: challenge.challenge,
                        deviceId: timerState.deviceId,
                        platform: Self.platform
                    )
                )
                timerState.prepare(for: me.user)
                sessionState = .signedIn(me.user)
                persist()
                await sync(force: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func signOut() {
        guard !isWorking else { return }
        sessionGeneration += 1
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await api.logout() } catch { try? await api.clearTokens() }
            GoogleAuthService.signOut()
            retryTask?.cancel()
            timerState = .fresh()
            rebuildOptimisticState()
            persist()
            sessionState = .signedOut
        }
    }

    func start() {
        let minutes = durationMinutes(for: selectedPhase)
        enqueue(
            .start,
            timerID: "timer-\(UUID().uuidString.lowercased())",
            phase: selectedPhase,
            duration: TimeInterval(minutes * 60),
            elapsed: 0
        )
    }

    func pause(at date: Date = .now) {
        guard let timer = canonicalTimer else { return }
        enqueue(.pause, timer: timer, elapsed: timer.elapsed(at: date))
    }

    func resume(at date: Date = .now) {
        guard let timer = canonicalTimer else { return }
        enqueue(.resume, timer: timer, elapsed: timer.elapsed(at: date))
    }

    func finish(at date: Date = .now) {
        guard let timer = canonicalTimer else { return }
        let finishedPhase = timer.phase
        enqueue(.finish, timer: timer, elapsed: timer.elapsed(at: date))
        guard finishedPhase == .focus, autoStartBreaks else { return }
        selectedPhase = nextBreakPhase()
        start()
    }

    func cancel(at date: Date = .now) {
        guard let timer = canonicalTimer else { return }
        enqueue(.cancel, timer: timer, elapsed: timer.elapsed(at: date))
    }

    func clear() {
        guard let timer = canonicalTimer, !isTimerActive else { return }
        enqueue(.clear, timer: timer, elapsed: timer.elapsed(at: .now))
    }

    func completeIfNeeded(timerID: String, at date: Date) {
        guard let timer = canonicalTimer,
              timer.id == timerID,
              timer.status == .running,
              timer.remaining(at: date) <= 0,
              completionQueuedFor != timer.id else { return }
        completionQueuedFor = timer.id
        finish(at: date)
    }

    func dismissConflict() { conflictMessage = nil }

    func sync(force: Bool = false) async {
        guard isSignedIn, !isSyncing else { return }
        let generation = sessionGeneration
        if !force, timerState.pendingCommands.isEmpty { return }
        retryTask?.cancel()
        isSyncing = true
        defer { isSyncing = false }
        do {
            repeat {
                let batch = Array(timerState.pendingCommands.prefix(256))
                let response = try await api.sync(
                    SyncRequest(
                        deviceId: timerState.deviceId,
                        lastRevision: timerState.revision,
                        commands: batch
                    )
                )
                guard generation == sessionGeneration, isSignedIn else { return }

                let sentIDs = Set(batch.map(\.id))
                let acknowledgedIDs = Set(response.acknowledgements.map(\.commandId))
                guard sentIDs == acknowledgedIDs else { throw AppError.invalidResponse }
                timerState.pendingCommands.removeAll { acknowledgedIDs.contains($0.id) }
                if let conflict = response.acknowledgements.first(where: { $0.outcome != "applied" }) {
                    conflictMessage = conflict.reason.isEmpty ? "Server resolved a timer action as \(conflict.outcome)." : conflict.reason
                }
                timerState.revision = response.revision
                timerState.canonicalTimer = response.canonicalTimer
                timerState.history = response.history
                mergeServerClock(response.serverHlcWallMs)
                rebuildOptimisticState()
                persist()
            } while !timerState.pendingCommands.isEmpty
        } catch AppError.unauthorized {
            guard generation == sessionGeneration else { return }
            try? await api.clearTokens()
            sessionState = .signedOut
            errorMessage = AppError.unauthorized.localizedDescription
        } catch {
            guard generation == sessionGeneration, isSignedIn else { return }
            errorMessage = "Working locally. \(error.localizedDescription)"
            scheduleRetry()
        }
    }

    func refreshAfterForeground() async {
        guard isSignedIn else { return }
        completionQueuedFor = nil
        await sync(force: true)
    }

    func nextBreakPhase() -> TimerPhase {
        TimerReducer.breakPhase(afterCompletedFocusCount: completedFocusCount)
    }

    private func enqueue(_ type: CommandType, timer: CanonicalTimer, elapsed: TimeInterval) {
        enqueue(
            type,
            timerID: timer.id,
            phase: timer.phase,
            duration: timer.plannedDuration,
            elapsed: elapsed
        )
    }

    private func enqueue(
        _ type: CommandType,
        timerID: String,
        phase: TimerPhase,
        duration: TimeInterval,
        elapsed: TimeInterval
    ) {
        let now = Date.now
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        if nowMs > timerState.hlcWallMs {
            timerState.hlcWallMs = nowMs
            timerState.hlcCounter = 0
        } else {
            timerState.hlcCounter += 1
        }
        let command = TimerCommand(
            id: "command-\(UUID().uuidString.lowercased())",
            deviceSequence: timerState.nextSequence,
            timerId: timerID,
            type: type,
            phase: phase,
            plannedDurationMs: Int64(duration * 1_000),
            occurredAt: now,
            hlcWallMs: timerState.hlcWallMs,
            hlcCounter: timerState.hlcCounter,
            observedElapsedMs: Int64(max(0, elapsed) * 1_000)
        )
        timerState.nextSequence += 1
        timerState.pendingCommands.append(command)
        rebuildOptimisticState()
        persist()
        Task { await sync() }
    }

    private func rebuildOptimisticState() {
        let result = TimerReducer.applying(
            timerState.pendingCommands,
            to: timerState.canonicalTimer,
            history: timerState.history
        )
        canonicalTimer = result.timer
        history = result.history
        if canonicalTimer?.status != .running { completionQueuedFor = nil }
    }

    private func mergeServerClock(_ serverWallMs: Int64) {
        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        let merged = max(nowMs, serverWallMs, timerState.hlcWallMs)
        timerState.hlcCounter = merged == timerState.hlcWallMs ? timerState.hlcCounter : 0
        timerState.hlcWallMs = merged
    }

    private func scheduleRetry() {
        guard retryTask == nil || retryTask?.isCancelled == true else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            await self.sync()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder.api.encode(timerState) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static let storageKey = "timer-state-v2"

    private static var platform: String {
#if os(iOS)
        "ios"
#else
        "macos"
#endif
    }
}

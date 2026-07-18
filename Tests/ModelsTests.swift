import Foundation
import Testing
@testable import Pomodorough

struct ModelsTests {
    private let anchor = Date(timeIntervalSince1970: 1_000)

    @Test func runningTimerClampsAtPlannedDuration() {
        let timer = makeTimer(status: .running, elapsed: 50_000)
        #expect(timer.elapsed(at: anchor.addingTimeInterval(20)) == 60)
        #expect(timer.remaining(at: anchor.addingTimeInterval(20)) == 0)
    }

    @Test func pausedTimerDoesNotAdvance() {
        let timer = makeTimer(status: .paused, elapsed: 15_000)
        #expect(timer.elapsed(at: anchor.addingTimeInterval(20)) == 15)
    }

    @Test func settingsClampDurationsToAPIContract() {
        var settings = TimerSettings()
        settings.setMinutes(0, for: .focus)
        settings.setMinutes(999, for: .longBreak)
        #expect(settings.minutes(for: .focus) == 1)
        #expect(settings.minutes(for: .longBreak) == 180)
    }

    @Test func reducerOptimisticallyRunsPausesAndFinishes() {
        let start = command(.start, sequence: 1, elapsed: 0)
        let pause = command(.pause, sequence: 2, elapsed: 12_000)
        let finish = command(.finish, sequence: 3, elapsed: 12_000)
        let result = TimerReducer.applying([finish, start, pause], to: nil, history: [])
        #expect(result.timer?.status == .completed)
        #expect(result.timer?.elapsedAtAnchorMs == 60_000)
        #expect(result.history.count == 1)
        #expect(result.history.first?.status == "completed")
    }

    @Test func accountChangeClearsAccountDataButKeepsDevicePreferences() {
        var state = PersistedTimerState.fresh()
        let deviceID = state.deviceId
        state.settings.focusMinutes = 42
        state.cachedUser = User(id: String(repeating: "a", count: 32), email: "a@example.com", name: "A", avatarUrl: "")
        state.pendingCommands = [command(.start, sequence: 1, elapsed: 0)]
        state.canonicalTimer = makeTimer(status: .running, elapsed: 0)

        let newUser = User(id: String(repeating: "b", count: 32), email: "b@example.com", name: "B", avatarUrl: "")
        state.prepare(for: newUser)

        #expect(state.deviceId == deviceID)
        #expect(state.settings.focusMinutes == 42)
        #expect(state.cachedUser == newUser)
        #expect(state.pendingCommands.isEmpty)
        #expect(state.canonicalTimer == nil)
    }

    @Test func cancelAddsOptimisticHistory() {
        let running = makeTimer(status: .running, elapsed: 5_000)
        let cancel = command(.cancel, sequence: 2, elapsed: 5_000)
        let result = TimerReducer.apply(cancel, to: running, history: [])

        #expect(result.0?.status == .cancelled)
        #expect(result.1.count == 1)
        #expect(result.1.first?.status == "cancelled")
        #expect(result.1.first?.endedAt == cancel.occurredAt)
    }

    @Test func clearOnlyRemovesInactiveTimer() {
        let running = makeTimer(status: .running, elapsed: 5_000)
        let clear = command(.clear, sequence: 2, elapsed: 5_000)
        #expect(TimerReducer.apply(clear, to: running, history: []).0 != nil)
        let completed = makeTimer(status: .completed, elapsed: 60_000)
        #expect(TimerReducer.apply(clear, to: completed, history: []).0 == nil)
    }

    @Test func longBreakFollowsEveryFourthCompletedFocus() {
        #expect(TimerReducer.breakPhase(afterCompletedFocusCount: 3) == .shortBreak)
        #expect(TimerReducer.breakPhase(afterCompletedFocusCount: 4) == .longBreak)
        #expect(TimerReducer.breakPhase(afterCompletedFocusCount: 8) == .longBreak)
    }

    @Test func persistedStateBackfillsNewSettingsAndClockFields() throws {
        let json = """
        {"deviceId":"device-test0001","nextSequence":1,"revision":0,"pendingCommands":[],"canonicalTimer":null,"history":[]}
        """.data(using: .utf8)!
        let state = try JSONDecoder.api.decode(PersistedTimerState.self, from: json)
        #expect(state.settings.focusMinutes == 25)
        #expect(state.hlcWallMs == 0)
        #expect(state.cachedUser == nil)
    }

    private func makeTimer(status: CanonicalTimer.Status, elapsed: Int64) -> CanonicalTimer {
        CanonicalTimer(
            id: "timer-test0001",
            phase: .focus,
            status: status,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: elapsed,
            anchorAt: anchor,
            lastIntent: nil
        )
    }

    private func command(_ type: CommandType, sequence: Int64, elapsed: Int64) -> TimerCommand {
        TimerCommand(
            id: "command-test\(sequence)",
            deviceSequence: sequence,
            timerId: "timer-test0001",
            type: type,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: anchor.addingTimeInterval(Double(sequence)),
            hlcWallMs: Int64(anchor.timeIntervalSince1970 * 1_000) + sequence,
            hlcCounter: 0,
            observedElapsedMs: elapsed
        )
    }
}

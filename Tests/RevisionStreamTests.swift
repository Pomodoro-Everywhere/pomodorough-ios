import Foundation
import Testing
@testable import Pomodorough

struct RevisionStreamTests {
    @Test func parserEmitsNamedJSONRevisionEvent() {
        var parser = SSERevisionParser()

        #expect(parser.consume(line: "event: revision") == nil)
        #expect(parser.consume(line: "data: {\"revision\":42}") == nil)
        #expect(parser.consume(line: "") == 42)
    }

    @Test func parserAcceptsPlainRevisionMessageAndIgnoresKeepalive() {
        var parser = SSERevisionParser()

        #expect(parser.consume(line: ": keepalive") == nil)
        #expect(parser.consume(line: "") == nil)
        #expect(parser.consume(line: "data: 17") == nil)
        #expect(parser.consume(line: "") == 17)
    }

    @Test func revisionHintDuringSyncIsCoalescedForFollowUp() {
        var hints = RevisionHintCoalescer()

        #expect(hints.receive(12, localRevision: 10, isSyncing: true) == false)
        #expect(hints.consumeFollowUp(localRevision: 10) == true)
        #expect(hints.consumeFollowUp(localRevision: 12) == false)
    }

    @Test func currentOrOlderRevisionDoesNotTriggerSync() {
        var hints = RevisionHintCoalescer()

        #expect(hints.receive(9, localRevision: 10, isSyncing: false) == false)
        #expect(hints.receive(10, localRevision: 10, isSyncing: false) == false)
        #expect(hints.receive(11, localRevision: 10, isSyncing: false) == true)
    }

    @Test func suspendedStreamCannotBeReclaimedByStaleTask() {
        var lifecycle = RevisionStreamLifecycle()
        lifecycle.setActive(true)
        let staleID = lifecycle.begin()

        lifecycle.setActive(false)
        #expect(lifecycle.owns(staleID) == false)
        #expect(lifecycle.begin() == nil)

        lifecycle.setActive(true)
        let currentID = lifecycle.begin()
        #expect(currentID != nil)
        #expect(currentID != staleID)
        #expect(lifecycle.owns(staleID) == false)
        #expect(lifecycle.owns(currentID) == true)
    }

    @Test func streamResponseRequiresSuccessfulSSEContentType() {
        #expect(RevisionStreamResponse.isValid(statusCode: 200, contentType: "text/event-stream; charset=utf-8"))
        #expect(!RevisionStreamResponse.isValid(statusCode: 204, contentType: "text/event-stream"))
        #expect(!RevisionStreamResponse.isValid(statusCode: 200, contentType: "application/json"))
        #expect(!RevisionStreamResponse.isValid(statusCode: 200, contentType: "application/text/event-stream+json"))
        #expect(!RevisionStreamResponse.isValid(statusCode: 200, contentType: "text/event-stream-invalid"))
        #expect(!RevisionStreamResponse.isValid(statusCode: 200, contentType: nil))
    }

    @Test func staleSyncCannotClearNewSessionOwnership() {
        var ownership = SyncOwnership()
        let oldSync = ownership.begin(generation: 1)
        #expect(oldSync != nil)

        ownership.invalidate()
        let newSync = ownership.begin(generation: 2)
        #expect(newSync != nil)
        #expect(ownership.finish(oldSync!, currentGeneration: 2) == nil)
        #expect(ownership.isOwned(by: newSync))

        #expect(ownership.begin(generation: 2) == nil)
        #expect(ownership.finish(newSync!, currentGeneration: 2) == true)
    }

    @Test func foregroundPollingIsFasterForActiveTimers() {
        #expect(RemotePolling.interval(isTimerActive: true) == 2)
        #expect(RemotePolling.interval(isTimerActive: false) == 5)
    }
}

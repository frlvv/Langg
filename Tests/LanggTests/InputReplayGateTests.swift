import CoreGraphics
import Testing
@testable import Langg

@MainActor @Suite struct InputReplayGateTests {
    @MainActor private final class Harness {
        var posted: [CGEvent] = []
        var logical: [CGEventType] = []
        var keys: [Int64] = []
        lazy var gate = InputReplayGate(poster: { [weak self] in self?.posted.append($0) })

        @discardableResult func route(_ event: CGEvent, handling: (() -> Void)? = nil) -> Bool {
            let replay = gate.prepareIncoming(event)
            defer { gate.finishIncoming(replay) }
            if gate.shouldBuffer(event, replay: replay) { return true }
            logical.append(event.type)
            keys.append(event.getIntegerValueField(.keyboardEventKeycode))
            handling?()
            return false
        }

        func deliverNext(handling: (() -> Void)? = nil) {
            let event = posted.removeFirst()
            route(event, handling: handling)
        }
    }

    private func key(_ code: CGKeyCode, down: Bool = true) throws -> CGEvent {
        try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
    }

    @Test func replayPreservesPressReleaseOrderAndCannotBeOvertaken() throws {
        let harness = Harness()
        #expect(harness.gate.begin())
        #expect(!harness.gate.begin())
        #expect(harness.route(try key(12)))
        #expect(harness.route(try key(12, down: false)))
        #expect(harness.logical.isEmpty)
        harness.gate.end()
        #expect(harness.gate.isReplaying)
        #expect(!harness.gate.begin())
        #expect(harness.posted.map(\.type) == [.keyDown, .keyUp])

        // A new physical press arrived after posting, but before replay came
        // back through the tap. It must follow the original release.
        #expect(harness.route(try key(13)))
        let freshRelease = try key(13, down: false)
        harness.deliverNext()
        #expect(harness.logical == [.keyDown])
        #expect(harness.posted.count == 1)
        harness.deliverNext {
            #expect(harness.logical == [.keyDown, .keyUp])
            #expect(!harness.gate.canBegin)
            #expect(harness.posted.isEmpty)
            // A keyUp during the last logical handler also belongs to the
            // next batch, so it cannot escape ahead of its buffered press.
            #expect(harness.route(freshRelease))
        }
        #expect(harness.posted.map(\.type) == [.keyDown, .keyUp])
        #expect(!harness.gate.canBegin)
        harness.deliverNext()
        harness.deliverNext { #expect(!harness.gate.begin()) }
        #expect(harness.logical == [.keyDown, .keyUp, .keyDown, .keyUp])
        #expect(harness.keys == [12, 12, 13, 13])
        #expect(harness.posted.isEmpty)
        #expect(!harness.gate.isReplaying)
        #expect(harness.gate.begin())
    }

    @Test func copiesTheWholeEventAndRestoresOriginalUserData() throws {
        var posted: [CGEvent] = []
        let gate = InputReplayGate(poster: { posted.append($0) })
        let event = try key(0)
        event.flags = [.maskShift, .maskAlternate]
        event.timestamp = 123_456_789
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: 42)
        let units: [UniChar] = [0x044F]
        units.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
        }
        #expect(gate.begin())
        #expect(gate.shouldBuffer(event))
        event.flags = []
        event.setIntegerValueField(.keyboardEventKeycode, value: 99)
        gate.end()
        let replay = try #require(posted.first)
        #expect(replay !== event)
        #expect(replay.flags == [.maskShift, .maskAlternate])
        #expect(replay.timestamp == 123_456_789)
        #expect(replay.getIntegerValueField(.keyboardEventKeycode) == 0)
        #expect(replay.getIntegerValueField(.keyboardEventAutorepeat) == 1)
        #expect(!TextAccess.isReplacementEvent(replay))
        let markerBeforeUnicode = replay.getIntegerValueField(.eventSourceUserData)
        #expect(markerBeforeUnicode == 0x4C414E4700000001)
        var length = 0
        var unicode: [UniChar] = [0]
        replay.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &length, unicodeString: &unicode)
        #expect(length == 1)
        #expect(unicode == units)
        #expect(replay.getIntegerValueField(.eventSourceUserData) == markerBeforeUnicode)
        let token = try #require(gate.prepareIncoming(replay))
        #expect(replay.getIntegerValueField(.eventSourceUserData) == 42)
        #expect(!gate.shouldBuffer(replay, replay: token))
        #expect(!gate.canBegin)
        gate.finishIncoming(token)
        #expect(gate.canBegin)
        gate.finishIncoming(token)
        #expect(gate.canBegin)
    }

    @Test func overflowRequestsCleanupOnceAndReleasesOnlyAfterEnd() throws {
        var posted: [CGEvent] = []
        var cancellations = 0
        let gate = InputReplayGate(bufferLimit: 2, onOverflow: { cancellations += 1 },
                                   poster: { posted.append($0) })
        #expect(gate.begin())
        for code: CGKeyCode in [0, 1, 2, 3, 4] { #expect(gate.shouldBuffer(try key(code))) }
        #expect(cancellations == 1)
        #expect(posted.isEmpty)
        #expect(!gate.isReplaying)
        gate.end()
        #expect(posted.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [0, 1, 2, 3, 4])
        for event in posted {
            let token = gate.prepareIncoming(event)
            #expect(token != nil)
            gate.finishIncoming(token)
        }
        #expect(gate.canBegin)
    }

    @Test func resetDoesNotLoseReleaseOrRepostInflightEvents() throws {
        let harness = Harness()
        var drained = 0
        harness.gate.onDrained = { drained += 1 }
        #expect(harness.gate.begin())
        #expect(harness.route(try key(7)))
        harness.gate.reset()
        harness.gate.reset()
        #expect(harness.posted.count == 1)
        #expect(harness.route(try key(7, down: false)))
        harness.deliverNext()
        #expect(harness.posted.count == 1)
        #expect(harness.posted.first?.type == .keyUp)
        harness.gate.reset()
        #expect(harness.posted.count == 1)
        harness.deliverNext()
        #expect(harness.logical == [.keyDown, .keyUp])
        #expect(drained == 1)
        #expect(harness.gate.canBegin)
    }

    @Test(arguments: [CGEventType.flagsChanged, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                      .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                      .otherMouseDown, .otherMouseUp, .otherMouseDragged])
    func buffersModifiersAndCompleteMouseGestures(type: CGEventType) throws {
        var posted: [CGEvent] = []
        let gate = InputReplayGate(poster: { posted.append($0) })
        let event = try #require(CGEvent(source: nil))
        event.type = type
        event.location = CGPoint(x: 123, y: 456)
        event.setIntegerValueField(.mouseEventClickState, value: 2)
        #expect(gate.begin())
        #expect(gate.shouldBuffer(event))
        gate.end()
        let replay = try #require(posted.first)
        #expect(replay.type == type)
        #expect(replay.location == CGPoint(x: 123, y: 456))
        if type != .flagsChanged { #expect(replay.getIntegerValueField(.mouseEventClickState) == 2) }
    }

    @Test func replacementEventsPassAndAnEmptySectionNeedsNoDrain() throws {
        let harness = Harness()
        var drained = 0
        harness.gate.onDrained = { drained += 1 }
        let ordinary = try key(1)
        #expect(!harness.route(ordinary))
        #expect(harness.gate.begin())
        let replacement = try key(0)
        replacement.setIntegerValueField(.eventSourceUserData, value: 0x4C414E4747544558)
        #expect(!harness.gate.shouldBuffer(replacement))
        harness.gate.end()
        #expect(harness.posted.isEmpty)
        #expect(harness.gate.canBegin)
        #expect(drained == 1)
    }

    @Test func lostTapWaitsForSelectionCleanupBeforeReleasingUnmarkedInput() throws {
        let harness = Harness()
        #expect(harness.gate.begin())
        #expect(harness.route(try key(7)))
        harness.gate.didLoseTap()
        #expect(harness.route(try key(7, down: false)))
        #expect(harness.posted.isEmpty)
        #expect(!harness.gate.canBegin)
        harness.gate.end()
        #expect(harness.gate.canBegin)
        #expect(harness.posted.map(\.type) == [.keyDown, .keyUp])
        #expect(harness.posted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 0 })
        harness.gate.didLoseTap()
        harness.gate.reset()
        #expect(harness.posted.count == 2)
    }

    @Test func lostTapDoesNotPostAlreadyDispatchedEventsTwice() throws {
        let harness = Harness()
        var drained = 0
        harness.gate.onDrained = { drained += 1 }
        #expect(harness.gate.begin())
        #expect(harness.route(try key(6)))
        harness.gate.end()
        #expect(harness.posted.count == 1)
        #expect(harness.route(try key(6, down: false)))
        harness.gate.didLoseTap()
        #expect(harness.posted.count == 2)
        #expect(harness.posted[1].type == .keyUp)
        #expect(harness.posted[1].getIntegerValueField(.eventSourceUserData) == 0)
        #expect(harness.gate.canBegin)
        #expect(drained == 1)
        // If an already posted event eventually reaches the reconnected tap,
        // its retired marker is still stripped and cannot finish a newer drain.
        harness.deliverNext()
        harness.deliverNext()
        #expect(harness.logical == [.keyDown, .keyUp])
        #expect(harness.posted.isEmpty)
        #expect(drained == 1)
    }
}

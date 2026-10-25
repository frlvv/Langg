import CoreGraphics
import Foundation

/// Holds input while an AX transaction temporarily owns the selection.
/// Keep the event tap alive until `canBegin` becomes true after `end`/`reset`.
@MainActor final class InputReplayGate {
    struct ReplayToken {
        fileprivate let marker: Int64
    }

    private struct ReplayRecord {
        let originalUserData: Int64
        let pressID: UInt64?
    }

    private struct HeldEvent {
        let event: CGEvent
        let pressID: UInt64?
    }

    private struct PhysicalPress {
        let id: UInt64
        var heldDowns: Int
    }

    private let bufferLimit: Int
    private let poster: @MainActor (CGEvent) -> Void
    var onOverflow: (@MainActor () -> Void)?
    var onDrained: (@MainActor () -> Void)?

    private var isCritical = false
    private var criticalBeganAt: TimeInterval?
    private var overflowReported = false
    private var pending: [HeldEvent] = []
    private var physicalPresses: [Int64: PhysicalPress] = [:]
    private var nextPressID: UInt64 = 0
    private var inFlight: [Int64: ReplayRecord] = [:]
    private var retired: [Int64: ReplayRecord] = [:]
    private var lastMarker: Int64?
    private var tapLost = false
    // LANG + a sequence number; deliberately distinct from LANGGTEX.
    private var nextMarker: Int64 = 0x4C414E4700000000

    private(set) var isReplaying = false
    var canBegin: Bool { !isCritical && !isReplaying }

    /// Prepare the entire held batch before changing its input source. Neither
    /// closure may suspend or reenter this gate; input remains held throughout.
    @discardableResult func changeInputSource(transform: (CGEvent) -> CGEvent?, select: () -> Bool) -> Bool {
        guard isCritical, !isReplaying, !tapLost else { return false }
        var transformed: [HeldEvent] = []
        transformed.reserveCapacity(pending.count)
        for original in pending {
            // A failing transform must never have access to an original event.
            guard let copy = original.event.copy(), let event = transform(copy) else { return false }
            transformed.append(HeldEvent(event: event, pressID: original.pressID))
        }
        guard select() else { return false }
        pending = transformed
        return true
    }

    init(bufferLimit: Int = 2_048,
         onOverflow: (@MainActor () -> Void)? = nil,
         poster: @escaping @MainActor (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        precondition(bufferLimit > 0)
        self.bufferLimit = bufferLimit
        self.onOverflow = onOverflow
        self.poster = poster
    }

    @discardableResult func begin() -> Bool {
        guard canBegin else { return false }
        isCritical = true
        criticalBeganAt = ProcessInfo.processInfo.systemUptime
        tapLost = false
        overflowReported = false
        return true
    }

    /// Call before buffering or logical handling. Replay passes through the
    /// logical handler exactly as ordinary input, with its private marker removed.
    func prepareIncoming(_ event: CGEvent) -> ReplayToken? {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard let record = inFlight.removeValue(forKey: marker) ?? retired.removeValue(forKey: marker) else { return nil }
        Self.setUserData(record.originalUserData, on: event)
        acknowledgeDown(event, pressID: record.pressID)
        return ReplayToken(marker: marker)
    }

    /// A true result consumes the original event; do not run logical handling yet.
    func shouldBuffer(_ event: CGEvent, replay: ReplayToken? = nil) -> Bool {
        guard replay == nil, !TextAccess.isReplacementEvent(event),
              Self.isBufferedType(event.type) else { return false }
        let holding = isCritical || isReplaying
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        var pressID: UInt64?
        if event.type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 || physicalPresses[key] == nil {
                nextPressID &+= 1
                physicalPresses[key] = PhysicalPress(id: nextPressID, heldDowns: 0)
            }
            if holding, var press = physicalPresses[key] {
                press.heldDowns += 1
                physicalPresses[key] = press
                pressID = press.id
            }
        } else if event.type == .keyUp {
            let press = physicalPresses.removeValue(forKey: key)
            // A press already delivered to the logical handler needs its release
            // promptly. Delaying it can turn a short tap into press-and-hold.
            // Held repeats must still precede their release, just like held downs.
            guard holding, let press, press.heldDowns > 0 else {
                if holding, press != nil { InputDiagnostics.record("replayForwardedReleaseBypassed") }
                return false
            }
            InputDiagnostics.record("replayPairedReleaseHeld")
        }
        guard holding else { return false }
        // Retaining the suppressed original is a lossless fallback if copying
        // fails; never let allocation failure leak a key into the AX selection.
        pending.append(HeldEvent(event: event.copy() ?? event, pressID: pressID))
        if isCritical, pending.count > bufferLimit, !overflowReported {
            overflowReported = true
            // The owner cancels and restores selection before calling end().
            // Continue retaining input until that cleanup has actually finished.
            onOverflow?()
        }
        return true
    }

    /// Call in a defer after logical handling, including consumed shortcuts.
    /// The last event remains inside the gate until that handler has completed.
    func finishIncoming(_ token: ReplayToken?) {
        guard let token, token.marker == lastMarker else { return }
        lastMarker = nil
        if pending.isEmpty {
            isReplaying = false
            onDrained?()
        } else {
            postPendingBatch()
        }
    }

    /// Only call after restoring the transaction's selection/caret.
    func end() {
        guard isCritical else { return }
        if let beganAt = criticalBeganAt {
            let duration = ProcessInfo.processInfo.systemUptime - beganAt
            if duration > 0.25 { InputDiagnostics.record("replayGateHeldOver250ms") }
            if duration > 0.50 { InputDiagnostics.record("replayGateHeldOver500ms") }
        }
        criticalBeganAt = nil
        isCritical = false
        if tapLost {
            releaseAfterTapLoss()
            return
        }
        if pending.isEmpty {
            onDrained?()
        } else {
            postPendingBatch()
        }
    }

    /// Cancellation and stop use the same cleanup boundary, never discard input.
    /// This does not interrupt an existing drain or repost its in-flight events.
    func reset() { end() }

    /// OS-disabled taps cannot acknowledge replay. Already posted events belong
    /// to the OS; only input still held here is released after AX cleanup.
    func didLoseTap() {
        guard !tapLost else { return }
        tapLost = true
        if !isCritical { releaseAfterTapLoss() }
    }

    private func releaseAfterTapLoss() {
        retired.merge(inFlight) { existing, _ in existing }
        inFlight.removeAll()
        lastMarker = nil
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        isReplaying = false
        // No tap acknowledgement is guaranteed now. These downs belong to the
        // OS once released; a later physical release must never stay held here.
        for key in physicalPresses.keys { physicalPresses[key]?.heldDowns = 0 }
        for held in batch { poster(held.event) }
        onDrained?()
    }

    private func postPendingBatch() {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        isReplaying = true
        // Register the whole batch before posting, also supporting a synchronous
        // test poster. Physical input arriving during replay starts the next batch.
        for held in batch {
            let event = held.event
            nextMarker += 1
            let marker = nextMarker
            inFlight[marker] = ReplayRecord(originalUserData: event.getIntegerValueField(.eventSourceUserData),
                                            pressID: held.pressID)
            Self.setUserData(marker, on: event)
            lastMarker = marker
        }
        for held in batch { poster(held.event) }
    }

    private func acknowledgeDown(_ event: CGEvent, pressID: UInt64?) {
        guard event.type == .keyDown, let pressID else { return }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        guard var press = physicalPresses[key], press.id == pressID, press.heldDowns > 0 else { return }
        press.heldDowns -= 1
        physicalPresses[key] = press
    }

    private static func setUserData(_ value: Int64, on event: CGEvent) {
        // Unicode events can regenerate their backing event when another field
        // is read. Update the source too so that regeneration retains the tag.
        if let source = CGEventSource(event: event) {
            source.userData = value
            event.setSource(source)
        }
        event.setIntegerValueField(.eventSourceUserData, value: value)
    }

    private static func isBufferedType(_ type: CGEventType) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            true
        default:
            false
        }
    }
}

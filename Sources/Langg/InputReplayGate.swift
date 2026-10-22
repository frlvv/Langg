import CoreGraphics

/// Holds input while an AX transaction temporarily owns the selection.
/// Keep the event tap alive until `canBegin` becomes true after `end`/`reset`.
@MainActor final class InputReplayGate {
    struct ReplayToken {
        fileprivate let marker: Int64
    }

    private struct ReplayRecord {
        let originalUserData: Int64
    }

    private let bufferLimit: Int
    private let poster: @MainActor (CGEvent) -> Void
    var onOverflow: (@MainActor () -> Void)?
    var onDrained: (@MainActor () -> Void)?

    private var isCritical = false
    private var overflowReported = false
    private var pending: [CGEvent] = []
    private var inFlight: [Int64: ReplayRecord] = [:]
    private var retired: [Int64: ReplayRecord] = [:]
    private var lastMarker: Int64?
    private var tapLost = false
    // LANG + a sequence number; deliberately distinct from LANGGTEX.
    private var nextMarker: Int64 = 0x4C414E4700000000

    private(set) var isReplaying = false
    var canBegin: Bool { !isCritical && !isReplaying }

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
        return ReplayToken(marker: marker)
    }

    /// A true result consumes the original event; do not run logical handling yet.
    func shouldBuffer(_ event: CGEvent, replay: ReplayToken? = nil) -> Bool {
        guard replay == nil, isCritical || isReplaying,
              !TextAccess.isReplacementEvent(event), Self.isBufferedType(event.type) else { return false }
        // Retaining the suppressed original is a lossless fallback if copying
        // fails; never let allocation failure leak a key into the AX selection.
        pending.append(event.copy() ?? event)
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
        for event in batch { poster(event) }
        onDrained?()
    }

    private func postPendingBatch() {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        isReplaying = true
        // Register the whole batch before posting, also supporting a synchronous
        // test poster. Physical input arriving during replay starts the next batch.
        for event in batch {
            nextMarker += 1
            let marker = nextMarker
            inFlight[marker] = ReplayRecord(originalUserData: event.getIntegerValueField(.eventSourceUserData))
            Self.setUserData(marker, on: event)
            lastMarker = marker
        }
        for event in batch { poster(event) }
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

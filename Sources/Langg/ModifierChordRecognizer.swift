// A modifier chord completes on its first release, after the complete chord
// was pressed without a key. Holding the other modifier must not delay it.
// Keys and extra modifiers cancel the whole press, including modifier repeats.
struct ModifierChordRecognizer {
    let modifiers: UInt64
    private var currentModifiers: UInt64 = 0
    private var reachedChord = false
    private var cancelled = false
    private var fired = false

    init(modifiers: UInt64) {
        self.modifiers = modifiers & Shortcut.modifierMask
    }

    mutating func observeModifiers(_ rawModifiers: UInt64) -> Bool {
        let current = rawModifiers & Shortcut.modifierMask
        currentModifiers = current
        if current == 0 {
            let completed = reachedChord && !cancelled && !fired
            reset()
            return completed
        }
        guard modifiers.nonzeroBitCount >= 2 else { return false }
        if current & ~modifiers != 0 { cancelled = true }
        if current == modifiers { reachedChord = true }
        if reachedChord, current != modifiers, !cancelled, !fired {
            fired = true
            return true
        }
        return false
    }

    mutating func noteKeyDown() {
        if currentModifiers != 0 { cancelled = true }
    }

    mutating func reset() {
        currentModifiers = 0
        reachedChord = false
        cancelled = false
        fired = false
    }
}

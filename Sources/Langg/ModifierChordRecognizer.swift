// A modifier chord completes only after every shortcut modifier is released.
// Keys and extra modifiers cancel the whole press, including modifier repeats.
struct ModifierChordRecognizer {
    let modifiers: UInt64
    private var currentModifiers: UInt64 = 0
    private var reachedChord = false
    private var cancelled = false

    init(modifiers: UInt64) {
        self.modifiers = modifiers & Shortcut.modifierMask
    }

    mutating func observeModifiers(_ rawModifiers: UInt64) -> Bool {
        let current = rawModifiers & Shortcut.modifierMask
        currentModifiers = current
        if current == 0 {
            let completed = reachedChord && !cancelled
            reset()
            return completed
        }
        guard modifiers.nonzeroBitCount >= 2 else { return false }
        if current & ~modifiers != 0 { cancelled = true }
        if current == modifiers { reachedChord = true }
        return false
    }

    mutating func noteKeyDown() {
        if currentModifiers != 0 { cancelled = true }
    }

    mutating func reset() {
        currentModifiers = 0
        reachedChord = false
        cancelled = false
    }
}

import Foundation

struct Shortcut: Codable, Hashable {
    static let modifierMask: UInt64 = 0x20000 | 0x40000 | 0x80000 | 0x100000

    let keyCode: Int64
    let modifiers: UInt64

    init(keyCode: Int64, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    // Shortcuts address physical keys. Event characters can be Cyrillic, shifted,
    // dead keys, or control characters, so they must never name a shortcut.
    var isModifierOnly: Bool { keyCode == -1 }
    var keyName: String { isModifierOnly ? "" : Self.keyNames[keyCode] ?? "Клавиша \(keyCode)" }
    var isValid: Bool {
        isModifierOnly ? modifiers.nonzeroBitCount >= 2 : Self.keyNames[keyCode] != nil
    }

    var title: String {
        let symbols: [(UInt64, String)] = [
            (0x40000, "⌃"), (0x80000, "⌥"), (0x20000, "⇧"), (0x100000, "⌘")
        ]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + keyName
    }

    func matches(keyCode: Int64, modifiers: UInt64) -> Bool {
        !isModifierOnly && self.keyCode == keyCode && self.modifiers == modifiers & Self.modifierMask
    }

    static let correction = Shortcut(keyCode: 49, modifiers: 0x40000 | 0x80000)
    static let switchLayout = Shortcut(keyCode: -1, modifiers: 0x100000 | 0x20000)
    static let undo = Shortcut(keyCode: 0x06, modifiers: 0x100000)

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, keyName }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try values.decode(Int64.self, forKey: .keyCode),
                  modifiers: try values.decode(UInt64.self, forKey: .modifiers))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(keyCode, forKey: .keyCode)
        try values.encode(modifiers, forKey: .modifiers)
        // Keep the v2 format readable by earlier versions, but derive this value.
        try values.encode(keyName, forKey: .keyName)
    }

    private static let keyNames: [Int64: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0A: "§", 0x0B: "B",
        0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
        0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
        0x24: "Return", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".",
        0x30: "Tab", 0x31: "Пробел", 0x32: "`", 0x33: "Delete", 0x35: "Esc",
        0x40: "F17", 0x41: "Num .", 0x43: "Num *", 0x45: "Num +", 0x47: "Clear",
        0x4B: "Num /", 0x4C: "Enter", 0x4E: "Num -", 0x4F: "F18", 0x50: "F19",
        0x51: "Num =", 0x52: "Num 0", 0x53: "Num 1", 0x54: "Num 2", 0x55: "Num 3",
        0x56: "Num 4", 0x57: "Num 5", 0x58: "Num 6", 0x59: "Num 7", 0x5A: "F20",
        0x5B: "Num 8", 0x5C: "Num 9", 0x5D: "¥", 0x5E: "_", 0x5F: "Num ,",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x63: "F3", 0x64: "F8", 0x65: "F9",
        0x66: "英数", 0x67: "F11", 0x68: "かな", 0x69: "F13", 0x6A: "F16",
        0x6B: "F14", 0x6D: "F10", 0x6F: "F12", 0x71: "F15", 0x72: "Help",
        0x73: "Home", 0x74: "Page Up", 0x75: "Forward Delete", 0x76: "F4",
        0x77: "End", 0x78: "F2", 0x79: "Page Down", 0x7A: "F1",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑"
    ]
}

// Consume the complete press, including repeats and key-up after modifiers or
// focus have changed. Otherwise the destination app receives an orphan key-up.
struct ConsumedKeyPresses {
    private var keys: Set<Int64> = []

    mutating func begin(_ keyCode: Int64) { keys.insert(keyCode) }

    mutating func consumeContinuation(keyCode: Int64, isKeyDown: Bool) -> Bool {
        guard keys.contains(keyCode) else { return false }
        if !isKeyDown { keys.remove(keyCode) }
        return true
    }
}

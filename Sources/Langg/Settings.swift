import Foundation
import Combine

enum ShortcutCommand: CaseIterable {
    case correction, switchLayout, undo
}

@MainActor final class AppSettings: ObservableObject {
    @Published var automatic = true { didSet { save() } }
    @Published var notifications = true { didSet { save() } }
    @Published var undoRestoresLayout = true { didSet { save() } }
    @Published var excludedApps: [String] = ["com.apple.Terminal", "com.googlecode.iterm2"] { didSet { save() } }
    @Published var excludedWords: [String] = [] { didSet { save() } }
    @Published private(set) var correctionShortcut = Shortcut.correction { didSet { save() } }
    @Published private(set) var switchShortcut = Shortcut.switchLayout { didSet { save() } }
    @Published private(set) var undoShortcut = Shortcut.undo { didSet { save() } }
    private let defaults: UserDefaults
    private var isRestoring = true

    private struct Stored: Codable {
        var automatic: Bool
        var notifications: Bool
        var undoRestoresLayout: Bool
        var excludedApps: [String]
        var excludedWords: [String]
        var correctionShortcut: Shortcut
        var switchShortcut: Shortcut
        var undoShortcut: Shortcut

        init(automatic: Bool = true, notifications: Bool = true, undoRestoresLayout: Bool = true,
             excludedApps: [String] = ["com.apple.Terminal", "com.googlecode.iterm2"],
             excludedWords: [String] = [], correctionShortcut: Shortcut = .correction,
             switchShortcut: Shortcut = .switchLayout, undoShortcut: Shortcut = .undo) {
            self.automatic = automatic
            self.notifications = notifications
            self.undoRestoresLayout = undoRestoresLayout
            self.excludedApps = excludedApps
            self.excludedWords = excludedWords
            self.correctionShortcut = correctionShortcut
            self.switchShortcut = switchShortcut
            self.undoShortcut = undoShortcut
        }

        private enum CodingKeys: String, CodingKey {
            case automatic, notifications, undoRestoresLayout, excludedApps, excludedWords
            case correctionShortcut, switchShortcut, undoShortcut
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = Stored()
            automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? fallback.automatic
            notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? fallback.notifications
            undoRestoresLayout = try values.decodeIfPresent(Bool.self, forKey: .undoRestoresLayout) ?? fallback.undoRestoresLayout
            excludedApps = try values.decodeIfPresent([String].self, forKey: .excludedApps) ?? fallback.excludedApps
            excludedWords = try values.decodeIfPresent([String].self, forKey: .excludedWords) ?? fallback.excludedWords
            correctionShortcut = try values.decodeIfPresent(Shortcut.self, forKey: .correctionShortcut) ?? fallback.correctionShortcut
            switchShortcut = try values.decodeIfPresent(Shortcut.self, forKey: .switchShortcut) ?? fallback.switchShortcut
            undoShortcut = try values.decodeIfPresent(Shortcut.self, forKey: .undoShortcut) ?? fallback.undoShortcut
        }
    }

    private struct LegacyStored: Codable {
        var automatic: Bool
        var notifications: Bool
        var excludedApps: [String]
        var excludedWords: [String]
        var lastWordShortcut: String
        var selectionShortcut: String
        var undoShortcut: String
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var shouldSaveMigration = false
        let currentData = defaults.data(forKey: "settings.v2")
        let stored = [currentData, defaults.data(forKey: "settings.v2.backup")]
            .compactMap { $0 }
            .compactMap { try? JSONDecoder().decode(Stored.self, from: $0) }.first
        if let stored {
            automatic = stored.automatic
            notifications = stored.notifications
            undoRestoresLayout = stored.undoRestoresLayout
            excludedApps = stored.excludedApps
            excludedWords = stored.excludedWords
            correctionShortcut = Self.availableShortcut(stored.correctionShortcut, avoiding: [])
            switchShortcut = Self.availableShortcut(stored.switchShortcut, avoiding: [correctionShortcut], allowsModifierOnly: true)
            undoShortcut = Self.availableShortcut(stored.undoShortcut, avoiding: [correctionShortcut, switchShortcut])
        } else if let data = defaults.data(forKey: "settings.v1"),
                  let stored = try? JSONDecoder().decode(LegacyStored.self, from: data) {
            automatic = stored.automatic
            notifications = stored.notifications
            excludedApps = stored.excludedApps
            excludedWords = stored.excludedWords
            correctionShortcut = Self.legacyShortcut(stored.lastWordShortcut) ?? .correction
            undoShortcut = Self.legacyShortcut(stored.undoShortcut) ?? .undo
            if correctionShortcut == undoShortcut {
                undoShortcut = Self.legacyCandidates.first { $0 != correctionShortcut && !$0.isModifierOnly } ?? .undo
            }
            switchShortcut = Self.legacyCandidates.first {
                $0 != correctionShortcut && $0 != undoShortcut
            } ?? .switchLayout
            // Launching an older build must not overwrite an unreadable newer format.
            shouldSaveMigration = currentData == nil
        }
        // Older versions did not store whether a shortcut was customized. Only
        // migrate the exact former factory binding, and never displace another command.
        let previousSwitchDefault = Shortcut(keyCode: 36, modifiers: 0x40000 | 0x80000)
        if switchShortcut == previousSwitchDefault,
           correctionShortcut != .switchLayout, undoShortcut != .switchLayout {
            switchShortcut = .switchLayout
            shouldSaveMigration = currentData == nil || stored != nil
        }
        let previousUndoDefault = Shortcut(keyCode: 51, modifiers: 0x40000 | 0x80000)
        if undoShortcut == previousUndoDefault,
           correctionShortcut != .undo, switchShortcut != .undo {
            undoShortcut = .undo
            shouldSaveMigration = currentData == nil || stored != nil
        }
        isRestoring = false
        if shouldSaveMigration { save() }
    }

    func shortcut(for command: ShortcutCommand) -> Shortcut {
        switch command {
        case .correction: correctionShortcut
        case .switchLayout: switchShortcut
        case .undo: undoShortcut
        }
    }

    @discardableResult
    func setShortcut(_ shortcut: Shortcut, for command: ShortcutCommand) -> Bool {
        guard shortcut.isValid, !shortcut.isModifierOnly || command == .switchLayout else { return false }
        for other in ShortcutCommand.allCases where other != command {
            if self.shortcut(for: other) == shortcut { return false }
        }
        switch command {
        case .correction: correctionShortcut = shortcut
        case .switchLayout: switchShortcut = shortcut
        case .undo: undoShortcut = shortcut
        }
        return true
    }

    private static func legacyShortcut(_ id: String) -> Shortcut? {
        let modifiers: UInt64 = 0x40000 | 0x80000
        switch id {
        case "space": return .correction
        case "return": return Shortcut(keyCode: 36, modifiers: modifiers)
        case "delete": return Shortcut(keyCode: 51, modifiers: modifiers)
        case "l": return Shortcut(keyCode: 37, modifiers: modifiers)
        case "semicolon": return Shortcut(keyCode: 41, modifiers: modifiers)
        case "slash": return Shortcut(keyCode: 44, modifiers: modifiers)
        default: return nil
        }
    }

    private static let legacyCandidates: [Shortcut] = [
        .switchLayout,
        Shortcut(keyCode: 37, modifiers: 0x40000 | 0x80000),
        .correction,
        .undo,
        Shortcut(keyCode: 41, modifiers: 0x40000 | 0x80000),
        Shortcut(keyCode: 44, modifiers: 0x40000 | 0x80000)
    ]

    private static func availableShortcut(_ preferred: Shortcut, avoiding used: [Shortcut],
                                          allowsModifierOnly: Bool = false) -> Shortcut {
        if preferred.isValid, !used.contains(preferred), allowsModifierOnly || !preferred.isModifierOnly {
            return preferred
        }
        return legacyCandidates.first {
            !used.contains($0) && (allowsModifierOnly || !$0.isModifierOnly)
        } ?? preferred
    }

    private func save() {
        guard !isRestoring else { return }
        let stored = Stored(automatic: automatic, notifications: notifications, undoRestoresLayout: undoRestoresLayout,
                            excludedApps: excludedApps, excludedWords: excludedWords,
                            correctionShortcut: correctionShortcut, switchShortcut: switchShortcut,
                            undoShortcut: undoShortcut)
        guard let encoded = try? JSONEncoder().encode(stored),
              var values = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return }
        if let oldData = defaults.data(forKey: "settings.v2") {
            if (try? JSONDecoder().decode(Stored.self, from: oldData)) != nil {
                defaults.set(oldData, forKey: "settings.v2.backup")
                // Preserve fields introduced by a newer app version on subsequent edits.
                if let previous = (try? JSONSerialization.jsonObject(with: oldData)) as? [String: Any] {
                    values = previous.merging(values) { _, new in new }
                }
            } else {
                defaults.set(oldData, forKey: "settings.v2.unreadable")
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        defaults.set(data, forKey: "settings.v2")
    }
}

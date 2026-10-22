import Foundation
import Testing
@testable import Langg

@MainActor private func withSettingsDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
    let suite = "LanggTests.persistence.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try test(defaults)
}

@MainActor @Test func settingsSurviveRelaunch() throws {
    try withSettingsDefaults { defaults in
        let settings = AppSettings(defaults: defaults)
        settings.automatic = false
        settings.notifications = false
        settings.excludedApps = ["app.example.Editor"]
        settings.excludedWords = ["Langg", "🙂"]
        let custom = Shortcut(keyCode: 37, modifiers: 0x100000 | 0x80000)
        #expect(settings.setShortcut(custom, for: .correction))
        let saved = try #require(defaults.data(forKey: "settings.v2"))
        let restored = AppSettings(defaults: defaults)
        #expect(!restored.automatic && !restored.notifications)
        #expect(restored.excludedApps == ["app.example.Editor"])
        #expect(restored.excludedWords == ["Langg", "🙂"])
        #expect(restored.correctionShortcut == custom)
        #expect(defaults.data(forKey: "settings.v2") == saved)
    }
}

@MainActor @Test func missingNewFieldsKeepExistingPreferences() {
    withSettingsDefaults { defaults in
        let data = Data(#"{"automatic":false,"excludedWords":["keep"]}"#.utf8)
        defaults.set(data, forKey: "settings.v2")
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.automatic)
        #expect(settings.notifications)
        #expect(settings.excludedWords == ["keep"])
        #expect(settings.correctionShortcut == .correction)
        #expect(defaults.data(forKey: "settings.v2") == data)
    }
}

@MainActor @Test func unreadableSettingsAreNotOverwrittenAtLaunch() {
    withSettingsDefaults { defaults in
        let unreadable = Data("{interrupted write".utf8)
        defaults.set(unreadable, forKey: "settings.v2")
        _ = AppSettings(defaults: defaults)
        #expect(defaults.data(forKey: "settings.v2") == unreadable)
    }
}

@MainActor @Test func corruptedSettingsRecoverFromBackupWithoutDestroyingOriginal() {
    withSettingsDefaults { defaults in
        let settings = AppSettings(defaults: defaults)
        settings.automatic = false
        settings.excludedWords = ["backup"]
        settings.notifications = false
        let unreadable = Data("broken".utf8)
        defaults.set(unreadable, forKey: "settings.v2")
        let restored = AppSettings(defaults: defaults)
        #expect(!restored.automatic)
        #expect(restored.excludedWords == ["backup"])
        #expect(defaults.data(forKey: "settings.v2") == unreadable)
        restored.notifications = false
        #expect(defaults.data(forKey: "settings.v2.unreadable") == unreadable)
        #expect(AppSettings(defaults: defaults).excludedWords == ["backup"])
    }
}

@MainActor @Test func editsPreserveFieldsFromNewerVersions() throws {
    try withSettingsDefaults { defaults in
        defaults.set(Data(#"{"automatic":false,"futureOption":{"value":42}}"#.utf8), forKey: "settings.v2")
        AppSettings(defaults: defaults).notifications = false
        let data = try #require(defaults.data(forKey: "settings.v2"))
        let values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((values["futureOption"] as? [String: Int])?["value"] == 42)
        #expect(values["automatic"] as? Bool == false)
    }
}

@MainActor @Test func duplicateShortcutRepairsKeepValidUserShortcut() throws {
    try withSettingsDefaults { defaults in
        let custom = Shortcut(keyCode: 37, modifiers: 0x100000)
        let encoded = try JSONEncoder().encode(custom)
        let shortcut = try JSONSerialization.jsonObject(with: encoded)
        let data = try JSONSerialization.data(withJSONObject: [
            "correctionShortcut": shortcut, "switchShortcut": shortcut, "undoShortcut": shortcut,
            "automatic": false, "excludedWords": ["keep"]
        ])
        defaults.set(data, forKey: "settings.v2")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.correctionShortcut == custom)
        #expect(Set(ShortcutCommand.allCases.map { settings.shortcut(for: $0) }).count == 3)
        #expect(!settings.automatic && settings.excludedWords == ["keep"])
    }
}

@MainActor @Test func newSettingsUseStandardCommandZForUndo() {
    withSettingsDefaults { defaults in
        let settings = AppSettings(defaults: defaults)
        #expect(settings.undoShortcut == Shortcut(keyCode: 6, modifiers: 0x100000))
        #expect(settings.undoShortcut.title == "⌘Z")
    }
}

@MainActor @Test func existingUndoAssignmentsSurviveDefaultChange() throws {
    try withSettingsDefaults { defaults in
        for shortcut in [Shortcut(keyCode: 50, modifiers: 0x100000),
                         Shortcut(keyCode: 6, modifiers: 0x20000 | 0x100000)] {
            let json: [String: Any] = [
                "automatic": false, "notifications": false,
                "excludedApps": ["app.example.Editor"], "excludedWords": ["keep"],
                "undoShortcut": try JSONSerialization.jsonObject(with: JSONEncoder().encode(shortcut))
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            defaults.set(data, forKey: "settings.v2")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.undoShortcut == shortcut)
            #expect(!settings.automatic && !settings.notifications)
            #expect(settings.excludedApps == ["app.example.Editor"])
            #expect(settings.excludedWords == ["keep"])
            #expect(defaults.data(forKey: "settings.v2") == data)
        }
    }
}

@MainActor @Test func legacyDeleteUndoMigratesFactoryDefaultWithoutChangingPreferences() throws {
    try withSettingsDefaults { defaults in
        let json: [String: Any] = [
            "automatic": false, "notifications": false,
            "excludedApps": ["app.example.Editor"], "excludedWords": ["keep"],
            "lastWordShortcut": "space", "selectionShortcut": "return", "undoShortcut": "delete"
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "settings.v1")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.undoShortcut == .undo)
        #expect(settings.correctionShortcut == .correction)
        #expect(settings.switchShortcut == .switchLayout)
        #expect(!settings.automatic && !settings.notifications)
        #expect(settings.excludedApps == ["app.example.Editor"])
        #expect(settings.excludedWords == ["keep"])
        #expect(AppSettings(defaults: defaults).undoShortcut == settings.undoShortcut)
    }
}

@MainActor @Test func formerFactoryUndoMigratesUnlessCommandZIsAlreadyAssigned() throws {
    try withSettingsDefaults { defaults in
        let oldUndo = Shortcut(keyCode: 51, modifiers: 0x40000 | 0x80000)
        for correction in [Shortcut.correction, Shortcut.undo] {
            let json: [String: Any] = [
                "automatic": false, "notifications": false, "excludedWords": ["keep"],
                "correctionShortcut": try JSONSerialization.jsonObject(with: JSONEncoder().encode(correction)),
                "undoShortcut": try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldUndo))
            ]
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "settings.v2")
            let settings = AppSettings(defaults: defaults)
            let expected = correction == .undo ? oldUndo : .undo
            #expect(settings.undoShortcut == expected)
            #expect(settings.correctionShortcut == correction)
            #expect(!settings.automatic && !settings.notifications && settings.excludedWords == ["keep"])
            #expect(AppSettings(defaults: defaults).undoShortcut == expected)
        }
    }
}

@MainActor @Test func modifierLayoutDefaultMigratesFactoryBindingAndKeepsCustom() throws {
    try withSettingsDefaults { defaults in
        let factory = Shortcut(keyCode: 36, modifiers: 0x40000 | 0x80000)
        let custom = Shortcut(keyCode: 50, modifiers: 0x100000)
        for saved in [factory, custom] {
            let json: [String: Any] = [
                "automatic": false, "excludedWords": ["keep"],
                "switchShortcut": try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
            ]
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "settings.v2")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.switchShortcut == (saved == factory ? .switchLayout : custom))
            #expect(!settings.automatic && settings.excludedWords == ["keep"])
            #expect(AppSettings(defaults: defaults).switchShortcut == settings.switchShortcut)
        }
    }
}

@MainActor @Test func undoLayoutPreferenceDefaultsTrueAndPersistsFalse() {
    withSettingsDefaults { defaults in
        defaults.set(Data(#"{"automatic":false,"excludedWords":["keep"]}"#.utf8), forKey: "settings.v2")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.undoRestoresLayout)
        #expect(settings.switchShortcut == .switchLayout)
        settings.undoRestoresLayout = false
        let restored = AppSettings(defaults: defaults)
        #expect(!restored.undoRestoresLayout)
        #expect(!restored.automatic && restored.excludedWords == ["keep"])
    }
}

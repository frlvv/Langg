import AppKit
import Carbon
import Testing
@testable import Langg

@MainActor
private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
    let name = "LanggTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    settings.notifications = true
    try body(settings, defaults)
}

private let modifierCombinations: [UInt64] = (0..<16).map { bits in
    let flags: [NSEvent.ModifierFlags] = [.control, .option, .shift, .command]
    return flags.enumerated().reduce(UInt64(0)) { value, item in
        value | (bits & (1 << item.offset) == 0 ? 0 : UInt64(item.element.rawValue))
    }
}

@Suite @MainActor struct ShortcutTests {
    @Test func graveNeverUsesStaleEventCharactersOrStoredLabel() throws {
        for oldLabel in ["C", "С", "Ё", "~", "\u{001B}"] {
            let json: [String: Any] = ["keyCode": kVK_ANSI_Grave,
                                       "modifiers": NSEvent.ModifierFlags.command.rawValue,
                                       "keyName": oldLabel]
            let data = try JSONSerialization.data(withJSONObject: json)
            let shortcut = try JSONDecoder().decode(Shortcut.self, from: data)
            #expect(shortcut.title == "⌘`")
            #expect(shortcut.matches(keyCode: Int64(kVK_ANSI_Grave), modifiers: CGEventFlags.maskCommand.rawValue))
            #expect(!shortcut.matches(keyCode: Int64(kVK_ANSI_C), modifiers: CGEventFlags.maskCommand.rawValue))
        }
    }

    @Test(arguments: [
        (kVK_ANSI_Grave, "`"), (kVK_ANSI_C, "C"), (kVK_ANSI_LeftBracket, "["),
        (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Quote, "'"), (kVK_Space, "Пробел"),
        (kVK_Return, "Return"), (kVK_ANSI_KeypadEnter, "Enter"), (kVK_Delete, "Delete"),
        (kVK_ForwardDelete, "Forward Delete"), (kVK_LeftArrow, "←"), (kVK_Home, "Home"),
        (kVK_PageDown, "Page Down"), (kVK_F1, "F1"), (kVK_F12, "F12"), (kVK_F20, "F20"),
        (kVK_ANSI_1, "1"), (kVK_ANSI_Keypad1, "Num 1"), (kVK_ISO_Section, "§")
    ])
    func namesPhysicalKeys(keyCode: Int, expected: String) {
        #expect(Shortcut(keyCode: Int64(keyCode), modifiers: 0).title == expected)
    }

    @Test(arguments: Array(zip([
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
        kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
        kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
        kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z
    ], Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init))))
    func lettersKeepTheirPhysicalEnglishNames(keyCode: Int, expected: String) {
        #expect(Shortcut(keyCode: Int64(keyCode), modifiers: 0).title == expected)
    }

    @Test(arguments: Array(zip([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ], 1...20)))
    func functionKeysDoNotDisplayPrivateUseCharacters(keyCode: Int, number: Int) {
        #expect(Shortcut(keyCode: Int64(keyCode), modifiers: 0).title == "F\(number)")
    }

    @Test(arguments: Array(zip([
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ], [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9])))
    func numberRowAndKeypadRemainDistinct(row: Int, keypad: Int) {
        let rowKey = Shortcut(keyCode: Int64(row), modifiers: 0)
        let padKey = Shortcut(keyCode: Int64(keypad), modifiers: 0)
        #expect(rowKey.isValid && padKey.isValid)
        #expect(rowKey != padKey)
        #expect(!rowKey.matches(keyCode: Int64(keypad), modifiers: 0))
        #expect(padKey.title == "Num \(rowKey.title)")
    }

    @Test(arguments: ShortcutCommand.allCases, modifierCombinations)
    func recordingPersistsExactPhysicalKey(command: ShortcutCommand, modifiers: UInt64) throws {
        try withSettings { settings, defaults in
            let recorder = ShortcutRecorder(settings: settings)
            recorder.start(command)
            recorder.record(keyCode: Int64(kVK_ANSI_Grave), modifiers: modifiers, isRepeat: false)
            #expect(recorder.command == nil)
            #expect(recorder.error == nil)
            let restored = AppSettings(defaults: defaults).shortcut(for: command)
            #expect(restored.keyCode == Int64(kVK_ANSI_Grave))
            #expect(restored.modifiers == modifiers)
            #expect(restored.matches(keyCode: Int64(kVK_ANSI_Grave), modifiers: modifiers))
            #expect(!restored.matches(keyCode: Int64(kVK_ANSI_C), modifiers: modifiers))
        }
    }

    @Test(arguments: ["`", "ё", "Ё", "~", "с", "c", "\u{0003}"])
    func eventRecordingUsesPhysicalGraveAcrossLayouts(characters: String) throws {
        try withSettings { settings, defaults in
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: UInt16(kVK_ANSI_Grave)))
            let recorder = ShortcutRecorder(settings: settings)
            recorder.start(.correction)
            recorder.record(event)
            // A later menu/system event must not overwrite the completed recording.
            recorder.record(keyCode: Int64(kVK_ANSI_C), modifiers: CGEventFlags.maskCommand.rawValue,
                            isRepeat: false)
            let restored = AppSettings(defaults: defaults)
            #expect(restored.correctionShortcut.title == "⌘`")
            #expect(restored.correctionShortcut.keyCode == Int64(kVK_ANSI_Grave))
            #expect(!restored.correctionShortcut.matches(keyCode: Int64(kVK_ANSI_C),
                                                        modifiers: CGEventFlags.maskCommand.rawValue))
        }
    }

    @Test(arguments: modifierCombinations)
    func ignoresNonShortcutFlagsAndRequiresExactModifiers(modifiers: UInt64) {
        let extra = UInt64(NSEvent.ModifierFlags.capsLock.rawValue |
                           NSEvent.ModifierFlags.function.rawValue |
                           NSEvent.ModifierFlags.numericPad.rawValue) | 0xFFFF
        let shortcut = Shortcut(keyCode: Int64(kVK_ANSI_Grave), modifiers: modifiers | extra)
        #expect(shortcut.modifiers == modifiers)
        #expect(shortcut.matches(keyCode: Int64(kVK_ANSI_Grave), modifiers: modifiers | extra))
        for other in modifierCombinations where other != modifiers {
            #expect(!shortcut.matches(keyCode: Int64(kVK_ANSI_Grave), modifiers: other))
        }
    }

    @Test(arguments: ShortcutCommand.allCases)
    func conflictKeepsRecordingAndDoesNotChangeAssignments(command: ShortcutCommand) throws {
        try withSettings { settings, _ in
            let before = ShortcutCommand.allCases.map(settings.shortcut)
            let other = try #require(ShortcutCommand.allCases.first { $0 != command })
            let occupied = settings.shortcut(for: other)
            let recorder = ShortcutRecorder(settings: settings)
            recorder.start(command)
            recorder.record(keyCode: occupied.keyCode, modifiers: occupied.modifiers, isRepeat: false)
            #expect(recorder.command == command)
            #expect(recorder.error != nil)
            #expect(ShortcutCommand.allCases.map(settings.shortcut) == before)
            recorder.record(keyCode: Int64(kVK_ANSI_Grave), modifiers: 0, isRepeat: false)
            #expect(recorder.command == nil)
            #expect(settings.shortcut(for: command).keyCode == Int64(kVK_ANSI_Grave))
        }
    }

    @Test func escapeRepeatFocusLossAndNewRecordingPreserveAssignments() throws {
        try withSettings { settings, _ in
            let before = ShortcutCommand.allCases.map(settings.shortcut)
            let recorder = ShortcutRecorder(settings: settings)
            recorder.start(.correction)
            recorder.record(keyCode: Int64(kVK_ANSI_Grave), modifiers: 0, isRepeat: true)
            #expect(recorder.command == .correction)
            recorder.record(keyCode: Int64(kVK_Escape), modifiers: 0, isRepeat: false)
            #expect(recorder.command == nil)
            recorder.start(.switchLayout)
            recorder.stop()
            recorder.record(keyCode: Int64(kVK_ANSI_C), modifiers: 0, isRepeat: false)
            #expect(ShortcutCommand.allCases.map(settings.shortcut) == before)
            recorder.start(.correction)
            recorder.start(.undo)
            recorder.record(keyCode: Int64(kVK_ANSI_Grave), modifiers: 0, isRepeat: false)
            #expect(settings.correctionShortcut == before[0])
            #expect(settings.undoShortcut.keyCode == Int64(kVK_ANSI_Grave))
        }
    }

    @Test(arguments: [kVK_Command, kVK_Shift, kVK_Option, kVK_Control, kVK_CapsLock, kVK_Function, -1, 999])
    func rejectsModifierOnlyAndInvalidKeys(keyCode: Int) throws {
        try withSettings { settings, _ in
            let before = settings.correctionShortcut
            let recorder = ShortcutRecorder(settings: settings)
            recorder.start(.correction)
            recorder.record(keyCode: Int64(keyCode), modifiers: 0, isRepeat: false)
            #expect(recorder.command == .correction)
            #expect(recorder.error != nil)
            #expect(settings.correctionShortcut == before)
        }
    }

    @Test func consumesWholePressAcrossModifierAndFocusChanges() {
        var keys = ConsumedKeyPresses()
        let grave = Int64(kVK_ANSI_Grave)
        keys.begin(grave)
        let results = [
            keys.consumeContinuation(keyCode: grave, isKeyDown: true),
            keys.consumeContinuation(keyCode: grave, isKeyDown: true),
            keys.consumeContinuation(keyCode: Int64(kVK_ANSI_C), isKeyDown: true),
            keys.consumeContinuation(keyCode: grave, isKeyDown: false),
            keys.consumeContinuation(keyCode: grave, isKeyDown: true),
            keys.consumeContinuation(keyCode: grave, isKeyDown: false)
        ]
        #expect(results == [true, true, false, true, false, false])
    }

    @Test func repairsStaleStoredNamesWithoutChangingPhysicalAssignments() throws {
        try withSettings { settings, defaults in
            let data = try #require(defaults.data(forKey: "settings.v2"))
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json["correctionShortcut"] = ["keyCode": kVK_ANSI_Grave,
                                           "modifiers": NSEvent.ModifierFlags.command.rawValue,
                                           "keyName": "C"]
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "settings.v2")
            let restored = AppSettings(defaults: defaults)
            #expect(restored.correctionShortcut.title == "⌘`")
            #expect(restored.switchShortcut == settings.switchShortcut)
            #expect(restored.undoShortcut == settings.undoShortcut)
        }
    }

    @Test func legacyMigrationKeepsThreeDistinctAssignments() throws {
        try withSettings { _, defaults in
            defaults.removeObject(forKey: "settings.v2")
            let json: [String: Any] = [
                "automatic": false, "notifications": true, "excludedApps": [], "excludedWords": [],
                "lastWordShortcut": "return", "selectionShortcut": "space", "undoShortcut": "return"
            ]
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "settings.v1")
            let settings = AppSettings(defaults: defaults)
            #expect(Set(ShortcutCommand.allCases.map(settings.shortcut)).count == 3)
            #expect(settings.correctionShortcut == Shortcut(keyCode: 36, modifiers: 0x40000 | 0x80000))
            #expect(!settings.undoShortcut.isModifierOnly)
            #expect(!settings.automatic)
        }
    }

    @Test func recordsModifierOnlyLayoutShortcutOnFullRelease() throws {
        try withSettings { settings, defaults in
            let custom = Shortcut(keyCode: Int64(kVK_ANSI_Grave), modifiers: 0x100000)
            #expect(settings.setShortcut(custom, for: .switchLayout))
            let recorder = ShortcutRecorder(settings: settings)
            recorder.start(.switchLayout)
            recorder.recordModifiers(0x100000)
            recorder.recordModifiers(0x100000 | 0x20000)
            recorder.recordModifiers(0x20000)
            #expect(settings.switchShortcut == custom)
            #expect(recorder.command == .switchLayout)
            recorder.recordModifiers(0)
            #expect(recorder.command == nil)
            #expect(AppSettings(defaults: defaults).switchShortcut == .switchLayout)
            #expect(settings.switchShortcut.isModifierOnly)
            #expect(settings.switchShortcut.title == "⇧⌘")
            #expect(!settings.switchShortcut.matches(keyCode: -1, modifiers: 0x120000))
        }
    }

    @Test func modifierRecordingDoesNotReplaceARecordedKeyShortcut() throws {
        try withSettings { settings, _ in
            let recorder = ShortcutRecorder(settings: settings)
            recorder.start(.switchLayout)
            recorder.recordModifiers(0x100000 | 0x20000)
            recorder.record(keyCode: Int64(kVK_ANSI_Z), modifiers: 0x100000 | 0x20000, isRepeat: false)
            recorder.recordModifiers(0)
            #expect(settings.switchShortcut == Shortcut(keyCode: Int64(kVK_ANSI_Z), modifiers: 0x120000))
            #expect(!settings.switchShortcut.isModifierOnly)
            #expect(!settings.setShortcut(.switchLayout, for: .undo))
        }
    }

    @Test func settingsUseOneRetainedSystemWindow() throws {
        _ = NSApplication.shared
        try withSettings { settings, _ in
            let monitor = InputMonitor(settings: settings)
            defer { monitor.stop() }
            let controller = SettingsWindowController(monitor: monitor)
            let window = try #require(controller.window)
            #expect(!(window is NSPanel))
            #expect(window.identifier == SettingsWindowController.windowID)
            #expect(!window.hidesOnDeactivate)
            #expect(!window.isReleasedWhenClosed)
            #expect(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
            #expect(!window.isVisible)
            monitor.shortcutRecorder.start(.correction)
            window.close()
            #expect(controller.window === window)
            #expect(monitor.shortcutRecorder.command == nil)
        }
    }
}

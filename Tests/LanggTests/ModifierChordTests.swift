import Testing
@testable import Langg

@Suite struct ModifierChordTests {
    private let command: UInt64 = 0x100000
    private let shift: UInt64 = 0x20000

    @Test(arguments: [
        [UInt64(0x100000), 0x120000, 0x120000, 0x20000, 0, 0],
        [UInt64(0x20000), 0x120000, 0x100000, 0, 0]
    ])
    func completesOnceAfterFullRelease(events: [UInt64]) {
        var chord = ModifierChordRecognizer(modifiers: command | shift)
        let results = events.map { chord.observeModifiers($0) }
        #expect(results.filter { $0 }.count == 1)
        #expect(results[events.count - 2])
        #expect(!results[events.count - 1])
    }

    @Test func commandShiftZDoesNotSwitchLayout() {
        var chord = ModifierChordRecognizer(modifiers: command | shift)
        let observed1 = chord.observeModifiers(command)
        #expect(!observed1)
        let observed2 = chord.observeModifiers(command | shift)
        #expect(!observed2)
        chord.noteKeyDown()
        let observed3 = chord.observeModifiers(command | shift)
        #expect(!observed3)
        let observed4 = chord.observeModifiers(command)
        #expect(!observed4)
        let observed5 = chord.observeModifiers(0)
        #expect(!observed5)
        let observed6 = chord.observeModifiers(command | shift)
        #expect(!observed6)
        let observed7 = chord.observeModifiers(0)
        #expect(observed7)
    }

    @Test func keysBeforeTheFullChordAndExtraModifiersCancelThePress() {
        var chord = ModifierChordRecognizer(modifiers: command | shift)
        let observed8 = chord.observeModifiers(command)
        #expect(!observed8)
        chord.noteKeyDown()
        let observed9 = chord.observeModifiers(command | shift)
        #expect(!observed9)
        let observed10 = chord.observeModifiers(0)
        #expect(!observed10)
        let observed11 = chord.observeModifiers(command | shift)
        #expect(!observed11)
        let observed12 = chord.observeModifiers(command | shift | 0x80000)
        #expect(!observed12)
        let observed13 = chord.observeModifiers(command | shift)
        #expect(!observed13)
        let observed14 = chord.observeModifiers(0)
        #expect(!observed14)
    }

    @Test func ordinaryTypingDoesNotBlockTheNextChordAndResetCancelsPendingPress() {
        var chord = ModifierChordRecognizer(modifiers: command | shift)
        chord.noteKeyDown()
        let observed15 = chord.observeModifiers(command | shift)
        #expect(!observed15)
        let observed16 = chord.observeModifiers(0)
        #expect(observed16)
        let observed17 = chord.observeModifiers(command | shift)
        #expect(!observed17)
        chord.reset()
        let observed18 = chord.observeModifiers(0)
        #expect(!observed18)
    }

    @Test func aSingleModifierCannotBecomeALayoutShortcut() {
        var chord = ModifierChordRecognizer(modifiers: command)
        let observed19 = chord.observeModifiers(command)
        #expect(!observed19)
        let observed20 = chord.observeModifiers(0)
        #expect(!observed20)
        #expect(!Shortcut(keyCode: -1, modifiers: command).isValid)
    }
}

import AppKit
import CoreGraphics
import LanggCore

struct DecodedKeystroke: Equatable {
    let text: String
    let sourceID: String
}

/// Decodes physical presses for tracking without changing application input.
/// CGEvent Unicode can still describe the previous layout after a TIS switch.
@MainActor enum KeyboardInput {
    static func decode(_ event: CGEvent) -> DecodedKeystroke? {
        let decoded = decode(event, selection: { InputSources.currentSelection() }, translate: { event, modifiers in
            NSEvent(cgEvent: event)?.characters(byApplyingModifiers: modifiers)
        })
        if let decoded, InputDiagnostics.enabled {
            var count = 0
            var units = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
            if (1...units.count).contains(count) {
                let raw = String(utf16CodeUnits: units, count: count).replacingOccurrences(of: "\r", with: "\n")
                InputDiagnostics.record(raw == decoded.text ? "eventTextAlreadyCurrent" : "eventTextRetranslated")
            }
        }
        return decoded
    }

    // Dependencies are explicit so metadata races can be verified without
    // changing the user's selected layout or intercepting their input.
    static func decode(_ event: CGEvent,
                       selection: () -> InputSourceSelectionSnapshot,
                       translate: (CGEvent, NSEvent.ModifierFlags) -> String?) -> DecodedKeystroke? {
        guard event.type == .keyDown else { return nil }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        guard isTextKey(key) else { return nil }
        guard let modifiers = layoutModifiers(for: event.flags) else { return nil }
        let before = selection()
        guard let sourceID = before.sourceID, before.matches(sourceID),
              InputSources.isSupportedIdentifier(sourceID) else { return nil }
        guard let translated = translate(event, modifiers),
              let text = normalized(translated, key: key),
              selection() == before else { return nil }
        return DecodedKeystroke(text: text, sourceID: sourceID)
    }

    static func layoutModifiers(for flags: CGEventFlags) -> NSEvent.ModifierFlags? {
        // Low device-specific bits and nonCoalesced do not change text. Pass
        // only the modifiers relevant to layout translation to AppKit.
        let allowed: CGEventFlags = [.maskShift, .maskAlphaShift, .maskNumericPad]
        let highFlags = flags.rawValue & ~UInt64(0xFFFF)
        guard highFlags & ~allowed.rawValue == 0 else { return nil }
        return NSEvent.ModifierFlags(rawValue: UInt(flags.intersection(allowed).rawValue))
    }

    private static func isTextKey(_ key: Int64) -> Bool {
        // ANSI/ISO letters, digits, punctuation, Return, Tab and Space.
        if (0...50).contains(key) { return true }
        // Keypad text/Enter and JIS punctuation. Clear, navigation, Fn,
        // language-mode keys and function keys never contribute to a token.
        return [65, 67, 69, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95].contains(key)
    }

    private static func normalized(_ value: String, key: Int64) -> String? {
        if key == 76, value == "\u{3}" { return "\n" }
        let text = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if key == 36 || key == 76 { return text == "\n" ? text : nil }
        if key == 48 { return text == "\t" ? text : nil }
        guard text.count == 1, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && !CharacterSet.illegalCharacters.contains(scalar)
                      && !CharacterSet.nonBaseCharacters.contains(scalar)
                      && !(0xF700...0xF8FF).contains(scalar.value)
              }) else { return nil }
        return text
    }
}

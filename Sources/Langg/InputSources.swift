import Carbon
import CoreGraphics
import Foundation
import LanggCore

@MainActor enum InputSources {
    static let selectionRequested = Notification.Name("Langg.inputSourceSelectionRequested")
    private static let supportedIDs: [String: [String]] = [
        "en": ["com.apple.keylayout.US", "com.apple.keylayout.ABC"],
        "ru": ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"]
    ]

    static func isSupportedIdentifier(_ identifier: String) -> Bool {
        supportedIDs.values.contains { $0.contains(identifier) }
    }

    static func decode(_ event: CGEvent) -> DecodedKeystroke? {
        KeyboardInput.decode(event)
    }

    static func currentIsSupported() -> Bool {
        guard let current = currentIdentifier() else { return false }
        return isSupportedIdentifier(current)
    }

    static func toggle() -> Bool {
        guard let current = currentIdentifier() else { return false }
        if supportedIDs["ru"]?.contains(current) == true { return requestSelection("en") }
        if supportedIDs["en"]?.contains(current) == true { return requestSelection("ru") }
        return false
    }

    static func select(_ language: String) -> Bool {
        guard let source = source(for: language), let targetID = identifier(source) else { return false }
        return select(source, identifier: targetID)
    }

    static func requestSelection(_ language: String) -> Bool {
        guard let source = source(for: language) else { return false }
        return request(source)
    }

    static func requestSelection(identifier id: String) -> Bool {
        guard isSupportedIdentifier(id),
              let source = enabledSelectableSources().first(where: { identifier($0) == id }) else { return false }
        // Selection is asynchronous. A stale immediate readback cannot mean
        // rejection after macOS has already accepted the source change.
        return request(source)
    }

    private static func request(_ source: TISInputSource) -> Bool {
        guard TISSelectInputSource(source) == noErr else { return false }
        NotificationCenter.default.post(name: selectionRequested, object: nil)
        return true
    }

    /// Translate only physical printable presses still held by InputReplayGate.
    /// Context-changing input vetoes the complete batch rather than mixing layouts.
    static func retranslated(_ event: CGEvent, language: String) -> CGEvent? {
        guard let source = source(for: language) else { return nil }
        return retranslated(event, source: source)
    }

    /// Undo restores the exact previous layout, including its punctuation variant.
    static func retranslated(_ event: CGEvent, sourceIdentifier: String) -> CGEvent? {
        guard isSupportedIdentifier(sourceIdentifier),
              let source = enabledSelectableSources().first(where: { identifier($0) == sourceIdentifier }) else { return nil }
        return retranslated(event, source: source)
    }

    private static func retranslated(_ event: CGEvent, source: TISInputSource) -> CGEvent? {
        guard event.type == .keyDown || event.type == .keyUp,
              let layoutModifiers = KeyboardInput.layoutModifiers(for: event.flags) else { return nil }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        // ANSI/ISO printable keys and Space. Return, Tab, keypad controls,
        // navigation, deletion, modifiers and function keys are not text.
        guard (0...50).contains(key), key != 36, key != 48,
              let copy = event.copy() else { return nil }
        if event.type == .keyUp { return copy }
        var originalLength = 0
        var originalUnits = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: originalUnits.count, actualStringLength: &originalLength,
                                       unicodeString: &originalUnits)
        guard originalLength > 0, originalLength <= originalUnits.count,
              isPrintable(String(utf16CodeUnits: originalUnits, count: originalLength)),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var modifiers: UInt32 = 0
        if layoutModifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if layoutModifiers.contains(.capsLock) { modifiers |= UInt32(alphaLock) }
        var deadKeys: UInt32 = 0
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        let status = withExtendedLifetime(data) {
            UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDown), modifiers >> 8,
                           keyboardType(for: event), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                           &deadKeys, units.count, &length, &units)
        }
        guard status == noErr, deadKeys == 0, length > 0, length <= units.count,
              isPrintable(String(utf16CodeUnits: units, count: Int(length))) else { return nil }
        let flags = event.flags
        let timestamp = event.timestamp
        let userData = event.getIntegerValueField(.eventSourceUserData)
        units.withUnsafeBufferPointer {
            copy.keyboardSetUnicodeString(stringLength: Int(length), unicodeString: $0.baseAddress!)
        }
        // Preserve the source as well as the event field: reading Unicode can
        // regenerate CGEvent's backing object, including its replay marker.
        if let eventSource = CGEventSource(event: event) {
            eventSource.userData = userData
            copy.setSource(eventSource)
        }
        copy.flags = flags
        copy.timestamp = timestamp
        copy.setIntegerValueField(.keyboardEventKeycode, value: key)
        copy.setIntegerValueField(.keyboardEventKeyboardType,
                                 value: event.getIntegerValueField(.keyboardEventKeyboardType))
        copy.setIntegerValueField(.eventSourceUserData, value: userData)
        return copy
    }

    static func keyboardType(for event: CGEvent) -> UInt32 {
        let reported = event.getIntegerValueField(.keyboardEventKeyboardType)
        guard reported > 0, reported < Int64(UInt32.max), let type = UInt32(exactly: reported) else {
            return UInt32(LMGetKbdType())
        }
        return type
    }

    private static func isPrintable(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return scalar == " " || CharacterSet.alphanumerics.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }

    static func currentIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return identifier(source)
    }

    static func currentLayoutIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return identifier(source)
    }

    static func currentSelection() -> InputSourceSelectionSnapshot {
        InputSourceSelectionSnapshot(sourceID: currentIdentifier(), layoutID: currentLayoutIdentifier())
    }

    private static func source(for language: String) -> TISInputSource? {
        guard let allowed = supportedIDs[language] else { return nil }
        let sources = enabledSelectableSources()
        // Preserve an already-selected supported variant rather than changing
        // between ABC/US or Russian/RussianWin without a language change.
        if let current = currentIdentifier(), allowed.contains(current),
           let source = sources.first(where: { identifier($0) == current }) { return source }
        return allowed.lazy.compactMap { id in sources.first(where: { identifier($0) == id }) }.first
    }

    private static func enabledSelectableSources() -> [TISInputSource] {
        let properties = [kTISPropertyInputSourceIsSelectCapable as String: true,
                          kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        return TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    private static func select(_ source: TISInputSource, identifier: String) -> Bool {
        guard TISSelectInputSource(source) == noErr else { return false }
        return currentSelection().matches(identifier)
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

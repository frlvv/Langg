import Foundation

public struct TextState: Equatable, Sendable {
    public let text: String
    public let selection: NSRange

    public init?(text: String, selection: NSRange) {
        guard LayoutConverter.validatedRange(selection, in: text) != nil else { return nil }
        self.text = text
        self.selection = selection
    }

    public func appendingAtCaret(_ input: String) -> TextState? {
        guard selection.length == 0, let caret = LayoutConverter.validatedRange(selection, in: text) else { return nil }
        return TextState(text: text.replacingCharacters(in: caret, with: input),
                         selection: NSRange(location: selection.location + input.utf16.count, length: 0))
    }

    /// A marker gives a measured offset for this paragraph. Do not extend
    /// that offset across a line break, where Chromium may count differently.
    public func nativeRange(_ range: NSRange, from nativeSelection: NSRange) -> NSRange? {
        guard LayoutConverter.validatedRange(range, in: text) != nil,
              (0...text.utf16.count).contains(nativeSelection.location),
              nativeSelection.length == selection.length else { return nil }
        let start = min(selection.location, range.location)
        let end = max(NSMaxRange(selection), NSMaxRange(range))
        guard let span = LayoutConverter.substring(text, range: NSRange(location: start, length: end - start)),
              !span.contains(where: \.isNewline) else { return nil }
        let location = nativeSelection.location + range.location - selection.location
        guard location >= 0 else { return nil }
        return NSRange(location: location, length: range.length)
    }

    /// Contenteditable fields can expose a nonbreaking space for a physical
    /// space key, or a curly apostrophe for the physical quote key.
    /// Keep the captured text and every UTF-16 offset intact.
    public func matchesEditorState(_ other: TextState?) -> Bool {
        guard let other, selection == other.selection else { return false }
        return Self.editorTextMatches(text, other.text)
    }

    public static func editorTextMatches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16) { left, right in
            left == right || (isEditorSpace(left) && isEditorSpace(right)) ||
                (isEditorApostrophe(left) && isEditorApostrophe(right))
        }
    }

    private static func isEditorApostrophe(_ value: UInt16) -> Bool {
        value == 0x0027 || value == 0x2018 || value == 0x2019
    }

    private static func isEditorSpace(_ value: UInt16) -> Bool {
        value == 0x0020 || value == 0x00A0 || value == 0x2007 || value == 0x202F
    }
}

public struct TextReplacement: Sendable {
    public let before: TextState
    public let after: TextState
    public let range: NSRange
    public let original: String
    public let replacement: String

    public init?(before: TextState, range: NSRange, replacement: String, restoringSelection: NSRange? = nil) {
        guard let swiftRange = LayoutConverter.validatedRange(range, in: before.text), !swiftRange.isEmpty,
              let original = LayoutConverter.substring(before.text, range: range), original != replacement else { return nil }
        let text = before.text.replacingCharacters(in: swiftRange, with: replacement)
        let newLength = replacement.utf16.count
        func translated(_ position: Int, end: Bool) -> Int {
            if position <= range.location { return position }
            if position >= range.location + range.length { return position + newLength - range.length }
            return range.location + (end ? newLength : min(position - range.location, newLength))
        }
        let start = translated(before.selection.location, end: false)
        let end = before.selection.length == 0 ? start : translated(before.selection.location + before.selection.length, end: true)
        let selection = restoringSelection ?? NSRange(location: start, length: end - start)
        guard let after = TextState(text: text, selection: selection) else { return nil }
        self.before = before
        self.after = after
        self.range = range
        self.original = original
        self.replacement = replacement
    }
}

@MainActor public protocol TextEditor {
    associatedtype Field: Equatable
    func read() -> (field: Field, state: TextState)?
    func select(_ range: NSRange, in field: Field) -> Bool
    func supportsDirectReplacement(in field: Field) -> Bool
    func replaceSelection(with text: String, in field: Field) -> Bool
    func insertText(_ text: String, in field: Field, expected: TextState) async -> Bool
}

public extension TextEditor {
    func supportsDirectReplacement(in field: Field) -> Bool { true }
    func insertText(_ text: String, in field: Field, expected: TextState) async -> Bool { false }
}

@MainActor public enum TextReplacementTransaction {
    public static func applyWithFallback<Editor: TextEditor>(_ edit: TextReplacement, to field: Editor.Field, using editor: Editor) async -> TextState? {
        guard !Task.isCancelled,
              let before = editor.read(), before.field == field, before.state == edit.before,
              let selected = TextState(text: edit.before.text, selection: edit.range) else { return nil }

        // AX setters can report success before a web editor exposes the new
        // selection. Own one selection phase, and clean it up on every exit.
        let selectionAccepted = editor.select(edit.range, in: field)
        let result = await applySelected(edit, field: field, selected: selected, editor: editor)
        if result == nil {
            await restoreSelectionAfterAttempt(edit, field: field, selected: selected,
                                               selectionAccepted: selectionAccepted, editor: editor)
        }
        return result
    }

    private static func applySelected<Editor: TextEditor>(_ edit: TextReplacement, field: Editor.Field,
                                                          selected: TextState, editor: Editor) async -> TextState? {
        guard await waitForState(selected, allowing: edit.before, field: field, editor: editor),
              !Task.isCancelled else { return nil }
        if editor.supportsDirectReplacement(in: field) {
            // Capability queries can also make external AX round trips. A
            // selection confirmed before that call may no longer be current.
            guard !Task.isCancelled, let ready = editor.read(),
                  ready.field == field, ready.state == selected else { return nil }
            _ = editor.replaceSelection(with: edit.replacement, in: field)
        // Neither success nor failure from AX proves whether text was written.
        // Both can precede a delayed commit, so use the same readback budget
        // before considering a second insertion method.
            if await waitForText(edit.after.text, allowing: selected, field: field, editor: editor,
                             attempts: 12) {
                return await finishAfterAttempt(edit, field: field, editor: editor)
            }
        }
        guard !Task.isCancelled,
              !edit.replacement.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && !"\n\r\t".unicodeScalars.contains($0)
              }),
              let ready = editor.read(), ready.field == field, ready.state == selected else { return nil }
        // Dispatch is followed by verification even if cancellation or a native
        // error happens after the event was sent. It may already have edited.
        let dispatched = await editor.insertText(edit.replacement, in: field, expected: selected)
        guard await waitForText(edit.after.text, allowing: selected, field: field, editor: editor, attempts: dispatched ? 40 : 1) else { return nil }
        return await finishAfterAttempt(edit, field: field, editor: editor)
    }

    private static func waitForAXUpdate() async {
        // Cleanup must also wait after Task cancellation: posted input and AX
        // selection updates are external side effects and cannot be cancelled.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4)) {
                continuation.resume()
            }
        }
    }

    private static func waitForState<Editor: TextEditor>(_ expected: TextState, allowing previous: TextState,
                                                        field: Editor.Field, editor: Editor) async -> Bool {
        for attempt in 0..<16 {
            // The AX tree can briefly be unavailable while a contenteditable
            // commits selection or text. Only a verified different field/state
            // invalidates the attempt; a missing read uses the existing budget.
            if let current = editor.read() {
                guard current.field == field else { return false }
                if current.state.matchesEditorState(expected) { return true }
                guard current.state.matchesEditorState(previous) else { return false }
            }
            if attempt < 15 { await waitForAXUpdate() }
        }
        return false
    }

    private static func waitForText<Editor: TextEditor>(_ expected: String, allowing previous: TextState,
                                                       field: Editor.Field, editor: Editor, attempts: Int) async -> Bool {
        for attempt in 0..<attempts {
            if let current = editor.read() {
                guard current.field == field else { return false }
                if TextState.editorTextMatches(current.state.text, expected) { return true }
                // A selection may briefly collapse while contenteditable commits
                // its edit. Do not treat that intermediate AX read as a failure.
                guard TextState.editorTextMatches(current.state.text, previous.text) else { return false }
            }
            if attempt + 1 < attempts { await waitForAXUpdate() }
        }
        return false
    }

    private static func finishAfterAttempt<Editor: TextEditor>(_ edit: TextReplacement, field: Editor.Field,
                                                             editor: Editor) async -> TextState? {
        guard let current = editor.read(), current.field == field,
              TextState.editorTextMatches(current.state.text, edit.after.text) else { return nil }
        let insertion = NSRange(location: edit.range.location + edit.replacement.utf16.count, length: 0)
        let replacedSelection = NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
        guard [insertion, replacedSelection, edit.after.selection].contains(current.state.selection) else { return nil }
        if current.state.selection == edit.after.selection { return current.state }
        _ = editor.select(edit.after.selection, in: field)
        guard await waitForState(edit.after, allowing: current.state, field: field, editor: editor),
              let restored = editor.read(), restored.field == field,
              restored.state.matchesEditorState(edit.after) else { return nil }
        return restored.state
    }

    private static func restoreSelectionAfterAttempt<Editor: TextEditor>(_ edit: TextReplacement, field: Editor.Field,
                                                                       selected: TextState, selectionAccepted: Bool,
                                                                       editor: Editor) async {
        var snapshot = editor.read()
        for _ in 0..<3 where snapshot == nil {
            // A rich editor can briefly lose its text markers after selection.
            await waitForAXUpdate()
            snapshot = editor.read()
        }
        guard let current = snapshot, current.field == field else { return }
        let misplacedSelection = selectionAccepted && !Task.isCancelled &&
            current.state.text == edit.before.text && current.state.selection.length > 0
        if current.state == selected || current.state == edit.before || misplacedSelection {
            // Reassert the original caret even when AX still exposes the old
            // state: an earlier accepted selection may still be in flight.
            _ = editor.select(edit.before.selection, in: field)
            let previous = current.state == edit.before ? selected : current.state
            _ = await waitForState(edit.before, allowing: previous, field: field, editor: editor)
        } else if TextState.editorTextMatches(current.state.text, edit.after.text) {
            _ = await finishAfterAttempt(edit, field: field, editor: editor)
        }
    }

    private static func restoreSelection<Editor: TextEditor>(_ edit: TextReplacement, field: Editor.Field, selected: TextState?, editor: Editor) {
        if let current = editor.read(), current.field == field, current.state == selected {
            _ = editor.select(edit.before.selection, in: field)
        }
    }

    private static func finish<Editor: TextEditor>(_ edit: TextReplacement, field: Editor.Field, editor: Editor) -> TextState? {
        guard let written = editor.read(), written.field == field, written.state.text == edit.after.text else { return nil }
        let insertion = NSRange(location: edit.range.location + edit.replacement.utf16.count, length: 0)
        let replacedSelection = NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
        guard [insertion, replacedSelection, edit.after.selection].contains(written.state.selection) else { return nil }
        if written.state == edit.after { return written.state }
        guard editor.select(edit.after.selection, in: field),
              let after = editor.read(), after.field == field, after.state == edit.after else { return nil }
        return after.state
    }

    public static func apply<Editor: TextEditor>(_ edit: TextReplacement, to field: Editor.Field, using editor: Editor) -> TextState? {
        guard let before = editor.read(), before.field == field, before.state == edit.before else { return nil }
        let selected = TextState(text: edit.before.text, selection: edit.range)
        _ = editor.select(edit.range, in: field)
        // Recheck focus and the selected range immediately before AXSelectedText is set.
        guard let ready = editor.read(), ready.field == field, ready.state == selected else {
            restoreSelection(edit, field: field, selected: selected, editor: editor)
            return nil
        }
        _ = editor.replaceSelection(with: edit.replacement, in: field)
        // Some web editors acknowledge AXSelectedText without changing the text.
        // A native success code alone must never strand the original selection.
        guard let current = editor.read(), current.field == field,
              current.state.text == edit.after.text else {
            restoreSelection(edit, field: field, selected: selected, editor: editor)
            return nil
        }
        return finish(edit, field: field, editor: editor)
    }
}

import Foundation
import Testing
@testable import LanggCore

@MainActor private final class FakeEditor: TextEditor {
    var field = 1
    var state: TextState
    var writes = 0
    var selections = 0
    var readCount = 0
    var replaceFails = false
    var replacementIsNoOp = false
    var keyboardEnabled = false
    var directReplacementSupported = true
    var keyboardWrites = 0
    var beforeKeyboard: ((FakeEditor) -> Void)?
    var onRead: ((FakeEditor) -> Void)?
    var onSelect: ((FakeEditor) -> Void)?
    var afterKeyboard: ((FakeEditor) -> Void)?
    var nativeReportsFailureAfterWrite = false
    var keyboardReportsFailureAfterWrite = false

    init(_ state: TextState) { self.state = state }
    func supportsDirectReplacement(in field: Int) -> Bool { directReplacementSupported }
    func read() -> (field: Int, state: TextState)? {
        readCount += 1
        onRead?(self)
        return (field, state)
    }
    func select(_ range: NSRange, in field: Int) -> Bool {
        selections += 1
        guard self.field == field, let state = TextState(text: state.text, selection: range) else { return false }
        self.state = state
        onSelect?(self)
        return true
    }
    func replaceSelection(with text: String, in field: Int) -> Bool {
        guard !replaceFails, self.field == field, let range = Range(state.selection, in: state.text) else { return false }
        if replacementIsNoOp { return true }
        writes += 1
        state = TextState(text: state.text.replacingCharacters(in: range, with: text),
                          selection: NSRange(location: state.selection.location + text.utf16.count, length: 0))!
        return !nativeReportsFailureAfterWrite
    }
    func insertText(_ text: String, in field: Int, expected: TextState) async -> Bool {
        await Task.yield()
        beforeKeyboard?(self)
        guard keyboardEnabled, self.field == field, state == expected,
              let range = Range(state.selection, in: state.text) else { return false }
        keyboardWrites += 1
        state = TextState(text: state.text.replacingCharacters(in: range, with: text),
                          selection: NSRange(location: state.selection.location + text.utf16.count, length: 0))!
        afterKeyboard?(self)
        return !keyboardReportsFailureAfterWrite
    }
}

@MainActor @Test func unsupportedNativeSetterIsSkippedBeforeVerifiedPaste() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.directReplacementSupported = false
    editor.keyboardEnabled = true
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == edit.after)
    #expect(editor.writes == 0)
    #expect(editor.keyboardWrites == 1)
}

@MainActor @Test func transactionRestoresCaretAfterDelimiter() throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    #expect(TextReplacementTransaction.apply(edit, to: 1, using: editor) == edit.after)
    #expect(editor.state.text == "привет ")
    #expect(editor.state.selection.location == 7)
    #expect(editor.writes == 1)
}

@MainActor @Test func transactionNeverWritesAfterFocusChanges() throws {
    let state = try #require(TextState(text: "[fn ", selection: NSRange(location: 4, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 3), replacement: "хат"))
    let editor = FakeEditor(state)
    editor.onRead = { editor in if editor.readCount == 2 { editor.field = 2 } }
    #expect(TextReplacementTransaction.apply(edit, to: 1, using: editor) == nil)
    #expect(editor.writes == 0)
    #expect(editor.state.text == "[fn ")
}

@MainActor @Test func transactionDoesNotOverwriteNewInput() throws {
    let state = try #require(TextState(text: "[fn ", selection: NSRange(location: 4, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 3), replacement: "хат"))
    let editor = FakeEditor(state)
    editor.state = try #require(state.appendingAtCaret("x"))
    #expect(TextReplacementTransaction.apply(edit, to: 1, using: editor) == nil)
    #expect(editor.writes == 0)
    #expect(editor.selections == 0)
}

@MainActor @Test func failedReplacementRestoresOriginalSelection() throws {
    let state = try #require(TextState(text: "[fn ", selection: NSRange(location: 4, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 3), replacement: "хат"))
    let editor = FakeEditor(state)
    editor.replaceFails = true
    #expect(TextReplacementTransaction.apply(edit, to: 1, using: editor) == nil)
    #expect(editor.state == state)
}

@MainActor @Test func transactionDoesNotMoveCaretAfterUnexpectedNativeEdit() throws {
    let state = try #require(TextState(text: "[fn ", selection: NSRange(location: 4, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 3), replacement: "хат"))
    let editor = FakeEditor(state)
    editor.onRead = { editor in
        if editor.readCount == 3 { editor.state = TextState(text: "хат x", selection: NSRange(location: 5, length: 0))! }
    }
    #expect(TextReplacementTransaction.apply(edit, to: 1, using: editor) == nil)
    #expect(editor.state.text == "хат x")
    #expect(editor.selections == 1)
}

@MainActor @Test func repeatedFastTypingKeepsEveryCharacter() throws {
    var state = try #require(TextState(text: "", selection: NSRange(location: 0, length: 0)))
    let words = [("ghbdtn", "привет"), ("[fn", "хат"), ("vbh", "мир"), ("rjn", "кот")]
    var expected = ""
    for i in 0..<300 {
        let (input, output) = words[i % words.count]
        for c in input + " " { state = try #require(state.appendingAtCaret(String(c))) }
        let range = NSRange(location: state.selection.location - input.utf16.count - 1, length: input.utf16.count)
        let edit = try #require(TextReplacement(before: state, range: range, replacement: output))
        let editor = FakeEditor(state)
        state = try #require(TextReplacementTransaction.apply(edit, to: 1, using: editor))
        expected += output + " "
        #expect(state.text == expected)
        #expect(state.selection == NSRange(location: state.text.utf16.count, length: 0))
    }
    #expect(expected.utf16.count > 1_000)
}

@MainActor @Test func acknowledgedNativeNoOpRestoresSelection() throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.replacementIsNoOp = true
    #expect(TextReplacementTransaction.apply(edit, to: 1, using: editor) == nil)
    #expect(editor.state == state)
}

@MainActor @Test(arguments: [true, false]) func keyboardFallbackReplacesOnlyTheVerifiedSelection(nativeNoOp: Bool) async throws {
    let state = try #require(TextState(text: "🙂 ghbdtn next", selection: NSRange(location: 10, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 3, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.replacementIsNoOp = nativeNoOp
    editor.replaceFails = !nativeNoOp
    editor.keyboardEnabled = true
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == edit.after)
    #expect(editor.state.text == "🙂 привет next")
    #expect(editor.keyboardWrites == 1)
    #expect(editor.writes == 0)
}

@MainActor @Test func fallbackNeverOverwritesConcurrentTyping() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.replaceFails = true
    editor.keyboardEnabled = true
    editor.beforeKeyboard = { editor in
        editor.state = TextState(text: "user input", selection: NSRange(location: 10, length: 0))!
    }
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == nil)
    #expect(editor.keyboardWrites == 0)
    #expect(editor.state.text == "user input")
}

@MainActor @Test func queuedBurstKeepsEveryCompletedWordBeforeWorkerStarts() throws {
    var queue = CorrectionQueue()
    var state = try #require(TextState(text: "🙂 ", selection: NSRange(location: 3, length: 0)))
    for _ in 0..<32 {
        for character in "ghbdtn " {
            let text = String(character)
            queue.append(text, completesWord: character.isWhitespace)
            state = try #require(state.appendingAtCaret(text))
        }
    }
    #expect(queue.requests.count == 32)
    var completed = 0
    while let request = queue.requests.first {
        let boundary = try #require(queue.boundaryCaret(for: request.id, in: state))
        let candidate = try #require(AutomaticCorrection.candidates(in: state.text, caretUTF16: boundary).first)
        let edit = try #require(TextReplacement(before: state, range: candidate.range, replacement: candidate.replacement))
        state = try #require(TextReplacementTransaction.apply(edit, to: 1, using: FakeEditor(state)))
        queue.remove(request.id)
        completed += 1
    }
    #expect(completed == 32)
    #expect(state.text == "🙂 " + String(repeating: "привет ", count: 32))
    #expect(state.selection.location == state.text.utf16.count)
}


@MainActor @Test func delayedAXSelectionIsVerifiedBeforeReplacing() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.onSelect = { editor in
        if editor.selections == 1 { editor.state = state }
    }
    editor.onRead = { editor in
        if editor.readCount == 3 { editor.state = TextState(text: state.text, selection: edit.range)! }
    }
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == edit.after)
    #expect(editor.state == edit.after)
    #expect(editor.writes == 1)
}

@MainActor @Test func nativeErrorAfterWriteNeverDispatchesDuplicateFallback() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.nativeReportsFailureAfterWrite = true
    editor.keyboardEnabled = true
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == edit.after)
    #expect(editor.keyboardWrites == 0)
    #expect(editor.state == edit.after)
}

@MainActor @Test func nativeErrorWithDelayedCommitNeverDispatchesFallback() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.nativeReportsFailureAfterWrite = true
    editor.keyboardEnabled = true
    editor.onRead = { editor in
        // Native AX reports an error while its commit is still queued. The
        // first two subsequent snapshots retain the original selected text.
        if editor.readCount == 3 {
            editor.state = TextState(text: state.text, selection: edit.range)!
        } else if editor.readCount == 5 {
            editor.state = TextState(text: edit.after.text, selection: NSRange(location: 6, length: 0))!
        }
    }
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == edit.after)
    #expect(editor.keyboardWrites == 0)
    #expect(editor.writes == 1)
    #expect(editor.state == edit.after)
}

@MainActor @Test func nativeNoOpUsesOneSelectionPhaseForFallback() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.replacementIsNoOp = true
    editor.keyboardEnabled = true
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == edit.after)
    #expect(editor.selections == 2)
}

@MainActor @Test func cancelledDispatchStillRestoresCaretAfterConfirmedInsertion() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.replaceFails = true
    editor.keyboardEnabled = true
    editor.keyboardReportsFailureAfterWrite = true
    editor.afterKeyboard = { _ in withUnsafeCurrentTask { $0?.cancel() } }
    let task = Task { await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) }
    #expect(await task.value == edit.after)
    #expect(editor.state == edit.after)
    #expect(editor.keyboardWrites == 1)
}

@MainActor @Test func delayedCaretRestorationIsVerified() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    var restoreAtRead: Int?
    editor.onSelect = { editor in
        if editor.selections == 2 {
            editor.state = TextState(text: edit.after.text, selection: NSRange(location: 6, length: 0))!
            restoreAtRead = editor.readCount + 2
        }
    }
    editor.onRead = { editor in
        if editor.readCount == restoreAtRead { editor.state = edit.after }
    }
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == edit.after)
    #expect(editor.state == edit.after)
}

@MainActor @Test func unsuccessfulFallbackRestoresOriginalCaret() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.replaceFails = true
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == nil)
    #expect(editor.state == state)
    #expect(editor.writes == 0)
    #expect(editor.keyboardWrites == 0)
}


@MainActor @Test func clipboardFallbackSupportsLongMultilineSelection() async throws {
    let original = String(repeating: "ghbdtn ", count: 30) + "\nsecond line"
    let replacement = String(repeating: "привет ", count: 30) + "\nвторая строка"
    let state = try #require(TextState(text: original, selection: NSRange(location: 0, length: original.utf16.count)))
    let edit = try #require(TextReplacement(before: state, range: state.selection, replacement: replacement))
    let editor = FakeEditor(state)
    editor.replaceFails = true
    editor.keyboardEnabled = true
    #expect(await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) == edit.after)
    #expect(editor.state == edit.after)
    #expect(editor.keyboardWrites == 1)
}

@MainActor @Test func cancelledDispatchedInputCanCommitOnLaterAXRead() async throws {
    let state = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 7, length: 0)))
    let edit = try #require(TextReplacement(before: state, range: NSRange(location: 0, length: 6), replacement: "привет"))
    let editor = FakeEditor(state)
    editor.replaceFails = true
    editor.keyboardEnabled = true
    editor.afterKeyboard = { editor in
        editor.state = TextState(text: state.text, selection: edit.range)!
        let commitRead = editor.readCount + 3
        editor.onRead = { editor in
            if editor.readCount == commitRead {
                editor.state = TextState(text: edit.after.text, selection: NSRange(location: 6, length: 0))!
            }
        }
        withUnsafeCurrentTask { $0?.cancel() }
    }
    let task = Task { await TextReplacementTransaction.applyWithFallback(edit, to: 1, using: editor) }
    #expect(await task.value == edit.after)
    #expect(editor.state == edit.after)
    #expect(editor.keyboardWrites == 1)
}

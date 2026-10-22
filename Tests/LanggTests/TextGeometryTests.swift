import Foundation
import Testing
@testable import Langg

@Test func correctionAnchorUsesEditedWordEvenWhenCaretHasMovedOn() {
    #expect(TextGeometry.leadingCharacter(in: "ghbdtn next words", range: NSRange(location: 0, length: 6)) == NSRange(location: 0, length: 1))
    #expect(TextGeometry.leadingCharacter(in: "hello 🙂word", range: NSRange(location: 6, length: 6)) == NSRange(location: 6, length: 2))
}

@Test func anchorSkipsLeadingLineBreaksAndKeepsComposedCharacters() {
    let text = "\n e\u{301}cho"
    #expect(TextGeometry.leadingCharacter(in: text, range: NSRange(location: 0, length: text.utf16.count)) == NSRange(location: 2, length: 2))
    #expect(TextGeometry.leadingCharacter(in: "word", range: NSRange(location: 4, length: 0)) == nil)
    #expect(TextGeometry.leadingCharacter(in: "word", range: NSRange(location: 20, length: 1)) == nil)
}

@Test func anchorRejectsInputFrameAndUnavailableGeometry() {
    let input = CGRect(x: 300, y: 400, width: 600, height: 200)
    #expect(!TextGeometry.usable(input, characterCount: 1, fieldFrame: input))
    #expect(!TextGeometry.usable(.zero, characterCount: 1, fieldFrame: input))
    #expect(!TextGeometry.usable(CGRect(x: 0, y: 0, width: 8, height: 18), characterCount: 1, fieldFrame: input))
    #expect(TextGeometry.usable(CGRect(x: 325, y: 430, width: 8, height: 18), characterCount: 1, fieldFrame: input))
    #expect(TextGeometry.usable(CGRect(x: 325, y: 430, width: 0, height: 18), characterCount: 1, fieldFrame: input))
}

@MainActor @Test func toastAppearsAboveEditedWordInsteadOfAFullPanelWidthToTheLeft() throws {
    let word = CGRect(x: 600, y: 300, width: 8, height: 18)
    let size = CGSize(width: 150, height: 30)
    let frame = try #require(CaretToast.frame(near: word, in: CGRect(x: 0, y: 0, width: 1440, height: 900), size: size))
    #expect(frame.minX + 12 == word.minX)
    #expect(frame.minY == word.maxY + 4)
    #expect(!frame.intersects(word))
}

@MainActor @Test func toastStaysOnSecondaryScreenAndFallsBelowTextAtTopEdge() throws {
    let screen = CGRect(x: -1920, y: 400, width: 1920, height: 1080)
    let word = CGRect(x: -1910, y: 1440, width: 8, height: 18)
    let frame = try #require(CaretToast.frame(near: word, in: screen, size: CGSize(width: 150, height: 30)))
    #expect(screen.contains(frame))
    #expect(frame.maxY == word.minY - 4)
    #expect(!frame.intersects(word))
}

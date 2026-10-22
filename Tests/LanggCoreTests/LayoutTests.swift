import Foundation
import Testing
@testable import LanggCore

@Test(arguments: [
    ("ghbdtn", "привет"), ("Ghbdtn", "Привет"),
    ("руддщ", "hello"), ("РУДДЩ", "HELLO")
])
func convertsKeys(input: String, output: String) {
    let direction: LayoutDirection = LayoutConverter.detectedDirection(input)!
    #expect(LayoutConverter.convert(input, direction: direction) == output)
}

@Test func preservesSurroundingUTF16Text() {
    let text = "🙂 ghbdtn! конец"
    let range = LayoutConverter.precedingWord(in: text, caretUTF16: 10, completed: true)
    #expect(range == NSRange(location: 3, length: 6))
    #expect(LayoutConverter.substring(text, range: range!) == "ghbdtn")
}

@Test(arguments: [
    ("[fn", "хат"), ("]eq", "ъуй"), (";tyf", "жена"), ("'eq", "эуй"),
    (",eq", "буй"), (".eq", "юуй"), ("`eq", "ёуй"),
    ("{fn", "Хат"), ("}eq", "Ъуй"), (":eq", "Жуй"), ("\"eq", "Эуй"),
    ("<eq", "Буй"), (">eq", "Юуй"), ("~eq", "Ёуй")
])
func convertsLeadingPhysicalKey(input: String, output: String) {
    let range = LayoutConverter.precedingWord(in: input, caretUTF16: input.utf16.count)
    #expect(range == NSRange(location: 0, length: input.utf16.count))
    let completed = LayoutConverter.precedingWord(in: input + " ", caretUTF16: input.utf16.count + 1, completed: true)
    #expect(completed == range)
    #expect(LayoutConverter.convert(input, direction: .englishToRussian) == output)
}

@Test func leadingKeyAfterSeparatorPreservesAdjacentText() {
    let text = "🙂 привет [fn"
    let range = LayoutConverter.precedingWord(in: text, caretUTF16: text.utf16.count)
    #expect(LayoutConverter.substring(text, range: range!) == "[fn")
    #expect(LayoutConverter.precedingWord(in: "hello,world", caretUTF16: 11) == NSRange(location: 6, length: 5))
    #expect(LayoutConverter.convert("ghbdtn, vbh", direction: .englishToRussian) == "привет, мир")
    #expect(LayoutConverter.convert("Хат", direction: .russianToEnglish) == "{fn")
}

@Test func rejectsMixedWords() {
    #expect(LayoutConverter.detectedDirection("abcтест") == nil)
    #expect(LayoutConverter.detectedDirection("x@y") == .englishToRussian)
}

@Test func convertsSelectedSentence() {
    let input = "🙂 Ghbdtn, vbh!\n"
    #expect(LayoutConverter.detectedDirection(input) == .englishToRussian)
    #expect(LayoutConverter.convert(input, direction: .englishToRussian) == "🙂 Привет, мир!\n")
}

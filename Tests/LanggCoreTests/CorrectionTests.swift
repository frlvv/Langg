import Foundation
import Testing
@testable import LanggCore

@Test(arguments: [
    ("[fn ", "[fn", "хат"), ("vbh ", "vbh", "мир"), ("rjn ", "rjn", "кот"),
    ("ljv ", "ljv", "дом"), ("njn ", "njn", "тот"), ("lf ", "lf", "да"),
    ("gj;fkeqcnf ", "gj;fkeqcnf", "пожалуйста"), ("[kt, ", "[kt,", "хлеб"),
    (",j, ", ",j,", "боб"), ("k.,jdm ", "k.,jdm", "любовь"),
    ("🙂 [fn, ", "[fn", "хат"), ("{FN! ", "{FN", "ХАТ"),
    ("руддщ ", "руддщ", "hello"), ("ЦЩКДВ ", "ЦЩКДВ", "WORLD")
])
func automaticCandidatesIncludeCompletePhysicalWords(text: String, original: String, replacement: String) {
    let candidates = AutomaticCorrection.candidates(in: text, caretUTF16: text.utf16.count)
    #expect(candidates.contains { $0.original == original && $0.replacement == replacement })
}

@Test func sourceDictionaryCannotDiscardLeadingKeyboardKeys() throws {
    let candidate = try #require(AutomaticCorrection.candidates(in: "[fn ", caretUTF16: 4).first)
    #expect(!candidate.sourceNeedsDictionaryCheck)
    #expect(AutomaticCorrection.shouldCorrect(candidate, sourceKnown: true, targetKnown: true))
    #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: false, targetKnown: nil))
    #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: false, targetKnown: false))
}

@Test func automaticCorrectionKeepsValidAndAmbiguousWords() throws {
    let candidate = try #require(AutomaticCorrection.candidates(in: "cat ", caretUTF16: 4).first)
    #expect(candidate.sourceNeedsDictionaryCheck)
    #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: true, targetKnown: true))
    #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: nil, targetKnown: true))
    #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: false, targetKnown: false))
    #expect(AutomaticCorrection.shouldCorrect(candidate, sourceKnown: false, targetKnown: true))
}

@Test(arguments: ["/tmp/ghbdtn ", "https://ghbdtn ", "foo@ghbdtn ", "@ghbdtn ",
                  "foo_ghbdtn ", "foo-ghbdtn ", "--ghbdtn ", "ghbdtn42 ", "42ghbdtn ",
                  "$ghbdtn ", "ghbdtn=ghbdtn ", "abcтест ", "🙂 "])
func automaticCorrectionRejectsTechnicalAndMixedTokens(_ text: String) {
    #expect(AutomaticCorrection.candidates(in: text, caretUTF16: text.utf16.count).isEmpty)
}

@Test func wordExclusionsAreCaseInsensitive() {
    #expect(AutomaticCorrection.candidates(in: "[FN ", caretUTF16: 4, excludedWords: ["[fn"]).isEmpty)
    #expect(AutomaticCorrection.candidates(in: "GHBDTN ", caretUTF16: 7, excludedWords: ["ghbdtn"]).isEmpty)
    #expect(AutomaticCorrection.candidates(in: "[fn ", caretUTF16: 4, excludedWords: ["ХАТ"]).isEmpty)
}

@Test(arguments: ["", " ", "ghbdtn ", "ghbdtn, ", "ghbdtn!  ", "🙂 ghbdtn\n", "[ghbdtn] "])
func manualWordRangesPreserveSeparators(_ text: String) throws {
    let range = LayoutConverter.precedingWord(in: text, caretUTF16: text.utf16.count)
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { #expect(range == nil); return }
    #expect(LayoutConverter.substring(text, range: try #require(range)) == "ghbdtn")
}

@Test func conversionHandlesAllPhysicalLettersAndUppercase() {
    let english = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`"
    let russian = "йцукенгшщзхъфывапролджэячсмитьбюё"
    let shifted = "QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>~"
    #expect(LayoutConverter.convert(english, direction: .englishToRussian, punctuation: .physicalKeys) == russian)
    #expect(LayoutConverter.convert(russian, direction: .russianToEnglish) == english)
    #expect(LayoutConverter.convert(shifted, direction: .englishToRussian, punctuation: .physicalKeys) == russian.uppercased())
    #expect(LayoutConverter.convert(russian.uppercased(), direction: .russianToEnglish) == shifted)
    for (en, ru) in zip(english, russian) {
        #expect(LayoutConverter.convert(String(en), direction: .englishToRussian, punctuation: .physicalKeys) == String(ru))
        #expect(LayoutConverter.convert(String(ru), direction: .russianToEnglish) == String(en))
    }
}

@Test func conversionPreservesUnicodeAndSentenceSeparators() {
    #expect(LayoutConverter.convert("🙂 Ghbdtn, vbh!\n[ghbdtn] ;tyf", direction: .englishToRussian) == "🙂 Привет, мир!\n[привет] жена")
    #expect(LayoutConverter.convert("gj;fkeqcnf pfrhjq jryj", direction: .englishToRussian) == "пожалуйста закрой окно")
    #expect(LayoutConverter.convert("é İ e\u{301} 👩🏽‍💻", direction: .englishToRussian) == nil)
    #expect(LayoutConverter.detectedDirection("İ") == nil)
    #expect(LayoutConverter.detectedDirection("abcтест") == nil)
}

@Test(arguments: [-1, 1, Int.max])
func invalidCaretDoesNotSplitEmoji(_ caret: Int) {
    #expect(LayoutConverter.precedingWord(in: "🙂ghbdtn", caretUTF16: caret) == nil)
}

@Test func invalidRangesDoNotTrapOrSplitUTF16() {
    for range in [NSRange(location: -1, length: 1), NSRange(location: Int.max, length: Int.max),
                  NSRange(location: 1, length: 1), NSRange(location: 0, length: 20)] {
        #expect(TextState(text: "🙂abc", selection: range) == nil)
        #expect(LayoutConverter.substring("🙂abc", range: range) == nil)
        #expect(!LayoutConverter.isSafeAutomaticContext(in: "🙂abc", range: range))
    }
}

@Test func replacementKeepsCaretAfterSeparatorAndNewWord() throws {
    let before = try #require(TextState(text: "🙂 ghbdtn vbh ", selection: NSRange(location: 14, length: 0)))
    let edit = try #require(TextReplacement(before: before, range: NSRange(location: 3, length: 6), replacement: "привет"))
    #expect(edit.after.text == "🙂 привет vbh ")
    #expect(edit.after.selection == before.selection)
    let undo = try #require(TextReplacement(before: edit.after, range: edit.range, replacement: edit.original,
                                          restoringSelection: before.selection))
    #expect(undo.after == before)
}

@Test func replacementPreservesSelectedTextAndAdjustsLengths() throws {
    let before = try #require(TextState(text: "🙂 hello!", selection: NSRange(location: 3, length: 5)))
    let edit = try #require(TextReplacement(before: before, range: before.selection, replacement: "привет"))
    #expect(edit.after.text == "🙂 привет!")
    #expect(edit.after.selection == NSRange(location: 3, length: 6))
    let caret = try #require(TextState(text: before.text, selection: NSRange(location: 9, length: 0)))
    #expect(TextReplacement(before: caret, range: before.selection, replacement: "привет")?.after.selection.location == 10)
}

@Test func typingDuringSpellingRebasesOnlyAppendAtOriginalCaret() throws {
    let before = try #require(TextState(text: "ghbdtn  конец", selection: NSRange(location: 7, length: 0)))
    let expected = before.appendingAtCaret("vbh")
    #expect(expected?.text == "ghbdtn vbh конец")
    #expect(expected?.selection.location == 10)
    #expect(expected != TextState(text: "ghbdtn  конецvbh", selection: NSRange(location: 15, length: 0)))
}

@Test func caretInsideReplacementRemainsAnInsertionPoint() throws {
    let before = try #require(TextState(text: "hello", selection: NSRange(location: 2, length: 0)))
    let edit = try #require(TextReplacement(before: before, range: NSRange(location: 0, length: 5), replacement: "привет"))
    #expect(edit.after.selection == NSRange(location: 2, length: 0))
}

@Test(arguments: [1, 2, 3, 4, 5, 6])
func manualCorrectionIncludesWholeWordAtCaret(_ caret: Int) throws {
    let text = "ghbdtn, vbh"
    let range = try #require(LayoutConverter.manualWordCandidates(in: text, caretUTF16: caret).last)
    #expect(LayoutConverter.substring(text, range: range) == "ghbdtn")
    #expect(range == NSRange(location: 0, length: 6))
}

@Test func queueRetainsCompletedWordDuringFastTyping() throws {
    var queue = CorrectionQueue()
    queue.append(" ", completesWord: true)
    let first = try #require(queue.requests.first)
    for c in "vbh" { queue.append(String(c), completesWord: false) }
    queue.append(" ", completesWord: true)
    let state = try #require(TextState(text: "ghbdtn vbh ", selection: NSRange(location: 11, length: 0)))
    #expect(queue.boundaryCaret(for: first.id, in: state) == 7)
    #expect(queue.request(first.id)?.suffix == " vbh ")
    let second = try #require(queue.requests.last)
    #expect(queue.boundaryCaret(for: second.id, in: state) == 11)
    queue.remove(first.id)
    #expect(queue.requests.count == 1)
    queue.reset()
    #expect(queue.requests.isEmpty)
}

@Test func queueIsBoundedAndRejectsMovedCaret() throws {
    var queue = CorrectionQueue()
    for _ in 0..<100 { queue.append(" ", completesWord: true) }
    #expect(queue.requests.count == 64)
    let request = try #require(queue.requests.first)
    let moved = try #require(TextState(text: "ghbdtn ", selection: NSRange(location: 3, length: 0)))
    #expect(queue.boundaryCaret(for: request.id, in: moved) == nil)
    for _ in 0..<4097 { queue.append("x", completesWord: false) }
    #expect(queue.requests.isEmpty)
}

@Test(arguments: ["дм ", "lf ", "lv ", "ab "])
func twoLetterAbbreviationsNeedMoreThanATargetDictionaryHit(_ text: String) {
    for candidate in AutomaticCorrection.candidates(in: text, caretUTF16: text.utf16.count) {
        #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: false, targetKnown: true))
    }
}

@Test func aSingleLetterNeedsConfirmedTargetLanguageContext() throws {
    let candidate = try #require(AutomaticCorrection.candidates(in: "z ", caretUTF16: 2).first)
    #expect(candidate.replacement == "я")
    #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: true, targetKnown: true))
    #expect(AutomaticCorrection.shouldCorrect(candidate, sourceKnown: true, targetKnown: true, targetContextKnown: true))
    let abbreviation = try #require(AutomaticCorrection.candidates(in: "дм ", caretUTF16: 3).first)
    #expect(!AutomaticCorrection.shouldCorrect(abbreviation, sourceKnown: false, targetKnown: true, targetContextKnown: true))
}

@Test func aLaterWordRevisitsAmbiguousTokensWithinTheCurrentLine() {
    let text = "ofc z вообще "
    let candidates = AutomaticCorrection.contextualCandidates(in: text, caretUTF16: text.utf16.count)
    #expect(candidates.contains { $0.original == "ofc" && $0.replacement == "щас" })
    #expect(candidates.contains { $0.original == "z" && $0.replacement == "я" })
    if let candidate = candidates.first(where: { $0.original == "ofc" }) {
        #expect(AutomaticCorrection.contextWords(for: candidate, in: text).contains("вообще"))
        #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: true, targetKnown: true))
        #expect(AutomaticCorrection.shouldCorrect(candidate, sourceKnown: true, targetKnown: true, targetContextKnown: true))
    }
}

@Test(arguments: ["ofc\nвообще ", "ofc " + String(repeating: " ", count: 65) + "вообще ", "ofc /tmp/file вообще "])
func contextualRescanStopsAtLineDistanceAndUnsafeTokens(_ text: String) {
    #expect(!AutomaticCorrection.contextualCandidates(in: text, caretUTF16: text.utf16.count).contains { $0.original == "ofc" })
}

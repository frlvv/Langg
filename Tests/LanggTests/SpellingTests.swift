import Foundation
import Testing
import LanggCore
@testable import Langg

@MainActor @Test(arguments: [
    ("[kt, ", "хлеб"), ("vbh ", "мир"), ("rjn ", "кот"), ("ljv ", "дом"),
    ("njn ", "тот"), ("gj;fkeqcnf ", "пожалуйста"),
    ("k.,jdm ", "любовь"), (",j, ", "боб"), ("руддщ ", "hello"), ("вщтэе ", "don't")
])
func actualSystemDictionaryCorrectsLayout(text: String, expected: String) async throws {
    let spelling = SpellingService()
    var accepted: String?
    var decisions: [String] = []
    for candidate in AutomaticCorrection.candidates(in: text, caretUTF16: text.utf16.count) {
        let source = candidate.sourceNeedsDictionaryCheck ? await spelling.isKnown(candidate.original, language: candidate.direction.sourceLanguage, acceptCaseVariants: false) : false
        let target = await spelling.isKnown(candidate.replacement, language: candidate.direction.targetLanguage)
        decisions.append("\(candidate.original): source=\(String(describing: source)), target=\(String(describing: target))")
        if AutomaticCorrection.shouldCorrect(candidate, sourceKnown: source, targetKnown: target) { accepted = candidate.replacement; break }
    }
    #expect(accepted == expected, "\(decisions)")
}

@MainActor @Test(arguments: ["hello", "world", "cat", "the", "code", "git", "API", "привет", "мир", "дом", "хат"])
func actualSystemDictionaryKeepsCorrectWords(_ word: String) async {
    let spelling = SpellingService()
    let text = word + " "
    for candidate in AutomaticCorrection.candidates(in: text, caretUTF16: text.utf16.count) {
        let source = candidate.sourceNeedsDictionaryCheck ? await spelling.isKnown(candidate.original, language: candidate.direction.sourceLanguage, acceptCaseVariants: false) : false
        let target = await spelling.isKnown(candidate.replacement, language: candidate.direction.targetLanguage)
        #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: source, targetKnown: target))
    }
}

@MainActor @Test func caseOnlyDictionarySuggestionsRecogniseProductWords() async {
    let spelling = SpellingService()
    #expect(await spelling.isKnown("iphone", language: "en") == true)
    #expect(await spelling.isKnown("щас", language: "ru") == true)
}

@MainActor @Test func actualDictionaryUsesRussianPhraseToResolveKnownEnglishAbbreviations() async throws {
    let spelling = SpellingService()
    let text = "ofc z вообще "
    let candidates = AutomaticCorrection.contextualCandidates(in: text, caretUTF16: text.utf16.count)
    var accepted: [String: String] = [:]
    for candidate in candidates {
        let source = await spelling.isKnown(candidate.original, language: candidate.direction.sourceLanguage, acceptCaseVariants: false)
        let target = await spelling.isKnown(candidate.replacement, language: candidate.direction.targetLanguage)
        let targetScript: LayoutDirection = candidate.direction == .englishToRussian ? .russianToEnglish : .englishToRussian
        var context = false
        for word in AutomaticCorrection.contextWords(for: candidate, in: text) {
            if LayoutConverter.isAlphabeticWord(word, direction: targetScript),
               await spelling.isKnown(word, language: candidate.direction.targetLanguage) == true { context = true; break }
        }
        if AutomaticCorrection.shouldCorrect(candidate, sourceKnown: source, targetKnown: target, targetContextKnown: context) {
            accepted[candidate.original] = candidate.replacement
        }
    }
    #expect(accepted["ofc"] == "щас")
    #expect(accepted["z"] == "я")
    #expect(accepted["вообще"] == nil)
}

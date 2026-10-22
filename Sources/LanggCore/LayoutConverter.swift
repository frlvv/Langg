import Foundation

public enum LayoutDirection: String, Codable, CaseIterable, Sendable {
    case englishToRussian, russianToEnglish

    public var sourceLanguage: String { self == .englishToRussian ? "en" : "ru" }
    public var targetLanguage: String { self == .englishToRussian ? "ru" : "en" }
}

public enum LayoutConverter {
    public enum Punctuation { case contextual, physicalKeys }

    private static let english = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`")
    private static let russian = Array("йцукенгшщзхъфывапролджэячсмитьбюё")
    private static let shifted = Array("QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>~")
    private static let upperRussian = Array("ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮЁ")
    private static let toRussian = Dictionary(uniqueKeysWithValues: zip(english + shifted, russian + upperRussian))
    private static let toEnglish = Dictionary(uniqueKeysWithValues: zip(russian + upperRussian, english + shifted))
    private static let punctuationKeys = Set("[];'`,.{}:\"~<>")

    public static func isEnglishLetter(_ c: Character) -> Bool {
        c.isASCII && (("a"..."z").contains(c) || ("A"..."Z").contains(c))
    }

    public static func isRussianLetter(_ c: Character) -> Bool { toEnglish[c] != nil }
    public static func isLayoutLetter(_ c: Character) -> Bool { isEnglishLetter(c) || isRussianLetter(c) }
    public static func isPhysicalLetterKey(_ c: Character) -> Bool { isLayoutLetter(c) || punctuationKeys.contains(c) }

    // Spell check may silently omit leading punctuation keyboard letters.
    public static func isAlphabeticWord(_ text: String, direction: LayoutDirection) -> Bool {
        let characters = Array(text)
        guard !characters.isEmpty else { return false }
        return characters.enumerated().allSatisfy { index, character in
            if direction == .russianToEnglish { return isRussianLetter(character) }
            if isEnglishLetter(character) { return true }
            return character == "'" && index > 0 && index + 1 < characters.count &&
                isEnglishLetter(characters[index - 1]) && isEnglishLetter(characters[index + 1])
        }
    }

    public static func convert(_ text: String, direction: LayoutDirection, punctuation: Punctuation = .contextual) -> String? {
        let mapping = direction == .englishToRussian ? toRussian : toEnglish
        let characters = Array(text)
        var output = String()
        output.reserveCapacity(text.utf16.count)
        for (index, character) in characters.enumerated() {
            guard let mapped = mapping[character] else { output.append(character); continue }
            if direction == .englishToRussian, punctuation == .contextual, punctuationKeys.contains(character) {
                let nextIsLetter = index + 1 < characters.count && isEnglishLetter(characters[index + 1])
                let atWordStart = index == 0 || characters[index - 1].isWhitespace
                let internalKey = nextIsLetter && index > 0 && isEnglishLetter(characters[index - 1]) && !",.\"".contains(character)
                let closing: [Character: Character] = ["[": "]", "{": "}", "<": ">", "\"": "\"", "'": "'"]
                let isWrapper = closing[character].map { closingChar in
                    characters.dropFirst(index + 1).prefix(while: { !$0.isWhitespace }).contains(closingChar)
                } ?? false
                guard !isWrapper && nextIsLetter && (atWordStart || internalKey) else { output.append(character); continue }
            }
            output.append(mapped)
        }
        return output == text ? nil : output
    }

    public static func detectedDirection(_ text: String) -> LayoutDirection? {
        let latin = text.contains(where: isEnglishLetter)
        let cyrillic = text.contains(where: isRussianLetter)
        guard latin != cyrillic else { return nil }
        return latin ? .englishToRussian : .russianToEnglish
    }

    // Longest first: try ",j," → "боб" before treating its final comma as punctuation.
    // All offsets are UTF-16, matching Accessibility; ranges never split a grapheme.
    public static func wordCandidates(in text: String, caretUTF16: Int, completed: Bool = false) -> [NSRange] {
        guard let caret = stringIndex(in: text, utf16: caretUTF16) else { return [] }
        var end = caret
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        if completed, end == caret, end > text.startIndex, isLayoutLetter(text[text.index(before: end)]) { return [] }
        while end > text.startIndex, !isPhysicalLetterKey(text[text.index(before: end)]) {
            let previous = text.index(before: end)
            guard text[previous].isPunctuation || text[previous].isWhitespace else { return [] }
            end = previous
        }
        var start = end
        while start > text.startIndex, isPhysicalLetterKey(text[text.index(before: start)]) { start = text.index(before: start) }
        guard start < end, text[start..<end].contains(where: isLayoutLetter) else { return [] }
        let wrappers: [Character: Character] = ["[": "]", "{": "}", "<": ">", "\"": "\"", "'": "'"]
        if let first = text[start..<end].first, let last = text[start..<end].last,
           wrappers[first] == last, text[start..<end].count > 2 {
            start = text.index(after: start)
            end = text.index(before: end)
        }
        var candidates: [NSRange] = []
        var candidateEnd = end
        while start < candidateEnd {
            if text[start..<candidateEnd].contains(where: isLayoutLetter) {
                candidates.append(NSRange(start..<candidateEnd, in: text))
            }
            let previous = text.index(before: candidateEnd)
            guard !isLayoutLetter(text[previous]) else { break }
            candidateEnd = previous
        }
        if let separator = text[start..<candidateEnd].lastIndex(where: { ",.".contains($0) }),
           separator > start, text.index(after: separator) < candidateEnd {
            let tail = NSRange(text.index(after: separator)..<candidateEnd, in: text)
            if !candidates.contains(tail) { candidates.append(tail) }
        }
        return candidates
    }

    public static func precedingWord(in text: String, caretUTF16: Int, completed: Bool = false) -> NSRange? {
        (completed ? wordCandidates(in: text, caretUTF16: caretUTF16, completed: true)
                   : manualWordCandidates(in: text, caretUTF16: caretUTF16)).last
    }

    public static func manualWordCandidates(in text: String, caretUTF16: Int) -> [NSRange] {
        guard let caret = stringIndex(in: text, utf16: caretUTF16) else { return [] }
        var end = caret
        // A hotkey in the middle of a word must not leave its second half in the
        // old layout. A caret after a separator still refers to the previous word.
        if caret > text.startIndex, caret < text.endIndex,
           isLayoutLetter(text[caret]), isLayoutLetter(text[text.index(before: caret)]) {
            while end < text.endIndex, isPhysicalLetterKey(text[end]), !",.".contains(text[end]) {
                end = text.index(after: end)
            }
        }
        return wordCandidates(in: text, caretUTF16: NSRange(text.startIndex..<end, in: text).length)
    }

    public static func isSafeAutomaticContext(in text: String, range: NSRange) -> Bool {
        guard let swiftRange = validatedRange(range, in: text) else { return false }
        let before = text[..<swiftRange.lowerBound].reversed().prefix(while: { !$0.isWhitespace }).reversed()
        let after = text[swiftRange.upperBound...].prefix(while: { !$0.isWhitespace })
        let token = String(before) + String(text[swiftRange]) + String(after)
        if token.contains(where: { $0.isNumber || "@/\\_#=+|$%&*".contains($0) }) { return false }
        if token.contains("://") || token.hasPrefix("-") { return false }
        if before.contains(".") || before.contains(":") || before.contains("-") { return false }
        if after.dropFirst().contains(where: isLayoutLetter) { return false }
        return true
    }

    public static func substring(_ text: String, range: NSRange) -> String? {
        guard let range = validatedRange(range, in: text) else { return nil }
        return String(text[range])
    }

    public static func validatedRange(_ range: NSRange, in text: String) -> Range<String.Index>? {
        guard range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location,
              let start = stringIndex(in: text, utf16: range.location),
              let end = stringIndex(in: text, utf16: range.location + range.length) else { return nil }
        return start..<end
    }

    private static func stringIndex(in text: String, utf16 offset: Int) -> String.Index? {
        guard offset >= 0, offset <= text.utf16.count,
              let index = String.Index(text.utf16.index(text.utf16.startIndex, offsetBy: offset), within: text),
              text.indices.contains(index) || index == text.endIndex else { return nil }
        return index
    }
}

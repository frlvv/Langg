import Foundation

public struct WordEvidence: Equatable, Sendable {
    public let dictionaryKnown: Bool?
    // nil means lexical evidence is unavailable or was not requested. A spell
    // checker accepting a letter name or abbreviation is weaker than a word.
    public let ordinaryShortWord: Bool?

    public init(dictionaryKnown: Bool?, ordinaryShortWord: Bool? = nil) {
        self.dictionaryKnown = dictionaryKnown
        self.ordinaryShortWord = ordinaryShortWord
    }
}

public struct CorrectionCandidate: Equatable, Sendable {
    public let range: NSRange
    public let original: String
    public let replacement: String
    public let direction: LayoutDirection

    public var sourceNeedsDictionaryCheck: Bool {
        LayoutConverter.isAlphabeticWord(original, direction: direction)
    }
}

public enum AutomaticCorrection {
    public static func candidates(in text: String, caretUTF16: Int, excludedWords: [String] = []) -> [CorrectionCandidate] {
        LayoutConverter.wordCandidates(in: text, caretUTF16: caretUTF16, completed: true).compactMap { range in
            guard LayoutConverter.isSafeAutomaticContext(in: text, range: range),
                  let word = LayoutConverter.substring(text, range: range), (1...32).contains(word.count),
                  !excludedWords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }),
                  let direction = LayoutConverter.detectedDirection(word),
                  let replacement = LayoutConverter.convert(word, direction: direction, punctuation: .physicalKeys),
                  !excludedWords.contains(where: { $0.caseInsensitiveCompare(replacement) == .orderedSame }),
                  LayoutConverter.isAlphabeticWord(replacement, direction: direction == .englishToRussian ? .russianToEnglish : .englishToRussian)
            else { return nil }
            return CorrectionCandidate(range: range, original: word, replacement: replacement, direction: direction)
        }
    }

    // Revisit a small part of the current line when a new word supplies language
    // evidence for an earlier ambiguous word. Oldest words are handled first.
    public static func contextualCandidates(in text: String, caretUTF16: Int, excludedWords: [String] = []) -> [CorrectionCandidate] {
        guard let prefix = LayoutConverter.substring(text, range: NSRange(location: 0, length: caretUTF16)) else { return [] }
        let lineStart = prefix.lastIndex(of: "\n").map { prefix.distance(from: prefix.startIndex, to: prefix.index(after: $0)) }
        let lineUTF16 = lineStart.map { String(prefix.prefix($0)).utf16.count } ?? 0
        let lowerBound = max(lineUTF16, caretUTF16 - 64)
        var caret = caretUTF16
        var groups: [[CorrectionCandidate]] = []
        for _ in 0..<4 {
            guard let word = LayoutConverter.wordCandidates(in: text, caretUTF16: caret, completed: true).first,
                  word.location >= lowerBound, word.location < caret,
                  LayoutConverter.isSafeAutomaticContext(in: text, range: word) else { break }
            groups.append(candidates(in: text, caretUTF16: caret, excludedWords: excludedWords))
            caret = word.location
        }
        return groups.reversed().flatMap { $0 }
    }

    public static func contextWords(for candidate: CorrectionCandidate, in text: String) -> [String] {
        guard let range = LayoutConverter.validatedRange(candidate.range, in: text) else { return [] }
        let beforeLine = text[..<range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let afterLine = text[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let preceding = Array(beforeLine.split(whereSeparator: \.isWhitespace).suffix(4).reversed())
        let following = Array(afterLine.split(whereSeparator: \.isWhitespace).prefix(4))
        let neighbors = (0..<max(preceding.count, following.count)).flatMap { distance in
            [preceding.indices.contains(distance) ? preceding[distance] : nil,
             following.indices.contains(distance) ? following[distance] : nil].compactMap { $0 }
        }
        return neighbors.compactMap { token in
            guard token.utf16.count <= 64,
                  LayoutConverter.isSafeAutomaticContext(in: text, range: NSRange(token.startIndex..<token.endIndex, in: text)) else { return nil }
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            return word.isEmpty ? nil : word
        }
    }

    public struct ContextEvidence: Equatable, Sendable {
        public var sourceWords: Int
        public var targetWords: Int

        public init(sourceWords: Int = 0, targetWords: Int = 0) {
            self.sourceWords = sourceWords
            self.targetWords = targetWords
        }

        public var favorsTarget: Bool { targetWords > sourceWords }

        public func supports(_ candidate: CorrectionCandidate) -> Bool {
            guard targetWords > 0 else { return false }
            // Short function words can belong to either side of a bilingual
            // sentence. Overriding a longer known word requires a majority.
            return candidate.original.count <= 2
                ? targetWords >= sourceWords : targetWords > sourceWords
        }
    }

    public static func requiresContext(_ candidate: CorrectionCandidate, sourceKnown: Bool?) -> Bool {
        candidate.original.count <= 2 || (candidate.sourceNeedsDictionaryCheck && sourceKnown == true)
    }

    public static func requiresContext(_ candidate: CorrectionCandidate, sourceEvidence: WordEvidence, targetEvidence: WordEvidence) -> Bool {
        if hasImmediateShortWordEvidence(candidate, source: sourceEvidence, target: targetEvidence) { return false }
        return requiresContext(candidate, sourceKnown: sourceEvidence.dictionaryKnown)
    }

    private static func hasImmediateShortWordEvidence(_ candidate: CorrectionCandidate, source: WordEvidence, target: WordEvidence) -> Bool {
        candidate.direction == .englishToRussian && candidate.original.count <= 2 &&
            source.dictionaryKnown != nil && source.ordinaryShortWord == false &&
            target.dictionaryKnown == true && target.ordinaryShortWord == true
    }

    public static func isEligibleTarget(_ candidate: CorrectionCandidate) -> Bool {
        guard candidate.direction == .russianToEnglish else { return true }
        let word = candidate.replacement.lowercased()
        // Spell checking accepts alphabet names and Roman numerals. They are
        // not evidence that a short Cyrillic token was typed in the wrong layout.
        if word.count == 1 { return word == "a" || word == "i" }
        if word.count == 2 {
            return word.range(of: "^m{0,4}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$",
                              options: .regularExpression) == nil
        }
        return true
    }

    public static func shouldCorrect(_ candidate: CorrectionCandidate, sourceKnown: Bool?, targetKnown: Bool?, targetContextKnown: Bool = false, contextEvidence: ContextEvidence? = nil) -> Bool {
        guard targetKnown == true, isEligibleTarget(candidate) else { return false }
        // nil means the service couldn't establish a result, not a misspelling.
        guard !candidate.sourceNeedsDictionaryCheck || sourceKnown != nil else { return false }
        let contextSupportsTarget = contextEvidence?.supports(candidate) ?? targetContextKnown
        if requiresContext(candidate, sourceKnown: sourceKnown) { return contextSupportsTarget }
        return !candidate.sourceNeedsDictionaryCheck || sourceKnown == false
    }

    public static func shouldCorrect(_ candidate: CorrectionCandidate, sourceEvidence: WordEvidence, targetEvidence: WordEvidence, contextEvidence: ContextEvidence? = nil) -> Bool {
        guard isEligibleTarget(candidate),
              !candidate.sourceNeedsDictionaryCheck || sourceEvidence.dictionaryKnown != nil else { return false }
        if hasImmediateShortWordEvidence(candidate, source: sourceEvidence, target: targetEvidence) {
            // Isolated weak tokens can be resolved immediately, but surrounding
            // prose in their source language is stronger evidence to keep them.
            return contextEvidence.map { $0.targetWords >= $0.sourceWords } ?? true
        }
        // A two-consonant Russian abbreviation need not be in the dictionary.
        // Only a dominant Russian context may resolve that ambiguity; never
        // treat a missing/unavailable dictionary result as a rejected spelling.
        if candidate.direction == .englishToRussian, candidate.replacement.count == 2,
           targetEvidence.dictionaryKnown == false, sourceEvidence.ordinaryShortWord == false,
           contextEvidence?.favorsTarget == true,
           candidate.replacement.lowercased().allSatisfy({ "бвгджзйклмнпрстфхцчшщ".contains($0) }) {
            return true
        }
        return shouldCorrect(candidate, sourceKnown: sourceEvidence.dictionaryKnown,
                             targetKnown: targetEvidence.dictionaryKnown, contextEvidence: contextEvidence)
    }
}

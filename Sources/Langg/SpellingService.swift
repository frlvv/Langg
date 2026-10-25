import AppKit
import LanggCore
import NaturalLanguage

@MainActor final class SpellingService {
    private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    private var preparedLanguages: Set<String> = []
    private struct Lookup: Hashable {
        let word: String
        let language: String
        let caseVariants: Bool
    }
    private var results: [Lookup: Bool] = [:]
    private var insertionOrder: [Lookup] = []
    private var shortWordResults: [Lookup: Bool] = [:]

    deinit {
        let tag = documentTag
        Task { @MainActor in NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
    }

    func shouldCorrect(_ candidate: CorrectionCandidate, in text: String) async -> Bool {
        guard AutomaticCorrection.isEligibleTarget(candidate), !Task.isCancelled else { return false }
        let source = candidate.sourceNeedsDictionaryCheck
            ? await evidence(candidate.original, language: candidate.direction.sourceLanguage, acceptCaseVariants: false)
            : WordEvidence(dictionaryKnown: false)
        let target = await evidence(candidate.replacement, language: candidate.direction.targetLanguage)
        let needsContext = candidate.original.count <= 2 ||
            AutomaticCorrection.requiresContext(candidate, sourceEvidence: source, targetEvidence: target)
        let context = needsContext ? await languageContext(for: candidate, in: text) : nil
        guard !Task.isCancelled else { return false }
        return AutomaticCorrection.shouldCorrect(candidate, sourceEvidence: source, targetEvidence: target, contextEvidence: context)
    }

    private func languageContext(for candidate: CorrectionCandidate, in text: String) async -> AutomaticCorrection.ContextEvidence {
        let targetDirection: LayoutDirection = candidate.direction == .englishToRussian ? .russianToEnglish : .englishToRussian
        var context = AutomaticCorrection.ContextEvidence()
        for word in AutomaticCorrection.contextWords(for: candidate, in: text) {
            guard !Task.isCancelled else { break }
            if LayoutConverter.isAlphabeticWord(word, direction: targetDirection) {
                let known = await evidence(word, language: candidate.direction.targetLanguage)
                if known.dictionaryKnown == true, word.count > 2 || known.ordinaryShortWord == true {
                    context.targetWords += 1
                }
            } else if LayoutConverter.isAlphabeticWord(word, direction: candidate.direction) {
                let known = await evidence(word, language: candidate.direction.sourceLanguage, acceptCaseVariants: false)
                if known.dictionaryKnown == true, word.count > 2 || known.ordinaryShortWord == true {
                    context.sourceWords += 1
                }
            }
        }
        return context
    }

    func evidence(_ word: String, language: String, acceptCaseVariants: Bool = true) async -> WordEvidence {
        let known = await isKnown(word, language: language, acceptCaseVariants: acceptCaseVariants)
        guard (1...2).contains(word.count), let known, !Task.isCancelled else {
            return WordEvidence(dictionaryKnown: known)
        }
        guard known else { return WordEvidence(dictionaryKnown: false, ordinaryShortWord: false) }
        let lookup = Lookup(word: word, language: language, caseVariants: acceptCaseVariants)
        if let cached = shortWordResults[lookup] {
            return WordEvidence(dictionaryKnown: known, ordinaryShortWord: cached)
        }
        let naturalLanguage = NLLanguage(rawValue: language)
        let schemes = NLTagger.availableTagSchemes(for: .word, language: naturalLanguage)
        guard schemes.contains(.lemma), schemes.contains(.lexicalClass) else {
            return WordEvidence(dictionaryKnown: known)
        }
        // A part-of-speech guess alone also labels arbitrary letter sequences.
        // Require a known stem and a compatible class for that stem. This keeps
        // inflections such as verbs/pronouns while weakening alphabet names,
        // abbreviations, and inconsistent isolated-word analyses.
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = word
        tagger.setLanguage(naturalLanguage, range: word.startIndex..<word.endIndex)
        let wordClass = tagger.tag(at: word.startIndex, unit: .word, scheme: .lexicalClass).0
        let lemma = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma).0?.rawValue
        var ordinary = false
        if let lemma, !lemma.isEmpty, let wordClass, wordClass != .number, wordClass != .otherWord {
            tagger.string = lemma
            tagger.setLanguage(naturalLanguage, range: lemma.startIndex..<lemma.endIndex)
            ordinary = tagger.tag(at: lemma.startIndex, unit: .word, scheme: .lexicalClass).0 == wordClass
        }
        if shortWordResults.count >= 256 { shortWordResults.removeAll(keepingCapacity: true) }
        shortWordResults[lookup] = ordinary
        return WordEvidence(dictionaryKnown: known, ordinaryShortWord: ordinary)
    }

    func isKnown(_ word: String, language: String, acceptCaseVariants: Bool = true) async -> Bool? {
        guard !Task.isCancelled else { return nil }
        let lookup = Lookup(word: word, language: language, caseVariants: acceptCaseVariants)
        if let cached = results[lookup] { return cached }
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains(language) else { return nil }
        if !preparedLanguages.contains(language) {
            let checked: Bool = await withCheckedContinuation { continuation in
                checker.requestChecking(of: word, range: NSRange(location: 0, length: word.utf16.count),
                                    types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: [.orthography: NSOrthography.defaultOrthography(forLanguage: language)],
                                    inSpellDocumentWithTag: documentTag) { _, _, _, wordCount in
                    continuation.resume(returning: wordCount > 0)
                }
            }
            guard checked else { return nil }
            preparedLanguages.insert(language)
        }
        guard !Task.isCancelled else { return nil }
        // Unified checking can silently accept abbreviations ("njn", for example).
        // Ask for exact spelling in the explicit language after the asynchronous
        // request has warmed the service, rather than trusting language inference.
        var count = 0
        let misspelling = checker.checkSpelling(of: word, startingAt: 0, language: language,
                                               wrap: false, inSpellDocumentWithTag: documentTag, wordCount: &count)
        guard count == 1 else { return nil }
        if misspelling.location == NSNotFound { return remember(true, for: lookup) }
        guard acceptCaseVariants else { return remember(false, for: lookup) }
        // Recognise dictionary entries whose only disagreement is casing, such
        // as product names, without maintaining a separate brand vocabulary.
        guard let caseMatch = await caseOnlyCorrection(word, language: language, checker: checker),
              !Task.isCancelled else { return nil }
        return remember(caseMatch, for: lookup)
    }

    @MainActor private final class PendingResult {
        var continuation: CheckedContinuation<Bool?, Never>?
        var timeout: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }

        func finish(_ result: Bool?) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            continuation.resume(returning: result)
        }
    }

    private func caseOnlyCorrection(_ word: String, language: String, checker: NSSpellChecker) async -> Bool? {
        await withCheckedContinuation { continuation in
            let pending = PendingResult(continuation)
            pending.timeout = Task { [weak pending] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                pending?.finish(nil)
            }
            // Synchronous suggestions can stall the event-tap run loop when the
            // system spell server is busy. Request only a case-equivalent correction.
            checker.requestChecking(of: word, range: NSRange(location: 0, length: word.utf16.count),
                                    types: NSTextCheckingResult.CheckingType.correction.rawValue | NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: [.orthography: NSOrthography.defaultOrthography(forLanguage: language)],
                                    inSpellDocumentWithTag: documentTag) { _, results, _, _ in
                let matches = results.contains { result in
                    result.range == NSRange(location: 0, length: word.utf16.count) &&
                        result.replacementString?.caseInsensitiveCompare(word) == .orderedSame
                }
                Task { @MainActor in pending.finish(matches) }
            }
        }
    }

    private func remember(_ result: Bool, for lookup: Lookup) -> Bool {
        // Bounded to the current typing session; never written to disk.
        guard lookup.word.utf16.count <= 64 else { return result }
        if results[lookup] == nil {
            if insertionOrder.count >= 256 { results.removeValue(forKey: insertionOrder.removeFirst()) }
            insertionOrder.append(lookup)
        }
        results[lookup] = result
        return result
    }
}

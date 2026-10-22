import AppKit

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

    deinit {
        let tag = documentTag
        Task { @MainActor in NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
    }

    func clearWordCache() {
        results.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
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

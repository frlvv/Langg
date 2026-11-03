import CryptoKit
import Foundation
import LanggCore

/// Persist only decisions about individual layout mappings. Editor text and
/// surrounding context stay in the correction engine's transient state.
@MainActor final class CorrectionLearning {
    enum Decision: String {
        case keep = "-"
        case correct = "+"
    }

    private static let storageKey = "correctionLearning.v1"
    private static let limit = 256
    private let defaults: UserDefaults
    private var ordered: [String]
    private var decisions: [String: Decision] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        ordered = Array((defaults.stringArray(forKey: Self.storageKey) ?? []).suffix(Self.limit))
        for record in ordered {
            guard record.count == 65, let first = record.first,
                  let decision = Decision(rawValue: String(first)) else { continue }
            decisions[String(record.dropFirst())] = decision
        }
    }

    func decision(for candidate: CorrectionCandidate) -> Decision? {
        guard !decisions.isEmpty else { return nil }
        return decisions[Self.key(original: candidate.original, replacement: candidate.replacement)]
    }

    func remember(original: String, replacement: String, decision: Decision) {
        guard (1...32).contains(original.count) else { return }
        let completed = original + " "
        // Learn the same whole-word mappings the automatic engine can find.
        // Phrases, URLs, arbitrary edits and protected context are excluded.
        guard AutomaticCorrection.candidates(in: completed, caretUTF16: completed.utf16.count)
                .contains(where: { $0.original == original && $0.replacement == replacement }) else { return }
        let key = Self.key(original: original, replacement: replacement)
        if decisions[key] == decision { return }
        ordered.removeAll { $0.dropFirst() == key }
        ordered.append(decision.rawValue + key)
        decisions[key] = decision
        if ordered.count > Self.limit {
            decisions.removeValue(forKey: String(ordered.removeFirst().dropFirst()))
        }
        defaults.set(ordered, forKey: Self.storageKey)
    }

    private static func key(original: String, replacement: String) -> String {
        let normalized = original.replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
        return SHA256.hash(data: Data((normalized + "\u{0}" + replacement).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

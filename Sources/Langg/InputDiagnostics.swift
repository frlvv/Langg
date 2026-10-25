import Foundation
import OSLog

/// Explicitly enabled troubleshooting counters. Never records keys or document text.
@MainActor enum InputDiagnostics {
    private(set) static var enabled = UserDefaults.standard.bool(forKey: "inputDiagnostics")
    private static let logger = Logger(subsystem: "app.langg.Langg", category: "InputPipeline")
    private static var counts: [String: Int] = [:]

    static func record(_ stage: String) {
        guard enabled else { return }
        counts[stage, default: 0] += 1
    }

    static func flush() {
        enabled = UserDefaults.standard.bool(forKey: "inputDiagnostics")
        guard enabled, !counts.isEmpty else { return }
        let report = counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: ", ")
        logger.notice("\(report, privacy: .public)")
        counts.removeAll(keepingCapacity: true)
    }
}

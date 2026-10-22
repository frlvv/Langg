import Foundation
import ApplicationServices
import IOKit

struct PermissionSnapshot: Codable, Equatable, Sendable {
    let accessibilityGranted: Bool
    let postEventGranted: Bool
    let inputMonitoringGranted: Bool

    func granted(_ permission: InputPermission) -> Bool {
        switch permission {
        case .accessibility: accessibilityGranted
        case .inputMonitoring: inputMonitoringGranted
        }
    }
}

@MainActor final class PermissionStatusProbe {
    static let argument = "--permission-status"
    private var inFlight: Task<PermissionSnapshot?, Never>?

    // The same signed executable checks permissions in a fresh process without
    // starting SwiftUI or showing another permission prompt.
    static func writeCurrentStatus() {
        let snapshot = PermissionSnapshot(
            accessibilityGranted: AXIsProcessTrusted(),
            postEventGranted: CGPreflightPostEventAccess() ||
                IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted,
            inputMonitoringGranted: CGPreflightListenEventAccess() ||
                IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        FileHandle.standardOutput.write(data)
    }

    func read() async -> PermissionSnapshot? {
        if let inFlight { return await inFlight.value }
        let task = Task { await ProbeRun().read() }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
    }

    @MainActor private final class ProbeRun {
        private let process = Process()
        private let output = Pipe()
        private var continuation: CheckedContinuation<PermissionSnapshot?, Never>?
        private var timeout: Task<Void, Never>?

        func read() async -> PermissionSnapshot? {
            guard let executable = Bundle.main.executableURL else { return nil }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                process.executableURL = executable
                process.arguments = [PermissionStatusProbe.argument]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [weak self] _ in
                    Task { @MainActor in self?.didTerminate() }
                }
                do {
                    try process.run()
                } catch {
                    finish(nil)
                    return
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { return }
                    guard let self, self.continuation != nil else { return }
                    if self.process.isRunning { self.process.terminate() }
                    self.finish(nil)
                }
            }
        }

        private func didTerminate() {
            guard continuation != nil else { return }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                finish(nil)
                return
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            finish(try? JSONDecoder().decode(PermissionSnapshot.self, from: data))
        }

        private func finish(_ snapshot: PermissionSnapshot?) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            process.terminationHandler = nil
            continuation.resume(returning: snapshot)
        }
    }
}

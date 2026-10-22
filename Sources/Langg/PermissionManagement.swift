import AppKit
import Combine
import CoreServices

@MainActor final class PermissionManagement: ObservableObject {
    static func registerCurrentApplication() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return }
        // Register the running copy before TCC routes a request to Settings.
        LSRegisterURL(url as CFURL, true)
    }

    @Published private(set) var isRevoking = false
    @Published private(set) var message: String?
    @Published private(set) var isRestarting = false

    var applicationURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    func showApplicationInFinder() {
        guard let applicationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
    }

    func restart() async {
        guard !isRestarting else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            message = "Перезапуск доступен в установленном приложении."
            return
        }
        isRestarting = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = ["--relaunch-from", String(ProcessInfo.processInfo.processIdentifier)]
        do {
            let application = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                                                          configuration: configuration)
            guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                throw CocoaError(.executableLoad)
            }
            NSApp.terminate(nil)
        } catch {
            isRestarting = false
            message = "Не удалось перезапустить Langg. Завершите приложение и откройте его из папки «Программы»."
        }
    }

    // Scope every reset to this application. Never reset another app's access.
    static let resetArguments = ["reset", "All", "app.langg.Langg"]

    @discardableResult
    func revoke() async -> Bool {
        guard !isRevoking else { return false }
        isRevoking = true
        defer { isRevoking = false }
        let success = await Self.resetPermissions()
        if success {
            message = "Разрешения Langg отозваны. Для повторного доступа перезапустите приложение."
        } else {
            message = "macOS не разрешила автоматический отзыв. Выключите Langg на страницах доступа ниже."
            openAccessibility()
        }
        return success
    }

    func openAccessibility() { open("Privacy_Accessibility") }
    func openInputMonitoring() { open("Privacy_ListenEvent") }

    private func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func resetPermissions() async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = resetArguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationReason == .exit && finished.terminationStatus == 0)
            }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }
}

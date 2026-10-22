import Combine
import ServiceManagement

@MainActor final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var error: String?

    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    // Refreshing the registered/approval state must never change login items or
    // override the user's decision in System Settings.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = readStatus() }

    func setEnabled(_ enabled: Bool) {
        refresh()
        guard enabled != isRegistered else { return }
        do {
            if enabled { try register() }
            else { try unregister() }
            error = nil
        } catch {
            self.error = "Не удалось изменить запуск при входе. Проверьте настройки macOS."
        }
        refresh()
    }
}

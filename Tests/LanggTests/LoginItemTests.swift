import ServiceManagement
import Testing
@testable import Langg

@MainActor private final class LoginItemFixture {
    var status: SMAppService.Status = .enabled
    var registrations = 0
    var removals = 0
    var fail = false
    enum Failure: Error { case denied }

    func controller() -> LoginItemController {
        LoginItemController(readStatus: { self.status }, register: {
            self.registrations += 1
            if self.fail { throw Failure.denied }
            self.status = .requiresApproval
        }, unregister: {
            self.removals += 1
            if self.fail { throw Failure.denied }
            self.status = .notRegistered
        })
    }
}

@MainActor @Test func refreshingLoginItemNeverChangesUserConsent() {
    let fixture = LoginItemFixture()
    let controller = fixture.controller()
    fixture.status = .requiresApproval
    controller.refresh()
    #expect(controller.isRegistered && controller.needsApproval)
    fixture.status = .notRegistered
    controller.refresh()
    #expect(!controller.isRegistered)
    #expect(fixture.registrations == 0 && fixture.removals == 0)
}

@MainActor @Test func pendingLoginApprovalDoesNotRegisterAgain() {
    let fixture = LoginItemFixture()
    fixture.status = .notRegistered
    let controller = fixture.controller()
    controller.setEnabled(true)
    controller.setEnabled(true)
    #expect(fixture.registrations == 1)
    #expect(controller.isRegistered && controller.needsApproval)
    controller.setEnabled(false)
    #expect(fixture.removals == 1)
    #expect(!controller.isRegistered && !controller.needsApproval)
}

@MainActor @Test func loginItemFailureKeepsActualSystemState() {
    let fixture = LoginItemFixture()
    fixture.fail = true
    let controller = fixture.controller()
    controller.setEnabled(false)
    #expect(controller.error != nil)
    #expect(controller.isRegistered)
    #expect(fixture.removals == 1)
}

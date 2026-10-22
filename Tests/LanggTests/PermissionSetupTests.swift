import Testing
@testable import Langg

@Test func permissionRequestIsNotAGrant() {
    var setup = PermissionSetup()
    setup.didRequest(.accessibility)
    #expect(setup.status(for: .accessibility, reportedGranted: false, keyboardVerified: false) == .awaitingVerification)
    #expect(setup.status(for: .inputMonitoring, reportedGranted: false, keyboardVerified: false) == .needsPermission)
    #expect(!setup.shouldOfferRestart(keyboardVerified: false))
}

@Test func cachedPermissionAnswersDoNotShowSuccessfulSetup() {
    let setup = PermissionSetup()
    for permission in InputPermission.allCases {
        #expect(setup.status(for: permission, reportedGranted: true, keyboardVerified: false) == .awaitingVerification)
    }
}

@Test func verifiedKeyboardCompletesBothPermissionSteps() {
    var setup = PermissionSetup()
    setup.didRequest(.accessibility)
    setup.didRequest(.inputMonitoring)
    for permission in InputPermission.allCases {
        #expect(setup.status(for: permission, reportedGranted: true, keyboardVerified: true) == .verified)
    }
    #expect(!setup.shouldOfferRestart(keyboardVerified: true))
}

@Test func monitoringCanBeRequestedBeforeAccessibilityWithoutClaimingSuccess() {
    var setup = PermissionSetup()
    setup.didRequest(.inputMonitoring)
    #expect(setup.status(for: .inputMonitoring, reportedGranted: true, keyboardVerified: false) == .awaitingVerification)
    #expect(setup.status(for: .accessibility, reportedGranted: false, keyboardVerified: false) == .needsPermission)
}

@Test func deniedRequestDoesNotSurviveAsGrantedAfterRelaunch() {
    var previous = PermissionSetup()
    previous.didRequest(.accessibility)
    previous.didRequest(.inputMonitoring)
    let relaunched = PermissionSetup()
    for permission in InputPermission.allCases {
        #expect(relaunched.status(for: permission, reportedGranted: false, keyboardVerified: false) == .needsPermission)
    }
    #expect(!relaunched.shouldOfferRestart(keyboardVerified: false))
}

@Test func revokedPermissionsRemainUnverifiedWithoutOfferingRelaunch() {
    var setup = PermissionSetup()
    setup.didRequest(.accessibility)
    setup.didRevoke()
    for permission in InputPermission.allCases {
        #expect(setup.status(for: permission, reportedGranted: false, keyboardVerified: false) == .needsPermission)
    }
    #expect(!setup.shouldOfferRestart(keyboardVerified: false))
}

@Test func monitoringRestartFallbackRequiresReturningFromSystemSettings() {
    var setup = PermissionSetup()
    setup.didRequest(.inputMonitoring)
    #expect(!setup.shouldOfferRestart(keyboardVerified: false))
    setup.didActivateApplication(isSystemSettings: true)
    #expect(!setup.shouldOfferRestart(keyboardVerified: false))
    setup.didActivateApplication(isSystemSettings: false)
    #expect(setup.shouldOfferRestart(keyboardVerified: false))
    #expect(!setup.shouldOfferRestart(keyboardVerified: true))
}

@Test func accessibilityRequestDoesNotOfferRestartAfterReturningFromSettings() {
    var setup = PermissionSetup()
    setup.didRequest(.accessibility)
    setup.didActivateApplication(isSystemSettings: true)
    setup.didActivateApplication(isSystemSettings: false)
    #expect(!setup.shouldOfferRestart(keyboardVerified: false))
}

@Test func anotherMonitoringRequestWaitsForItsOwnSettingsVisit() {
    var setup = PermissionSetup()
    setup.didRequest(.inputMonitoring)
    setup.didActivateApplication(isSystemSettings: true)
    setup.didActivateApplication(isSystemSettings: false)
    setup.didRequest(.inputMonitoring)
    setup.didActivateApplication(isSystemSettings: false)
    #expect(!setup.shouldOfferRestart(keyboardVerified: false))
}

import AppKit
import Carbon
import Testing
@testable import Langg

private func launchEvent(reason: AEKeyword? = nil, eventID: AEEventID = kAEOpenApplication) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: eventID,
                                       targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
    if let reason { event.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: keyAEPropData) }
    return event
}

@Test func ordinaryLaunchOpensSettingsEveryTime() {
    #expect(StartupPolicy.shouldOpenSettings(event: launchEvent()))
    #expect(StartupPolicy.shouldOpenSettings(event: launchEvent()))
    #expect(StartupPolicy.shouldOpenSettings(event: nil))
}

@Test(arguments: [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem])
func backgroundLaunchDoesNotOpenSetup(reason: AEKeyword) {
    #expect(!StartupPolicy.shouldOpenSettings(event: launchEvent(reason: reason)))
}

@Test func reopenIsAnExplicitUserAction() {
    #expect(StartupPolicy.shouldOpenSettings(event: launchEvent(reason: keyAELaunchedAsLogInItem,
                                                               eventID: kAEReopenApplication)))
}

@Test func relaunchIdentifiesOnlyThePreviousProcess() {
    #expect(StartupPolicy.relaunchParentPID(arguments: ["Langg", "--relaunch-from", "42"], currentPID: 99) == 42)
}

@Test(arguments: [
    ["Langg"], ["Langg", "--relaunch-from"], ["Langg", "--relaunch-from", "invalid"],
    ["Langg", "--relaunch-from", "0"], ["Langg", "--relaunch-from", "-1"],
    ["Langg", "--relaunch-from", "99"]
])
func invalidRelaunchArgumentsDoNotDelayStartup(arguments: [String]) {
    #expect(StartupPolicy.relaunchParentPID(arguments: arguments, currentPID: 99) == nil)
}

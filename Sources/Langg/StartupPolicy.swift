import AppKit
import Carbon

enum StartupPolicy {
    static func relaunchParentPID(arguments: [String], currentPID: Int32) -> Int32? {
        guard let index = arguments.firstIndex(of: "--relaunch-from"),
              arguments.indices.contains(index + 1),
              let pid = Int32(arguments[index + 1]), pid > 0, pid != currentPID else { return nil }
        return pid
    }

    static func shouldOpenSettings(event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass,
              event.eventID == kAEOpenApplication else { return true }
        let launchReason = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        // Login and service launches run in the background even if permissions
        // are temporarily unavailable. An ordinary launch is an explicit open.
        return launchReason != keyAELaunchedAsLogInItem && launchReason != keyAELaunchedAsServiceItem
    }
}

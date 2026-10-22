import CoreGraphics
import Foundation

enum EventTapAccess {
    static let keyboardMask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
        CGEventMask(1 << CGEventType.keyUp.rawValue)

    static func receivesKeyboard(_ effectiveMask: CGEventMask?) -> Bool {
        guard let effectiveMask else { return false }
        return effectiveMask & keyboardMask == keyboardMask
    }

    static func effectiveMask() -> CGEventMask? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return nil }
        var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &entries, &count) == .success else { return nil }
        return entries.prefix(Int(count)).first {
            $0.tappingProcess == ProcessInfo.processInfo.processIdentifier &&
                $0.tapPoint == .cgSessionEventTap && $0.processBeingTapped == 0 &&
                $0.options == .defaultTap && $0.enabled
        }?.eventsOfInterest
    }
}

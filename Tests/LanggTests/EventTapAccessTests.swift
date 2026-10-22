import CoreGraphics
import Testing
@testable import Langg

@Test func mouseOnlyTapIsNotKeyboardReady() {
    // Actual mask returned by macOS with AX/PostEvent granted but ListenEvent denied.
    #expect(!EventTapAccess.receivesKeyboard(0x200000a))
    #expect(!EventTapAccess.receivesKeyboard(nil))
}

@Test func tapRequiresBothKeyboardPressAndRelease() {
    #expect(EventTapAccess.receivesKeyboard(0x2000c0a))
    #expect(!EventTapAccess.receivesKeyboard(CGEventMask(1 << CGEventType.keyDown.rawValue)))
    #expect(!EventTapAccess.receivesKeyboard(CGEventMask(1 << CGEventType.keyUp.rawValue)))
}

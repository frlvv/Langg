import AppKit
import Testing
@testable import Langg

@MainActor @Test func clipboardLeaseRestoresEveryItemAndRepresentation() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let first = NSPasteboardItem()
    first.setString("original", forType: .string)
    first.setData(Data([0, 255, 127]), forType: .init("test.binary"))
    let second = NSPasteboardItem()
    second.setData(Data("<b>second</b>".utf8), forType: .html)
    #expect(board.writeObjects([first, second]))
    let lease = try #require(PasteboardLease.acquire(text: "привет", pasteboard: board))
    #expect(board.string(forType: .string) == "привет")
    #expect(board.types?.contains(.init("org.nspasteboard.TransientType")) == true)
    #expect(board.types?.contains(.init("org.nspasteboard.ConcealedType")) == true)
    lease.restore()
    let items = try #require(board.pasteboardItems)
    #expect(items.count == 2)
    #expect(items[0].string(forType: .string) == "original")
    #expect(items[0].data(forType: .init("test.binary")) == Data([0, 255, 127]))
    #expect(items[1].data(forType: .html) == Data("<b>second</b>".utf8))
}

@MainActor @Test func clipboardLeasePreservesANewerCopy() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("original", forType: .string)
    let lease = try #require(PasteboardLease.acquire(text: "привет", pasteboard: board))
    board.clearContents()
    board.setString("new user copy", forType: .string)
    #expect(!lease.isCurrent)
    lease.restore()
    #expect(board.string(forType: .string) == "new user copy")
}

@MainActor @Test func clipboardLeaseRestoresAnEmptyClipboard() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents()
    let lease = try #require(PasteboardLease.acquire(text: "привет", pasteboard: board))
    lease.restore()
    #expect((board.pasteboardItems ?? []).isEmpty)
}

private final class UnreadablePasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

@MainActor @Test func clipboardLeaseRejectsUnreadableRepresentationsWithoutClearing() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let provider = UnreadablePasteboardProvider()
    let item = NSPasteboardItem()
    let promisedType = NSPasteboard.PasteboardType("test.unreadable")
    item.setDataProvider(provider, forTypes: [promisedType])
    #expect(board.writeObjects([item]))
    let count = board.changeCount
    #expect(PasteboardLease.acquire(text: "привет", pasteboard: board) == nil)
    #expect(board.changeCount == count)
    #expect(board.types?.contains(promisedType) == true)
}

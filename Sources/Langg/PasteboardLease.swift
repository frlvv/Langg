import AppKit

/// A short clipboard lease which never restores over a later clipboard owner.
@MainActor struct PasteboardLease {
    private let pasteboard: NSPasteboard
    private let originalItems: [NSPasteboardItem]
    private let changeCount: Int
    private let token: Data
    private static let ownershipType = NSPasteboard.PasteboardType("app.langg.clipboard-lease")

    var isCurrent: Bool {
        pasteboard.changeCount == changeCount && pasteboard.data(forType: Self.ownershipType) == token
    }

    static func acquire(text: String, pasteboard: NSPasteboard = .general) -> Self? {
        let originalCount = pasteboard.changeCount
        var originals: [NSPasteboardItem] = []
        let items = pasteboard.pasteboardItems
        guard items != nil || (pasteboard.types ?? []).isEmpty else { return nil }
        for item in items ?? [] {
            guard !item.types.isEmpty else { return nil }
            let copy = NSPasteboardItem()
            for type in item.types {
                // Promised or unreadable representations cannot be restored
                // faithfully. Leave the clipboard untouched in that case.
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else { return nil }
            }
            originals.append(copy)
        }
        guard pasteboard.changeCount == originalCount else { return nil }
        let replacement = NSPasteboardItem()
        let token = Data(UUID().uuidString.utf8)
        guard replacement.setString(text, forType: .string),
              replacement.setData(token, forType: ownershipType),
              replacement.setData(Data(), forType: .init("org.nspasteboard.TransientType")),
              replacement.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")) else { return nil }
        let clearedCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.changeCount == clearedCount else { return nil }
        guard pasteboard.writeObjects([replacement]) else {
            if pasteboard.changeCount == clearedCount { _ = pasteboard.writeObjects(originals) }
            return nil
        }
        let lease = Self(pasteboard: pasteboard, originalItems: originals, changeCount: pasteboard.changeCount, token: token)
        return lease.isCurrent ? lease : nil
    }

    func restore() {
        guard isCurrent else { return }
        let clearedCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard !originalItems.isEmpty, pasteboard.changeCount == clearedCount else { return }
        _ = pasteboard.writeObjects(originalItems)
    }
}

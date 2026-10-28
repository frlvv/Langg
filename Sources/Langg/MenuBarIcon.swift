import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor struct MenuBarInputSource {
    let name: String
    let badge: String

    static func current() -> Self {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return Self(name: "Раскладка", badge: "")
        }
        func string(_ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let name = string(kTISPropertyLocalizedName) ?? "Раскладка"
        let identifier = string(kTISPropertyInputSourceID) ?? ""
        let languages: [String]
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
        } else {
            languages = []
        }
        return Self(name: name, badge: badge(identifier: identifier, languages: languages, name: name))
    }

    static func badge(identifier: String, languages: [String], name: String) -> String {
        let language = languages.first?.prefix(2).lowercased()
        if language == "ru" || identifier.contains("Russian") { return "РУ" }
        if language == "en" || ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].contains(identifier) { return "A" }
        return language.map { $0.uppercased() } ?? String(name.prefix(2)).uppercased()
    }
}

@MainActor final class MenuBarInputSourceObserver: ObservableObject {
    @Published private(set) var current = MenuBarInputSource(name: "Раскладка", badge: "")
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private let readSource: @MainActor () -> MenuBarInputSource

    init(notificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
         readSource: @escaping @MainActor () -> MenuBarInputSource = { .current() }) {
        self.readSource = readSource
        notificationCenter.publisher(
            for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.synchronize() }
            .store(in: &subscriptions)
        for name in [NSApplication.didBecomeActiveNotification, InputSources.selectionRequested] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.synchronize() }
                .store(in: &subscriptions)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.synchronize() }
                .store(in: &subscriptions)
        }
        // Subscribe before the first read, then reconcile the asynchronous TIS
        // transition. A notification can precede its settled source readback.
        synchronize()
    }

    deinit { refreshTask?.cancel() }

    private func synchronize() {
        refreshTask?.cancel()
        refresh()
        refreshTask = Task { [weak self] in
            for delay in [10, 40, 100] {
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let next = readSource()
        guard !next.badge.isEmpty,
              next.badge != current.badge || next.name != current.name else { return }
        current = next
    }
}

@MainActor enum MenuBarSymbols {
    static let imageSize = NSSize(width: 24, height: 18)
    private static let englishFilled = badge("A", filled: true)
    private static let englishOutline = badge("A", filled: false)
    private static let russianFilled = badge("РУ", filled: true)
    private static let russianOutline = badge("РУ", filled: false)
    private static let englishFilledPreview = badge("A", filled: true, scale: 4.0 / 3.0)
    private static let englishOutlinePreview = badge("A", filled: false, scale: 4.0 / 3.0)
    private static let russianFilledPreview = badge("РУ", filled: true, scale: 4.0 / 3.0)
    private static let russianOutlinePreview = badge("РУ", filled: false, scale: 4.0 / 3.0)

    static func image(for badge: String, primaryLanguage: MenuBarPrimaryLanguage) -> NSImage {
        let filled = badge == primaryLanguage.badge
        switch badge {
        case "A": return filled ? englishFilled : englishOutline
        case "РУ": return filled ? russianFilled : russianOutline
        case "": return LanggMark.menuImage
        default: return self.badge(badge, filled: false)
        }
    }

    static func preview(for badge: String, primaryLanguage: MenuBarPrimaryLanguage) -> NSImage {
        let filled = badge == primaryLanguage.badge
        switch badge {
        case "A": return filled ? englishFilledPreview : englishOutlinePreview
        case "РУ": return filled ? russianFilledPreview : russianOutlinePreview
        default: return self.badge(badge, filled: filled, scale: 4.0 / 3.0)
        }
    }

    private static func badge(_ value: String, filled: Bool, scale: CGFloat = 1) -> NSImage {
        let font = NSFont.systemFont(ofSize: (value == "A" ? 13 : 12) * scale, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let text = value as NSString
        let bounds = text.size(withAttributes: attributes)
        // Both images have identical intrinsic and visible bounds. Changing the
        // source must not resize the status item or move its neighbours.
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let image = NSImage(size: size, flipped: false) { rect in
            let badgeRect = rect.insetBy(dx: scale, dy: scale)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            if filled {
                NSBezierPath(roundedRect: badgeRect, xRadius: 4.5 * scale, yRadius: 4.5 * scale).fill()
            } else {
                let border = NSBezierPath(roundedRect: badgeRect.insetBy(dx: 0.5 * scale, dy: 0.5 * scale),
                                         xRadius: 4 * scale, yRadius: 4 * scale)
                border.lineWidth = scale
                border.stroke()
            }
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.saveGState()
            if filled { context.setBlendMode(.destinationOut) }
            text.draw(at: NSPoint(x: (rect.width - bounds.width) / 2,
                                 y: (rect.height - bounds.height) / 2), withAttributes: attributes)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor struct MenuBarIcon: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var source: MenuBarInputSourceObserver

    var body: some View {
        Image(nsImage: settings.menuBarIconStyle == .appIcon
              ? LanggMark.menuImage : MenuBarSymbols.image(for: source.current.badge,
                                                        primaryLanguage: settings.primaryMenuBarLanguage))
            .accessibilityLabel(settings.menuBarIconStyle == .appIcon ? "Langg" : "Langg, \(source.current.name)")
            .help(settings.menuBarIconStyle == .appIcon ? "Langg" : "Langg · \(source.current.name)")
    }
}

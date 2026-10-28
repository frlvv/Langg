import AppKit
import SwiftUI

@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let windowID = NSUserInterfaceItemIdentifier("settings")
    private let recorder: ShortcutRecorder
    init(monitor: InputMonitor) {
        recorder = monitor.shortcutRecorder
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Langg – Настройки"
        window.identifier = Self.windowID
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.animationBehavior = .documentWindow
        window.level = .normal
        window.contentMinSize = NSSize(width: 780, height: 560)
        window.contentViewController = NSHostingController(rootView: SettingsView(monitor: monitor))
        window.center()
        window.setFrameAutosaveName("LanggSettings")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }


    func showSettings() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) { recorder.stop() }
    func windowWillClose(_ notification: Notification) { recorder.stop() }
}

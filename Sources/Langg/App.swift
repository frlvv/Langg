import SwiftUI
import AppKit

@main enum LanggEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains(PermissionStatusProbe.argument) {
            PermissionStatusProbe.writeCurrentStatus()
            return
        }
        LanggApp.main()
    }
}

struct LanggApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: delegate.monitor, openSettings: delegate.showSettings)
        } label: {
            Image(nsImage: LanggMark.menuImage)
                .accessibilityLabel("Langg")
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…", action: delegate.showSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Закрыть окно") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = InputMonitor(settings: AppSettings())
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateController.shared.start()
        let permissionRelaunch = StartupPolicy.relaunchParentPID(arguments: CommandLine.arguments,
                                                               currentPID: ProcessInfo.processInfo.processIdentifier) != nil
        if permissionRelaunch || StartupPolicy.shouldOpenSettings(event: NSAppleEventManager.shared().currentAppleEvent) {
            showSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        UserDefaults.standard.set(true, forKey: "hasOpenedSettings")
        if settingsWindow == nil { settingsWindow = SettingsWindowController(monitor: monitor) }
        settingsWindow?.showSettings()
    }
}

private struct MenuContent: View {
    @ObservedObject var monitor: InputMonitor
    @ObservedObject private var settings: AppSettings
    let openSettings: () -> Void

    init(monitor: InputMonitor, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        _settings = ObservedObject(wrappedValue: monitor.settings)
        self.openSettings = openSettings
    }

    var body: some View {
        Text(monitor.status == "Работает" ? "Langg готов к работе"
             : monitor.needsPermission ? "Langg требуется доступ" : "Langg подключается…")
        Divider()
        Toggle("Автоисправление", isOn: $settings.automatic)
        Button("Настройки…", action: openSettings)
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Завершить Langg") { NSApp.terminate(nil) }
    }
}

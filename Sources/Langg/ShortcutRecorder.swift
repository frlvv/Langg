import AppKit
import Combine

@MainActor final class ShortcutRecorder: ObservableObject {
    @Published private(set) var command: ShortcutCommand?
    @Published private(set) var error: String?

    private let settings: AppSettings
    private var localMonitor: Any?
    private var consumedKeys = ConsumedKeyPresses()
    private var pendingModifiers: UInt64 = 0
    private var modifierRecordingCancelled = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    func start(_ command: ShortcutCommand) {
        self.command = command
        error = nil
        resetModifierRecording()
        // Fallback for recording before Accessibility permission is granted.
        // With permission, InputMonitor captures the same physical key earlier,
        // before system and menu shortcuts can act on it.
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                if NSApp.keyWindow?.identifier == SettingsWindowController.windowID {
                    self.recordModifiers(UInt64(event.modifierFlags.rawValue))
                }
                return event
            }
            let keyCode = Int64(event.keyCode)
            if self.consumedKeys.consumeContinuation(keyCode: keyCode, isKeyDown: event.type == .keyDown) {
                return nil
            }
            guard event.type == .keyDown, self.command != nil,
                  NSApp.keyWindow?.identifier == SettingsWindowController.windowID else { return event }
            self.consumedKeys.begin(keyCode)
            self.record(event)
            return nil
        }
    }

    func stop() {
        command = nil
        error = nil
        resetModifierRecording()
    }

    func record(_ event: NSEvent) {
        if event.type == .flagsChanged {
            recordModifiers(UInt64(event.modifierFlags.rawValue))
            return
        }
        guard event.type == .keyDown else { return }
        record(keyCode: Int64(event.keyCode), modifiers: UInt64(event.modifierFlags.rawValue),
               isRepeat: event.isARepeat)
    }

    func recordModifiers(_ modifiers: UInt64) {
        guard command == .switchLayout else { return }
        let current = modifiers & Shortcut.modifierMask
        if current != 0 {
            if current & pendingModifiers == pendingModifiers {
                pendingModifiers = current
            } else if current & pendingModifiers != current {
                modifierRecordingCancelled = true
            }
            return
        }
        let candidate = Shortcut(keyCode: -1, modifiers: pendingModifiers)
        let cancelled = modifierRecordingCancelled
        resetModifierRecording()
        guard candidate.isValid, !cancelled else { return }
        record(keyCode: candidate.keyCode, modifiers: candidate.modifiers, isRepeat: false)
    }

    private func resetModifierRecording() {
        pendingModifiers = 0
        modifierRecordingCancelled = false
    }

    func record(keyCode: Int64, modifiers: UInt64, isRepeat: Bool) {
        guard let command, !isRepeat else { return }
        resetModifierRecording()
        let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers)
        if keyCode == 53, shortcut.modifiers == 0 {
            stop()
        } else if !shortcut.isValid {
            error = "Эту клавишу нельзя назначить. Нажмите другую клавишу или Esc."
        } else if settings.setShortcut(shortcut, for: command) {
            stop()
        } else {
            error = "Это сочетание уже назначено другой команде."
        }
    }
}

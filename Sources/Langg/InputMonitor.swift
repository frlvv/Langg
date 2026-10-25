import AppKit
import ApplicationServices
import Carbon
import Combine
import IOKit
import LanggCore

@MainActor final class InputMonitor: ObservableObject {
    @Published private(set) var status = "Ожидает разрешений"
    @Published private(set) var correctionFeedback: String?
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var eventTapAccessGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var inputMonitoringRequired = false
    @Published private(set) var permissionSetup = PermissionSetup()
    @Published private(set) var freshPermissionSnapshot: PermissionSnapshot?
    private let permissionProbe = PermissionStatusProbe()
    private var permissionProbeTask: Task<Void, Never>?
    private var permissionRevision: UInt64 = 0
    private var lastPermissionProbe = Date.distantPast
    let settings: AppSettings
    let shortcutRecorder: ShortcutRecorder
    private var consumedKeys = ConsumedKeyPresses()
    private var modifierChord = ModifierChordRecognizer(modifiers: Shortcut.switchLayout.modifiers)
    private var modifierChordBinding: Shortcut?
    private let toast = CaretToast()
    private var tap: CFMachPort?
    private var runSource: CFRunLoopSource?
    private let inputReplay = InputReplayGate()
    private var tapStopRequested = false
    private var observers: Set<AnyCancellable> = []
    private var isSleeping = false
    private var isSessionActive = true
    private var isStopped = false
    private var relaunchParent: NSRunningApplication? = {
        guard let pid = StartupPolicy.relaunchParentPID(arguments: CommandLine.arguments,
                                                       currentPID: ProcessInfo.processInfo.processIdentifier),
              let parent = NSRunningApplication(processIdentifier: pid),
              parent.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL else { return nil }
        return parent
    }()

    private lazy var engine = CorrectionEngine(settings: settings, replay: inputReplay,
        onFeedback: { [weak self] in self?.correctionFeedback = $0 },
        onCorrection: { [weak self] in self?.toast.show(at: $0) },
        onUndo: { [weak self] in self?.toast.showUndoIfVisible() },
        onMissingGeometry: { [weak self] in self?.toast.hide() })

    init(settings: AppSettings) {
        self.settings = settings
        shortcutRecorder = ShortcutRecorder(settings: settings)
        inputReplay.onOverflow = { [weak self] in
            self?.engine.cancelForOverflow()
        }
        inputReplay.onDrained = { [weak self] in
            DispatchQueue.main.async {
                self?.finishStoppingEventTap()
            }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                TextAccess.invalidateFocusEvidence()
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self.permissionSetup.didActivateApplication(isSystemSettings: app.bundleIdentifier == "com.apple.systempreferences")
                    TextAccess.prepareTextAccessibility(for: app)
                }
                self.invalidate()
            }
            .store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    TextAccess.applicationDidDeactivate(pid: app.processIdentifier)
                }
            }
            .store(in: &observers)
        settings.$automatic.dropFirst().sink { [weak self] _ in self?.invalidate() }.store(in: &observers)
        observeLifecycle()
        start()
    }

    var requiredAccessGranted: Bool { accessibilityGranted && eventTapAccessGranted && inputMonitoringGranted && !inputMonitoringRequired }
    var needsPermission: Bool { !requiredAccessGranted }
    var keyboardAccessVerified: Bool { requiredAccessGranted && status == "Работает" }
    var shouldOfferPermissionRestart: Bool {
        permissionSetup.shouldOfferRestart(keyboardVerified: keyboardAccessVerified)
    }

    func permissionStatus(for permission: InputPermission) -> PermissionSetupStatus {
        permissionSetup.status(for: permission,
                               reportedGranted: permission == .accessibility ? accessibilityGranted : inputMonitoringGranted,
                               keyboardVerified: keyboardAccessVerified,
                               freshlyGranted: freshPermissionSnapshot?.granted(permission))
    }

    private func refreshPermissionStatus() {
        guard !keyboardAccessVerified, permissionProbeTask == nil,
              Date().timeIntervalSince(lastPermissionProbe) >= 1.5,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        lastPermissionProbe = Date()
        let revision = permissionRevision
        permissionProbeTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.permissionProbe.read()
            if self.permissionRevision == revision { self.freshPermissionSnapshot = snapshot }
            self.permissionProbeTask = nil
        }
    }

    private func invalidatePermissionSnapshot() {
        permissionRevision &+= 1
        freshPermissionSnapshot = nil
        lastPermissionProbe = .distantPast
    }

    private func observeLifecycle() {
        // These checks never request permission. They also run when Settings has
        // never been opened, including launch at login and returning from sleep.
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.start() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.start() }
            .store(in: &observers)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] notification in
                    guard let self else { return }
                    switch notification.name {
                    case NSWorkspace.willSleepNotification: self.isSleeping = true
                    case NSWorkspace.didWakeNotification: self.isSleeping = false
                    case NSWorkspace.sessionDidResignActiveNotification: self.isSessionActive = false
                    case NSWorkspace.sessionDidBecomeActiveNotification: self.isSessionActive = true
                    default: return
                    }
                    self.start()
                }
                .store(in: &observers)
        }
    }

    func requestAccessibilityPermission() {
        isStopped = false
        invalidatePermissionSnapshot()
        PermissionManagement.registerCurrentApplication()
        permissionSetup.didRequest(.accessibility)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if AXIsProcessTrusted(), !CGPreflightPostEventAccess() {
            // AX APIs and a modifying event tap can have different effective
            // states after a signature change. Both are managed in Accessibility.
            _ = CGRequestPostEventAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestInputMonitoringPermission() {
        isStopped = false
        invalidatePermissionSnapshot()
        PermissionManagement.registerCurrentApplication()
        permissionSetup.didRequest(.inputMonitoring)
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        InputDiagnostics.flush()
        guard !isStopped else { return }
        defer { refreshPermissionStatus() }
        if let parent = relaunchParent, !parent.isTerminated {
            updateStatus("Перезапуск Langg…")
            return
        }
        relaunchParent = nil
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        // A modifying tap needs PostEvent. Some macOS configurations additionally
        // strip keyboard events without ListenEvent; verify the actual event mask.
        let canModifyEvents = CGPreflightPostEventAccess() ||
            IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted
        let canListen = CGPreflightListenEventAccess() ||
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if accessibilityGranted != trusted || eventTapAccessGranted != canModifyEvents || inputMonitoringGranted != canListen {
            invalidatePermissionSnapshot()
            accessibilityGranted = trusted
            eventTapAccessGranted = canModifyEvents
            inputMonitoringGranted = canListen
        }
        if inputMonitoringRequired, CGPreflightListenEventAccess() { inputMonitoringRequired = false }
        guard !isSleeping, isSessionActive else {
            stopEventTap()
            shortcutRecorder.stop()
            updateStatus("Приостановлено")
            return
        }
        guard accessibilityGranted else {
            stopEventTap()
            updateStatus("Нет разрешения на Универсальный доступ")
            return
        }
        guard eventTapAccessGranted else {
            stopEventTap()
            updateStatus("Нет разрешения на управление клавиатурой")
            return
        }
        guard inputMonitoringGranted else {
            stopEventTap()
            inputMonitoringRequired = true
            updateStatus("Нет разрешения на мониторинг ввода")
            return
        }
        defer {
            if let tap, CGEvent.tapIsEnabled(tap: tap),
               let app = NSWorkspace.shared.frontmostApplication {
                TextAccess.prepareTextAccessibility(for: app)
            }
        }
        if tapStopRequested {
            finishStoppingEventTap()
            guard !tapStopRequested else { return }
        }
        if let tap, CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) {
                invalidate()
                consumedKeys = ConsumedKeyPresses()
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if CGEvent.tapIsEnabled(tap: tap) {
                let mask = EventTapAccess.effectiveMask()
                if EventTapAccess.receivesKeyboard(mask) {
                    inputMonitoringRequired = false
                    updateStatus("Работает")
                    return
                }
                if mask != nil, !CGPreflightListenEventAccess() {
                    inputMonitoringRequired = true
                    updateStatus("Нет разрешения на мониторинг ввода")
                    return
                }
            }
        }
        stopEventTap()
        guard !tapStopRequested else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                   .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                   .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                   .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, ref in
            guard let ref else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(ref).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.inputReplay.didLoseTap()
                monitor.invalidate()
                // Reconnect outside this callback so an invalid port is never
                // torn down while its callback is still executing.
                DispatchQueue.main.async { [weak monitor] in monitor?.start() }
                return Unmanaged.passUnretained(event)
            }
            return monitor.handle(event, type: type) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: ref)
        guard let tap else {
            updateStatus("Восстанавливаем подключение к клавиатуре")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            stopEventTap()
            updateStatus("Восстанавливаем подключение к клавиатуре")
            return
        }
        runSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap), EventTapAccess.receivesKeyboard(EventTapAccess.effectiveMask()) {
            inputMonitoringRequired = false
            InputDiagnostics.record("tapConnected")
            updateStatus("Работает")
        } else if CGEvent.tapIsEnabled(tap: tap), EventTapAccess.effectiveMask() != nil, !CGPreflightListenEventAccess() {
            inputMonitoringRequired = true
            InputDiagnostics.record("keyboardEventsStripped")
            updateStatus("Нет разрешения на мониторинг ввода")
        } else {
            stopEventTap()
            updateStatus("Восстанавливаем подключение к клавиатуре")
        }
    }

    func permissionsWereRevoked() {
        isStopped = true
        shortcutRecorder.stop()
        stopEventTap()
        invalidatePermissionSnapshot()
        accessibilityGranted = false
        eventTapAccessGranted = false
        inputMonitoringGranted = false
        inputMonitoringRequired = false
        permissionSetup.didRevoke()
        updateStatus("Разрешения отозваны. Перезапустите Langg.")
    }

    func stop() {
        isStopped = true
        observers.removeAll()
        shortcutRecorder.stop()
        stopEventTap()
    }

    private func updateStatus(_ value: String) {
        if status != value { status = value }
    }

    private func stopEventTap() {
        TextAccess.stopFocusObservation()
        invalidate()
        toast.hide()
        tapStopRequested = true
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { inputReplay.didLoseTap() }
        finishStoppingEventTap()
    }

    private func finishStoppingEventTap() {
        guard tapStopRequested, inputReplay.canBegin else { return }
        tapStopRequested = false
        // Do not destroy the port before queued key releases finish replaying.
        consumedKeys = ConsumedKeyPresses()
        if let runSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runSource, .commonModes)
            CFRunLoopSourceInvalidate(runSource)
        }
        runSource = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    private func invalidate() {
        engine.invalidate()
        modifierChord.reset()
    }

    private func handle(_ event: CGEvent, type: CGEventType) -> Bool {
        guard !TextAccess.isReplacementEvent(event) else { return false }
        let replay = inputReplay.prepareIncoming(event)
        defer { inputReplay.finishIncoming(replay) }
        if inputReplay.shouldBuffer(event, replay: replay) { return true }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                TextAccess.invalidateFocusEvidence()
                invalidate()
                if type == .leftMouseDown, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                    TextAccess.notePointerFocus(at: event.location, pid: pid)
                }
            }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let binding = settings.shortcut(for: .switchLayout)
        if modifierChordBinding != binding {
            modifierChordBinding = binding
            modifierChord = ModifierChordRecognizer(modifiers: binding.modifiers)
        }
        let ownApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let recording = ownApp && NSApp.isActive && shortcutRecorder.command != nil &&
            NSApp.keyWindow?.identifier == SettingsWindowController.windowID
        if type == .flagsChanged {
            if recording {
                shortcutRecorder.recordModifiers(event.flags.rawValue)
                modifierChord.reset()
            } else if binding.isModifierOnly, modifierChord.observeModifiers(event.flags.rawValue),
                      !IsSecureEventInputEnabled(), accessibilityGranted, !ownApp {
                invalidate()
                _ = InputSources.toggle()
            }
            return false
        }
        if type == .keyDown { modifierChord.noteKeyDown() }
        if consumedKeys.consumeContinuation(keyCode: key, isKeyDown: type == .keyDown) { return true }
        guard type == .keyDown else { return false }
        InputDiagnostics.record("keyDown")
        if recording {
            consumedKeys.begin(key)
            shortcutRecorder.record(keyCode: key, modifiers: event.flags.rawValue,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            return true
        }
        guard !IsSecureEventInputEnabled(), accessibilityGranted,
              let front = NSWorkspace.shared.frontmostApplication, !ownApp else {
            invalidate()
            return false
        }
        let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).rawValue
        func matches(_ command: ShortcutCommand) -> Bool {
            settings.shortcut(for: command).matches(keyCode: key, modifiers: flags)
        }
        if matches(.undo) {
            guard engine.undoIfCurrent() else {
                engine.noteNativeUndo()
                return false
            }
            consumedKeys.begin(key)
            return true
        }
        if matches(.correction) || matches(.switchLayout) {
            consumedKeys.begin(key)
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
            if matches(.switchLayout) {
                invalidate()
                _ = InputSources.toggle()
            } else { engine.correctManually() }
            return true
        }
        if FocusContextTransition.invalidatesLease(keyCode: key, flags: event.flags) {
            TextAccess.invalidateFocusEvidence()
            InputDiagnostics.record("focusEvidenceInvalidatedNavigation")
        }
        guard settings.automatic, !settings.excludedApps.contains(front.bundleIdentifier ?? ""),
              key != 48, let decoded = InputSources.decode(event) else {
            invalidate()
            return false
        }
        InputDiagnostics.record("decodedKey")
        engine.accept(text: decoded.text, sourceID: decoded.sourceID, pid: front.processIdentifier)
        return false
    }
}

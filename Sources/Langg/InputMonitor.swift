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
    private let spelling = SpellingService()
    private var tap: CFMachPort?
    private var runSource: CFRunLoopSource?
    private var undo: UndoRecord?
    private var suppressed: SuppressedCorrection?
    private var queue = CorrectionQueue()
    private var pendingFields: [UInt64: TextFieldIdentity] = [:]
    private var pendingProcesses: [UInt64: pid_t] = [:]
    private let inputReplay = InputReplayGate()
    private var tapStopRequested = false
    private var workerTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var typingField: TextFieldIdentity?
    private var typingSource: String?
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

    private struct UndoRecord {
        let edit: TextReplacement
        let after: TextSnapshot
        let previousInputSourceID: String?
        let wordRange: NSRange
    }

    private struct SuppressedCorrection {
        let field: TextFieldIdentity
        let range: NSRange
        let word: String
    }

    init(settings: AppSettings) {
        self.settings = settings
        shortcutRecorder = ShortcutRecorder(settings: settings)
        inputReplay.onOverflow = { [weak self] in
            self?.workerTask?.cancel()
            self?.manualTask?.cancel()
        }
        inputReplay.onDrained = { [weak self] in
            DispatchQueue.main.async { self?.finishStoppingEventTap() }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self.permissionSetup.didActivateApplication(isSystemSettings: app.bundleIdentifier == "com.apple.systempreferences")
                }
                self.invalidate()
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
        generation &+= 1
        spelling.clearWordCache()
        workerTask?.cancel()
        workerTask = nil
        manualTask?.cancel()
        manualTask = nil
        queue.reset()
        pendingFields.removeAll()
        pendingProcesses.removeAll()
        typingField = nil
        typingSource = nil
        undo = nil
        suppressed = nil
        modifierChord.reset()
    }

    private func handle(_ event: CGEvent, type: CGEventType) -> Bool {
        // Replacement events are application input, not new user typing.
        if TextAccess.isReplacementEvent(event) { return false }
        let replay = inputReplay.prepareIncoming(event)
        defer { inputReplay.finishIncoming(replay) }
        if inputReplay.shouldBuffer(event, replay: replay) { return true }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown { invalidate() }
            return false
        }
        if type == .keyDown { InputDiagnostics.record("keyDown") }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let binding = settings.shortcut(for: .switchLayout)
        if modifierChordBinding != binding {
            modifierChordBinding = binding
            modifierChord = ModifierChordRecognizer(modifiers: binding.modifiers)
        }
        if type == .flagsChanged {
            let recording = shortcutRecorder.command != nil && NSApp.isActive && NSApp.keyWindow?.identifier == SettingsWindowController.windowID
            if recording { shortcutRecorder.recordModifiers(event.flags.rawValue); modifierChord.reset(); return false }
            if binding.isModifierOnly, modifierChord.observeModifiers(event.flags.rawValue),
               !IsSecureEventInputEnabled(), accessibilityGranted,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                invalidate()
                _ = InputSources.toggle()
            }
            return false
        }
        if type == .keyDown { modifierChord.noteKeyDown() }
        if consumedKeys.consumeContinuation(keyCode: key, isKeyDown: type == .keyDown) { return true }
        guard type == .keyDown else { return false }
        let isOwnApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if InputDiagnostics.enabled {
            InputDiagnostics.record(isOwnApp ? "ownApplication" : "otherApplication")
            InputDiagnostics.record(InputSources.currentIsSupported() ? "supportedLayout" : "unsupportedLayout")
            InputDiagnostics.record(Self.typedText(event) == nil ? "missingUnicode" : "hasUnicode")
        }
        if isOwnApp, NSApp.isActive, shortcutRecorder.command != nil, NSApp.keyWindow?.identifier == SettingsWindowController.windowID {
            consumedKeys.begin(key)
            shortcutRecorder.record(keyCode: key, modifiers: event.flags.rawValue,
                                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            return true
        }
        guard !IsSecureEventInputEnabled(), accessibilityGranted,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { invalidate(); return false }
        let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).rawValue
        func matches(_ command: ShortcutCommand) -> Bool {
            let shortcut = settings.shortcut(for: command)
            return shortcut.matches(keyCode: key, modifiers: flags)
        }
        if matches(.undo) {
            // An absent or stale Langg undo must leave the application's Cmd+Z intact.
            guard let record = undo, TextAccess.isCurrent(record.after) else { invalidate(); return false }
            consumedKeys.begin(key)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                invalidate()
                manualTask = Task { [weak self] in await self?.undoLast(record) }
            }
            return true
        }
        if matches(.correction) || matches(.switchLayout) {
            consumedKeys.begin(key)
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
            invalidate()
            if matches(.switchLayout) { _ = InputSources.toggle() }
            else {
                let pid = front.processIdentifier
                manualTask = Task { [weak self] in
                    guard let self, pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                    await self.correctText()
                }
            }
            return true
        }
        manualTask?.cancel()
        undo = nil
        guard settings.automatic, !settings.excludedApps.contains(front.bundleIdentifier ?? ""),
              event.flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty,
              let source = InputSources.currentIdentifier(), InputSources.currentIsSupported(),
              let text = Self.typedText(event), text.count == 1 else { invalidate(); return false }
        if let typingSource, typingSource != source { invalidate() }
        typingSource = source
        // AX queries happen in the worker, outside the event-tap callback. Keep
        // every completed request's process even before the first field is read.
        if key == 48 { invalidate(); return false }
        let character = text.first!
        let completes = character.isWhitespace || (character.isPunctuation && !"[{'\"`~<".contains(character))
        queue.append(text, completesWord: completes)
        let ids = Set(queue.requests.map(\.id))
        pendingFields = pendingFields.filter { ids.contains($0.key) }
        pendingProcesses = pendingProcesses.filter { ids.contains($0.key) }
        if completes, let request = queue.requests.last {
            pendingProcesses[request.id] = front.processIdentifier
            if let field = typingField { pendingFields[request.id] = field }
            startWorker(source: source)
        }
        if key == 48 || key == 36 || key == 76 { typingField = nil }
        return false
    }

    private static func typedText(_ event: CGEvent) -> String? {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        // Navigation, deletion and function keys aren't text, even if Unicode is supplied.
        guard ![51, 53, 71, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(key),
              !(96...113).contains(key) else { return nil }
        var count = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        guard count > 0, count <= units.count else { return nil }
        let text = String(utf16CodeUnits: units, count: count).replacingOccurrences(of: "\r", with: "\n")
        guard text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || "\n\t".unicodeScalars.contains($0) }) else { return nil }
        return text
    }

    private func startWorker(source: String) {
        guard workerTask == nil, !queue.requests.isEmpty else { return }
        let epoch = generation
        workerTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == epoch { self.workerTask = nil } }
            while !Task.isCancelled, self.generation == epoch, let request = self.queue.requests.first {
                await self.process(request.id, source: source, epoch: epoch)
                guard self.generation == epoch else { return }
                self.queue.remove(request.id)
                self.pendingFields.removeValue(forKey: request.id)
                self.pendingProcesses.removeValue(forKey: request.id)
            }
        }
    }

    private func process(_ id: UInt64, source: String, epoch: UInt64) async {
        InputDiagnostics.record("completedWord")
        // Let the editor consume the delimiter. Ambiguous punctuation gets a short
        // grace period so a semicolon in "gj;fkeqcnf" isn't mistaken for word end.
        let ambiguous = queue.request(id)?.delimiter.first.map(LayoutConverter.isPhysicalLetterKey) == true
        do { try await Task.sleep(for: .milliseconds(ambiguous ? 45 : 8)) } catch { return }
        guard let expectedProcess = pendingProcesses[id] else { return }
        let expectedField = pendingFields[id]
        var initial: TextSnapshot?
        var boundary: Int?
        for _ in 0..<5 {
            guard !Task.isCancelled, generation == epoch, settings.automatic,
                  InputSources.currentIdentifier() == source,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedProcess else { return }
            guard let snapshot = TextAccess.capture() else {
                do { try await Task.sleep(for: .milliseconds(12)) } catch { return }
                continue
            }
            guard snapshot.pid == expectedProcess,
                  expectedField == nil || snapshot.field == expectedField else { return }
            if let caret = queue.boundaryCaret(for: id, in: snapshot.state) {
                initial = snapshot
                boundary = caret
                pendingFields[id] = snapshot.field
                typingField = snapshot.field
                break
            }
            do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
        }
        guard let initial, let boundary, let initialRequest = queue.request(id) else { return }
        if ambiguous, initialRequest.followingText.first.map(LayoutConverter.isLayoutLetter) == true { return }
        var reference = initial
        var referenceFollowing = initialRequest.followingText
        let currentWordStart = LayoutConverter.wordCandidates(in: initial.text, caretUTF16: boundary, completed: true).first?.location
        var switchDirection: LayoutDirection?
        let candidates = AutomaticCorrection.contextualCandidates(in: initial.text, caretUTF16: boundary, excludedWords: settings.excludedWords)
        var correctedRanges: Set<NSRange> = []
        for candidate in candidates {
            guard candidate.original.count != 2 else { continue }
            if correctedRanges.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 }) { continue }
            if let suppressed, suppressed.field == initial.field, suppressed.range == candidate.range,
               suppressed.word == candidate.original { continue }
            let sourceKnown = candidate.sourceNeedsDictionaryCheck
                ? await spelling.isKnown(candidate.original, language: candidate.direction.sourceLanguage, acceptCaseVariants: false) : false
            if candidate.sourceNeedsDictionaryCheck && sourceKnown == nil { continue }
            let needsContext = sourceKnown == true || candidate.original.count == 1
            let targetContextKnown = needsContext
                ? await hasTargetLanguageContext(candidate, in: TextAccess.capture()?.text ?? reference.text) : false
            if needsContext && !targetContextKnown { continue }
            let targetKnown = await spelling.isKnown(candidate.replacement, language: candidate.direction.targetLanguage)
            guard !Task.isCancelled, generation == epoch, settings.automatic,
                  !settings.excludedApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""),
                  !settings.excludedWords.contains(where: { $0.caseInsensitiveCompare(candidate.original) == .orderedSame }),
                  InputSources.currentIdentifier() == source,
                  AutomaticCorrection.shouldCorrect(candidate, sourceKnown: sourceKnown, targetKnown: targetKnown, targetContextKnown: targetContextKnown),
                  let request = queue.request(id), request.followingText.hasPrefix(referenceFollowing),
                  let latest = TextAccess.capture(), latest.field == initial.field else { continue }
            let appended = String(request.followingText.dropFirst(referenceFollowing.count))
            guard latest.state == reference.state.appendingAtCaret(appended),
                  queue.boundaryCaret(for: id, in: latest.state) != nil,
                  LayoutConverter.substring(latest.text, range: candidate.range) == candidate.original else { return }
            // Finish this batch before changing the layout; later dictionary
            // decisions still belong to the source captured for this request.
            guard let after = await apply(latest, range: candidate.range, replacement: candidate.replacement,
                                          direction: candidate.direction, switchLayout: false) else { return }
            correctedRanges.insert(candidate.range)
            reference = after
            referenceFollowing = request.followingText
            if candidate.range.location == currentWordStart { switchDirection = candidate.direction }
        }
        if let switchDirection, generation == epoch, InputSources.currentIdentifier() == source,
           let request = queue.request(id), request.followingText.allSatisfy({
               $0.isWhitespace || ($0.isPunctuation && !LayoutConverter.isPhysicalLetterKey($0))
           }), TextAccess.isCurrent(reference) {
            _ = InputSources.select(switchDirection.targetLanguage)
        }
    }

    private func hasTargetLanguageContext(_ candidate: CorrectionCandidate, in text: String) async -> Bool {
        let targetDirection: LayoutDirection = candidate.direction == .englishToRussian ? .russianToEnglish : .englishToRussian
        for word in AutomaticCorrection.contextWords(for: candidate, in: text) {
            if LayoutConverter.isAlphabeticWord(word, direction: targetDirection),
               await spelling.isKnown(word, language: candidate.direction.targetLanguage) == true { return true }
        }
        return false
    }

    private func correctText() async {
        InputDiagnostics.record("manualCorrection")
        guard let snapshot = TextAccess.capture() else {
            correctionFeedback = "Не удалось получить доступ к тексту в этом поле."
            return
        }
        let source = InputSources.currentIdentifier()
        let epoch = generation
        let ranges = snapshot.state.selection.length > 0 ? [snapshot.state.selection]
            : LayoutConverter.manualWordCandidates(in: snapshot.text, caretUTF16: snapshot.state.selection.location)
        guard let fallback = ranges.last else { correctionFeedback = "Нет слова или выделения для исправления."; return }
        var chosenRange = fallback
        var chosenReplacement: String?
        var chosenDirection: LayoutDirection?
        // Resolve punctuation keys, including internal/trailing comma and period,
        // using a whole-word match. Manual correction never requires valid spelling.
        for range in ranges {
            guard let word = LayoutConverter.substring(snapshot.text, range: range),
                  let direction = LayoutConverter.detectedDirection(word),
                  let literal = LayoutConverter.convert(word, direction: direction, punctuation: .physicalKeys),
                  LayoutConverter.isAlphabeticWord(literal, direction: direction == .englishToRussian ? .russianToEnglish : .englishToRussian),
                  await spelling.isKnown(literal, language: direction.targetLanguage) == true else { continue }
            chosenRange = range
            chosenReplacement = literal
            chosenDirection = direction
            break
        }
        guard let original = LayoutConverter.substring(snapshot.text, range: chosenRange),
              let direction = chosenDirection ?? LayoutConverter.detectedDirection(original) else {
            correctionFeedback = "Выделите фрагмент в одной раскладке: русской или английской."
            return
        }
        let replacement: String?
        if let chosenReplacement { replacement = chosenReplacement }
        else { replacement = await convertedManualText(original, direction: direction) }
        guard let replacement, replacement != original else { return }
        guard !Task.isCancelled, generation == epoch, TextAccess.isCurrent(snapshot), InputSources.currentIdentifier() == source else { return }
        await apply(snapshot, range: chosenRange, replacement: replacement, direction: direction, switchLayout: true)
    }

    private func convertedManualText(_ text: String, direction: LayoutDirection) async -> String? {
        var output = ""
        var token = ""
        func convertToken(_ token: String) async -> String {
            var result = LayoutConverter.convert(token, direction: direction) ?? token
            for range in LayoutConverter.wordCandidates(in: token + " ", caretUTF16: token.utf16.count + 1, completed: true) {
                guard let word = LayoutConverter.substring(token, range: range),
                      let literal = LayoutConverter.convert(word, direction: direction, punctuation: .physicalKeys),
                      literal != LayoutConverter.substring(result, range: range),
                      LayoutConverter.isAlphabeticWord(literal, direction: direction == .englishToRussian ? .russianToEnglish : .englishToRussian),
                      await spelling.isKnown(literal, language: direction.targetLanguage) == true,
                      let resultRange = Range(range, in: result) else { continue }
                result.replaceSubrange(resultRange, with: literal)
                break
            }
            return result
        }
        for character in text {
            if Task.isCancelled { return nil }
            if character.isWhitespace {
                output += await convertToken(token)
                token = ""
                output.append(character)
            } else { token.append(character) }
        }
        output += await convertToken(token)
        return output == text ? nil : output
    }

    @discardableResult private func apply(_ snapshot: TextSnapshot, range: NSRange, replacement: String,
                       direction: LayoutDirection, switchLayout: Bool) async -> TextSnapshot? {
        InputDiagnostics.record("replacementAttempt")
        let previousSource = InputSources.currentIdentifier()
        guard let edit = TextReplacement(before: snapshot.state, range: range, replacement: replacement),
              await beginReplacement() else { return nil }
        defer { inputReplay.end() }
        var editedBounds: CGRect?
        let captureBounds: ((CGRect) -> Void)? = settings.notifications ? { editedBounds = $0 } : nil
        guard let after = await TextAccess.replace(snapshot, edit: edit, selectedBounds: captureBounds) else {
            correctionFeedback = "Поле не подтвердило замену. Проверьте текст перед повторным исправлением."
            return nil
        }
        undo = UndoRecord(edit: edit, after: after, previousInputSourceID: previousSource, wordRange: range)
        if switchLayout { _ = InputSources.select(direction.targetLanguage) }
        correctionFeedback = "Текст исправлен."
        if settings.notifications {
            let writtenRange = NSRange(location: range.location, length: replacement.utf16.count)
            // A growing web composer may reflow while committing the edit.
            // Prefer its final glyph position over the pre-insertion selection.
            if let bounds = TextAccess.textBounds(after, range: writtenRange) ?? editedBounds {
                toast.show(at: bounds)
            } else {
                InputDiagnostics.record("notificationMissingGeometry")
                toast.hide()
            }
        }
        return after
    }

    private func undoLast(_ record: UndoRecord) async {
        guard !Task.isCancelled, TextAccess.isCurrent(record.after) else { return }
        let range = NSRange(location: record.edit.range.location, length: record.edit.replacement.utf16.count)
        guard let edit = TextReplacement(before: record.after.state, range: range, replacement: record.edit.original,
                                         restoringSelection: record.edit.before.selection),
              await beginReplacement() else { return }
        defer { inputReplay.end() }
        guard await TextAccess.replace(record.after, edit: edit) != nil else { return }
        if settings.undoRestoresLayout, let id = record.previousInputSourceID { _ = InputSources.selectIdentifier(id) }
        suppressed = SuppressedCorrection(field: record.after.field, range: record.wordRange, word: record.edit.original)
        correctionFeedback = "Исправление отменено."
        if settings.notifications { toast.showUndoIfVisible() }
    }

    private func beginReplacement() async -> Bool {
        for _ in 0..<100 {
            guard !Task.isCancelled, !tapStopRequested else { return false }
            if inputReplay.begin() { return true }
            do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
        }
        return false
    }
}

@MainActor enum InputSources {
    private static let supportedIDs: [String: [String]] = [
        "en": ["com.apple.keylayout.US", "com.apple.keylayout.ABC"],
        "ru": ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"]
    ]

    static func currentIsSupported() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = identifier(source) else { return false }
        return supportedIDs.values.flatMap { $0 }.contains(id)
    }

    static func toggle() -> Bool {
        guard let current = currentIdentifier() else { return false }
        if supportedIDs["ru"]?.contains(current) == true { return select("en") }
        if supportedIDs["en"]?.contains(current) == true { return select("ru") }
        return false
    }

    static func select(_ language: String) -> Bool {
        guard let allowed = supportedIDs[language],
              let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return false }
        for source in sources where identifier(source).map(allowed.contains) == true {
            return TISSelectInputSource(source) == noErr
        }
        return false
    }

    static func currentIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return identifier(source)
    }

    static func selectIdentifier(_ id: String) -> Bool {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return false }
        guard let source = sources.first(where: { identifier($0) == id }) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

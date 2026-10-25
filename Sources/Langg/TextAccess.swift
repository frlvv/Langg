import AppKit
import ApplicationServices
import Carbon
import LanggCore

struct TextFieldIdentity: Equatable {
    let element: AXUIElement
    let pid: pid_t

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element) }
}

struct TextSnapshot {
    let field: TextFieldIdentity
    let state: TextState
    var element: AXUIElement { field.element }
    var pid: pid_t { field.pid }
    var text: String { state.text }
    var selection: CFRange { CFRange(location: state.selection.location, length: state.selection.length) }
}

@MainActor enum TextAccess {
    private enum AccessibilityActivation {
        case enabled
        case unsupported
        case retryAfter(TimeInterval)

        var isEnabled: Bool {
            if case .enabled = self { return true }
            return false
        }
    }

    private struct AccessibilityClient {
        let application: NSRunningApplication
        let isChromium: Bool
        var manual: AccessibilityActivation?
        var enhanced: AccessibilityActivation?
        var enabledAt: TimeInterval?
    }

    private static var accessibilityClients: [pid_t: AccessibilityClient] = [:]
    private struct RecoveredFocus {
        let field: TextFieldIdentity
        let window: AXUIElement
        let notification: FocusedElementObserver.Token?

        init(field: TextFieldIdentity, window: AXUIElement, notification: FocusedElementObserver.Token? = nil) {
            self.field = field
            self.window = window
            self.notification = notification
        }
    }
    private static var recoveredFocus: RecoveredFocus?
    private struct PointerFocusHint {
        let point: CGPoint
        let pid: pid_t
        let capturedAt: TimeInterval
        var checked = false
    }
    private static var pointerFocusHint: PointerFocusHint?
    private static let focusObserver: FocusedElementObserver = {
        let observer = FocusedElementObserver()
        observer.onChange = { contextChanged in
            recoveredFocus = nil
            if contextChanged { pointerFocusHint = nil }
        }
        return observer
    }()

    static func invalidateFocusEvidence() { focusObserver.invalidate() }
    static func stopFocusObservation() { focusObserver.stop() }
    static func applicationDidDeactivate(pid: pid_t) { focusObserver.stop(ifObserving: pid) }

    /// The event tap records only the physical click. All accessibility work is
    /// deferred until a failed typed-text boundary needs focus recovery.
    static func notePointerFocus(at point: CGPoint, pid: pid_t) {
        invalidateFocusEvidence()
        pointerFocusHint = PointerFocusHint(point: point, pid: pid, capturedAt: ProcessInfo.processInfo.systemUptime)
        recoveredFocus = nil
    }

    /// Start Chromium's asynchronous accessibility-tree activation when the app
    /// becomes active, before a completed word needs its first AX snapshot.
    static func prepareTextAccessibility(for application: NSRunningApplication) {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { stopFocusObservation(); return }
        focusObserver.observe(pid: application.processIdentifier)
        let chromium = accessibilityClients[application.processIdentifier]?.isChromium
            ?? application.bundleURL.map { ChromiumAccessibility.isChromiumApplication(at: $0) } ?? false
        guard chromium else { return }
        enableTextAccessibility(for: application, element: applicationElement(application))
    }

    static func isTextAccessibilityWarmingUp(forPID pid: pid_t) -> Bool {
        guard let enabledAt = accessibilityClients[pid]?.enabledAt else { return false }
        return ProcessInfo.processInfo.systemUptime - enabledAt < 0.75
    }

    private static func applicationElement(_ application: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.10)
        return element
    }

    private static func enableTextAccessibility(for application: NSRunningApplication, element: AXUIElement) {
        let pid = application.processIdentifier
        accessibilityClients = accessibilityClients.filter { !$0.value.application.isTerminated }
        var client = accessibilityClients[pid] ?? AccessibilityClient(application: application,
            isChromium: application.bundleURL.map { ChromiumAccessibility.isChromiumApplication(at: $0) } ?? false)
        defer {
            if client.enabledAt == nil, client.manual?.isEnabled == true || client.enhanced?.isEnabled == true {
                client.enabledAt = ProcessInfo.processInfo.systemUptime
            }
            accessibilityClients[pid] = client
        }
        if client.enhanced?.isEnabled == true { return }
        // Electron documents this opt-in for third-party assistive technology.
        // Chromium 155 can reject it; its enhanced opt-in is restricted to
        // embedded Chromium engines because it also affects native UI behavior.
        client.manual = activateAccessibility("AXManualAccessibility", state: client.manual,
            element: element, verify: false, diagnostic: "textAccessibility")
        if case .enabled = client.manual { return }
        guard client.isChromium else { return }
        client.enhanced = activateAccessibility("AXEnhancedUserInterface", state: client.enhanced,
            element: element, verify: true, diagnostic: "enhancedTextAccessibility")
    }

    private static func activateAccessibility(_ attribute: String, state: AccessibilityActivation?,
                                              element: AXUIElement, verify: Bool,
                                              diagnostic: String) -> AccessibilityActivation {
        switch state {
        case .enabled: return .enabled
        case .unsupported: return .unsupported
        case .retryAfter(let deadline) where ProcessInfo.processInfo.systemUptime < deadline: return .retryAfter(deadline)
        default: break
        }
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue)
        if result == .success {
            var raw: CFTypeRef?
            if !verify || (AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success && raw as? Bool == true) {
                InputDiagnostics.record("\(diagnostic)Enabled")
                return .enabled
            }
        }
        InputDiagnostics.record("\(diagnostic)Unavailable")
        // Unsupported attributes are distinct from enabled ones. Temporary
        // messaging failures can recover, with a cooldown instead of per-word IPC.
        if result == .attributeUnsupported { return .unsupported }
        return .retryAfter(ProcessInfo.processInfo.systemUptime + 5)
    }

    static func focusedField(recoveringFocus: Bool = false, excluding rejected: TextFieldIdentity? = nil) -> TextFieldIdentity? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            stopFocusObservation(); InputDiagnostics.record("captureProtected"); return nil
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { stopFocusObservation(); return nil }
        focusObserver.observe(pid: application.processIdentifier)
        let app = applicationElement(application)
        enableTextAccessibility(for: application, element: app)
        let window = elementAttribute(app, kAXFocusedWindowAttribute as CFString)
        if !recoveringFocus, let recovered = recoveredFocus,
           recovered.field.pid == application.processIdentifier, recoveredFocusIsCurrent(recovered) {
            InputDiagnostics.record("focusRecoveredCacheUsed")
            return recovered.field
        }
        recoveredFocus = nil
        if let observed = observedFocusedTarget(appWindow: window, pid: application.processIdentifier, excluding: rejected) {
            recoveredFocus = observed
            return observed.field
        }
        if !recoveringFocus, let hint = pointerFocusHint, !hint.checked {
            pointerFocusHint?.checked = true
            if hint.pid == application.processIdentifier,
               let recovered = pointerFocusedTarget(appWindow: window, pid: application.processIdentifier, excluding: nil) {
                recoveredFocus = recovered
                return recovered.field
            }
        }
        if recoveringFocus {
            guard let recovered = recoverFocusedTarget(application: app, window: window,
                      pid: application.processIdentifier, excluding: rejected) else { return nil }
            recoveredFocus = recovered
            return recovered.field
        }
        // Embedded views can leave the application's pointer on an old editor
        // while their focused window already points at the active dialog input.
        if let window, let field = focusTarget(window),
           validTextField(field, pid: application.processIdentifier), focused(field) != false {
            InputDiagnostics.record("focusFromWindow")
            return TextFieldIdentity(element: field, pid: application.processIdentifier)
        }
        var raw: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw)
        if error != .success || raw == nil {
            InputDiagnostics.record("applicationFocusError.\(error.rawValue)")
            error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw)
        }
        if error != .success || raw == nil {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.05)
            error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw)
        }
        if error != .success || raw == nil {
            // Some embedded web views expose focus on their focused window
            // while the application and system-wide focus attributes have no value.
            var rawWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
               let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(window, 0.05)
                raw = nil
                error = AXUIElementCopyAttributeValue(window, kAXFocusedUIElementAttribute as CFString, &raw)
                if error == .success, raw != nil { InputDiagnostics.record("focusRecoveredFromWindow") }
            }
        }
        guard error == .success, let element = raw,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            InputDiagnostics.record("captureNoFocus")
            InputDiagnostics.record("focusError.\(error.rawValue)")
            return nil
        }
        let field = unsafeBitCast(element, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(field, 0.05)
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success,
              pid == application.processIdentifier,
              pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { InputDiagnostics.record("captureWrongApplication"); return nil }
        guard let role = string(field, kAXRoleAttribute as CFString),
              [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role),
              string(field, kAXSubroleAttribute as CFString) != kAXSecureTextFieldSubrole as String else {
            enableTextAccessibility(for: application, element: app)
            InputDiagnostics.record("captureNotText")
            return nil
        }
        if focused(field) == false {
            InputDiagnostics.record("captureFocusExplicitlyFalse")
            guard let window, let recovered = recoverFocusedText(in: window, pid: pid) else { return nil }
            let identity = TextFieldIdentity(element: recovered, pid: pid)
            recoveredFocus = RecoveredFocus(field: identity, window: window)
            return identity
        }
        return TextFieldIdentity(element: field, pid: pid)
    }

    static func capture(recoveringFocus: Bool = false, excluding rejected: TextFieldIdentity? = nil) -> TextSnapshot? {
        guard let identity = focusedField(recoveringFocus: recoveringFocus, excluding: rejected) else { return nil }
        let field = identity.element
        var selectedSettable = DarwinBoolean(false)
        let selectionCapability = AXUIElementIsAttributeSettable(field, kAXSelectedTextRangeAttribute as CFString, &selectedSettable)
        guard selectionCapability == .success else {
            InputDiagnostics.record("captureSelectionCapabilityError.\(selectionCapability.rawValue)")
            return nil
        }
        guard selectedSettable.boolValue else { InputDiagnostics.record("captureSelectionReadOnly"); return nil }
        guard let text = string(field, kAXValueAttribute as CFString) else { InputDiagnostics.record("captureNoText"); return nil }
        guard text.utf16.count <= 100_000 else { InputDiagnostics.record("captureTextTooLong"); return nil }
        guard let selection = range(field) else { InputDiagnostics.record("captureNoSelection"); return nil }
        guard let state = TextState(text: text, selection: selection) else { InputDiagnostics.record("captureInvalidSelection"); return nil }
        if InputDiagnostics.enabled {
            InputDiagnostics.record(focused(field).map { $0 ? "captureFocusedTrue" : "captureFocusedFalse" } ?? "captureFocusedUnknown")
            InputDiagnostics.record(selection.length == 0 ? "captureSelectionCollapsed" : "captureSelectionNonempty")
            InputDiagnostics.record(NSMaxRange(selection) == text.utf16.count ? "captureSelectionAtEnd" : "captureSelectionInterior")
        }
        InputDiagnostics.record("captureSuccess")
        return TextSnapshot(field: identity, state: state)
    }

    private static func focused(_ element: AXUIElement) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &raw) == .success else { return nil }
        return raw as? Bool
    }

    private static func elementAttribute(_ element: AXUIElement, _ key: CFString) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let result = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(result, 0.05)
        return result
    }

    private static func focusTarget(_ element: AXUIElement) -> AXUIElement? {
        var target = elementAttribute(element, kAXFocusedUIElementAttribute as CFString)
        var visited: [AXUIElement] = [element]
        for _ in 0..<4 {
            guard let current = target, !visited.contains(where: { CFEqual($0, current) }) else { return nil }
            visited.append(current)
            guard let nested = elementAttribute(current, kAXFocusedUIElementAttribute as CFString),
                  !CFEqual(current, nested) else { return current }
            target = nested
        }
        return nil
    }

    private static func validTextField(_ element: AXUIElement, pid: pid_t) -> Bool {
        var actualPID: pid_t = 0
        return AXUIElementGetPid(element, &actualPID) == .success && actualPID == pid
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && string(element, kAXSubroleAttribute as CFString) != kAXSecureTextFieldSubrole as String
            && string(element, kAXRoleAttribute as CFString).map {
                [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains($0)
            } == true
    }

    private static func validWindow(_ window: AXUIElement, pid: pid_t) -> Bool {
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(window, &actualPID) == .success, actualPID == pid,
              string(window, kAXRoleAttribute as CFString) == kAXWindowRole as String else { return false }
        for key in ["AXHidden", kAXMinimizedAttribute as String] {
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(window, key as CFString, &raw)
            guard error == .success || error == .attributeUnsupported || error == .noValue,
                  raw as? Bool != true else { return false }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func recoveredFocusIsCurrent(_ recovered: RecoveredFocus) -> Bool {
        let field = recovered.field.element
        let vouched = recovered.notification.map { focusObserver.isCurrent($0) } == true
        guard recovered.notification == nil || vouched,
              focused(field) == true || vouched, validTextField(field, pid: recovered.field.pid),
              isEditable(field),
              validWindow(recovered.window, pid: recovered.field.pid),
              let owner = elementAttribute(field, kAXWindowAttribute as CFString), CFEqual(owner, recovered.window) else {
            InputDiagnostics.record("focusRecoveredCacheInvalid")
            return false
        }
        var hidden: CFTypeRef?
        let hiddenError = AXUIElementCopyAttributeValue(field, "AXHidden" as CFString, &hidden)
        guard hiddenError == .success || hiddenError == .attributeUnsupported || hiddenError == .noValue,
              hidden as? Bool != true else {
            InputDiagnostics.record("focusRecoveredCacheHiddenOrUnavailable")
            return false
        }
        return true
    }

    private static func observedFocusedTarget(appWindow: AXUIElement?, pid: pid_t,
                                               excluding rejected: TextFieldIdentity?) -> RecoveredFocus? {
        guard let token = focusObserver.current(pid: pid) else { return nil }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(token.element, &actualPID) == .success, actualPID == pid,
              let window = elementAttribute(token.element, kAXWindowAttribute as CFString), validWindow(window, pid: pid) else {
            InputDiagnostics.record("observedFocusInvalidOwner"); return nil
        }
        var vouchedFields: [AXUIElement] = []
        let related = [token.element, elementAttribute(token.element, "AXEditableAncestor" as CFString),
                       elementAttribute(token.element, "AXHighestEditableAncestor" as CFString)].compactMap { $0 }
        for candidate in related where !vouchedFields.contains(where: { CFEqual($0, candidate) }) {
            if validTextField(candidate, pid: pid), let owner = elementAttribute(candidate, kAXWindowAttribute as CFString),
               CFEqual(owner, window) { vouchedFields.append(candidate) }
        }
        guard !vouchedFields.isEmpty else {
            focusObserver.reject(token)
            InputDiagnostics.record("observedFocusNoEditableRelation"); return nil
        }
        guard let field = focusedAncestor(of: token.element, in: window, pid: pid, excluding: rejected,
                                          requireDeclaredWindow: true, notification: token,
                                          vouchedFields: vouchedFields) else { return nil }
        let recovered = RecoveredFocus(field: TextFieldIdentity(element: field, pid: pid), window: window, notification: token)
        // A notification queued before a physical click must not supersede the
        // clicked editor. In this context prove the same field by both routes.
        if let hint = pointerFocusHint, hint.pid == pid,
           ProcessInfo.processInfo.systemUptime - hint.capturedAt < 30 {
            guard let clicked = pointerFocusedTarget(appWindow: appWindow, pid: pid, excluding: rejected,
                                                     notification: token, requiredField: field), clicked.field == recovered.field else {
                InputDiagnostics.record("observedFocusPointerDisagrees"); return nil
            }
            pointerFocusHint?.checked = true
        }
        guard recoveredFocusIsCurrent(recovered) else { return nil }
        focusObserver.watchDestruction(of: field)
        guard focusObserver.isCurrent(token) else { return nil }
        InputDiagnostics.record("focusRecoveredFromNotification")
        return recovered
    }

    private static func recoverFocusedTarget(application: AXUIElement, window: AXUIElement?,
                                              pid: pid_t, excluding rejected: TextFieldIdentity?) -> RecoveredFocus? {
        if let recovered = pointerFocusedTarget(appWindow: window, pid: pid, excluding: rejected) { return recovered }
        guard let window else { InputDiagnostics.record("focusRecoveryNoAppWindow"); return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.04)
        // Query system-wide focus even when app focus succeeded: separate
        // embedded surfaces can leave those two pointers temporarily different.
        for (source, diagnostic) in [(system, "focusRecoveredFromSystem"), (window, "focusRecoveredFromWindow"),
                                     (application, "focusRecoveredFromApplication")] {
            if let target = focusTarget(source),
               let field = focusedAncestor(of: target, in: window, pid: pid, excluding: rejected) {
                InputDiagnostics.record(diagnostic)
                return RecoveredFocus(field: TextFieldIdentity(element: field, pid: pid), window: window)
            }
        }
        guard let field = recoverFocusedText(in: window, pid: pid, excluding: rejected) else { return nil }
        return RecoveredFocus(field: TextFieldIdentity(element: field, pid: pid), window: window)
    }

    private static func pointerFocusedTarget(appWindow: AXUIElement?, pid: pid_t,
                                              excluding rejected: TextFieldIdentity?,
                                              notification: FocusedElementObserver.Token? = nil,
                                              requiredField: AXUIElement? = nil) -> RecoveredFocus? {
        if let hint = pointerFocusHint, hint.pid == pid,
           ProcessInfo.processInfo.systemUptime - hint.capturedAt < 30,
           hint.point.x.isFinite, hint.point.y.isFinite {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.04)
            var rawHit: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(system, Float(hint.point.x), Float(hint.point.y), &rawHit)
            guard result == .success, let hit = rawHit else {
                InputDiagnostics.record("focusPointerHitError.\(result.rawValue)")
                return nil
            }
            var hitPID: pid_t = 0
            guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else {
                InputDiagnostics.record("focusPointerWrongPID"); return nil
            }
            guard let window = elementAttribute(hit, kAXWindowAttribute as CFString) else {
                InputDiagnostics.record("focusPointerNoOwningWindow"); return nil
            }
            guard validWindow(window, pid: pid) else {
                InputDiagnostics.record("focusPointerInvalidWindow"); return nil
            }
            if appWindow.map({ CFEqual($0, window) }) == false {
                InputDiagnostics.record("focusPointerAppWindowDisagrees")
            }
            guard let field = focusedAncestor(of: hit, in: window, pid: pid, excluding: rejected,
                                               requireDeclaredWindow: true, notification: notification,
                                               vouchedFields: requiredField.map { [$0] } ?? []) else {
                InputDiagnostics.record("focusPointerAncestryRejected"); return nil
            }
            guard requiredField.map({ CFEqual($0, field) }) != false else { return nil }
            let recovered = RecoveredFocus(field: TextFieldIdentity(element: field, pid: pid), window: window,
                                          notification: notification)
            guard recoveredFocusIsCurrent(recovered) else { return nil }
            InputDiagnostics.record("focusRecoveredFromPointer")
            return recovered
        }
        return nil
    }

    private static func focusedAncestor(of hit: AXUIElement, in window: AXUIElement,
                                         pid: pid_t, excluding rejected: TextFieldIdentity?,
                                         requireDeclaredWindow: Bool = false,
                                         notification: FocusedElementObserver.Token? = nil,
                                         vouchedFields: [AXUIElement] = []) -> AXUIElement? {
        let prefix = notification == nil ? "focusAncestor" : "observedAncestor"
        guard notification.map({ $0.pid == pid && focusObserver.isCurrent($0) }) != false else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.040
        var touched: [AXUIElement] = []
        var failed = false
        defer { touched.forEach { AXUIElementSetMessagingTimeout($0, 0.05) } }
        func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(remaining))
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key, &raw)
            guard error == .success else {
                if error != .attributeUnsupported && error != .noValue {
                    failed = true
                    InputDiagnostics.record("\(prefix)ReadError.\(error.rawValue)")
                }
                return nil
            }
            return raw
        }
        func element(_ raw: CFTypeRef?) -> AXUIElement? {
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
        let result = FocusedFieldSearch.findAncestor(from: hit, owningWindow: requireDeclaredWindow ? window : nil,
                                                    equal: { CFEqual($0, $1) }) { current in
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            touched.append(current)
            AXUIElementSetMessagingTimeout(current, Float(deadline - ProcessInfo.processInfo.systemUptime))
            var actualPID: pid_t = 0
            guard AXUIElementGetPid(current, &actualPID) == .success, actualPID == pid else {
                InputDiagnostics.record("\(prefix)WrongPID"); return nil
            }
            if CFEqual(current, window) {
                if CFEqual(current, hit) { InputDiagnostics.record("\(prefix)HitRole.window") }
                return FocusedFieldSearch.Ancestor(isFocusedText: false, isExpectedWindow: true, parent: nil)
            }
            // A secure ancestor invalidates the entire hit, including its leaves.
            let subrole = attribute(current, kAXSubroleAttribute as CFString) as? String
            guard subrole != kAXSecureTextFieldSubrole as String else {
                InputDiagnostics.record("\(prefix)Secure"); return nil
            }
            guard attribute(current, "AXHidden" as CFString) as? Bool != true else {
                InputDiagnostics.record("\(prefix)Hidden"); return nil
            }
            let role = attribute(current, kAXRoleAttribute as CFString) as? String
            let textRole = role.map { [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains($0) } == true
            let category: String
            if textRole { category = "text" }
            else if role == kAXStaticTextRole as String { category = "static" }
            else if role == kAXGroupRole as String { category = "group" }
            else if role == "AXWebArea" { category = "web" }
            else { category = role == nil ? "missing" : "other" }
            InputDiagnostics.record("\(prefix)Role.\(category)")
            if CFEqual(current, hit) { InputDiagnostics.record("\(prefix)HitRole.\(category)") }
            let isRejected = rejected.map { $0.pid == pid && CFEqual($0.element, current) } == true
            let actualFocus = textRole || (InputDiagnostics.enabled && CFEqual(current, hit))
                ? attribute(current, kAXFocusedAttribute as CFString) as? Bool : nil
            if CFEqual(current, hit) {
                InputDiagnostics.record("\(prefix)HitFocused.\(actualFocus.map { $0 ? "true" : "false" } ?? "missing")")
            }
            let isVouched = notification.map { focusObserver.vouches($0, for: current, related: vouchedFields) } == true
            let editable = textRole && (actualFocus == true || isVouched || InputDiagnostics.enabled) && isEditable(current)
            if textRole {
                InputDiagnostics.record("\(prefix)TextFocused.\(actualFocus.map { $0 ? "true" : "false" } ?? "missing")")
                InputDiagnostics.record("\(prefix)TextEditable.\(editable ? "true" : "false")")
                if isRejected { InputDiagnostics.record("\(prefix)RejectedField") }
            }
            let isFocused = textRole && !isRejected && editable && (actualFocus == true || isVouched)
            var parent = element(attribute(current, kAXParentAttribute as CFString))
            var parentRoute = "parent"
            if parent == nil { parent = element(attribute(current, "AXEditableAncestor" as CFString)); parentRoute = "editable" }
            if parent == nil { parent = element(attribute(current, "AXHighestEditableAncestor" as CFString)); parentRoute = "highestEditable" }
            InputDiagnostics.record("\(prefix)Parent.\(parent == nil ? "missing" : parentRoute)")
            guard !failed else { return nil }
            let declaredWindow = isFocused && requireDeclaredWindow ? element(attribute(current, kAXWindowAttribute as CFString)) : nil
            if isFocused, requireDeclaredWindow {
                if let declaredWindow {
                    if !CFEqual(declaredWindow, window) { InputDiagnostics.record("\(prefix)OwningWindowMismatch") }
                } else { InputDiagnostics.record("\(prefix)NoOwningWindow") }
            }
            guard !failed else { return nil }
            return FocusedFieldSearch.Ancestor(isFocusedText: isFocused, isExpectedWindow: false,
                                              parent: parent, declaredWindow: declaredWindow)
        }
        guard !failed else { InputDiagnostics.record("\(prefix)AXError"); return nil }
        guard ProcessInfo.processInfo.systemUptime < deadline else { InputDiagnostics.record("\(prefix)Deadline"); return nil }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            InputDiagnostics.record("\(prefix)ApplicationChanged"); return nil
        }
        guard notification.map({ focusObserver.isCurrent($0) }) != false else {
            InputDiagnostics.record("observedAncestorSuperseded"); return nil
        }
        switch result {
        case .found(let field): return field
        case .noMatch: InputDiagnostics.record("\(prefix)NoMatch")
        case .ambiguous: InputDiagnostics.record("\(prefix)Ambiguous")
        case .incomplete: InputDiagnostics.record("\(prefix)Incomplete")
        }
        return nil
    }

    private static func recoverFocusedText(in window: AXUIElement, pid: pid_t,
                                            excluding rejected: TextFieldIdentity? = nil) -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.040
        var touched: [AXUIElement] = []
        defer { touched.forEach { AXUIElementSetMessagingTimeout($0, 0.05) } }
        func attribute(_ element: AXUIElement, _ key: CFString) -> (AXError, CFTypeRef?) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return (.cannotComplete, nil) }
            AXUIElementSetMessagingTimeout(element, Float(remaining))
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key, &raw)
            guard ProcessInfo.processInfo.systemUptime < deadline else { return (.cannotComplete, nil) }
            return (error, raw)
        }
        let result = FocusedFieldSearch.find(in: window, equal: { CFEqual($0, $1) }) { element in
            touched.append(element)
            let (roleError, rawRole) = attribute(element, kAXRoleAttribute as CFString)
            guard roleError == .success, let role = rawRole as? String else { return nil }
            let (hiddenError, rawHidden) = attribute(element, "AXHidden" as CFString)
            guard hiddenError == .success || hiddenError == .attributeUnsupported || hiddenError == .noValue else { return nil }
            if rawHidden as? Bool == true || role == kAXStaticTextRole as String {
                return FocusedFieldSearch.Node(isFocusedText: false, children: [])
            }
            let (focusedError, rawFocused) = attribute(element, kAXFocusedAttribute as CFString)
            guard focusedError == .success || focusedError == .attributeUnsupported || focusedError == .noValue else { return nil }
            var isFocused = false
            if rawFocused as? Bool == true,
               [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) {
                let (subroleError, rawSubrole) = attribute(element, kAXSubroleAttribute as CFString)
                guard subroleError == .success || subroleError == .attributeUnsupported || subroleError == .noValue else { return nil }
                var actualPID: pid_t = 0
                isFocused = rawSubrole as? String != kAXSecureTextFieldSubrole as String
                    && AXUIElementGetPid(element, &actualPID) == .success && actualPID == pid
                    && rejected.map { $0.pid == pid && CFEqual($0.element, element) } != true
            }
            let (childrenError, rawChildren) = attribute(element, kAXChildrenAttribute as CFString)
            let children: [AXUIElement]
            if childrenError == .attributeUnsupported || childrenError == .noValue {
                children = []
            } else {
                guard childrenError == .success, let rawChildren,
                      CFGetTypeID(rawChildren) == CFArrayGetTypeID(), let array = rawChildren as? [AnyObject],
                      array.count <= 64, array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
                children = array.map { unsafeBitCast($0, to: AXUIElement.self) }
            }
            return FocusedFieldSearch.Node(isFocusedText: isFocused, children: children)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { InputDiagnostics.record("focusSearchIncomplete"); return nil }
        switch result {
        case .found(let element): InputDiagnostics.record("focusSearchRecovered"); return element
        case .noMatch: InputDiagnostics.record("focusSearchNoMatch")
        case .ambiguous: InputDiagnostics.record("focusSearchAmbiguous")
        case .incomplete: InputDiagnostics.record("focusSearchIncomplete")
        }
        return nil
    }

    static func isCurrent(_ snapshot: TextSnapshot) -> Bool {
        guard let current = capture() else { return false }
        return current.field == snapshot.field && current.state == snapshot.state
    }

    /// Call while input is held, with a snapshot that includes every key the
    /// monitor has already forwarded. A replay's tap callback precedes its
    /// consumption by the target, so one matching AX read can still be stale.
    static func settledSnapshot(matching expected: TextSnapshot,
                                isValid: @MainActor () -> Bool = { true },
                                capture read: @MainActor () -> TextSnapshot? = { capture() }) async -> TextSnapshot? {
        var consecutiveMatches = 0
        for attempt in 0..<8 {
            guard !Task.isCancelled, isValid() else { return nil }
            if let current = read() {
                guard current.field == expected.field else { return nil }
                consecutiveMatches = current.state.matchesEditorState(expected.state) ? consecutiveMatches + 1 : 0
                if consecutiveMatches == 2 { return current }
            } else {
                consecutiveMatches = 0
            }
            if attempt < 7 {
                do { try await Task.sleep(for: .milliseconds(4)) }
                catch { return nil }
            }
        }
        return nil
    }

    static func replace(_ snapshot: TextSnapshot, edit: TextReplacement,
                        selectedBounds: ((CGRect) -> Void)? = nil) async -> TextSnapshot? {
        guard snapshot.state == edit.before else { InputDiagnostics.record("replacementSnapshotMismatch"); return nil }
        guard isEditable(snapshot.element) else { InputDiagnostics.record("replacementNotEditable"); return nil }
        // Resolve notification geometry before selecting the word. Embedded web
        // editors may need several AX queries for it; keep those round trips out
        // of the visible selection interval whenever a pre-edit anchor exists.
        let bounds = selectedBounds == nil ? nil : textBounds(snapshot, range: edit.range)
        if let bounds { selectedBounds?(bounds) }
        guard let after = await TextReplacementTransaction.applyWithFallback(edit, to: snapshot.field,
                using: AXEditor(edit: edit, selectedBounds: bounds == nil ? selectedBounds : nil)) else {
            InputDiagnostics.record("replacementTransactionFailed")
            return nil
        }
        return TextSnapshot(field: snapshot.field, state: after)
    }

    private static let replacementMarker: Int64 = 0x4C414E4747544558
    static func isReplacementEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == replacementMarker
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        for key in [kAXSelectedTextAttribute as CFString, kAXValueAttribute as CFString] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, key, &settable) == .success, settable.boolValue { return true }
        }
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &raw) == .success,
           (raw as? Bool) == true { return true }
        // Web contenteditables can expose editable ancestry while their
        // AXSelectedText/AXValue setters are unavailable. Require this exact
        // focused text element to be the editable ancestor, never a web area.
        for key in ["AXEditableAncestor", "AXHighestEditableAncestor"] {
            raw = nil
            if AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success,
               let ancestor = raw, CFGetTypeID(ancestor) == AXUIElementGetTypeID(),
               CFEqual(ancestor, element) { return true }
        }
        return false
    }

    private struct AXEditor: TextEditor {
        let edit: TextReplacement
        let selectedBounds: ((CGRect) -> Void)?

        func supportsDirectReplacement(in field: TextFieldIdentity) -> Bool {
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(field.element, kAXSelectedTextAttribute as CFString, &settable)
            return result == .success && settable.boolValue
        }

        func read() -> (field: TextFieldIdentity, state: TextState)? {
            guard let snapshot = capture() else { return nil }
            return (snapshot.field, snapshot.state)
        }

        func select(_ range: NSRange, in field: TextFieldIdentity) -> Bool {
            var value = CFRange(location: range.location, length: range.length)
            guard let axValue = AXValueCreate(.cfRange, &value) else { return false }
            return AXUIElementSetAttributeValue(field.element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
        }

        func replaceSelection(with text: String, in field: TextFieldIdentity) -> Bool {
            // Selection has been verified by the transaction. Web editors can
            // expose text-marker geometry even without integer-range bounds.
            captureSelectionBounds(in: field)
            // Geometry is a separate AX round trip. Input already queued by
            // the target can commit while that query runs, so the transaction's
            // earlier selection read cannot authorize this later write.
            guard !Task.isCancelled, let ready = read(), ready.field == field,
                  ready.state.text == edit.before.text,
                  ready.state.selection == edit.range else { return false }
            return AXUIElementSetAttributeValue(field.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        }

        private func captureSelectionBounds(in field: TextFieldIdentity) {
            if selectedBounds != nil,
               let bounds = textBounds(field.element, text: edit.before.text, range: edit.range)
                    ?? selectedMarkerBounds(field.element, characterCount: edit.original.count) {
                selectedBounds?(bounds)
            }
        }

        func insertText(_ text: String, in field: TextFieldIdentity, expected: TextState) async -> Bool {
            guard !Task.isCancelled, CGPreflightPostEventAccess(),
                  let source = CGEventSource(stateID: .privateState) else { return false }
            source.userData = replacementMarker
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
                  let selectedRange = Range(expected.selection, in: expected.text) else { return false }
            captureSelectionBounds(in: field)
            for event in [down, up] {
                event.flags = .maskCommand
                event.setIntegerValueField(.eventSourceUserData, value: replacementMarker)
            }
            // Preserve every representation before leasing the shared clipboard.
            // Its change count prevents restoration over a subsequent user copy.
            guard let lease = PasteboardLease.acquire(text: text) else { return false }
            defer { lease.restore() }
            guard !Task.isCancelled, lease.isCurrent, let ready = read(), ready.field == field, ready.state == expected else { return false }
            down.postToPid(field.pid)
            up.postToPid(field.pid)
            let expectedText = expected.text.replacingCharacters(in: selectedRange, with: text)
            // Paste is delivered asynchronously. Keep its clipboard payload alive
            // until readback confirms consumption, including after cancellation.
            for _ in 0..<75 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4)) { continuation.resume() }
                }
                if let current = read(), current.field == field, current.state.text == expectedText { break }
            }
            // Dispatch alone is not success: Core verifies text and restores the
            // caret while InputMonitor holds physical input until completion.
            return true
        }
    }

    static func textBounds(_ snapshot: TextSnapshot, range: NSRange) -> CGRect? {
        if let direct = textBounds(snapshot.element, text: snapshot.text, range: range) { return direct }
        guard let leading = TextGeometry.leadingCharacter(in: snapshot.text, range: range) else { return nil }
        let result = FocusedTextGeometry.bounds(snapshot.element, text: snapshot.text, editedRange: range, leading: leading)
        InputDiagnostics.record(result == nil ? "descendantBoundsUnavailable" : "descendantBoundsFound")
        return result
    }

    private static func textBounds(_ element: AXUIElement, text: String, range: NSRange) -> CGRect? {
        guard let leading = TextGeometry.leadingCharacter(in: text, range: range) else { return nil }
        var range = CFRange(location: leading.location, length: leading.length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element,
            kAXBoundsForRangeParameterizedAttribute as CFString, param, &raw)
        guard result == .success else { InputDiagnostics.record("boundsError.\(result.rawValue)"); return nil }
        guard let rect = rectValue(raw) else { InputDiagnostics.record("boundsNotRectangle"); return nil }
        if let reason = TextGeometry.rejection(rect, characterCount: 1, fieldFrame: frame(element)) {
            InputDiagnostics.record("boundsRejected.\(reason)")
            return nil
        }
        return rect
    }

    private static func selectedMarkerBounds(_ element: AXUIElement, characterCount: Int) -> CGRect? {
        var marker: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker)
        guard result == .success, let marker else { InputDiagnostics.record("markerError.\(result.rawValue)"); return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,
              "AXBoundsForTextMarkerRange" as CFString, marker, &raw) == .success,
              let rect = rectValue(raw),
              TextGeometry.usable(rect, characterCount: characterCount, fieldFrame: frame(element)) else { return nil }
        return rect
    }

    private static func rectValue(_ raw: CFTypeRef?) -> CGRect? {
        guard let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &rect) else { return nil }
        return rect
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              let position = rawPosition, CFGetTypeID(position) == AXValueGetTypeID(),
              let size = rawSize, CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func string(_ element: AXUIElement, _ key: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &raw) == .success else { return nil }
        if let text = raw as? String { return text }
        if CFEqual(key, kAXValueAttribute as CFString), let text = raw as? NSAttributedString {
            InputDiagnostics.record("captureAttributedValue")
            return text.string
        }
        return nil
    }

    private static func range(_ element: AXUIElement) -> NSRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &result) else { return nil }
        return NSRange(location: result.location, length: result.length)
    }
}


/// Only the captured focused input's own descendants may supply missing text geometry.
/// No application/window ancestry or mouse position is used as an anchor.
private enum FocusedTextGeometry {
    private final class Budget {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.040
        var exhausted = false

        func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { exhausted = true; return false }
            AXUIElementSetMessagingTimeout(element, Float(remaining))
            return true
        }

        func attribute(_ element: AXUIElement, _ key: CFString) -> (AXError, CFTypeRef?) {
            guard prepare(element) else { return (.cannotComplete, nil) }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key, &value)
            if ProcessInfo.processInfo.systemUptime >= deadline { exhausted = true }
            return (error, value)
        }
    }

    static func bounds(_ focused: AXUIElement, text: String, editedRange: NSRange, leading: NSRange) -> CGRect? {
        let budget = Budget()
        defer { AXUIElementSetMessagingTimeout(focused, 0.05) }
        // The focused input's leading range was already queried by textBounds.
        guard let inputFrame = frame(focused, budget: budget), !inputFrame.isEmpty else { return nil }
        var stack: [(AXUIElement, Int)] = [(focused, 0)]
        var visited: [AXUIElement] = []
        var candidate: (AXUIElement, String, NSRange, String)?
        while let (element, depth) = stack.popLast() {
            guard !budget.exhausted, visited.count < 24,
                  !visited.contains(where: { CFEqual($0, element) }) else { return nil }
            visited.append(element)
            let (childrenError, rawChildren) = budget.attribute(element, kAXChildrenAttribute as CFString)
            let children: [AXUIElement]
            if childrenError == .success {
                guard let rawChildren, CFGetTypeID(rawChildren) == CFArrayGetTypeID(),
                      let array = rawChildren as? [AnyObject], array.count <= 24,
                      array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
                children = array.map { unsafeBitCast($0, to: AXUIElement.self) }
            } else if childrenError == .attributeUnsupported || childrenError == .noValue { children = [] }
            else { return nil }
            if !children.isEmpty {
                guard depth < 5, visited.count + stack.count + children.count <= 24 else { return nil }
                stack.append(contentsOf: children.map { ($0, depth + 1) })
                continue
            }
            guard depth > 0 else { continue }
            let (roleError, rawRole) = budget.attribute(element, kAXRoleAttribute as CFString)
            guard roleError == .success, let role = rawRole as? String else { return nil }
            guard [kAXStaticTextRole as String, kAXTextFieldRole as String, kAXTextAreaRole as String].contains(role) else { continue }
            let (valueError, rawText) = budget.attribute(element, kAXValueAttribute as CFString)
            guard valueError == .success, let leaf = rawText as? String else { return nil }
            guard let mapped = TextGeometry.mappedLeaf(leaf, in: text, covering: editedRange) else { continue }
            guard candidate == nil else { return nil }
            candidate = (element, leaf, mapped, role)
        }
        guard !budget.exhausted, let (element, leaf, mapped, role) = candidate else { return nil }
        defer { AXUIElementSetMessagingTimeout(element, 0.05) }
        let local = NSRange(location: leading.location - mapped.location, length: leading.length)
        if let result = rangeBounds(element, range: local, budget: budget),
           TextGeometry.usable(result, characterCount: 1, fieldFrame: inputFrame), !budget.exhausted {
            return result
        }
        // Static text frames start at their first glyph, even with a trailing
        // delimiter or further words. An interior word still needs range geometry.
        guard role == kAXStaticTextRole as String,
              let result = frame(element, budget: budget), !budget.exhausted else { return nil }
        return TextGeometry.leafFrameAnchor(result, leaf: leaf, mapped: mapped,
                                            leading: leading, fieldFrame: inputFrame)
    }

    private static func rangeBounds(_ element: AXUIElement, range: NSRange, budget: Budget) -> CGRect? {
        guard budget.prepare(element) else { return nil }
        var range = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        if ProcessInfo.processInfo.systemUptime >= budget.deadline { budget.exhausted = true; return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgRect, &rect) else { return nil }
        return rect
    }

    private static func frame(_ element: AXUIElement, budget: Budget) -> CGRect? {
        let (positionError, position) = budget.attribute(element, kAXPositionAttribute as CFString)
        let (sizeError, size) = budget.attribute(element, kAXSizeAttribute as CFString)
        guard positionError == .success, sizeError == .success,
              let position, CFGetTypeID(position) == AXValueGetTypeID(),
              let size, CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

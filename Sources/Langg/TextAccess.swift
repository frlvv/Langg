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
    private static var accessibilityClients: [pid_t: NSRunningApplication] = [:]

    private static func applicationElement(_ application: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.10)
        return element
    }

    private static func enableTextAccessibility(for application: NSRunningApplication, element: AXUIElement) {
        let pid = application.processIdentifier
        guard accessibilityClients[pid]?.isTerminated != false else { return }
        accessibilityClients = accessibilityClients.filter { !$0.value.isTerminated }
        // Electron documents this opt-in for third-party assistive technology.
        // Set it once per process, not on each word or accessibility read.
        accessibilityClients[pid] = application
        let result = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        InputDiagnostics.record(result == .success ? "textAccessibilityEnabled" : "textAccessibilityUnavailable")
    }

    static func focusedField() -> TextFieldIdentity? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { InputDiagnostics.record("captureProtected"); return nil }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = applicationElement(application)
        var raw: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw)
        if error != .success || raw == nil {
            InputDiagnostics.record("applicationFocusError.\(error.rawValue)")
            enableTextAccessibility(for: application, element: app)
            error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw)
        }
        if error != .success || raw == nil {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.05)
            error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw)
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
        return TextFieldIdentity(element: field, pid: pid)
    }

    static func capture() -> TextSnapshot? {
        guard let identity = focusedField() else { return nil }
        let field = identity.element
        var selectedSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field, kAXSelectedTextRangeAttribute as CFString, &selectedSettable) == .success,
              selectedSettable.boolValue,
              let text = string(field, kAXValueAttribute as CFString), text.utf16.count <= 100_000,
              let selection = range(field),
              let state = TextState(text: text, selection: selection) else { InputDiagnostics.record("captureUnavailableAttributes"); return nil }
        InputDiagnostics.record("captureSuccess")
        return TextSnapshot(field: identity, state: state)
    }

    static func isCurrent(_ snapshot: TextSnapshot) -> Bool {
        guard let current = capture() else { return false }
        return current.field == snapshot.field && current.state == snapshot.state
    }

    static func replace(_ snapshot: TextSnapshot, edit: TextReplacement,
                        selectedBounds: ((CGRect) -> Void)? = nil) async -> TextSnapshot? {
        guard snapshot.state == edit.before, isEditable(snapshot.element),
              let after = await TextReplacementTransaction.applyWithFallback(edit, to: snapshot.field,
                using: AXEditor(edit: edit, selectedBounds: selectedBounds)) else { return nil }
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
            if selectedBounds != nil,
               let bounds = textBounds(field.element, text: edit.before.text, range: edit.range)
                    ?? selectedMarkerBounds(field.element, characterCount: edit.original.count) {
                selectedBounds?(bounds)
            }
            return AXUIElementSetAttributeValue(field.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        }

        func insertText(_ text: String, in field: TextFieldIdentity, expected: TextState) async -> Bool {
            guard !Task.isCancelled, CGPreflightPostEventAccess(),
                  let source = CGEventSource(stateID: .privateState) else { return false }
            source.userData = replacementMarker
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
                  let selectedRange = Range(expected.selection, in: expected.text) else { return false }
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
        textBounds(snapshot.element, text: snapshot.text, range: range)
    }

    private static func textBounds(_ element: AXUIElement, text: String, range: NSRange) -> CGRect? {
        guard let leading = TextGeometry.leadingCharacter(in: text, range: range) else { return nil }
        var range = CFRange(location: leading.location, length: leading.length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,
            kAXBoundsForRangeParameterizedAttribute as CFString, param, &raw) == .success,
              let rect = rectValue(raw),
              TextGeometry.usable(rect, characterCount: 1, fieldFrame: frame(element)) else { return nil }
        return rect
    }

    private static func selectedMarkerBounds(_ element: AXUIElement, characterCount: Int) -> CGRect? {
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success,
              let marker else { return nil }
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
        return raw as? String
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

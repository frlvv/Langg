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
        enableTextAccessibility(for: application, element: app)
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

        func supportsDirectReplacement(in field: TextFieldIdentity) -> Bool {
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(field.element, kAXSelectedTextAttribute as CFString, &settable)
            return result == .attributeUnsupported ? false : result != .success || settable.boolValue
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

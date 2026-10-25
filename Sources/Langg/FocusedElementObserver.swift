import ApplicationServices
import CoreGraphics
import Foundation

/// One current focus event, invalidated by physical context changes. The element
/// is opaque here: deciding whether it is an editable field belongs to TextAccess.
struct FocusNotificationLease<Element> {
    struct Token {
        let element: Element
        let pid: pid_t
        let epoch: UInt64
        let revision: UInt64
    }

    private(set) var pid: pid_t?
    private var epoch: UInt64 = 0
    private var revision: UInt64 = 0
    private(set) var token: Token?

    mutating func activate(_ pid: pid_t?) {
        guard self.pid != pid else { return }
        self.pid = pid
        invalidate()
    }

    mutating func invalidate() {
        epoch &+= 1
        token = nil
    }

    @discardableResult mutating func invalidate(ifCurrent candidate: Token) -> Bool {
        guard isCurrent(candidate) else { return false }
        invalidate()
        return true
    }

    mutating func receive(_ element: Element?, from pid: pid_t) {
        guard self.pid == pid else { return }
        revision &+= 1
        token = element.map { Token(element: $0, pid: pid, epoch: epoch, revision: revision) }
    }

    func isCurrent(_ candidate: Token) -> Bool {
        guard let token else { return false }
        return candidate.pid == pid && candidate.epoch == epoch && candidate.revision == token.revision
    }

    func vouches(for candidate: Element, using token: Token, related: [Element],
                 equal: (Element, Element) -> Bool) -> Bool {
        isCurrent(token) && related.contains(where: { equal($0, candidate) })
    }
}

enum FocusContextTransition {
    static func invalidatesLease(keyCode: Int64, flags: CGEventFlags) -> Bool {
        if keyCode == 48 || keyCode == 53 { return true } // Tab changes editor; Escape dismisses UI.
        let commands = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if [51, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(keyCode) {
            // Cursor movement and deletion normally keep keyboard focus.
            return commands.contains([.maskCommand, .maskControl])
        }
        if commands.contains(.maskCommand) {
            // Standard editing, including redo and paste-and-match-style.
            if !commands.contains(.maskControl), [0, 6, 7, 8, 9].contains(keyCode) { return false }
            return true
        }
        return commands.contains(.maskControl)
    }
}

@MainActor final class FocusedElementObserver {
    typealias Token = FocusNotificationLease<AXUIElement>.Token
    private var lease = FocusNotificationLease<AXUIElement>()
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var watchedField: AXUIElement?
    private var watchedToken: Token?
    private var retryAfter: TimeInterval = 0
    var onChange: ((_ contextChanged: Bool) -> Void)?

    func observe(pid: pid_t) {
        if lease.pid == pid, observer != nil || ProcessInfo.processInfo.systemUptime < retryAfter { return }
        stop(notify: false)
        lease.activate(pid)
        var created: AXObserver?
        let result = AXObserverCreate(pid, { observer, element, notification, context in
            FocusedElementObserver.callback(observer, element, notification, context)
        }, &created)
        guard result == .success, let created else { unavailable(result); return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let registered = AXObserverAddNotification(created, app, kAXFocusedUIElementChangedNotification as CFString, refcon)
        guard registered == .success else { unavailable(registered); return }
        let windowResult = AXObserverAddNotification(created, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        if windowResult != .success { InputDiagnostics.record("focusObserverWindowUnavailable.\(windowResult.rawValue)") }
        observer = created
        application = app
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        InputDiagnostics.record("focusObserverConnected")
    }

    private func unavailable(_ error: AXError) {
        retryAfter = ProcessInfo.processInfo.systemUptime + 5
        InputDiagnostics.record("focusObserverUnavailable.\(error.rawValue)")
    }

    func stop(notify: Bool = true) {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        application = nil
        watchedField = nil
        watchedToken = nil
        lease.activate(nil)
        retryAfter = 0
        if notify { onChange?(true) }
    }

    func invalidate() {
        lease.invalidate()
        onChange?(true)
    }

    func stop(ifObserving pid: pid_t) {
        if lease.pid == pid { stop() }
    }

    func current(pid: pid_t) -> Token? { lease.pid == pid ? lease.token : nil }
    func isCurrent(_ token: Token) -> Bool { lease.isCurrent(token) }
    func vouches(_ token: Token, for candidate: AXUIElement, related: [AXUIElement]) -> Bool {
        lease.vouches(for: candidate, using: token, related: related, equal: { CFEqual($0, $1) })
    }

    func reject(_ token: Token) {
        guard lease.isCurrent(token) else { return }
        lease.receive(nil, from: token.pid)
        onChange?(false)
    }

    func watchDestruction(of field: AXUIElement) {
        guard let observer else { return }
        watchedToken = lease.token
        guard watchedField.map({ CFEqual($0, field) }) != true else { return }
        if let watchedField { _ = AXObserverRemoveNotification(observer, watchedField, kAXUIElementDestroyedNotification as CFString) }
        watchedField = field
        _ = AXObserverAddNotification(observer, field, kAXUIElementDestroyedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
    }

    private nonisolated static func callback(_ observer: AXObserver, _ element: AXUIElement,
                                             _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
        // This observer's source is installed only on the main run loop. Do not
        // query AX here: callbacks merely replace or invalidate opaque evidence.
        MainActor.assumeIsolated {
            guard let refcon else { return }
            let owner = Unmanaged<FocusedElementObserver>.fromOpaque(refcon).takeUnretainedValue()
            guard let current = owner.observer, CFEqual(current, observer), let pid = owner.lease.pid else { return }
            if CFEqual(notification, kAXFocusedUIElementChangedNotification as CFString) {
                let noFocus = owner.application.map { CFEqual($0, element) } == true
                owner.lease.receive(noFocus ? nil : element, from: pid)
                owner.onChange?(false)
                InputDiagnostics.record(noFocus ? "focusObserverNoFocus" : "focusObserverChanged")
            } else if CFEqual(notification, kAXUIElementDestroyedNotification as CFString) {
                // A destroyed reference must never be queried again.
                guard owner.watchedField.map({ CFEqual($0, element) }) == true else { return }
                owner.watchedField = nil
                let watched = owner.watchedToken
                owner.watchedToken = nil
                // Destruction of the previous editor can arrive after a newer
                // focus event. It must not erase that new field's evidence.
                guard let watched, owner.lease.invalidate(ifCurrent: watched) else {
                    InputDiagnostics.record("focusObserverOldDestructionIgnored"); return
                }
                owner.onChange?(true)
                InputDiagnostics.record("focusObserverFieldDestroyed")
            } else {
                owner.lease.invalidate()
                owner.onChange?(true)
                InputDiagnostics.record("focusObserverContextChanged")
            }
        }
    }
}

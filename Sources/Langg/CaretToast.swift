import AppKit
import QuartzCore

@MainActor final class CaretToast {
    private var panel: NSPanel?
    private var content: ToastContentView?
    private var dismissTask: Task<Void, Never>?
    private var dismissalID = UUID()

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        dismissalID = UUID()
        panel?.orderOut(nil)
        content?.resetTextAnimation()
    }

    func show(at bounds: CGRect) {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 0, bounds.height >= 0 else { return }
        // Accessibility uses the top-left of the primary screen as its origin.
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let caret = CGRect(x: bounds.minX, y: desktopTop - bounds.maxY,
                           width: bounds.width, height: bounds.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) || $0.frame.contains(caret.origin) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { hide(); return }
        let window = panel ?? makePanel()
        guard let frame = Self.frame(near: caret, in: visible, size: window.frame.size) else {
            hide()
            return
        }
        content?.setStatus(.corrected, fromEmpty: !window.isVisible)
        window.setAccessibilityLabel(ToastStatus.corrected.title)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        scheduleDismissal()
    }

    /// Undo replaces the visible correction without moving or creating a panel.
    func showUndoIfVisible() {
        guard let panel, panel.isVisible else { return }
        content?.setStatus(.undone)
        panel.setAccessibilityLabel(ToastStatus.undone.title)
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissTask?.cancel()
        let id = UUID()
        dismissalID = id
        // A new status owns the deadline; old animation/timer completions cannot hide it.
        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch { return }
            guard let self, !Task.isCancelled, self.dismissalID == id else { return }
            self.hide()
        }
    }

    /// AppKit screen coordinates. Never cover the corrected line or typing ahead.
    static func frame(near caret: CGRect, in visibleFrame: CGRect, size: CGSize) -> CGRect? {
        let safe = visibleFrame.insetBy(dx: 8, dy: 8)
        guard size.width > 0, size.height > 0,
              size.width <= safe.width, size.height <= safe.height else { return nil }
        let gap: CGFloat = 4
        // Align the label's leading edge with the edited word. The reserved
        // width for a longer undo message must not push correction far left.
        let x = min(max(caret.minX - 12, safe.minX), safe.maxX - size.width)
        let above = CGRect(x: x, y: caret.maxY + gap, width: size.width, height: size.height)
        if safe.contains(above) { return above }
        let below = CGRect(x: x, y: caret.minY - size.height - gap,
                           width: size.width, height: size.height)
        if safe.contains(below) { return below }
        // At a screen edge, omit feedback rather than put it across the text line.
        return nil
    }

    private func makePanel() -> NSPanel {
        let view = ToastContentView()
        let window = ToastPanel(contentRect: CGRect(origin: .zero, size: view.frame.size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        content = view
        panel = window
        return window
    }
}

private enum ToastStatus: CaseIterable {
    case corrected
    case undone

    var title: String {
        switch self {
        case .corrected: "Исправлено"
        case .undone: "Исправление отменено"
        }
    }

}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Keep the window's backdrop in AppKit: no opaque hosting surface above the blur.
private final class ToastContentView: NSView {
    private let backdrop: NSView
    private let text = RollingToastTextView()

    override var isOpaque: Bool { false }

    init() {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.tintColor = nil
            glass.cornerRadius = 0
            backdrop = glass
        } else {
            // Older materials add a visible tint; leave only the text instead.
            backdrop = NSView()
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        // Reserve both statuses up front, so undo never resizes or shifts feedback.
        let textWidth = ToastStatus.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        super.init(frame: CGRect(x: 0, y: 0, width: ceil(textWidth) + 24, height: 30))
        wantsLayer = true

        backdrop.wantsLayer = true
        addSubview(backdrop)

        text.frame = CGRect(x: 12, y: 6, width: ceil(textWidth) + 2, height: 18)
        addSubview(text)
        updateBackdrop()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    func setStatus(_ status: ToastStatus, fromEmpty: Bool = false) {
        if fromEmpty { text.reset() }
        let width = ceil((status.title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]).width)
        // Text starts at one fixed point: the shared prefix never shifts on undo.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = CGRect(x: 0, y: 0, width: width + 24, height: bounds.height)
        let mask = CALayer()
        mask.frame = backdrop.bounds
        mask.contents = Self.softMask(size: backdrop.bounds.size).cgImage(
            forProposedRect: nil, context: nil, hints: nil
        )
        backdrop.layer?.mask = mask
        CATransaction.commit()
        text.setText(status.title)
        updateBackdrop()
    }

    func resetTextAnimation() { text.reset() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackdrop()
    }

    @objc private func accessibilityOptionsChanged(_ notification: Notification) {
        updateBackdrop()
    }

    /// The alpha falls away continuously; the blur has no capsule or panel edge.
    private static func softMask(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext,
                  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor.white.cgColor,
                             NSColor.white.withAlphaComponent(0.85).cgColor,
                             NSColor.white.withAlphaComponent(0.25).cgColor,
                             NSColor.clear.cgColor] as CFArray,
                    locations: [0, 0.35, 0.7, 1]) else { return false }
            context.saveGState()
            // Leave a transparent outer pixel even after rasterisation of the mask.
            let featherBounds = rect.insetBy(dx: 1, dy: 1)
            context.translateBy(x: featherBounds.midX, y: featherBounds.midY)
            context.scaleBy(x: featherBounds.width / 2, y: featherBounds.height / 2)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                       endCenter: .zero, endRadius: 1, options: [])
            context.restoreGState()
            return true
        }
    }

    private func updateBackdrop() {
        let workspace = NSWorkspace.shared
        if #available(macOS 26.0, *) {
            backdrop.isHidden = workspace.accessibilityDisplayShouldReduceTransparency
        } else {
            backdrop.isHidden = true
        }
        layer?.backgroundColor = nil
        text.updateAppearance()
        if workspace.accessibilityDisplayShouldReduceMotion { text.finishAnimations() }
    }
}

/// Each changed character rolls independently; a shared prefix keeps its layers.
private final class RollingToastTextView: NSView {
    private struct Glyph {
        let character: Character
        let layer: CATextLayer
        let restingPosition: CGPoint
    }

    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private var glyphs: [Glyph] = []
    private var retiring: [CALayer] = []
    private var cleanupTask: Task<Void, Never>?
    private var text = ""
    private let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func reset() {
        cleanupTask?.cancel()
        cleanupTask = nil
        (glyphs.map(\.layer) + retiring).forEach { $0.removeFromSuperlayer() }
        glyphs = []
        retiring = []
        text = ""
    }

    func setText(_ newText: String) {
        guard newText != text else { return }
        cleanupTask?.cancel()
        retiring.forEach { $0.removeFromSuperlayer() }
        retiring = []
        let previous = glyphs
        let characters = Array(newText)
        let sharedCount = zip(previous.map(\.character), characters).prefix { $0 == $1 }.count
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: CFTimeInterval = reduceMotion ? 0.10 : 0.14
        // Keep the entire rolling transition within 175 ms, including the cascade.
        let changedCount = max(previous.count, characters.count) - sharedCount
        let stagger: CFTimeInterval = reduceMotion || changedCount <= 1 ? 0 : min(0.003, 0.035 / Double(changedCount - 1))
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphs = []
        var prefix = ""
        for (index, character) in characters.enumerated() {
            let x = (prefix as NSString).size(withAttributes: [.font: font]).width
            prefix.append(character)
            let end = (prefix as NSString).size(withAttributes: [.font: font]).width
            let position = CGPoint(x: x, y: 0)
            if index < sharedCount {
                let glyph = previous[index]
                retarget(glyph.layer, to: position, opacity: 1, duration: duration,
                         beginTime: now, initialOffset: 0)
                glyphs.append(Glyph(character: character, layer: glyph.layer, restingPosition: position))
            } else {
                let glyph = CATextLayer()
                glyph.anchorPoint = .zero
                glyph.bounds = CGRect(x: 0, y: 0, width: ceil(end - x) + 2, height: bounds.height)
                glyph.position = position
                glyph.font = font
                glyph.fontSize = font.pointSize
                glyph.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                glyph.string = String(character)
                layer?.addSublayer(glyph)
                let delay = Double(index - sharedCount) * stagger
                retarget(glyph, to: position, opacity: 1, duration: duration,
                         beginTime: now + delay, initialOffset: reduceMotion ? 0 : -bounds.height,
                         appearing: true)
                glyphs.append(Glyph(character: character, layer: glyph, restingPosition: position))
            }
        }
        for (index, glyph) in previous.enumerated() where index >= sharedCount {
            let target = CGPoint(x: glyph.restingPosition.x,
                                 y: glyph.restingPosition.y + (reduceMotion ? 0 : bounds.height))
            retarget(glyph.layer, to: target, opacity: 0, duration: duration,
                     beginTime: now + Double(index - sharedCount) * stagger, initialOffset: 0)
            retiring.append(glyph.layer)
        }
        CATransaction.commit()
        text = newText
        setAccessibilityLabel(newText)
        updateAppearance()
        let total = duration + Double(max(changedCount - 1, 0)) * stagger
        cleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(total)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.retiring.forEach { $0.removeFromSuperlayer() }
            self.retiring = []
            self.cleanupTask = nil
        }
    }

    private func retarget(_ glyph: CATextLayer, to target: CGPoint, opacity: Float,
                          duration: CFTimeInterval, beginTime: CFTimeInterval,
                          initialOffset: CGFloat, appearing: Bool = false) {
        let current = glyph.presentation()
        let position = appearing ? CGPoint(x: target.x, y: target.y + initialOffset) : current?.position ?? glyph.position
        let alpha: Float = appearing ? 0 : current?.opacity ?? glyph.opacity
        glyph.removeAllAnimations()
        glyph.position = target
        glyph.opacity = opacity
        let movement = CABasicAnimation(keyPath: "position")
        movement.fromValue = NSValue(point: position)
        movement.toValue = NSValue(point: target)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = alpha
        fade.toValue = opacity
        let group = CAAnimationGroup()
        group.animations = [movement, fade]
        group.beginTime = beginTime
        group.duration = duration
        group.timingFunction = curve
        group.fillMode = .backwards
        glyph.add(group, forKey: "rollingStatus")
    }

    func finishAnimations() {
        cleanupTask?.cancel()
        cleanupTask = nil
        retiring.forEach { $0.removeFromSuperlayer() }
        retiring = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for glyph in glyphs {
            glyph.layer.removeAllAnimations()
            glyph.layer.position = glyph.restingPosition
            glyph.layer.opacity = 1
        }
        CATransaction.commit()
    }

    func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let workspace = NSWorkspace.shared
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for glyph in glyphs.map(\.layer) + retiring.compactMap({ $0 as? CATextLayer }) {
                glyph.foregroundColor = NSColor.labelColor.cgColor
                glyph.shadowColor = (dark ? NSColor.black : NSColor.white).cgColor
                glyph.shadowOpacity = workspace.accessibilityDisplayShouldIncreaseContrast ? 0.95 : 0.75
                glyph.shadowOffset = .zero
                glyph.shadowRadius = workspace.accessibilityDisplayShouldReduceTransparency ? 3 : 1
            }
            CATransaction.commit()
        }
    }
}

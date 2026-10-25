import AppKit
import LanggCore

/// One owner for completed words, editor identity, correction history and Undo.
/// Every operation runs in the same task; cancellation must finish AX cleanup
/// before its successor is allowed to acquire the replay gate.
@MainActor final class CorrectionEngine {
    private struct UndoRecord {
        let edit: TextReplacement
        let after: TextSnapshot
        let previousSourceID: String?
    }
    private struct RequestBinding {
        let pid: pid_t
        let source: String
        let field: TextFieldIdentity?
    }
    private enum Command {
        case manual(pid_t, String?)
        case undo(UndoRecord)
    }
    private let settings: AppSettings
    private let replay: InputReplayGate
    private let backend: any CorrectionBackend
    private let onFeedback: (String?) -> Void
    private let onCorrection: (CGRect) -> Void
    private let onUndo: () -> Void
    private let onMissingGeometry: () -> Void
    private var serialTask: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var command: Command?
    private var queue = CorrectionQueue()
    private var bindings: [UInt64: RequestBinding] = [:]
    private var typingField: TextFieldIdentity?
    private var typingSource: String?
    private var typingPID: pid_t?
    private var undo: UndoRecord?
    private var history = CorrectionHistory()
    private var historyField: TextFieldIdentity?

    init(settings: AppSettings, replay: InputReplayGate,
         backend: any CorrectionBackend,
         onFeedback: @escaping (String?) -> Void,
         onCorrection: @escaping (CGRect) -> Void,
         onUndo: @escaping () -> Void,
         onMissingGeometry: @escaping () -> Void) {
        self.settings = settings
        self.replay = replay
        self.backend = backend
        self.onFeedback = onFeedback
        self.onCorrection = onCorrection
        self.onUndo = onUndo
        self.onMissingGeometry = onMissingGeometry
    }

    convenience init(settings: AppSettings, replay: InputReplayGate,
                     onFeedback: @escaping (String?) -> Void,
                     onCorrection: @escaping (CGRect) -> Void,
                     onUndo: @escaping () -> Void,
                     onMissingGeometry: @escaping () -> Void) {
        self.init(settings: settings, replay: replay, backend: NativeCorrectionBackend(),
                  onFeedback: onFeedback, onCorrection: onCorrection,
                  onUndo: onUndo, onMissingGeometry: onMissingGeometry)
    }

    /// Also useful to await deterministic completion with an injected backend.
    var isIdle: Bool { serialTask == nil && command == nil && queue.requests.isEmpty }

    func invalidate() {
        epoch &+= 1
        serialTask?.cancel()
        command = nil
        queue.reset()
        bindings.removeAll()
        typingField = nil
        typingSource = nil
        typingPID = nil
        undo = nil
        // Intact corrected and explicitly restored words remain authoritative
        // across pointer events, layout changes and operation cancellation.
    }

    func cancelForOverflow() { invalidate() }

    func accept(text: String, sourceID: String, pid: pid_t) {
        guard settings.automatic, automaticAllowed(pid: pid), !text.isEmpty else { invalidate(); return }
        if typingSource != nil && (typingSource != sourceID || typingPID != pid) { invalidate() }
        typingSource = sourceID
        typingPID = pid
        undo = nil
        let completes = text.count == 1 && text.first.map(LayoutConverter.isUnambiguousWordBoundary) == true
        queue.append(text, completesWord: completes)
        let ids = Set(queue.requests.map(\.id))
        bindings = bindings.filter { ids.contains($0.key) }
        if completes, let request = queue.requests.last {
            bindings[request.id] = RequestBinding(pid: pid, source: sourceID, field: typingField)
        }
        start()
    }

    func correctManually() {
        guard let pid = backend.frontmostPID, allowed(pid: pid) else { return }
        let source = backend.currentSourceID
        invalidate()
        command = .manual(pid, source)
        start()
    }

    /// Return synchronously so the event tap consumes Cmd+Z only for our exact
    /// last edit. Native Undo remains the editor's action in every other case.
    func undoIfCurrent() -> Bool {
        guard let record = undo, allowed(pid: record.after.pid),
              let current = capture(), current.field == record.after.field,
              current.state == record.after.state else { return false }
        invalidate()
        command = .undo(record)
        start()
        return true
    }

    func noteNativeUndo() {
        let before = capture()
        invalidate()
        if let before {
            reconcileHistory(with: before)
            history.expectNativeUndo(in: before.state)
        }
    }

    private func start() {
        guard serialTask == nil, command != nil || !queue.requests.isEmpty else { return }
        let revision = epoch
        let next = command
        command = nil
        serialTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.serialTask = nil
                self.start()
            }
            if let next {
                switch next {
                case .manual(let pid, let source): await self.correctManual(pid: pid, source: source, revision: revision)
                case .undo(let record): await self.restore(record, revision: revision)
                }
                return
            }
            while self.valid(revision), let request = self.queue.requests.first {
                if let binding = self.bindings[request.id] {
                    await self.process(request.id, binding: binding, revision: revision)
                }
                guard self.epoch == revision else { return }
                // A dictionary decision to keep a word is still a completed
                // request, so it can never block the next word in the queue.
                self.queue.remove(request.id)
                self.bindings.removeValue(forKey: request.id)
            }
        }
    }

    private func valid(_ revision: UInt64) -> Bool { epoch == revision && !Task.isCancelled }
    private func allowed(pid: pid_t) -> Bool {
        backend.frontmostPID == pid && !backend.secureInputEnabled &&
            pid != ProcessInfo.processInfo.processIdentifier
    }
    private func automaticAllowed(pid: pid_t) -> Bool {
        allowed(pid: pid) && !settings.excludedApps.contains(backend.bundleIdentifier ?? "")
    }
    private func current(_ binding: RequestBinding, revision: UInt64) -> Bool {
        valid(revision) && settings.automatic && automaticAllowed(pid: binding.pid) && backend.currentSourceID == binding.source
    }
    private func capture() -> TextSnapshot? { backend.capture(recoveringFocus: false, excluding: nil) }
    private func pause(milliseconds: Int) async -> Bool {
        do { try await Task.sleep(for: .milliseconds(milliseconds)); return true }
        catch { return false }
    }

    private func process(_ id: UInt64, binding: RequestBinding, revision: UInt64) async {
        InputDiagnostics.record("completedWord")
        guard await pause(milliseconds: 8), current(binding, revision: revision) else { return }
        var initial: TextSnapshot?
        var boundary: Int?
        var attempts = 0
        var recovered = false
        while attempts < 5 || (attempts < 64 && backend.isWarmingUp(pid: binding.pid)) {
            attempts += 1
            guard current(binding, revision: revision) else { return }
            var snapshot = capture()
            // A recovery read is permitted only after ordinary reads have
            // failed three times in the same frontmost process.
            if attempts >= 3, !recovered,
               snapshot == nil || snapshot.map({ queue.boundaryCaret(for: id, in: $0.state) == nil }) == true {
                recovered = true
                let rejected = snapshot?.field
                if let found = backend.capture(recoveringFocus: true, excluding: rejected), found.pid == binding.pid,
                   binding.field == nil || found.field == binding.field {
                    snapshot = found
                }
            }
            if let snapshot {
                guard snapshot.pid == binding.pid,
                      binding.field == nil || snapshot.field == binding.field else { invalidate(); return }
                if let caret = queue.boundaryCaret(for: id, in: snapshot.state) {
                    initial = snapshot
                    boundary = caret
                    break
                }
                if let reason = queue.boundaryFailure(for: id, in: snapshot.state) {
                    InputDiagnostics.record("queueBoundary.\(reason.rawValue)")
                }
            }
            guard await pause(milliseconds: 8) else { return }
        }
        guard current(binding, revision: revision), let initial, let boundary,
              let authenticated = queue.request(id),
              queue.confirmBoundary(for: id, in: initial.state), let request = queue.request(id) else {
            InputDiagnostics.record("requestNotBound")
            return
        }
        typingField = initial.field
        // Requests already queued before the first AX read acquire the same
        // authenticated field, rather than independently accepting another one.
        for (key, value) in bindings where value.field == nil && value.pid == binding.pid && value.source == binding.source {
            bindings[key] = RequestBinding(pid: value.pid, source: value.source, field: initial.field)
        }
        reconcileHistory(with: initial)
        // Only physical text authenticated by this request can expire an old
        // choice. A text snapshot alone cannot distinguish an editor Undo from
        // selecting all and freshly typing the original in the same field.
        let leadingLength = authenticated.leadingText.utf16.count
        let delimiterLength = authenticated.delimiter.utf16.count
        if leadingLength > 0, boundary >= delimiterLength + leadingLength {
            history.forget(overlapping: NSRange(location: boundary - delimiterLength - leadingLength,
                                               length: leadingLength))
        }
        var reference = initial
        var following = request.followingText
        let latestWordStart = LayoutConverter.wordCandidates(in: initial.text, caretUTF16: boundary, completed: true).first?.location
        let candidates = AutomaticCorrection.contextualCandidates(in: initial.text, caretUTF16: boundary, excludedWords: settings.excludedWords)
        var correctedRanges: [NSRange] = []
        for candidate in candidates {
            guard AutomaticCorrection.isEligibleTarget(candidate), !history.contains(candidate.range),
                  !correctedRanges.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 }) else { continue }
            let approved = await backend.shouldCorrect(candidate, in: reference.text)
            guard current(binding, revision: revision) else { return }
            guard approved, !settings.excludedWords.contains(where: {
                $0.caseInsensitiveCompare(candidate.original) == .orderedSame ||
                $0.caseInsensitiveCompare(candidate.replacement) == .orderedSame
            }) else { continue }
            guard let request = queue.request(id), request.followingText.hasPrefix(following),
                  let expected = reference.state.appendingAtCaret(String(request.followingText.dropFirst(following.count))),
                  let latest = capture() else { return }
            guard latest.field == initial.field else { invalidate(); return }
            guard latest.state.matchesEditorState(expected), queue.boundaryCaret(for: id, in: latest.state) != nil,
                  LayoutConverter.substring(latest.text, range: candidate.range) == candidate.original else { return }
            guard let result = await apply(latest, range: candidate.range, replacement: candidate.replacement,
                    direction: candidate.direction, source: binding.source, revision: revision,
                    request: (id, request.followingText),
                    switchSource: candidate.range.location == latestWordStart, automatic: true) else { return }
            reference = result.snapshot
            following = result.followingText ?? request.followingText
            correctedRanges.append(candidate.range)
            // A successful switch ends this source's batch. The next physical
            // input supplies the observed source and starts a fresh binding.
            if backend.currentSourceID != binding.source { return }
        }
    }

    private struct Applied {
        let snapshot: TextSnapshot
        let followingText: String?
    }

    private func begin(revision: UInt64, pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            guard valid(revision), allowed(pid: pid) else { return false }
            if replay.begin() { return true }
            guard await pause(milliseconds: 1) else { return false }
        }
        return false
    }

    /// Two matching full-state reads include all keys already forwarded by the
    /// tap. Merely seeing the delimiter once cannot authorize a selection write.
    private func settled(_ expected: TextSnapshot, revision: UInt64, source: String?) async -> TextSnapshot? {
        await TextAccess.settledSnapshot(matching: expected, isValid: {
            self.valid(revision) && self.allowed(pid: expected.pid) && self.backend.currentSourceID == source
        }, capture: { self.capture() })
    }

    private func apply(_ snapshot: TextSnapshot, range: NSRange, replacement: String,
                       direction: LayoutDirection, source: String?, revision: UInt64,
                       request pending: (id: UInt64, following: String)? = nil,
                       switchSource: Bool, automatic: Bool) async -> Applied? {
        guard await begin(revision: revision, pid: snapshot.pid) else { return nil }
        defer { replay.end() }
        guard valid(revision), allowed(pid: snapshot.pid), backend.currentSourceID == source,
              !automatic || (settings.automatic && automaticAllowed(pid: snapshot.pid)) else { return nil }
        var expected = snapshot.state
        var heldFollowing: String?
        if let pending {
            guard let request = queue.request(pending.id), request.followingText.hasPrefix(pending.following),
                  let appended = expected.appendingAtCaret(String(request.followingText.dropFirst(pending.following.count))) else { return nil }
            expected = appended
            heldFollowing = request.followingText
        }
        guard let ready = await settled(TextSnapshot(field: snapshot.field, state: expected), revision: revision, source: source),
              valid(revision), allowed(pid: snapshot.pid), backend.currentSourceID == source,
              !automatic || (settings.automatic && automaticAllowed(pid: snapshot.pid)),
              let edit = TextReplacement(before: ready.state, range: range, replacement: replacement) else { return nil }
        InputDiagnostics.record("replacementAttempt")
        guard let written = await backend.replace(ready, edit: edit, captureBounds: settings.notifications) else {
            InputDiagnostics.record("replacementWriteFailed")
            if valid(revision) { onFeedback("Поле не подтвердило замену. Проверьте текст перед повторным исправлением.") }
            return nil
        }
        guard valid(revision), allowed(pid: snapshot.pid), backend.currentSourceID == source,
              !automatic || (settings.automatic && automaticAllowed(pid: snapshot.pid)),
              written.snapshot.field == ready.field, written.snapshot.state.matchesEditorState(edit.after),
              let verified = capture(), verified.field == ready.field,
              verified.state.matchesEditorState(written.snapshot.state) else { return nil }
        reconcileHistory(with: ready)
        history.remember(edit)
        undo = UndoRecord(edit: edit, after: written.snapshot, previousSourceID: source)
        InputDiagnostics.record("replacementSucceeded")
        if switchSource, backend.currentSourceID == source {
            let eligible: Bool
            if let pending, let request = queue.request(pending.id) {
                eligible = queue.requests.last?.id == pending.id && request.followingText == heldFollowing &&
                    request.followingText.allSatisfy(LayoutConverter.isUnambiguousWordBoundary)
            } else { eligible = !automatic }
            if eligible, valid(revision), allowed(pid: snapshot.pid), !automatic || (settings.automatic && automaticAllowed(pid: snapshot.pid)) {
                let selected = replay.changeInputSource(
                    transform: { Self.isSourceNeutral($0) ? $0 : self.backend.retranslate($0, language: direction.targetLanguage) },
                    select: { self.backend.selectLanguage(direction.targetLanguage) })
                // Selection acceptance is useful evidence, never a claim that
                // asynchronous source and effective-layout readback has settled.
                InputDiagnostics.record(selected ? "layoutSwitchRequested" : "layoutSwitchSkipped")
            }
        }
        onFeedback("Текст исправлен.")
        if settings.notifications {
            let writtenRange = NSRange(location: range.location, length: replacement.utf16.count)
            if let bounds = backend.bounds(written.snapshot, range: writtenRange) ?? written.preEditBounds { onCorrection(bounds) }
            else { InputDiagnostics.record("notificationMissingGeometry"); onMissingGeometry() }
        }
        return Applied(snapshot: written.snapshot, followingText: heldFollowing)
    }

    private func correctManual(pid: pid_t, source: String?, revision: UInt64) async {
        guard valid(revision), allowed(pid: pid), backend.currentSourceID == source else { return }
        guard let snapshot = capture(), snapshot.pid == pid else {
            onFeedback("Не удалось получить доступ к тексту в этом поле.")
            return
        }
        let ranges = snapshot.state.selection.length > 0 ? [snapshot.state.selection]
            : LayoutConverter.manualWordCandidates(in: snapshot.text, caretUTF16: snapshot.state.selection.location)
        guard let fallback = ranges.last else { onFeedback("Нет слова или выделения для исправления."); return }
        var chosenRange = fallback
        var chosenReplacement: String?
        var chosenDirection: LayoutDirection?
        for range in ranges {
            guard let word = LayoutConverter.substring(snapshot.text, range: range),
                  let direction = LayoutConverter.detectedDirection(word),
                  let literal = LayoutConverter.convert(word, direction: direction, punctuation: .physicalKeys),
                  LayoutConverter.isAlphabeticWord(literal, direction: direction == .englishToRussian ? .russianToEnglish : .englishToRussian) else { continue }
            let known = await backend.isKnown(literal, language: direction.targetLanguage)
            guard valid(revision), allowed(pid: pid), backend.currentSourceID == source else { return }
            if known == true {
                chosenRange = range
                chosenReplacement = literal
                chosenDirection = direction
                break
            }
        }
        guard let original = LayoutConverter.substring(snapshot.text, range: chosenRange),
              let direction = chosenDirection ?? LayoutConverter.detectedDirection(original) else {
            onFeedback("Выделите фрагмент в одной раскладке: русской или английской.")
            return
        }
        let replacement: String?
        if let chosenReplacement { replacement = chosenReplacement }
        else { replacement = await convertedManualText(original, direction: direction, pid: pid, source: source, revision: revision) }
        guard valid(revision), allowed(pid: pid), backend.currentSourceID == source,
              let replacement, replacement != original else { return }
        _ = await apply(snapshot, range: chosenRange, replacement: replacement, direction: direction,
                        source: source, revision: revision, switchSource: true, automatic: false)
    }

    private func convertedManualText(_ text: String, direction: LayoutDirection,
                                     pid: pid_t, source: String?, revision: UInt64) async -> String? {
        var output = ""
        var token = ""
        func convertToken(_ token: String) async -> String {
            var result = LayoutConverter.convert(token, direction: direction) ?? token
            for range in LayoutConverter.wordCandidates(in: token + " ", caretUTF16: token.utf16.count + 1, completed: true) {
                guard valid(revision), allowed(pid: pid), backend.currentSourceID == source,
                      let word = LayoutConverter.substring(token, range: range),
                      let literal = LayoutConverter.convert(word, direction: direction, punctuation: .physicalKeys),
                      literal != LayoutConverter.substring(result, range: range),
                      LayoutConverter.isAlphabeticWord(literal, direction: direction == .englishToRussian ? .russianToEnglish : .englishToRussian),
                      await backend.isKnown(literal, language: direction.targetLanguage) == true,
                      valid(revision), allowed(pid: pid), backend.currentSourceID == source,
                      let resultRange = Range(range, in: result) else { continue }
                result.replaceSubrange(resultRange, with: literal)
                break
            }
            return result
        }
        for character in text {
            guard valid(revision), allowed(pid: pid), backend.currentSourceID == source else { return nil }
            if character.isWhitespace {
                output += await convertToken(token)
                token = ""
                output.append(character)
            } else { token.append(character) }
        }
        output += await convertToken(token)
        return output == text ? nil : output
    }

    /// Modifier transitions carry no text. Each later press carries its own
    /// authoritative flags, so forwarding a transition cannot authorize a
    /// Command/Control/Option press for translation.
    private static func isSourceNeutral(_ event: CGEvent) -> Bool {
        event.type == .keyUp || event.type == .flagsChanged
    }

    private func restore(_ record: UndoRecord, revision: UInt64) async {
        let source = backend.currentSourceID
        guard await begin(revision: revision, pid: record.after.pid) else { return }
        defer { replay.end() }
        guard let ready = await settled(record.after, revision: revision, source: source),
              let edit = TextReplacement(before: ready.state,
                range: NSRange(location: record.edit.range.location, length: record.edit.replacement.utf16.count),
                replacement: record.edit.original, restoringSelection: record.edit.before.selection),
              let restored = await backend.replace(ready, edit: edit, captureBounds: false),
              valid(revision), allowed(pid: ready.pid), backend.currentSourceID == source, restored.snapshot.field == ready.field,
              restored.snapshot.state.matchesEditorState(edit.after),
              let verified = capture(), verified.field == ready.field,
              verified.state.matchesEditorState(restored.snapshot.state) else { return }
        reconcileHistory(with: restored.snapshot)
        history.rememberUnchanged(NSRange(location: record.edit.range.location, length: record.edit.original.utf16.count), in: restored.snapshot.text)
        if settings.undoRestoresLayout, let id = record.previousSourceID, backend.currentSourceID == source {
            _ = replay.changeInputSource(transform: { event in
                Self.isSourceNeutral(event) ? event : backend.retranslate(event, sourceIdentifier: id)
            }, select: { backend.selectIdentifier(id) })
        }
        onFeedback("Исправление отменено.")
        if settings.notifications { onUndo() }
    }

    private func reconcileHistory(with snapshot: TextSnapshot) {
        if historyField != snapshot.field {
            history = CorrectionHistory()
            historyField = snapshot.field
        }
        history.reconcile(with: snapshot.text)
    }
}

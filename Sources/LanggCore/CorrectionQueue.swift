import Foundation

// Bounded, transient anchors for completed words. New typing extends the anchor
// instead of cancelling a correction. Navigation invalidates all anchors.
public struct CorrectionQueue {
    public enum BoundaryFailure: String {
        case missingRequest, activeSelection, caretBeforeSuffix, suffixMismatch, layoutDisagrees
    }
    public struct Request: Equatable, Sendable {
        public let id: UInt64
        public let delimiter: String
        public fileprivate(set) var leadingText: String
        public fileprivate(set) var followingText = ""
        public var suffix: String { leadingText + delimiter + followingText }

        fileprivate mutating func confirm() {
            leadingText = ""
        }
    }

    public private(set) var requests: [Request] = []
    private var nextID: UInt64 = 0
    private var typedTail = ""

    public init() {}

    public mutating func append(_ text: String, completesWord: Bool) {
        guard !text.isEmpty, text.utf16.count <= 8 else { reset(); return }
        for index in requests.indices { requests[index].followingText += text }
        requests.removeAll { $0.suffix.utf16.count > 4096 }
        if completesWord {
            nextID &+= 1
            requests.append(Request(id: nextID, delimiter: text, leadingText: typedTail))
            typedTail = ""
            if requests.count > 64 { requests.removeFirst() }
        } else {
            typedTail += text
            while typedTail.utf16.count > 64 { typedTail.removeFirst() }
        }
    }

    public mutating func remove(_ id: UInt64) { requests.removeAll { $0.id == id } }
    public mutating func reset() { requests.removeAll(); typedTail = "" }
    public func request(_ id: UInt64) -> Request? { requests.first { $0.id == id } }

    /// Authenticate the typed word when binding a request to its first field.
    /// The owner must then retain that field and verify the full editor state
    /// around every edit; corrections can legitimately change this word.
    @discardableResult public mutating func confirmBoundary(for id: UInt64, in state: TextState) -> Bool {
        guard boundaryCaret(for: id, in: state) != nil,
              let index = requests.firstIndex(where: { $0.id == id }) else { return false }
        requests[index].confirm()
        return true
    }

    public func boundaryCaret(for id: UInt64, in state: TextState) -> Int? {
        guard state.selection.length == 0, let request = request(id),
              state.selection.location >= request.suffix.utf16.count,
              let actualSuffix = LayoutConverter.substring(state.text, range: NSRange(
                location: state.selection.location - request.suffix.utf16.count, length: request.suffix.utf16.count)),
              TextState.editorTextMatches(actualSuffix, request.suffix) else { return nil }
        return state.selection.location - request.followingText.utf16.count
    }

    public func boundaryFailure(for id: UInt64, in state: TextState) -> BoundaryFailure? {
        guard let request = request(id) else { return .missingRequest }
        guard state.selection.length == 0 else { return .activeSelection }
        guard state.selection.location >= request.suffix.utf16.count else { return .caretBeforeSuffix }
        guard let suffix = LayoutConverter.substring(state.text, range: NSRange(
            location: state.selection.location - request.suffix.utf16.count, length: request.suffix.utf16.count)) else { return .suffixMismatch }
        if TextState.editorTextMatches(suffix, request.suffix) { return nil }
        let actualKeys = LayoutConverter.convert(suffix, direction: .russianToEnglish, punctuation: .physicalKeys) ?? suffix
        let expectedKeys = LayoutConverter.convert(request.suffix, direction: .russianToEnglish, punctuation: .physicalKeys) ?? request.suffix
        return TextState.editorTextMatches(actualKeys, expectedKeys) ? .layoutDisagrees : .suffixMismatch
    }
}

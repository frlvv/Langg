import Foundation

// Bounded, transient anchors for completed words. New typing extends the anchor
// instead of cancelling a correction. Navigation invalidates all anchors.
public struct CorrectionQueue {
    public struct Request: Equatable, Sendable {
        public let id: UInt64
        public let delimiter: String
        public fileprivate(set) var followingText = ""
        public var suffix: String { delimiter + followingText }
    }

    public private(set) var requests: [Request] = []
    private var nextID: UInt64 = 0

    public init() {}

    public mutating func append(_ text: String, completesWord: Bool) {
        guard !text.isEmpty, text.utf16.count <= 8 else { reset(); return }
        for index in requests.indices { requests[index].followingText += text }
        requests.removeAll { $0.suffix.utf16.count > 4096 }
        if completesWord {
            nextID &+= 1
            requests.append(Request(id: nextID, delimiter: text))
            if requests.count > 64 { requests.removeFirst() }
        }
    }

    public mutating func remove(_ id: UInt64) { requests.removeAll { $0.id == id } }
    public mutating func reset() { requests.removeAll() }
    public func request(_ id: UInt64) -> Request? { requests.first { $0.id == id } }

    public func boundaryCaret(for id: UInt64, in state: TextState) -> Int? {
        guard state.selection.length == 0, let request = request(id),
              state.selection.location >= request.suffix.utf16.count,
              let prefix = LayoutConverter.substring(state.text, range: NSRange(location: 0, length: state.selection.location)),
              prefix.hasSuffix(request.suffix) else { return nil }
        return state.selection.location - request.followingText.utf16.count
    }
}

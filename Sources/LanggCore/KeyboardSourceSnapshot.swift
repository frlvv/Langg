/// A readback of both the selected input source and the layout macOS is using.
public struct InputSourceSelectionSnapshot: Equatable, Sendable {
    public let sourceID: String?
    public let layoutID: String?

    public init(sourceID: String?, layoutID: String?) {
        self.sourceID = sourceID
        self.layoutID = layoutID
    }

    public func matches(_ identifier: String) -> Bool {
        sourceID == identifier && layoutID == identifier
    }
}

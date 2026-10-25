import Foundation

/// Searches focus metadata only. A text field's value never establishes focus.
enum FocusedFieldSearch {
    struct Node<NodeID> {
        let isFocusedText: Bool
        let children: [NodeID]
    }

    enum Result<NodeID> {
        case found(NodeID)
        case noMatch
        case ambiguous
        case incomplete
    }

    struct Ancestor<NodeID> {
        let isFocusedText: Bool
        let isExpectedWindow: Bool
        let parent: NodeID?
        let declaredWindow: NodeID?

        init(isFocusedText: Bool, isExpectedWindow: Bool, parent: NodeID?, declaredWindow: NodeID? = nil) {
            self.isFocusedText = isFocusedText
            self.isExpectedWindow = isExpectedWindow
            self.parent = parent
            self.declaredWindow = declaredWindow
        }
    }

    /// A physical hit has one ancestry path. Finish that path at the expected
    /// window before accepting its unique focused editor; sibling count is irrelevant.
    static func findAncestor<NodeID>(from hit: NodeID, owningWindow: NodeID? = nil, maximumNodes: Int = 16,
                                     equal: (NodeID, NodeID) -> Bool,
                                     read: (NodeID) -> Ancestor<NodeID>?) -> Result<NodeID> {
        var current = hit
        var visited: [NodeID] = []
        var candidate: NodeID?
        while visited.count < maximumNodes {
            guard !visited.contains(where: { equal($0, current) }), let node = read(current) else { return .incomplete }
            visited.append(current)
            if node.isFocusedText {
                if let owningWindow {
                    guard let declared = node.declaredWindow, equal(declared, owningWindow) else { return .incomplete }
                }
                guard candidate == nil else { return .ambiguous }
                candidate = current
            }
            if node.isExpectedWindow {
                guard owningWindow.map({ equal($0, current) }) != false else { return .incomplete }
                return candidate.map { .found($0) } ?? .noMatch
            }
            guard let parent = node.parent else { return .incomplete }
            current = parent
        }
        return .incomplete
    }

    static func find<NodeID>(in root: NodeID, maximumNodes: Int = 64, maximumDepth: Int = 12,
                             equal: (NodeID, NodeID) -> Bool,
                             read: (NodeID) -> Node<NodeID>?) -> Result<NodeID> {
        var pending = [(root, 0)]
        var visited: [NodeID] = []
        var candidate: NodeID?
        while let (element, depth) = pending.popLast() {
            if visited.contains(where: { equal($0, element) }) { continue }
            guard visited.count < maximumNodes, depth <= maximumDepth,
                  let node = read(element) else { return .incomplete }
            visited.append(element)
            if node.isFocusedText {
                guard candidate == nil else { return .ambiguous }
                candidate = element
            }
            guard node.children.isEmpty || depth < maximumDepth,
                  node.children.count + pending.count + visited.count <= maximumNodes else { return .incomplete }
            pending.append(contentsOf: node.children.map { ($0, depth + 1) })
        }
        return candidate.map { .found($0) } ?? .noMatch
    }
}

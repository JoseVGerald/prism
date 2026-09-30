import Foundation

/// Picking several items from a list the way a Mac does: shift-click one and
/// then another for everything between them, ⌘-click to add or take away one,
/// a plain click to let the picks go. Picks belong to one list at a time;
/// picking in another starts over.
public struct Picks: Equatable, Sendable {
    public private(set) var scope: String?
    /// Picked ids, in the list's order.
    public private(set) var ids: [String] = []
    private var anchor: Int?

    public init() {}

    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ id: String, in scope: String) -> Bool {
        self.scope == scope && ids.contains(id)
    }

    /// A click on item `index` of `list`. True when it picked — shift or ⌘
    /// held — so the caller should not also act on the item.
    public mutating func click(_ index: Int, in list: [String], scope: String,
                               shift: Bool, command: Bool) -> Bool {
        guard list.indices.contains(index), shift || command else {
            clear()
            return false
        }
        if self.scope != scope {
            ids = []
            anchor = nil
            self.scope = scope
        }
        if shift, let a = anchor, list.indices.contains(a) {
            ids = Array(list[min(a, index)...max(a, index)])
        } else if shift {
            anchor = index
            ids = [list[index]]
        } else {
            if let at = ids.firstIndex(of: list[index]) {
                ids.remove(at: at)
            } else {
                ids.append(list[index])
                let order = Dictionary(list.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                ids.sort { (order[$0] ?? 0) < (order[$1] ?? 0) }
            }
            anchor = index
        }
        if ids.isEmpty { clear() }
        return true
    }

    public mutating func clear() {
        scope = nil
        ids = []
        anchor = nil
    }
}

import Foundation

/// The grid's whole state: every terminal pane Rex knows about.
///
/// A board starts from a snapshot and is then patched one event at a time.
/// It holds no connection and does no I/O, so it can be tested with plain
/// values.
public struct Board: Sendable, Equatable {
    public private(set) var panes: [Pane]

    public init(panes: [Pane] = []) {
        self.panes = panes
    }

    /// Applies one event. Returns false when the event names a pane the board
    /// doesn't hold, which means the board is out of date.
    @discardableResult
    public mutating func apply(_ event: RexEvent) -> Bool {
        guard let blockID = event.blockID else { return true }
        guard let index = panes.firstIndex(where: { $0.blockID == blockID }) else { return false }
        switch event {
        case .status(_, let record):
            panes[index].records[record.id] = record
        case .statusRemoved(_, let ids):
            for id in ids { panes[index].records[id] = nil }
        case .title(_, let title):
            panes[index].title = title
        case .process(_, let name, let cwd):
            panes[index].process = name
            if let cwd { panes[index].cwd = cwd }
        case .directory(_, let path):
            panes[index].cwd = path
        case .layoutChanged:
            break
        }
        return true
    }

    /// Rebuilds the board around a fresh layout: the panes Rex lists now, in
    /// Rex's order. A pane already on the board keeps everything it has
    /// reported and takes only its new position and labels. Panes the board
    /// hasn't seen come back as `missing`, still to be described.
    ///
    /// Layout changes are frequent (every tab switch is one), and describing
    /// a pane costs three `rex` calls, so only new panes pay it.
    public func adopting(layout: [Pane]) -> (board: Board, missing: [Pane]) {
        let known = Dictionary(panes.map { ($0.blockID, $0) }, uniquingKeysWith: { first, _ in first })
        var missing: [Pane] = []
        let merged = layout.map { skeleton -> Pane in
            guard var pane = known[skeleton.blockID] else {
                missing.append(skeleton)
                return skeleton
            }
            pane.sessionID = skeleton.sessionID
            pane.sessionLabel = skeleton.sessionLabel
            pane.windowID = skeleton.windowID
            pane.windowLabel = skeleton.windowLabel
            pane.sharesWindow = skeleton.sharesWindow
            return pane
        }
        return (Board(panes: merged), missing)
    }

    /// Replaces panes with freshly described versions of themselves.
    public mutating func fill(_ described: [Pane]) {
        for pane in described {
            if let index = panes.firstIndex(where: { $0.blockID == pane.blockID }) { panes[index] = pane }
        }
    }

    public func contains(blockID: String) -> Bool {
        panes.contains { $0.blockID == blockID }
    }

    /// Panes that get a cell: everything except idle shells, most urgent first.
    public var cells: [Pane] {
        panes
            .filter { $0.state != .shell }
            .sorted { ($0.state.rank, $0.name.lowercased(), $0.blockID) < ($1.state.rank, $1.name.lowercased(), $1.blockID) }
    }

    /// Idle shells, collapsed to one entry per directory.
    public var shells: [ShellGroup] {
        var counts: [String: Int] = [:]
        for pane in panes where pane.state == .shell {
            counts[pane.directory.isEmpty ? pane.name : pane.directory, default: 0] += 1
        }
        return counts.map { ShellGroup(directory: $0.key, count: $0.value) }.sorted { $0.directory < $1.directory }
    }

    /// How many panes are in each state, most urgent first, empty states left out.
    public var counts: [StateCount] {
        var tally: [PaneState: Int] = [:]
        for pane in panes { tally[pane.state, default: 0] += 1 }
        return PaneState.allCases.compactMap { state in
            tally[state].map { StateCount(state: state, count: $0) }
        }
    }
}

public struct ShellGroup: Sendable, Equatable, Identifiable {
    public var directory: String
    public var count: Int
    public var id: String { directory }

    public var label: String { count > 1 ? "\(directory) ×\(count)" : directory }
}

public struct StateCount: Sendable, Equatable, Identifiable {
    public var state: PaneState
    public var count: Int
    public var id: PaneState { state }
}

import Foundation

/// The events the grid acts on, parsed from one line of `rex events --json`.
public enum RexEvent: Sendable, Equatable {
    case status(blockID: String, record: StatusRecord)
    case statusRemoved(blockID: String, ids: [String])
    case title(blockID: String, title: String)
    /// The foreground process changed. `cwd` is nil when Rex reports no
    /// foreground process, in which case the last known directory stands.
    case process(blockID: String, name: String, cwd: String?)
    case directory(blockID: String, path: String)
    /// Panes, tabs, or sessions were added, removed, moved, or renamed. The
    /// event doesn't say enough to patch the board, so the caller re-reads it.
    case layoutChanged

    static let terminal = "com.superlogical.terminal"

    private static let layoutEvents: Set<String> = [
        "block_created", "block_closed", "window_created", "window_closed",
        "window_label_changed", "session_label_changed", "session_view_changed",
    ]

    public var blockID: String? {
        switch self {
        case .status(let id, _), .statusRemoved(let id, _), .title(let id, _),
             .process(let id, _, _), .directory(let id, _):
            return id
        case .layoutChanged:
            return nil
        }
    }

    /// Parses one event line. Returns nil for events the grid ignores, which
    /// is most of them: client connections alone arrive many times a second.
    public static func parse(line: String) -> RexEvent? {
        guard let root = JSONValue.parse(line) else { return nil }
        switch root["type"].string {
        case "session_created", "session_destroyed", "session_moved":
            return .layoutChanged
        case "session_event":
            // A session event wraps the real one; a terminal event is wrapped
            // once more, in a `block_event`.
            let event = root["payload"]["event"]
            guard let type = event["type"].string else { return nil }
            if type == "block_event" { return blockEvent(event["payload"]) }
            return layoutEvents.contains(type) ? .layoutChanged : nil
        default:
            return nil
        }
    }

    private static func blockEvent(_ event: JSONValue) -> RexEvent? {
        guard event["creator_name"].string == terminal, let blockID = event["block_id"].string else {
            return nil
        }
        let payload = event["payload"]
        switch event["name"].string {
        case "program_status_changed":
            guard let record = StatusRecord(json: payload["record"], id: payload["id"].string) else { return nil }
            return .status(blockID: blockID, record: record)
        case "program_status_removed":
            return .statusRemoved(blockID: blockID, ids: payload["ids"].array.compactMap(\.string))
        case "title_changed":
            return .title(blockID: blockID, title: payload["title"].string ?? "")
        case "process_changed":
            let foreground = payload["foreground"]
            return .process(blockID: blockID, name: foreground["name"].string ?? "", cwd: foreground["cwd"].string)
        case "pwd_changed":
            // `pwd` is a file URL such as file://host/Users/you/src.
            guard let pwd = payload["pwd"].string, let path = URL(string: pwd)?.path, !path.isEmpty else {
                return nil
            }
            return .directory(blockID: blockID, path: path)
        default:
            return nil
        }
    }
}

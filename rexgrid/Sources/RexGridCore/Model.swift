import Foundation

/// What a pane is doing, in the order the grid shows it: what needs you first.
///
/// The first five are states a program reports through OSC 7501. The last two
/// are inferred for panes that report nothing: `running` is a foreground
/// program that isn't a shell, `shell` is a pane sitting at its prompt.
public enum PaneState: String, Sendable, CaseIterable {
    case blocked, error, done, working, idle, running, shell

    public var rank: Int { Self.allCases.firstIndex(of: self)! }

    /// Whether a program can report this state, as opposed to the grid inferring it.
    public var isReported: Bool { self != .running && self != .shell }
}

/// One status record a program reported. A pane holds one per id; the empty
/// id is the root record, and `build/test` is a child of `build`.
public struct StatusRecord: Sendable, Equatable {
    public var id: String
    public var state: PaneState
    public var kind: String?
    public var app: String?
    public var title: String?
    public var message: String?
    public var progress: Int?
    public var updatedAt: Date?

    public init(
        id: String = "", state: PaneState, kind: String? = nil, app: String? = nil,
        title: String? = nil, message: String? = nil, progress: Int? = nil, updatedAt: Date? = nil
    ) {
        self.id = id
        self.state = state
        self.kind = kind
        self.app = app
        self.title = title
        self.message = message
        self.progress = progress
        self.updatedAt = updatedAt
    }

    /// Reads a record as Rex sends it. A state this build doesn't know makes
    /// the whole record nil, the same rule the protocol gives terminals.
    public init?(json: JSONValue, id: String? = nil) {
        guard let raw = json["state"].string, let state = PaneState(rawValue: raw), state.isReported else {
            return nil
        }
        self.init(
            id: id ?? json["id"].string ?? "",
            state: state,
            kind: json["kind"].string,
            // A child record carries no `app` of its own; Rex resolves the
            // inherited one into `effective_app`.
            app: json["effective_app"].string ?? json["app"].string,
            title: json["title"].string,
            message: json["msg"].string,
            progress: json["progress"].int,
            updatedAt: json["updated_at"].string.flatMap(Timestamp.parse)
        )
    }

    public var isChild: Bool { !id.isEmpty }
}

/// One terminal pane and everything the grid knows about it.
public struct Pane: Sendable, Equatable, Identifiable {
    public var blockID: String
    public var sessionID: String
    public var sessionLabel: String
    public var windowID: String
    public var windowLabel: String
    /// Whether other terminal panes share this pane's tab. A shared tab label
    /// can't tell them apart, so the pane's own title names it instead.
    public var sharesWindow: Bool
    public var title: String
    /// Name of the foreground process; empty when Rex reports none.
    public var process: String
    public var cwd: String
    public var records: [String: StatusRecord]

    public init(
        blockID: String, sessionID: String = "", sessionLabel: String = "", windowID: String = "",
        windowLabel: String = "", sharesWindow: Bool = false, title: String = "", process: String = "",
        cwd: String = "", records: [String: StatusRecord] = [:]
    ) {
        self.blockID = blockID
        self.sessionID = sessionID
        self.sessionLabel = sessionLabel
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.sharesWindow = sharesWindow
        self.title = title
        self.process = process
        self.cwd = cwd
        self.records = records
    }

    public var id: String { blockID }

    static let shells: Set<String> = ["fish", "zsh", "bash", "sh", "nu", "dash", "ksh", "tcsh"]

    /// The record that most needs attention. A program can be idle at its
    /// prompt while one of its workers is blocked; the worker wins.
    public var primary: StatusRecord? {
        records.values.min { ($0.state.rank, $0.id) < ($1.state.rank, $1.id) }
    }

    public var state: PaneState {
        if let primary { return primary.state }
        return process.isEmpty || Self.shells.contains(process) ? .shell : .running
    }

    public var app: String {
        records[""]?.app ?? primary?.app ?? (process.isEmpty ? "shell" : process)
    }

    public var name: String {
        if !sharesWindow, !windowLabel.isEmpty, !Titles.isPlaceholder(windowLabel) { return windowLabel }
        let fromTitle = Titles.name(title: title, app: app, message: primary?.message)
        if !fromTitle.isEmpty { return fromTitle }
        if !windowLabel.isEmpty, !Titles.isPlaceholder(windowLabel) { return windowLabel }
        return app
    }

    /// Last component of the working directory, or empty when unknown.
    public var directory: String {
        cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// What the pane is doing or waiting for. Falls back to the terminal
    /// title for programs that report a state but no message.
    public var message: String {
        if let primary {
            let text = primary.message ?? ""
            if primary.isChild, let title = primary.title, !title.isEmpty {
                return text.isEmpty ? title : "\(title): \(text)"
            }
            if !text.isEmpty { return text }
        }
        let steady = Titles.steady(title)
        return steady == name ? "" : steady
    }

    public var since: Date? { primary?.updatedAt }

    public var children: [StatusRecord] {
        records.values.filter(\.isChild).sorted { $0.id < $1.id }
    }
}

public enum Timestamp {
    /// Parses Rex's timestamps, such as `2026-11-09T15:53:23.403153-08:00`.
    ///
    /// Rex trims trailing zeros, so the fraction has anywhere from zero to
    /// six digits. Foundation's ISO 8601 parser wants a fixed shape, so the
    /// fraction is taken off, parsed separately, and added back.
    public static func parse(_ text: String) -> Date? {
        var whole = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text[text.index(after: dot)...]
            let digits = afterDot.prefix { $0.isASCII && $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            whole = String(text[..<dot]) + afterDot.dropFirst(digits.count)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: whole)?.addingTimeInterval(fraction)
    }
}

public enum Age {
    /// A compact age such as `42s`, `7m`, `3h`, or `2d`.
    public static func short(since start: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        switch seconds {
        case ..<90: return "\(Int(seconds))s"
        case ..<5400: return "\(Int(seconds / 60))m"
        case ..<129_600: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}

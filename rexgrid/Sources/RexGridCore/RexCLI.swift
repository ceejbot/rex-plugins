import Foundation

/// How an attempt to show a pane in the Rex app went.
public enum RevealResult: Sendable, Equatable {
    /// The app switched to the pane.
    case shown
    /// The app has Remote Control turned off, so it would not switch tabs.
    case remoteControlOff
    /// Something else went wrong; the text is Rex's own error.
    case failed(String)

    public init(focused: Bool, selected: Bool, selectError: String) {
        if selected {
            self = .shown
        } else if selectError.localizedCaseInsensitiveContains("not accepting actions") {
            self = .remoteControlOff
        } else {
            self = .failed(selectError.isEmpty ? (focused ? "the app did not switch tabs" : "the pane could not be focused") : selectError)
        }
    }
}

/// The boundary to Rex: everything the grid knows comes through the `rex`
/// command, and everything it does to Rex goes out through it.
///
/// Rex's socket protocol isn't documented; the CLI is the supported way in.
public struct RexCLI: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Finds the `rex` binary. An app launched from Finder gets a bare PATH,
    /// so the place the Rex app installs its CLI is checked as well.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        var candidates: [String] = []
        if let explicit = environment["REX_BIN"] { candidates.append(explicit) }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/rex" }
        candidates += [
            "\(home)/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
            "/opt/homebrew/bin/rex",
            "/usr/local/bin/rex",
            "\(home)/.local/bin/rex",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// What one `rex` command did.
    public struct Outcome: Sendable {
        public var succeeded: Bool
        public var stdout: Data
        /// Rex's error message when the command failed; small, so it is read whole.
        public var stderr: String
    }

    /// Runs one `rex` command to completion.
    public func run(_ arguments: [String]) async -> Outcome {
        let executable = executable
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Outcome(succeeded: false, stdout: Data(), stderr: "\(error)"))
                    return
                }
                // Stdout can be large and stderr is a line or two, so draining
                // stdout first can't stall on a full stderr pipe.
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Outcome(
                    succeeded: process.terminationStatus == 0,
                    stdout: out,
                    stderr: String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }

    /// Runs one `rex` command and returns its stdout, or nil if it failed.
    public func output(_ arguments: [String]) async -> Data? {
        let outcome = await run(arguments)
        return outcome.succeeded ? outcome.stdout : nil
    }

    public func json(_ arguments: [String]) async -> JSONValue? {
        await output(arguments).flatMap(JSONValue.parse)
    }

    /// Lists every terminal pane in every session, with where it sits but not
    /// what it reports. Returns nil when Rex can't be reached, which is
    /// different from Rex having no panes.
    public func layout() async -> [Pane]? {
        guard let listing = await json(["ls", "--json"]) else { return nil }
        var panes: [Pane] = []
        for session in listing["sessions"].array {
            guard let sessionID = session["session_id"].string,
                  let view = await json(["window", "ls", "-s", sessionID, "--json"]) else { continue }
            for window in view["windows"].array {
                let blocks = window["layers"].array
                    .flatMap { $0["blocks"].array }
                    .filter { $0["creator_name"].string == RexEvent.terminal }
                for block in blocks {
                    guard let blockID = block["block_id"].string else { continue }
                    panes.append(Pane(
                        blockID: blockID,
                        sessionID: sessionID,
                        sessionLabel: session["label"].string ?? "",
                        windowID: window["window_id"].string ?? "",
                        windowLabel: window["label"].string ?? "",
                        sharesWindow: blocks.count > 1
                    ))
                }
            }
        }
        return panes
    }

    /// Describes several panes at once, keeping their order.
    public func describe(_ panes: [Pane]) async -> [Pane] {
        await withTaskGroup(of: (Int, Pane).self) { group in
            for (index, pane) in panes.enumerated() {
                group.addTask { (index, await describe(pane)) }
            }
            var described = panes
            for await (index, pane) in group { described[index] = pane }
            return described
        }
    }

    /// Fills in what a pane reports: its status records, title, and
    /// foreground process.
    public func describe(_ pane: Pane) async -> Pane {
        let call = ["block", "call", "-s", pane.sessionID, "-b", pane.blockID]
        async let status = json(call + ["program_status"])
        async let title = json(call + ["title"])
        async let process = json(call + ["process"])

        var pane = pane
        for record in (await status)?["records"].array ?? [] {
            if let record = StatusRecord(json: record) { pane.records[record.id] = record }
        }
        pane.title = (await title)?["title"].string ?? ""
        let foreground = (await process)?["foreground"] ?? .null
        pane.process = foreground["name"].string ?? ""
        pane.cwd = foreground["cwd"].string ?? ""
        return pane
    }

    /// Streams `rex events --all --json`, one line per event, until the
    /// consumer stops or the server goes away.
    public func eventLines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["events", "--all", "--json"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let pid = process.processIdentifier
            let handle = stdout.fileHandleForReading
            let reader = Task.detached {
                do {
                    for try await line in handle.bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                kill(pid, SIGTERM)
            }
        }
    }

    /// Shows a pane in the Rex app.
    ///
    /// Two steps, because Rex keeps two kinds of state. `rex focus` changes
    /// the session on the server: which tab is active and which pane has
    /// focus. The app does not follow that; which tab it displays is the
    /// app's own state, changed only by the `session.select` client action.
    /// The app refuses client actions unless Remote Control is turned on in
    /// its settings, and that refusal is reported so the user can be told.
    public func reveal(_ pane: Pane) async -> RevealResult {
        let focus = await run(["focus", "-s", pane.sessionID, pane.blockID])
        let select = await run(["do", "session.select", "session_id=\(pane.sessionID)", "window_id=\(pane.windowID)"])
        return RevealResult(focused: focus.succeeded, selected: select.succeeded, selectError: select.stderr)
    }
}

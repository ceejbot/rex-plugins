import CoreGraphics
import Foundation
import Testing

@testable import RexGridCore

/// Wraps a terminal event the way `rex events --json` does: a `block_event`
/// inside a `session_event`.
private func blockEvent(_ name: String, block: String = "block:1", payload: String) -> String {
    """
    {"type":"session_event","payload":{"session_id":"session:1","event":{"type":"block_event","payload":\
    {"block_id":"\(block)","creator_name":"com.superlogical.terminal","name":"\(name)","payload":\(payload)}}}}
    """
}

@Suite struct EventParsing {
    // Payloads below are copied from events recorded on a live server.

    @Test func claudePermissionPrompt() throws {
        let line = blockEvent("program_status_changed", payload: """
            {"id":"","record":{"state":"blocked","kind":"permission","app":"claude-code","effective_app":"claude-code",\
            "msg":"approve Bash: touch probe.txt","updated_at":"2026-11-09T15:53:23.403153-08:00",\
            "owner":{"pid":87751,"name":"2.1.321"}},"reason":"report"}
            """)
        guard case .status(let blockID, let record) = RexEvent.parse(line: line) else {
            Issue.record("expected a status event")
            return
        }
        #expect(blockID == "block:1")
        #expect(record.id == "")
        #expect(record.state == .blocked)
        #expect(record.kind == "permission")
        #expect(record.app == "claude-code")
        #expect(record.message == "approve Bash: touch probe.txt")
        #expect(record.updatedAt != nil)
    }

    @Test func childRecordInheritsAppAndKeepsItsID() {
        let line = blockEvent("program_status_changed", payload: """
            {"id":"w1/sub","record":{"id":"w1/sub","state":"working","progress":40,"effective_app":"demo",\
            "updated_at":"2026-11-09T21:16:37.294075-08:00"},"reason":"report"}
            """)
        let expected = StatusRecord(
            id: "w1/sub", state: .working, app: "demo", progress: 40,
            updatedAt: Timestamp.parse("2026-11-09T21:16:37.294075-08:00"))
        #expect(RexEvent.parse(line: line) == .status(blockID: "block:1", record: expected))
    }

    @Test func removalListsEveryClearedID() {
        let line = blockEvent("program_status_removed", payload: #"{"ids":["w1","w1/sub"],"reason":"clear"}"#)
        #expect(RexEvent.parse(line: line) == .statusRemoved(blockID: "block:1", ids: ["w1", "w1/sub"]))
    }

    @Test func unknownStateIsIgnoredRatherThanGuessed() {
        let line = blockEvent("program_status_changed", payload: #"{"id":"","record":{"state":"paused"}}"#)
        #expect(RexEvent.parse(line: line) == nil)
    }

    @Test func titleAndProcess() {
        let title = blockEvent("title_changed", payload: #"{"title":"⠹ probe-codex","owner":{"pid":1,"name":"codex"}}"#)
        #expect(RexEvent.parse(line: title) == .title(blockID: "block:1", title: "⠹ probe-codex"))

        let process = blockEvent("process_changed", payload: """
            {"generation":4,"foreground":{"pid":88198,"name":"codex","argv0":"codex","cwd":"/tmp/probe-codex"}}
            """)
        #expect(RexEvent.parse(line: process) == .process(blockID: "block:1", name: "codex", cwd: "/tmp/probe-codex"))

        let none = blockEvent("process_changed", payload: #"{"generation":1,"foreground":null}"#)
        #expect(RexEvent.parse(line: none) == .process(blockID: "block:1", name: "", cwd: nil))
    }

    @Test func workingDirectoryComesFromAFileURL() {
        let line = blockEvent("pwd_changed", payload: #"{"pwd":"file://unobtanium/Users/me/src","owner":{}}"#)
        #expect(RexEvent.parse(line: line) == .directory(blockID: "block:1", path: "/Users/me/src"))
    }

    @Test func layoutEventsAskForARefresh() {
        let created = #"{"type":"session_event","payload":{"session_id":"s","event":{"type":"block_created","payload":{"block_id":"b"}}}}"#
        #expect(RexEvent.parse(line: created) == .layoutChanged)
        #expect(RexEvent.parse(line: #"{"type":"session_created","payload":{"session":{"session_id":"s","label":"work"}}}"#) == .layoutChanged)
    }

    @Test func noiseIsDropped() {
        // Every CLI call joins and leaves as a client; these dominate the stream.
        #expect(RexEvent.parse(line: #"{"type":"client_joined","payload":{"client":{}}}"#) == nil)
        #expect(RexEvent.parse(line: #"{"type":"session_event","payload":{"session_id":"s","event":{"type":"client_connected","payload":{}}}}"#) == nil)
        #expect(RexEvent.parse(line: blockEvent("size_changed", payload: #"{"columns":146,"rows":51}"#)) == nil)
        #expect(RexEvent.parse(line: "not json, a line cut short by a kill") == nil)
    }

    @Test func otherBlockKindsAreIgnored() {
        let line = #"{"type":"session_event","payload":{"session_id":"s","event":{"type":"block_event","payload":{"block_id":"b","creator_name":"com.superlogical.onboarding","name":"title_changed","payload":{"title":"x"}}}}}"#
        #expect(RexEvent.parse(line: line) == nil)
    }
}

@Suite struct Timestamps {
    @Test func fractionOfAnyLength() throws {
        let six = try #require(Timestamp.parse("2026-11-09T15:53:23.403153-08:00"))
        let five = try #require(Timestamp.parse("2026-11-09T15:52:23.84809-08:00"))  // Rex trims trailing zeros
        let none = try #require(Timestamp.parse("2026-11-09T15:53:23-08:00"))
        let utc = try #require(Timestamp.parse("2026-11-09T23:53:23.5Z"))
        #expect(abs(six.timeIntervalSince(none) - 0.403153) < 0.0001)
        #expect(abs(none.timeIntervalSince(five) - 59.15191) < 0.0001)
        #expect(abs(utc.timeIntervalSince(none) - 0.5) < 0.0001)
    }

    @Test func garbageIsNil() {
        #expect(Timestamp.parse("yesterday") == nil)
    }

    @Test func ages() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Age.short(since: now.addingTimeInterval(-42), now: now) == "42s")
        #expect(Age.short(since: now.addingTimeInterval(-8 * 60), now: now) == "8m")
        #expect(Age.short(since: now.addingTimeInterval(-16 * 3600), now: now) == "16h")
        #expect(Age.short(since: now.addingTimeInterval(-3 * 86400), now: now) == "3d")
        #expect(Age.short(since: now.addingTimeInterval(5), now: now) == "0s")  // clock skew
    }
}

@Suite struct TitleCleanup {
    // Titles below were recorded from Codex 0.167.0 and Grok 1.0.77.

    @Test(arguments: [
        ("⠹ probe-codex", "probe-codex"),
        ("[ ! ] Action Required | Run curl command | probe-codex", "Run curl command | probe-codex"),
        ("[ . ] Action Required | Run curl command | probe-codex", "Run curl command | probe-codex"),
        ("⚠ Action Required - ⠴ - Fetch google.com response headers… - fooble - grok", "Fetch google.com response headers… - fooble - grok"),
        ("⠸ - Waiting for response… - fooble - grok", "Waiting for response… - fooble - grok"),
        ("- Responding - fooble - grok", "Responding - fooble - grok"),
        ("◑ Rex session status switcher", "Rex session status switcher"),
        ("✳ Claude Code", "Claude Code"),
        ("⚠️ Action Required - x", "x"),
        ("Boltzman bot", "Boltzman bot"),
        ("+page.svelte", "+page.svelte"),
        ("~/c/p/r/boltzmann", "~/c/p/r/boltzmann"),
        ("-zsh", "-zsh"),
        ("", ""),
    ])
    func steady(raw: String, expected: String) {
        #expect(Titles.steady(raw) == expected)
    }

    @Test func grokNameHoldsStillAcrossPhases() {
        let idle = Titles.name(title: "fooble - grok", app: "grok", message: nil)
        let waiting = Titles.name(title: "⠸ - Waiting for response… - fooble - grok", app: "grok", message: "Waiting for response…")
        let blocked = Titles.name(
            title: "⚠ Action Required - ⠴ - Fetch google.com response headers… - fooble - grok",
            app: "grok", message: "Fetch google.com response headers")
        #expect(idle == "fooble")
        #expect(waiting == "fooble")
        #expect(blocked == "fooble")
    }

    @Test func nameKeepsATitleThatIsOnlyTheApp() {
        #expect(Titles.name(title: "grok", app: "grok", message: nil) == "grok")
    }

    @Test func printableDisarmsEscapesAndInvisibleFormatting() {
        // An escape sequence in a directory name must not reach the terminal.
        #expect(Titles.printable("proj\u{1B}[2J\u{07}") == "proj [2J ")
        #expect(Titles.printable("line\none\ttwo\r") == "line one two ")
        // C1 controls and right-to-left override.
        #expect(Titles.printable("a\u{9B}b\u{202E}c") == "a b c")
        #expect(Titles.printable("Fetch headers… · fooble ×2") == "Fetch headers… · fooble ×2")
    }

    @Test func placeholders() {
        #expect(Titles.isPlaceholder("Window b907f442"))
        #expect(!Titles.isPlaceholder("Window shopping"))
        #expect(!Titles.isPlaceholder("Boltzman bot"))
    }
}

@Suite struct PaneDerivation {
    @Test func noRecordMeansShellOrRunning() {
        #expect(Pane(blockID: "b", process: "fish").state == .shell)
        #expect(Pane(blockID: "b", process: "").state == .shell)
        #expect(Pane(blockID: "b", process: "ruby").state == .running)
    }

    @Test func mostUrgentRecordWins() {
        // A program idle at its prompt while one of its workers is blocked.
        let pane = Pane(blockID: "b", process: "demo", records: [
            "": StatusRecord(state: .working, app: "demo", message: "parent"),
            "w1": StatusRecord(id: "w1", state: .blocked, kind: "question", app: "demo", title: "Worker one", message: "which branch?"),
        ])
        #expect(pane.state == .blocked)
        #expect(pane.message == "Worker one: which branch?")
        #expect(pane.app == "demo")
        #expect(pane.children.map(\.id) == ["w1"])
    }

    @Test func nameComesFromTheTabUnlessItIsAPlaceholderOrShared() {
        let labelled = Pane(blockID: "b", windowLabel: "Boltzman bot", title: "Session start")
        #expect(labelled.name == "Boltzman bot")

        let placeholder = Pane(blockID: "b", windowLabel: "Window 0f9184ec", title: "Rex session status switcher")
        #expect(placeholder.name == "Rex session status switcher")

        // Two panes in one labelled tab: the label can't tell them apart, so
        // the title names the pane (minus the app, which the cell shows anyway).
        let shared = Pane(blockID: "b", windowLabel: "Work", sharesWindow: true, title: "fooble - grok", process: "grok")
        #expect(shared.name == "fooble")

        // With no usable title, a shared label is still better than nothing.
        let untitled = Pane(blockID: "b", windowLabel: "Work", sharesWindow: true, process: "fish")
        #expect(untitled.name == "Work")
    }

    @Test func codexFallsBackToItsTitleForAMessage() {
        // Codex reports `blocked` with no message; the title carries the task.
        let pane = Pane(
            blockID: "b", windowLabel: "probe-codex",
            title: "[ ! ] Action Required | Run curl header check | probe-codex", process: "codex",
            records: ["": StatusRecord(state: .blocked, kind: "permission", app: "codex")])
        #expect(pane.name == "probe-codex")
        #expect(pane.message == "Run curl header check | probe-codex")
    }

    @Test func directoryIsTheLastPathComponent() {
        #expect(Pane(blockID: "b", cwd: "/Users/me/code/personal/rust/boltzmann").directory == "boltzmann")
        #expect(Pane(blockID: "b").directory == "")
    }
}

@Suite struct BoardBehavior {
    private func board() -> Board {
        Board(panes: [
            Pane(blockID: "shell-a", process: "fish", cwd: "/x/Forsyte"),
            Pane(blockID: "shell-b", process: "fish", cwd: "/y/Forsyte"),
            Pane(blockID: "shell-c", process: "fish", cwd: "/x/boltzmann"),
            Pane(blockID: "claude", windowLabel: "Boltzman bot", process: "2.1.321",
                 records: ["": StatusRecord(state: .done, app: "claude-code", message: "finished")]),
            Pane(blockID: "brew", title: "brew upgrade", process: "ruby"),
        ])
    }

    @Test func shellsCollapseByDirectory() {
        #expect(board().shells.map(\.label) == ["Forsyte ×2", "boltzmann"])
    }

    @Test func cellsLeaveShellsOutAndPutUrgentFirst() {
        var board = board()
        #expect(board.cells.map(\.blockID) == ["claude", "brew"])

        board.apply(.status(blockID: "shell-c", record: StatusRecord(state: .blocked, app: "codex")))
        #expect(board.cells.map(\.blockID) == ["shell-c", "claude", "brew"])
    }

    @Test func countsFollowTheStateOrder() {
        #expect(board().counts == [
            StateCount(state: .done, count: 1),
            StateCount(state: .running, count: 1),
            StateCount(state: .shell, count: 3),
        ])
    }

    @Test func statusLifecycle() {
        var board = board()
        let working = StatusRecord(state: .working, app: "claude-code", message: "building")
        let known = board.apply(.status(blockID: "claude", record: working))
        #expect(known)
        #expect(board.panes[3].state == .working)

        // The program exits: Rex removes the root record and the pane is a shell again.
        board.apply(.statusRemoved(blockID: "claude", ids: [""]))
        board.apply(.process(blockID: "claude", name: "fish", cwd: nil))
        #expect(board.panes[3].state == .shell)
        #expect(board.panes[3].records.isEmpty)
    }

    @Test func processChangeWithoutForegroundKeepsTheDirectory() {
        var board = board()
        board.apply(.process(blockID: "shell-a", name: "", cwd: nil))
        #expect(board.panes[0].cwd == "/x/Forsyte")
        board.apply(.directory(blockID: "shell-a", path: "/x/elsewhere"))
        #expect(board.panes[0].directory == "elsewhere")
    }

    @Test func adoptingALayoutKeepsWhatKnownPanesReported() {
        let old = board()
        // The tab holding `claude` was renamed, `brew` closed, and a new pane opened.
        let layout = [
            Pane(blockID: "claude", sessionID: "s", windowID: "w9", windowLabel: "Renamed"),
            Pane(blockID: "new", sessionID: "s", windowID: "w9", sharesWindow: true),
        ]
        var (next, missing) = old.adopting(layout: layout)

        #expect(missing.map(\.blockID) == ["new"])
        #expect(next.panes.map(\.blockID) == ["claude", "new"])
        #expect(next.panes[0].windowLabel == "Renamed")
        #expect(next.panes[0].windowID == "w9")
        #expect(next.panes[0].state == .done)  // its record survived the re-read

        next.fill([Pane(blockID: "new", sessionID: "s", windowID: "w9", sharesWindow: true, process: "codex")])
        #expect(next.panes[1].state == .running)
    }

    @Test func unknownPaneReportsTheBoardIsStale() {
        var board = board()
        let known = board.apply(.title(blockID: "never-seen", title: "x"))
        #expect(!known)
        let layout = board.apply(.layoutChanged)
        #expect(layout)
    }
}

@Suite struct Revealing {
    @Test func appSwitchedTabs() {
        #expect(RevealResult(focused: true, selected: true, selectError: "") == .shown)
    }

    @Test func remoteControlOffIsRecognizedFromRexsOwnMessage() {
        // The exact text the CLI printed on 2026-11-09.
        let refusal = "Error: Rex.app is not accepting actions. Turn on Remote Control in its Settings under Rex Server."
        #expect(RevealResult(focused: true, selected: false, selectError: refusal) == .remoteControlOff)
    }

    @Test func otherFailuresKeepRexsExplanation() {
        #expect(RevealResult(focused: true, selected: false, selectError: "Error: no app client is connected")
            == .failed("Error: no app client is connected"))
        #expect(RevealResult(focused: false, selected: false, selectError: "") == .failed("the pane could not be focused"))
    }
}

@Suite struct Locating {
    @Test func explicitOverrideWinsWhenExecutable() {
        let found = RexCLI.locate(environment: ["REX_BIN": "/bin/ls", "PATH": "/nonexistent", "HOME": "/nonexistent"])
        #expect(found?.path == "/bin/ls")
    }

    @Test func nothingFoundIsNil() {
        #expect(RexCLI.locate(environment: ["PATH": "/nonexistent", "HOME": "/nonexistent"]) == nil
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rex")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/rex"))
    }
}

@Suite struct PanelFitting {
    // A 1440×900 screen with a 25-point menu bar and a 70-point Dock.
    private let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
    // Top edge at y = 800.
    private let current = CGRect(x: 900, y: 500, width: 520, height: 300)

    private func fit(_ contentHeight: CGFloat, from frame: CGRect? = nil) -> CGRect {
        PanelFrame.fitting(current: frame ?? current, contentHeight: contentHeight, visible: visible, minimumHeight: 36)
    }

    @Test func growsDownwardWithTheTopEdgeHeld() {
        #expect(fit(430) == CGRect(x: 900, y: 370, width: 520, height: 430))
    }

    @Test func shrinksWithTheTopEdgeHeld() {
        #expect(fit(36) == CGRect(x: 900, y: 764, width: 520, height: 36))
    }

    @Test func slidesUpWhenTheBottomWouldLeaveTheScreen() {
        // Top edge at 300: 430 points below it would end at -130.
        let low = CGRect(x: 900, y: 264, width: 520, height: 36)
        #expect(fit(430, from: low) == CGRect(x: 900, y: 70, width: 520, height: 430))
    }

    @Test func tallContentIsCappedAtTheVisibleHeight() {
        #expect(fit(2000) == CGRect(x: 900, y: 70, width: 520, height: 805))
    }

    @Test func neverShorterThanTheMinimum() {
        #expect(fit(0) == CGRect(x: 900, y: 764, width: 520, height: 36))
    }

    @Test func fractionalHeightsRoundUpSoNothingIsClipped() {
        #expect(fit(157.5).height == 158)
    }
}

@Suite struct GridSizing {
    private let metrics = GridMetrics.standard

    @Test func aRowHoldsAsManyCellsAsFit() {
        #expect(metrics.columns(fitting: 0) == 1)
        #expect(metrics.columns(fitting: 230) == 1)
        // Two cells need 230 + 8 + 230.
        #expect(metrics.columns(fitting: 467) == 1)
        #expect(metrics.columns(fitting: 468) == 2)
        // The default 520-point panel, less its side padding.
        #expect(metrics.columns(fitting: 500) == 2)
        #expect(metrics.columns(fitting: 706) == 3)
    }

    @Test func heightCountsRowsAndTheGapsBetweenThem() {
        #expect(metrics.height(cells: 0, columns: 2) == 0)
        #expect(metrics.height(cells: 2, columns: 2) == 122)
        // The third session starts a second row.
        #expect(metrics.height(cells: 3, columns: 2) == 252)
        #expect(metrics.height(cells: 3, columns: 1) == 382)
    }
}

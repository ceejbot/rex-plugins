import AppKit
import RexGridCore
import SwiftUI

/// RexGrid: a floating status grid for the panes of a Rex server.
///
///     RexGrid           open the panel
///     RexGrid --dump    print the board once and exit
///     RexGrid --watch   print the board each time it changes, without the panel
///     RexGrid --reveal NAME   show the pane whose name contains NAME, as a click would

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: Store
    private var panel: FloatingPanel?

    init(store: Store) {
        self.store = store
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = FloatingPanel(rootView: GridView(store: store))
        panel.orderFrontRegardless()
        self.panel = panel
        store.start()
    }

    // The panel is the whole app: closing it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}

func describe(_ board: Board) -> String {
    var lines = [board.counts.map { "\($0.count) \($0.state.rawValue)" }.joined(separator: "  ")]
    for pane in board.cells {
        let age = pane.since.map { Age.short(since: $0, now: .now) } ?? "-"
        lines.append("  <\(pane.state.rawValue)> \(pane.name) | \(pane.app) · \(pane.directory) | \(age) | \(pane.message)")
    }
    lines.append("  shells: " + board.shells.map(\.label).joined(separator: " · "))
    // Every field above comes from a program in a pane; see `Titles.printable`.
    return lines.map(Titles.printable).joined(separator: "\n")
}

/// Prints the board once, for checking the boundary to Rex without the UI.
func dump(_ rex: RexCLI) async {
    guard let layout = await rex.layout() else {
        print("cannot reach Rex with \(rex.executable.path)")
        exit(1)
    }
    print(describe(Board(panes: await rex.describe(layout))))
}

/// Runs the same store the panel uses and prints the board on every change,
/// for checking the event path without the UI.
@MainActor
func watch(_ store: Store) {
    setvbuf(stdout, nil, _IOLBF, 0)
    report(store)
    store.start()
}

/// Prints the board and arranges to be called again when it next changes.
@MainActor
func report(_ store: Store) {
    withObservationTracking {
        print("--- \(Date.now.formatted(date: .omitted, time: .standard))\(store.reachable ? "" : " (Rex unreachable)")")
        print(describe(store.board))
    } onChange: {
        Task { @MainActor in report(store) }
    }
}

guard let executable = RexCLI.locate() else {
    FileHandle.standardError.write(Data("rexgrid: cannot find the rex command; set REX_BIN to its path\n".utf8))
    exit(1)
}
let rex = RexCLI(executable: executable)

if CommandLine.arguments.contains("--dump") {
    Task {
        await dump(rex)
        exit(0)
    }
    dispatchMain()
}

if let flag = CommandLine.arguments.firstIndex(of: "--reveal"), CommandLine.arguments.count > flag + 1 {
    let wanted = CommandLine.arguments[flag + 1].lowercased()
    Task { @MainActor in
        let panes = await rex.describe(await rex.layout() ?? [])
        guard let pane = panes.first(where: { $0.blockID == wanted || $0.name.lowercased().contains(wanted) }) else {
            print("no pane matches \"\(Titles.printable(wanted))\"")
            exit(1)
        }
        let result = await rex.reveal(pane)
        bringRexForward()
        // Give Launch Services a moment before the process goes away.
        try? await Task.sleep(for: .milliseconds(500))
        if let problem = Store.notice(for: result) {
            print(Titles.printable(problem))
            exit(1)
        }
        print("revealed \(Titles.printable(pane.name))")
        exit(0)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--watch") {
    watch(Store(rex: rex))
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate(store: Store(rex: rex))
app.delegate = delegate
// No Dock icon and no menu bar: the panel is the only surface.
app.setActivationPolicy(.accessory)
app.run()

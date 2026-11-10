import AppKit
import Observation
import OSLog
import RexGridCore

/// Brings the Rex app to the front.
///
/// This goes through Launch Services, as `open` does. Asking a running app
/// to activate itself (`NSRunningApplication.activate`) is ignored when the
/// caller isn't the active app, and the panel never is: it is built not to
/// take focus.
@MainActor
func bringRexForward() {
    let bundleID = "com.superlogical.rex"
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
    guard let url = running ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error {
            revealLog.error("could not bring Rex forward: \(error.localizedDescription, privacy: .public)")
        }
    }
    // Record what actually ended up in front, so "nothing happened" can be
    // told apart from "the tab changed but Rex stayed behind".
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(700))
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        revealLog.notice("frontmost app after reveal: \(front, privacy: .public)")
    }
}

/// Read with: /usr/bin/log show --last 5m --predicate 'subsystem == "local.rexgrid"'
let revealLog = Logger(subsystem: "local.rexgrid", category: "reveal")

/// Keeps a `Board` current: reads Rex once, then follows its event stream.
///
/// Everything here runs on the main actor, so events are applied one at a
/// time and the views read a consistent board.
@MainActor @Observable
final class Store {
    private(set) var board = Board()
    /// False while Rex can't be reached; the board then shows its last state.
    private(set) var reachable = true
    /// Why the last click couldn't show its pane, until a click succeeds.
    private(set) var notice: String?

    @ObservationIgnored private let rex: RexCLI
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var fullRefreshWanted = true
    /// Events that arrived while a refresh was reading Rex. The refresh may
    /// have read a pane before the event happened, so they are applied again
    /// on top of its result. Records replace by id, so twice is harmless.
    @ObservationIgnored private var replay: [RexEvent] = []
    /// Panes that sent events while unknown to the board.
    @ObservationIgnored private var strangers: Set<String> = []
    /// Strangers that a refresh then failed to find, such as detached panes.
    /// Their events are dropped so they can't trigger a refresh each time.
    @ObservationIgnored private var unplaced: Set<String> = []

    init(rex: RexCLI) {
        self.rex = rex
    }

    func start() {
        tasks.append(Task { await follow() })
        tasks.append(Task {
            // Events should keep the board exact. This catches anything missed.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                fullRefreshWanted = true
                scheduleRefresh()
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        pendingRefresh?.cancel()
    }

    /// Shows a pane in the Rex app and brings Rex forward.
    func reveal(_ pane: Pane) {
        // Logged so a click that seems to do nothing can be traced.
        revealLog.notice("click on \(pane.name, privacy: .public)")
        Task {
            let result = await rex.reveal(pane)
            revealLog.notice("reveal of \(pane.blockID, privacy: .public): \(String(describing: result), privacy: .public)")
            notice = Self.notice(for: result)
            bringRexForward()
        }
    }

    /// What to tell the user when a click couldn't show the pane; nil when it could.
    static func notice(for result: RevealResult) -> String? {
        switch result {
        case .shown:
            nil
        case .remoteControlOff:
            "Rex won't switch tabs for other apps yet. Turn on Remote Control in Rex Settings › Server › Client Info."
        case .failed(let reason):
            "Couldn't show that pane: \(reason)"
        }
    }

    private func follow() async {
        while !Task.isCancelled {
            // Start listening before reading, so nothing falls between the two.
            let lines = rex.eventLines()
            fullRefreshWanted = true
            scheduleRefresh(after: .zero)
            do {
                for try await line in lines {
                    if let event = RexEvent.parse(line: line) { handle(event) }
                }
            } catch {}
            // The stream ended: the server stopped or restarted. Try again.
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func handle(_ event: RexEvent) {
        guard let blockID = event.blockID else {
            scheduleRefresh()
            return
        }
        if unplaced.contains(blockID) { return }
        if refreshing { replay.append(event) }

        var next = board
        if next.apply(event) {
            // Assigning notifies every view, so skip no-op changes. Codex
            // rewrites its title several times a second.
            if next != board { board = next }
        } else {
            strangers.insert(blockID)
            scheduleRefresh()
        }
    }

    /// Refreshes soon. Layout events arrive in bursts, so each one pushes the
    /// refresh back and a burst costs a single read.
    private func scheduleRefresh(after delay: Duration = .milliseconds(400)) {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await refresh()
        }
    }

    private func refresh() async {
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        replay = []
        let full = fullRefreshWanted
        fullRefreshWanted = false
        let asked = strangers
        strangers = []

        if let layout = await rex.layout() {
            // A full refresh re-reads every pane; otherwise only new ones.
            let toDescribe = full ? layout : board.adopting(layout: layout).missing
            let described = await rex.describe(toDescribe)

            // Built from the board as it is now, not as it was before the
            // awaits above: known panes kept receiving events meanwhile.
            var next = board.adopting(layout: layout).board
            next.fill(described)
            for event in replay { next.apply(event) }
            if next != board { board = next }

            unplaced = unplaced.union(asked).filter { !next.contains(blockID: $0) }
            reachable = true
        } else {
            reachable = false
            fullRefreshWanted = true
            strangers.formUnion(asked)
        }

        replay = []
        refreshing = false
        if refreshAgain {
            refreshAgain = false
            scheduleRefresh()
        }
    }
}

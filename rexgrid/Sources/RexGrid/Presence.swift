import AppKit
import Observation
import OSLog

/// The Rex app, as Launch Services knows it.
let rexBundleID = "com.superlogical.rex"

/// Read with: /usr/bin/log show --last 5m --predicate 'subsystem == "local.rexgrid"'
let panelLog = Logger(subsystem: "local.rexgrid", category: "panel")

/// Whether the panel should stay out of the way.
///
/// While Rex is the frontmost app the panes are already on screen, so the
/// panel shrinks to its header. Putting the pointer on it brings the grid
/// back, which keeps click-to-jump usable from inside Rex.
@MainActor @Observable
final class Presence {
    private(set) var rexFrontmost: Bool
    private(set) var hovering = false

    var compact: Bool { rexFrontmost && !hovering }

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var leaving: Task<Void, Never>?

    init() {
        let front = NSWorkspace.shared.frontmostApplication
        rexFrontmost = front?.bundleIdentifier == rexBundleID
        panelLog.notice("frontmost at launch: \(front?.localizedName ?? "unknown", privacy: .public)")

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let name = app?.localizedName ?? "unknown"
            MainActor.assumeIsolated { self?.activated(bundleID: bundleID, name: name) }
        }
    }

    private func activated(bundleID: String?, name: String) {
        // The panel's own app coming forward says nothing about Rex.
        if bundleID == Bundle.main.bundleIdentifier { return }
        rexFrontmost = bundleID == rexBundleID
        panelLog.notice("frontmost: \(name, privacy: .public), compact: \(self.compact)")
    }

    /// The pointer crossed the panel's edge. Leaving waits a moment, so a
    /// pointer that grazes the edge doesn't make the panel flap.
    func pointerCrossed(inside: Bool) {
        leaving?.cancel()
        if inside {
            setHovering(true)
        } else {
            leaving = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { setHovering(false) }
            }
        }
    }

    /// Where the pointer is now, for when the panel changed size around a
    /// pointer that didn't move and so no crossing was reported.
    func pointerIs(inside: Bool) {
        leaving?.cancel()
        setHovering(inside)
    }

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        panelLog.notice("hovering: \(value), compact: \(self.compact)")
    }
}

import AppKit
import SwiftUI

/// A hosting view that acts on the first click it gets.
///
/// By default the first click on a window that isn't key only selects the
/// window; the view never sees it. This panel is never key, so every click
/// is a first click, and without this a cell could not be clicked at all.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small window that floats above other apps and follows across Spaces.
///
/// It is a non-activating panel that doesn't become key: clicking a cell
/// leaves keyboard focus in whatever app you were typing in.
final class FloatingPanel: NSPanel {
    private static let frameName = "RexGridPanel"

    init(rootView: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "RexGrid"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isFloatingPanel = true
        // Nothing in the panel takes typing, so it never needs to be key.
        becomesKeyOnlyIfNeeded = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 250, height: 150)
        // The translucent background is dark; pin the appearance to match so
        // text stays legible when the system is in light mode.
        appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active

        let host = FirstClickHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background

        // Remember where the user put it; start in the top-right corner.
        if !setFrameUsingName(Self.frameName), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 16))
        }
        setFrameAutosaveName(Self.frameName)
    }

    override var canBecomeKey: Bool { true }
}

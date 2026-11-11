import AppKit
import RexGridCore
import SwiftUI

/// A hosting view that acts on the first click it gets.
///
/// By default the first click on a window that isn't key only selects the
/// window; the view never sees it. This panel is never key, so every click
/// is a first click, and without this a cell could not be clicked at all.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's background, which also reports the pointer entering and
/// leaving the panel.
final class PanelBackgroundView: NSVisualEffectView {
    var onPointerCrossed: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // `.activeAlways` because the panel is never key and its app is never
        // active; the default would report nothing.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseEntered(with event: NSEvent) { onPointerCrossed?(true) }
    override func mouseExited(with event: NSEvent) { onPointerCrossed?(false) }
}

/// A small window that floats above other apps and follows across Spaces.
///
/// It is a non-activating panel that doesn't become key: clicking a cell
/// leaves keyboard focus in whatever app you were typing in.
///
/// Its width is the user's to set. Its height follows its content: see `fit`.
final class FloatingPanel: NSPanel, NSWindowDelegate {
    private static let frameName = "RexGridPanel"
    /// The header row alone, which is all the panel shows when compact.
    private static let minimumHeight: CGFloat = 28
    /// How opaque the compact strip is. The full grid is always opaque.
    private static let compactAlpha: CGFloat = 0.5

    private let presence: Presence
    /// The last height the content asked for.
    private var wantedHeight: CGFloat?
    private var pendingFit: Task<Void, Never>?

    init(rootView: some View, presence: Presence) {
        self.presence = presence
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
        minSize = NSSize(width: 250, height: Self.minimumHeight)
        // The translucent background is dark; pin the appearance to match so
        // text stays legible when the system is in light mode.
        appearance = NSAppearance(named: .darkAqua)

        let background = PanelBackgroundView(frame: .zero)
        background.onPointerCrossed = { [presence] inside in presence.pointerCrossed(inside: inside) }
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active

        let host = FirstClickHostingView(rootView: rootView)
        // The panel sizes itself from what the content reports (see `fit`).
        // Left on, the hosting view also holds the window to its own idea of
        // a minimum, which is taller than the header row.
        host.sizingOptions = []
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
        // What matters in the saved frame is the top-left corner and the
        // width; the height is worked out again from the content.
        setFrameAutosaveName(Self.frameName)
        delegate = self
        followCompact()
    }

    /// Dims the panel while it is compact, so what it covers shows through.
    private func followCompact() {
        withObservationTracking {
            animator().alphaValue = presence.compact ? Self.compactAlpha : 1
        } onChange: { [weak self] in
            // Observation reports one change; ask again for the next.
            Task { @MainActor in self?.followCompact() }
        }
    }

    override var canBecomeKey: Bool { true }

    /// Asks the panel to show `contentHeight` of content. It gets there a
    /// moment later, growing and shrinking downward.
    ///
    /// The content settles over a few layout passes and reports a height on
    /// each. Waiting briefly means only the last one moves the window.
    func fit(contentHeight: CGFloat) {
        wantedHeight = contentHeight
        pendingFit?.cancel()
        pendingFit = Task {
            try? await Task.sleep(for: .milliseconds(40))
            if !Task.isCancelled { settle() }
        }
    }

    /// Moves the panel to the last height asked for.
    private func settle() {
        // Fighting the user's drag makes the edge jitter; the end of the drag
        // calls this again.
        guard let wantedHeight, !inLiveResize, let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }

        // The content fills the whole window here, title bar included, but
        // ask rather than assume.
        let height = frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: wantedHeight)).height
        let target = PanelFrame.fitting(
            current: frame,
            contentHeight: height,
            visible: visible,
            minimumHeight: Self.minimumHeight
        )
        if target != frame {
            // Not animated: AppKit reports its own animated resizes as live
            // resizes, which can't then be told apart from the user's.
            setFrame(target, display: true)
            // Logs the frame the window took, which is not always the one asked for.
            panelLog.notice("""
                panel: content \(Int(wantedHeight)) high, asked for \(Int(target.width))x\(Int(target.height)), \
                now \(Int(self.frame.width))x\(Int(self.frame.height)) with top edge at \(Int(self.frame.maxY))
                """)
        }
        // A panel that changes size around a still pointer gets no enter or
        // exit event, so ask where the pointer is.
        presence.pointerIs(inside: frame.contains(NSEvent.mouseLocation))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        settle()
    }
}

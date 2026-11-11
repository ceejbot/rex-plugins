import RexGridCore
import SwiftUI

extension PaneState {
    var color: Color {
        switch self {
        case .blocked: .red
        case .error: Color(red: 0.92, green: 0.35, blue: 0.85)
        case .done: .green
        case .working: .yellow
        case .idle: .cyan
        case .running: .blue
        case .shell: .gray
        }
    }
}

struct GridView: View {
    let store: Store
    let presence: Presence
    /// Called with the height that would show everything without scrolling.
    let onIdealHeight: (CGFloat) -> Void

    private let metrics = GridMetrics.standard

    /// The whole stack, as laid out in the window as it is now.
    @State private var stackHeight: CGFloat = 0
    /// The part of the grid the window currently has room to show.
    @State private var viewport: CGSize = .zero

    var body: some View {
        // Ages tick once a second; the board itself changes only on events.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 8) {
                header
                if !presence.compact {
                    if let notice = store.notice {
                        Text(notice)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    cells(now: timeline.date)
                    shells
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, presence.compact ? 0 : 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stackHeight = $0 }
            // The window follows the content a moment later; stay at the top
            // of it meanwhile.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .onChange(of: idealHeight, initial: true) { _, height in
            // Zero means nothing has been laid out yet.
            if height > 0 { onIdealHeight(height) }
        }
    }

    /// The stack's height if the grid were shown in full.
    ///
    /// Everything but the grid has a fixed height, so the stack is that much
    /// taller than the grid's viewport whatever size the window is. Swapping
    /// the viewport for the whole grid gives a number that doesn't move while
    /// the window resizes toward it.
    private var idealHeight: CGFloat {
        let count = store.board.cells.count
        guard !presence.compact, count > 0 else { return stackHeight }
        let columns = metrics.columns(fitting: viewport.width)
        return stackHeight - viewport.height + metrics.height(cells: count, columns: columns)
    }

    /// Sits in the title bar row, to the right of the close button.
    private var header: some View {
        HStack(spacing: 10) {
            ForEach(store.board.counts) { entry in
                Text("\(entry.count) \(entry.state.rawValue)")
                    .foregroundStyle(entry.state.color)
            }
            Spacer()
            if !store.reachable {
                Text("Rex unreachable").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .padding(.leading, 20)
        .frame(height: 28)
    }

    @ViewBuilder
    private func cells(now: Date) -> some View {
        let panes = store.board.cells
        if panes.isEmpty {
            Text(store.reachable ? "Nothing running" : "Waiting for Rex")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
        } else {
            // The column count comes from the same metrics the panel sizes
            // itself with, not from an adaptive grid item, so the two agree.
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: metrics.spacing),
                count: metrics.columns(fitting: viewport.width)
            )
            ScrollView {
                LazyVGrid(columns: columns, spacing: metrics.spacing) {
                    ForEach(panes) { pane in
                        PaneCell(pane: pane, now: now) { store.reveal(pane) }
                    }
                }
            }
            .scrollIndicators(.never)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        }
    }

    @ViewBuilder
    private var shells: some View {
        let groups = store.board.shells
        if !groups.isEmpty {
            Text("shells   " + groups.map(\.label).joined(separator: "  ·  "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// One pane. Every cell is the same size so a session keeps its place and
/// the grid doesn't reflow as messages change.
struct PaneCell: View {
    let pane: Pane
    let now: Date
    let reveal: () -> Void

    @State private var hovering = false

    private var color: Color { pane.state.color }

    private var subtitle: String {
        [pane.app, pane.directory].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var badge: String {
        var text = pane.state.rawValue.uppercased()
        if let kind = pane.primary?.kind { text += " · \(kind)" }
        if let progress = pane.primary?.progress { text += " \(progress)%" }
        return text
    }

    var body: some View {
        // A real button, not a tap gesture: the panel can be dragged by its
        // background, and a button is what AppKit reliably treats as "not
        // background" under the pointer.
        Button(action: reveal) { content }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(pane.message.isEmpty ? "Show in Rex" : pane.message)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pane.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Text(badge)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                Spacer()
                if let since = pane.since {
                    Text(Age.short(since: since, now: now))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Text(pane.message)
                .font(.system(size: 12))
                .lineLimit(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        // The panel works its height out from this number; see `GridMetrics`.
        .frame(height: GridMetrics.standard.cellHeight)
        .background(color.opacity(hovering ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(color.opacity(0.75), lineWidth: pane.state == .blocked ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

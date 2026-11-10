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

    var body: some View {
        // Ages tick once a second; the board itself changes only on events.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 8) {
                header
                if let notice = store.notice {
                    Text(notice)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                cells(now: timeline.date)
                shells
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea()
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                    ForEach(panes) { pane in
                        PaneCell(pane: pane, now: now) { store.reveal(pane) }
                    }
                }
            }
            .scrollIndicators(.never)
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
        .frame(height: 122)
        .background(color.opacity(hovering ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(color.opacity(0.75), lineWidth: pane.state == .blocked ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

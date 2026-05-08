// App/UI/DashboardView.swift
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var preferences: Preferences
    let onClickSession: (Session) -> Void

    @State private var flashIds: [String: UUID] = [:]
    @State private var flashCoordinator = FlashCoordinator()
    @State private var now: Date = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let metrics = TileMetrics.resolve(preferences.tileSize)
        let palette = Palette.resolve(preferences.paletteID)

        let sessions = store.visibleSessions

        return Group {
            if sessions.isEmpty {
                emptyState
            } else {
                VerticalFirstGridLayout(
                    tileSize: metrics.tileSize,
                    gutter: metrics.gutter,
                    padding: metrics.padding
                ) {
                    ForEach(sessions) { session in
                        TileView(session: session, now: now, metrics: metrics, palette: palette)
                            .flash(id: flashIds[session.id])
                            .onTapGesture { onClickSession(session) }
                            .contextMenu {
                                Button("Ignore") {
                                    store.ignore(sessionId: session.id)
                                }
                            }
                    }
                }
                .padding(0)
            }
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: store.visibleSessions) { _, new in
            flashIds = flashCoordinator.update(sessions: new)
        }
        .onAppear {
            flashIds = flashCoordinator.update(sessions: store.visibleSessions)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No sessions")
                .font(.headline)
            Text("Start a Claude Code session in a terminal to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
    }
}

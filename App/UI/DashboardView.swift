// App/UI/DashboardView.swift
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: SessionStore
    let onClickSession: (Session) -> Void

    @State private var flashIds: [String: UUID] = [:]
    @State private var flashCoordinator = FlashCoordinator()
    @State private var now: Date = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if store.orderedSessions.isEmpty {
                emptyState
            } else {
                VerticalFirstGridLayout {
                    ForEach(store.orderedSessions) { session in
                        TileView(session: session, now: now)
                            .flash(id: flashIds[session.id])
                            .onTapGesture { onClickSession(session) }
                    }
                }
                .padding(0)
            }
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: store.orderedSessions) { _, new in
            flashIds = flashCoordinator.update(sessions: new)
        }
        .onAppear {
            flashIds = flashCoordinator.update(sessions: store.orderedSessions)
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
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
    }
}

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
                            .draggable(DraggedSessionID(id: session.id)) {
                                TileView(session: session, now: now)
                                    .opacity(0.7)
                            }
                            .dropDestination(for: DraggedSessionID.self) { items, _ in
                                guard let source = items.first,
                                      let targetIdx = store.orderedSessions.firstIndex(where: { $0.id == session.id })
                                else { return false }
                                store.move(sessionId: source.id, toIndex: targetIdx)
                                return true
                            }
                    }
                }
                .padding(0)
            }
        }
        .frame(minWidth: 200, minHeight: 120)
        .onReceive(ticker) { now = $0 }
        .onChange(of: store.orderedSessions) { _, new in
            flashIds = flashCoordinator.update(sessions: new)
        }
        .onAppear {
            flashIds = flashCoordinator.update(sessions: store.orderedSessions)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.headline)
            Text("Start a Claude Code session in a terminal to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

/// Transferable wrapper used by drag-to-reorder.
struct DraggedSessionID: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

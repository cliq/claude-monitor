// iOS/MobileSessionsView.swift
import SwiftUI
import UIKit

/// The iPhone rendering of the Mac's session dashboard: one colored tile per
/// agent session, fed by the LAN bridge's `/sessions`. Tapping a session
/// hosted by Chauffeur opens it in the Chauffeur iPhone app.
struct MobileSessionsView: View {
    @ObservedObject var sessions: SessionsStore
    @ObservedObject var store: UsageStore
    let chooseMac: () -> Void
    @AppStorage("sessionPalette") private var paletteID: PaletteID = .vibrant
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
        }
        .refreshable { await sessions.refresh() }
        .background(UsagePalette.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
    }

    @ViewBuilder
    private var content: some View {
        if store.endpoint == nil {
            placeholder("Choose the Mac running Claude Monitor", action: "Choose Mac")
        } else if let snapshot = sessions.snapshot {
            if snapshot.sessions.isEmpty {
                placeholder("No sessions running on the Mac")
            } else {
                grid(snapshot.sessions)
            }
        } else if let error = sessions.errorMessage {
            placeholder(error, action: "Choose Mac")
        } else {
            placeholder("connecting...")
        }
    }

    private func grid(_ list: [RemoteSession]) -> some View {
        let palette = Palette.resolve(paletteID)
        // Like the Mac's badge rule: label every tile, or none.
        let showBadge = Set(list.map(\.provider)).count > 1
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(list) { session in
                    let link = openableChauffeurURL(session)
                    SessionTile(session: session,
                                elapsed: sessions.elapsed(session, now: context.date),
                                palette: palette,
                                showProviderBadge: showBadge,
                                opensInChauffeur: link != nil)
                        .onTapGesture {
                            if let link { openURL(link) }
                        }
                }
            }
            .padding(12)
        }
    }

    /// The session's Chauffeur link, when the Chauffeur app that owns its
    /// scheme is installed (`LSApplicationQueriesSchemes`).
    private func openableChauffeurURL(_ session: RemoteSession) -> URL? {
        guard let url = session.chauffeurSessionURL, UIApplication.shared.canOpenURL(url) else { return nil }
        return url
    }

    private func placeholder(_ text: String, action: String? = nil) -> some View {
        VStack(spacing: 14) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(UsagePalette.muted)
                .multilineTextAlignment(.center)
            if let action {
                Button(action, action: chooseMac)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sessions.errorMessage == nil && sessions.snapshot != nil ? UsagePalette.okDot : UsagePalette.crit)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(sessions.errorMessage == nil ? UsagePalette.muted : UsagePalette.crit)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 30)
        .background(UsagePalette.statusBg)
    }

    private var statusText: String {
        guard let endpoint = store.endpoint else { return "no Mac selected" }
        if let error = sessions.errorMessage, sessions.snapshot != nil {
            return "\(endpoint.displayName): \(error)"
        }
        guard let count = sessions.snapshot?.sessions.count else { return endpoint.displayName }
        return "\(count) session\(count == 1 ? "" : "s") · \(endpoint.displayName)"
    }
}

/// Picks the tile color palette; shown in the Sessions tab's toolbar.
struct SessionPaletteMenu: View {
    @AppStorage("sessionPalette") private var paletteID: PaletteID = .vibrant

    var body: some View {
        Menu {
            Picker("Colors", selection: $paletteID) {
                ForEach(Palette.all, id: \.id) { palette in
                    Text(palette.displayName).tag(palette.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "paintpalette")
        }
        .accessibilityLabel("Tile colors")
    }
}

/// One session, styled like the Mac's dashboard tile (`TileView`) but sized
/// by the phone's grid instead of a fixed preset.
struct SessionTile: View {
    let session: RemoteSession
    let elapsed: TimeInterval
    let palette: Palette
    var showProviderBadge = false
    var opensInChauffeur = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(session.project)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showProviderBadge {
                    Text(session.provider.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(palette.textColor.opacity(0.18)))
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if opensInChauffeur {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityLabel("Opens in Chauffeur")
                }
                Circle()
                    .fill(palette.textColor)
                    .frame(width: 8, height: 8)
            }
            Text(session.statusLine(elapsed: elapsed))
                .font(.system(size: 12).monospacedDigit())
                .opacity(0.95)
            if let preview = session.promptPreview {
                Text(preview)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .opacity(0.85)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .foregroundStyle(palette.textColor)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(palette.backgroundColor(for: session.state))
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 2)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(opensInChauffeur ? .isButton : [])
    }
}

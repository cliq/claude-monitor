// App/UI/AppearanceSettingsView.swift
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            sizeSection
            paletteSection
        }
        .padding(20)
    }

    // MARK: - Tile size

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tile size").font(.headline)
            Text("How big each card appears on the dashboard. Font sizes scale along with the card.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Tile size", selection: $preferences.tileSize) {
                ForEach(TileSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Palette

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color palette").font(.headline)
            Text("Colors used for each session state. Applies live; click a palette to switch.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                spacing: 10
            ) {
                ForEach(Palette.all, id: \.id) { palette in
                    PaletteSwatch(palette: palette,
                                  isSelected: preferences.paletteID == palette.id) {
                        preferences.paletteID = palette.id
                    }
                }
            }
        }
    }
}

private struct PaletteSwatch: View {
    let palette: Palette
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 2) {
                        palette.backgroundColor(for: .working)
                        palette.backgroundColor(for: .waiting)
                        palette.backgroundColor(for: .needsYou)
                        palette.backgroundColor(for: .finished)
                    }
                    .frame(height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(2)
                            .accessibilityHidden(true)
                    }
                }

                Text(palette.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(palette.displayName) palette")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// App/UI/TileView.swift
import SwiftUI

struct TileView: View {
    let session: Session
    let now: Date   // passed in so elapsed time ticks from a shared clock
    let metrics: TileMetrics
    let palette: Palette

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: metrics.cornerRadius)
                .fill(palette.backgroundColor(for: session.state))
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(session.projectName)
                        .font(.system(size: metrics.titlePointSize, weight: metrics.titleWeight))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(palette.textColor)
                        .frame(width: metrics.dotSize, height: metrics.dotSize)
                }
                Text("\(session.state.displayLabel) · \(elapsed)")
                    .font(.system(size: metrics.statusPointSize, weight: .regular).monospacedDigit())
                    .opacity(0.95)
                if let preview = session.lastPromptPreview {
                    Text(preview)
                        .font(.system(size: metrics.previewPointSize, weight: metrics.previewWeight))
                        .lineSpacing(metrics.previewLineSpacing)
                        .lineLimit(3)
                        .opacity(0.85)
                        .padding(.top, 2)
                }
            }
            .padding(metrics.padding)
            .foregroundStyle(palette.textColor)
        }
        .frame(width: metrics.tileSize.width, height: metrics.tileSize.height)
        .contentShape(Rectangle())
        .accessibilityLabel(session.projectName)
        .accessibilityIdentifier("tile-\(session.projectName)")
    }

    private var elapsed: String {
        let secs = max(0, Int(now.timeIntervalSince(session.enteredStateAt)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

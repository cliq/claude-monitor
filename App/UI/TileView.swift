// App/UI/TileView.swift
import SwiftUI

struct TileView: View {
    let session: Session
    let now: Date   // passed in so elapsed time ticks from a shared clock

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(session.state.tileColor)
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 8, height: 8)
                }
                Text("\(session.state.displayLabel) · \(elapsed)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .opacity(0.95)
                if let preview = session.lastPromptPreview {
                    Text(preview)
                        .font(.system(size: 9))
                        .lineLimit(3)
                        .opacity(0.85)
                        .padding(.top, 2)
                }
            }
            .padding(8)
            .foregroundColor(.white)
        }
        .frame(width: 160, height: 80)
        .contentShape(Rectangle())
    }

    private var elapsed: String {
        let secs = max(0, Int(now.timeIntervalSince(session.enteredStateAt)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

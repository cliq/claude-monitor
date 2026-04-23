// App/UI/FlashModifier.swift
import SwiftUI

struct FlashModifier: ViewModifier {
    let flashId: UUID?
    @State private var phase: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .opacity(phase)
            .onChange(of: flashId) { _, _ in
                guard flashId != nil else { return }
                Task {
                    let steps: [(CGFloat, UInt64)] = [
                        (0.7, 150_000_000),
                        (1.0, 150_000_000),
                        (0.7, 150_000_000),
                        (1.0, 150_000_000),
                    ]
                    for (target, delay) in steps {
                        withAnimation(.easeInOut(duration: 0.15)) { phase = target }
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    phase = 1
                }
            }
    }
}

extension View {
    func flash(id: UUID?) -> some View { modifier(FlashModifier(flashId: id)) }
}

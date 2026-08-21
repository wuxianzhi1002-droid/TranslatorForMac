import SwiftUI

struct TranslationButton: View {
    let isEnabled: Bool
    let isTranslating: Bool
    let autoSubmitPhase: AutoSubmitPhase
    let action: () -> Void

    private let scale: CGFloat = 2.0 / 3.0

    private var countdownStartedAt: Date? {
        if case .countdown(let startedAt) = autoSubmitPhase {
            return startedAt
        }
        return nil
    }

    var body: some View {
        ZStack {
            if let countdownStartedAt {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let elapsed = context.date.timeIntervalSince(countdownStartedAt)
                    let progress = max(0, min(1, 1 - elapsed / 5.0))
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 68 * scale, height: 68 * scale)
                .transition(.opacity)
            }

            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(isEnabled ? Color.accentColor : Color.secondary.opacity(0.42))
                    Circle()
                        .strokeBorder(.white.opacity(isEnabled ? 0.28 : 0.12), lineWidth: 1)

                    Image(systemName: "play.fill")
                        .font(.system(size: 22 * scale, weight: .semibold))
                        .foregroundStyle(isEnabled ? .white : .white.opacity(0.5))
                        .offset(x: 2 * scale)
                        .opacity(isTranslating ? 0.55 : 1)
                }
                .frame(width: 56 * scale, height: 56 * scale)
            }
            .buttonStyle(FloatingCircleButtonStyle())
            .disabled(!isEnabled)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(isEnabled ? "翻译（⌘↩）" : "当前没有可提交的新内容")
            .accessibilityLabel("翻译")
        }
        .frame(width: 76 * scale, height: 76 * scale)
        .animation(.easeInOut(duration: 0.18), value: countdownStartedAt != nil)
    }
}

private struct FloatingCircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .shadow(
                color: .black.opacity(isEnabled ? 0.32 : 0.12),
                radius: configuration.isPressed ? 3.3 : 8,
                y: configuration.isPressed ? 1.3 : 4.7
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

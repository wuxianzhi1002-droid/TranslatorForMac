import SwiftUI

struct TranslationButton: View {
    let isEnabled: Bool
    let isTranslating: Bool
    let action: () -> Void

    private let scale: CGFloat = 2.0 / 3.0

    var body: some View {
        ZStack {
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

import AppKit
import SwiftUI

@MainActor
final class SelectionDotWindowController: NSWindowController {
    private let onHover: (Bool) -> Void

    init(onHover: @escaping (Bool) -> Void) {
        self.onHover = onHover
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: SelectionDotView(onHover: onHover))
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isMouseInside: Bool {
        guard let window, window.isVisible else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    func show(at point: NSPoint) {
        guard let window else { return }
        window.setFrameOrigin(NSPoint(x: point.x + 10, y: point.y - 34))
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }
}

private struct SelectionDotView: View {
    let onHover: (Bool) -> Void

    var body: some View {
        Circle()
            .fill(Color(red: 0.94, green: 0.20, blue: 0.22))
            .frame(width: 15, height: 15)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .onHover(perform: onHover)
            .help("悬停以翻译选中文字")
    }
}

import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        let rootView = MainView(appState: appState)
        let hostingController = NSHostingController(rootView: rootView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 390),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 620, height: 350)

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

    func showNear(_ point: NSPoint) {
        guard let window else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        var origin = NSPoint(x: point.x + 24, y: point.y - window.frame.height - 12)
        if origin.x + window.frame.width > visible.maxX { origin.x = point.x - window.frame.width - 24 }
        if origin.x < visible.minX { origin.x = visible.minX + 8 }
        if origin.y < visible.minY { origin.y = min(point.y + 24, visible.maxY - window.frame.height) }
        if origin.y + window.frame.height > visible.maxY { origin.y = visible.maxY - window.frame.height - 8 }
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func setAlwaysOnTop(_ isEnabled: Bool) {
        window?.level = isEnabled ? .floating : .normal
    }
}

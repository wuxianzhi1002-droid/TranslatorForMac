import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        let rootView = MainView(appState: appState)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "AI 翻译工具"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 820, height: 380)
        window.isReleasedWhenClosed = false
        window.level = appState.settings.alwaysOnTop ? .floating : .normal
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindowAndActivate() {
        guard let window else { return }
        let wasVisible = window.isVisible
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !wasVisible {
            appState.mainWindowDidOpen()
        }
    }

    func setAlwaysOnTop(_ isEnabled: Bool) {
        window?.level = isEnabled ? .floating : .normal
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        appState.mainWindowDidHide()
        return false
    }
}

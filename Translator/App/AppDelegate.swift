import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var statusItem: NSStatusItem?
    private var translationWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var selectionDotWindowController: SelectionDotWindowController?
    private let selectionMonitor = SelectionMonitor()
    private var panelHideTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()

        appState.onOpenSettings = { [weak self] in self?.showSettings() }
        appState.onAlwaysOnTopChanged = { [weak self] enabled in
            self?.translationWindowController?.setAlwaysOnTop(enabled)
        }
        appState.onTranslationPanelHoverChanged = { [weak self] isInside in
            self?.handleTranslationPanelHover(isInside)
        }

        selectionDotWindowController = SelectionDotWindowController { [weak self] isInside in
            guard isInside else { return }
            self?.showTranslationPanel()
        }
        selectionMonitor.start { [weak self] selection in
            self?.handleSelectionChange(selection)
        }

        if !appState.configurationReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showSettings()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelHideTask?.cancel()
        selectionMonitor.stop()
        appState.cancelAllWork()
    }

    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(appState: appState)
        }
        settingsWindowController?.showWindowAndActivate()
    }

    @objc private func requestAccessibilityPermission() {
        _ = SelectionMonitor.requestAccessibilityPermission(prompt: true)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            showSettings()
            return
        }
        if event.type == .rightMouseUp {
            showStatusMenu(relativeTo: sender)
        } else {
            showSettings()
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "character.book.closed",
                accessibilityDescription: "AI 划词翻译"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "AI 划词翻译：选择文字后悬停红点"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func showStatusMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()
        let permissionItem = NSMenuItem(title: "启用划词辅助功能权限…", action: #selector(requestAccessibilityPermission), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 AI 划词翻译", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func handleSelectionChange(_ selection: TextSelection?) {
        guard let selection else {
            selectionDotWindowController?.hide()
            translationWindowController?.hide()
            return
        }
        appState.loadSelectedText(selection.text)
        translationWindowController?.hide()
        selectionDotWindowController?.show(at: selection.screenPoint)
    }

    private func showTranslationPanel() {
        guard appState.configurationReady, !appState.sourceText.isEmpty else {
            showSettings()
            return
        }
        panelHideTask?.cancel()
        if translationWindowController == nil {
            translationWindowController = MainWindowController(appState: appState)
        }
        translationWindowController?.showNear(NSEvent.mouseLocation)
        translationWindowController?.setAlwaysOnTop(appState.settings.alwaysOnTop)
        appState.translateCurrentSelection()
    }

    private func handleTranslationPanelHover(_ isInside: Bool) {
        if isInside {
            panelHideTask?.cancel()
            panelHideTask = nil
            return
        }
        panelHideTask?.cancel()
        panelHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self,
                  self.translationWindowController?.isMouseInside != true,
                  self.selectionDotWindowController?.isMouseInside != true else { return }
            self.translationWindowController?.hide()
            self.panelHideTask = nil
        }
    }
}

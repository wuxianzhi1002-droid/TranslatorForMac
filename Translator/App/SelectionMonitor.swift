import AppKit
import ApplicationServices

struct TextSelection: Equatable {
    let text: String
    let screenPoint: NSPoint
}

@MainActor
final class SelectionMonitor {
    private var timer: Timer?
    private var onSelectionChanged: ((TextSelection?) -> Void)?
    private var candidateKey: String?
    private var candidateStartedAt = Date.distantPast
    private var deliveredKey: String?
    private var missingSelectionStartedAt: Date?
    private var lastPointerLocation = NSEvent.mouseLocation

    static func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start(onSelectionChanged: @escaping (TextSelection?) -> Void) {
        stop()
        self.onSelectionChanged = onSelectionChanged
        _ = Self.requestAccessibilityPermission(prompt: true)

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onSelectionChanged = nil
        candidateKey = nil
        deliveredKey = nil
        missingSelectionStartedAt = nil
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let systemElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemElement, 0.05)

        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
        let focusedElement = focusedElementValue as? AXUIElement else {
            observeMissingSelection()
            return
        }

        var focusedPID: pid_t = 0
        AXUIElementGetPid(focusedElement, &focusedPID)
        if focusedPID == ProcessInfo.processInfo.processIdentifier { return }

        var selectedTextValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        ) == .success,
        let selectedText = selectedTextValue as? String,
        !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            observeMissingSelection()
            return
        }

        missingSelectionStartedAt = nil
        let pointer = NSEvent.mouseLocation
        let pointKey = "\(Int(pointer.x / 8)):\(Int(pointer.y / 8))"
        let key = "\(focusedPID)|\(selectedText)|\(pointKey)"
        if key != candidateKey {
            candidateKey = key
            candidateStartedAt = Date()
            lastPointerLocation = pointer
            deliveredKey = nil
            onSelectionChanged?(nil)
            return
        }

        lastPointerLocation = pointer
        guard deliveredKey != key,
              Date().timeIntervalSince(candidateStartedAt) >= 0.12 else { return }
        deliveredKey = key
        onSelectionChanged?(TextSelection(text: selectedText, screenPoint: lastPointerLocation))
    }

    private func observeMissingSelection() {
        candidateKey = nil
        deliveredKey = nil
        if let missingSelectionStartedAt {
            if Date().timeIntervalSince(missingSelectionStartedAt) >= 0.28 {
                onSelectionChanged?(nil)
                missingSelectionStartedAt = nil
            }
            return
        }
        missingSelectionStartedAt = Date()
    }
}

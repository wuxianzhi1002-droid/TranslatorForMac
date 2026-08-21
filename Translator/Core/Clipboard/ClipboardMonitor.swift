import AppKit
import Foundation

struct ClipboardSnapshot: Equatable {
    let changeCount: Int
    let text: String?
}

@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastObservedChangeCount = NSPasteboard.general.changeCount
    private var onChange: ((ClipboardSnapshot) -> Void)?

    var currentSnapshot: ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        return ClipboardSnapshot(
            changeCount: pasteboard.changeCount,
            text: pasteboard.string(forType: .string)
        )
    }

    func start(onChange: @escaping (ClipboardSnapshot) -> Void) {
        stop()
        self.onChange = onChange
        lastObservedChangeCount = NSPasteboard.general.changeCount

        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onChange = nil
    }

    func markCurrentAsObserved() {
        lastObservedChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let snapshot = currentSnapshot
        guard snapshot.changeCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = snapshot.changeCount
        onChange?(snapshot)
    }
}

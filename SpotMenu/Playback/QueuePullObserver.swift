import AppKit
import SwiftUI

struct QueuePullGesture {
    private var distance: CGFloat = 0
    private var refreshed = false

    mutating func shouldRefresh(delta: CGFloat, phase: NSEvent.Phase, atBottom: Bool) -> Bool {
        if phase.contains(.began) {
            self = Self()
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            self = Self()
            return false
        }
        guard !refreshed, phase.contains(.began) || phase.contains(.changed) else {
            return false
        }
        guard atBottom, delta < 0 else {
            distance = 0
            return false
        }

        distance -= delta
        guard distance >= 48 else { return false }
        refreshed = true
        return true
    }
}

struct QueuePullObserver: NSViewRepresentable {
    let atBottom: Bool
    let refresh: () -> Void

    func makeNSView(context: Context) -> Observer {
        Observer()
    }

    func updateNSView(_ view: Observer, context: Context) {
        view.atBottom = atBottom
        view.refresh = refresh
    }

    final class Observer: NSView {
        var atBottom = false
        var refresh: (() -> Void)?
        private var monitor: Any?
        private var gesture = QueuePullGesture()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            gesture = QueuePullGesture()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.observe(event)
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func observe(_ event: NSEvent) {
            guard let window, event.window === window,
                event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
                bounds.contains(convert(event.locationInWindow, from: nil))
            else { return }

            if gesture.shouldRefresh(delta: event.scrollingDeltaY, phase: event.phase, atBottom: atBottom) {
                refresh?()
            }
        }
    }
}

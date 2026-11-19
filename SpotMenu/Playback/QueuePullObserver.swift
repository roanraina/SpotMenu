import AppKit
import SwiftUI

struct QueuePullGesture {
    private var distance: CGFloat = 0
    private var refreshed = false
    private var lastWheelEvent: TimeInterval?

    mutating func shouldRefresh(
        delta: CGFloat, phase: NSEvent.Phase, atTop: Bool, timestamp: TimeInterval
    ) -> Bool {
        if phase.contains(.began) {
            self = Self()
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            self = Self()
            return false
        }
        if phase.isEmpty {
            if lastWheelEvent.map({ timestamp - $0 > 0.25 }) != false {
                self = Self()
            }
            lastWheelEvent = timestamp
        }
        guard !refreshed, phase.isEmpty || phase.contains(.began) || phase.contains(.changed) else {
            return false
        }
        guard atTop, delta > 0 else {
            distance = 0
            return false
        }

        distance += delta
        guard distance >= 48 else { return false }
        refreshed = true
        return true
    }
}

struct QueuePullObserver: NSViewRepresentable {
    let atTop: Bool
    let refresh: () -> Void

    func makeNSView(context: Context) -> Observer {
        Observer()
    }

    func updateNSView(_ view: Observer, context: Context) {
        view.atTop = atTop
        view.refresh = refresh
    }

    final class Observer: NSView {
        var atTop = false
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
            guard let window, window.isVisible, event.momentumPhase.isEmpty,
                event.window == nil || event.window === window
            else { return }

            let location = event.window == nil
                ? window.convertPoint(fromScreen: NSEvent.mouseLocation) : event.locationInWindow
            guard bounds.contains(convert(location, from: nil)) else { return }
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
            if gesture.shouldRefresh(
                delta: delta, phase: event.phase, atTop: atTop, timestamp: event.timestamp
            ) {
                refresh?()
            }
        }
    }
}

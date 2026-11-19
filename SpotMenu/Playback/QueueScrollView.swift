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

struct QueueScrollView<Content: View>: NSViewRepresentable {
    let viewport: CGSize
    let refresh: () -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> NSHostingView<Content> {
        NSHostingView(rootView: content())
    }

    func makeNSView(context: Context) -> QueueScrollContainer {
        let scrollView = QueueScrollContainer()
        scrollView.install(context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: QueueScrollContainer, context: Context) {
        let hosted = context.coordinator
        hosted.rootView = content()
        scrollView.refresh = refresh
        scrollView.fit(hosted, to: viewport)
    }
}

final class QueueScrollContainer: NSScrollView {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    private var pull = QueuePullGesture()
    var refresh: (() -> Void)?

    func install(_ hosted: NSView) {
        drawsBackground = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        verticalScrollElasticity = .allowed

        let document = Document()
        document.addSubview(hosted)
        documentView = document
    }

    func fit(_ hosted: NSView, to viewport: CGSize) {
        guard let documentView else { return }
        let size = CGSize(width: viewport.width, height: max(viewport.height, hosted.fittingSize.height))
        guard documentView.frame.size != size || hosted.frame.size != size else { return }

        let offset = min(max(0, contentView.bounds.minY), max(0, size.height - viewport.height))
        documentView.setFrameSize(size)
        hosted.frame = documentView.bounds
        contentView.scroll(to: CGPoint(x: 0, y: offset))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase.isEmpty {
            let top = documentView?.bounds.minY ?? 0
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
            if pull.shouldRefresh(
                delta: delta, phase: event.phase,
                atTop: contentView.bounds.minY <= top + 2, timestamp: event.timestamp
            ) {
                refresh?()
            }
        }
        super.scrollWheel(with: event)
    }
}

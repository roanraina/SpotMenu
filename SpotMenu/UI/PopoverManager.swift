import SwiftUI

class PopoverManager {
    private static let queueGap: CGFloat = 6
    private let window: PopoverWindow
    private let makeQueueWindow: (@escaping (Bool) -> Void) -> PopoverWindow
    private let onQueueVisibilityChanged: (Bool) -> Void
    private var queueWindow: PopoverWindow?
    private var queueDismissTimer: Timer?

    init<Content: View, QueueContent: View>(
        contentView: Content,
        queueContent: @escaping () -> QueueContent,
        onQueueVisibilityChanged: @escaping (Bool) -> Void
    ) {
        self.window = PopoverWindow(rootView: contentView)
        self.makeQueueWindow = { onHover in
            PopoverWindow(
                rootView: queueContent()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onHover(perform: onHover)
            )
        }
        self.onQueueVisibilityChanged = onQueueVisibilityChanged
    }

    func toggle(relativeTo button: NSStatusBarButton?, reserveQueueSpace: Bool) {
        guard let button = button else { return }

        if window.isVisible {
            dismiss()
        } else {
            show(relativeTo: button, reserveQueueSpace: reserveQueueSpace)
        }
    }

    private func show(relativeTo button: NSStatusBarButton, reserveQueueSpace: Bool) {
        guard let buttonWindow = button.window,
            let screen = buttonWindow.screen
        else { return }

        let buttonFrame = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )

        let popoverSize = window.frame.size

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let spacingBelowMenuBar: CGFloat = 0
        let totalOffset = menuBarHeight + spacingBelowMenuBar

        let popoverY = screen.frame.maxY - totalOffset - popoverSize.height
        let popoverX = Self.playbackX(
            centeredAt: buttonFrame.midX, width: popoverSize.width,
            visibleFrame: screen.visibleFrame, reserveQueueSpace: reserveQueueSpace
        )

        window.setFrameOrigin(NSPoint(x: popoverX, y: popoverY))
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
    }

    func queueTriggerHovered(_ hovering: Bool) {
        if hovering {
            showQueue()
        } else {
            scheduleQueueDismissal()
        }
    }

    func showQueue() {
        queueDismissTimer?.invalidate()
        guard queueWindow == nil, window.isVisible, let screen = window.screen else {
            return
        }

        let queue = makeQueueWindow { [weak self] hovering in
            if hovering {
                self?.queueDismissTimer?.invalidate()
            } else {
                self?.scheduleQueueDismissal()
            }
        }
        let origin = Self.queueOrigin(
            beside: window.frame, queueWidth: queue.frame.width, visibleFrame: screen.visibleFrame
        )
        queue.setFrameOrigin(origin)
        queueWindow = queue
        window.addChildWindow(queue, ordered: .above)
        queue.orderFront(nil)
        onQueueVisibilityChanged(true)
    }

    private func scheduleQueueDismissal() {
        queueDismissTimer?.invalidate()
        guard queueWindow != nil else { return }
        // Let the pointer cross from the icon to the adjacent window.
        queueDismissTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) {
            [weak self] _ in
            guard let self, let queue = self.queueWindow,
                !queue.frame.contains(NSEvent.mouseLocation)
            else { return }
            self.dismissQueue()
        }
    }

    func dismissQueue() {
        queueDismissTimer?.invalidate()
        queueDismissTimer = nil
        guard let queue = queueWindow else { return }
        queueWindow = nil
        window.removeChildWindow(queue)
        queue.orderOut(nil)
        onQueueVisibilityChanged(false)
    }

    static func playbackX(
        centeredAt anchor: CGFloat, width: CGFloat, visibleFrame: CGRect,
        reserveQueueSpace: Bool
    ) -> CGFloat {
        let combinedWidth = width * 2 + queueGap
        let reservedWidth = reserveQueueSpace && combinedWidth <= visibleFrame.width
            ? combinedWidth : width
        return max(visibleFrame.minX, min(anchor - width / 2, visibleFrame.maxX - reservedWidth))
    }

    static func queueOrigin(beside playback: CGRect, queueWidth: CGFloat, visibleFrame: CGRect) -> CGPoint {
        let right = playback.maxX + queueGap
        let left = playback.minX - queueGap - queueWidth
        let x = right + queueWidth <= visibleFrame.maxX || left < visibleFrame.minX
            ? min(right, visibleFrame.maxX - queueWidth)
            : left
        return CGPoint(x: max(visibleFrame.minX, x), y: playback.minY)
    }

    func dismiss() {
        dismissQueue()
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        } completionHandler: {
            self.window.orderOut(nil)
            self.window.alphaValue = 1
        }
    }
}

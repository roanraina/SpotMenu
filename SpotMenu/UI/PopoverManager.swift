import SwiftUI

class PopoverManager {
    private static let queueGap: CGFloat = 6
    private static let queueDismissDelay: TimeInterval = 7
    private static let queueSlideDuration: TimeInterval = 0.5
    private let window: PopoverWindow
    private let makeQueueWindow: (@escaping (Bool) -> Void) -> PopoverWindow
    private let onPlaybackVisibilityChanged: (Bool) -> Void
    private let onQueueVisibilityChanged: (Bool) -> Void
    private var queueWindow: PopoverWindow?
    private var queueDismissTimer: Timer?
    private var queueCloseID: UUID?
    private var isQueueTriggerHovered = false
    private(set) var isPlaybackVisible = false

    init<Content: View, QueueContent: View>(
        contentView: Content,
        queueContent: @escaping () -> QueueContent,
        onPlaybackVisibilityChanged: @escaping (Bool) -> Void,
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
        self.onPlaybackVisibilityChanged = onPlaybackVisibilityChanged
        self.onQueueVisibilityChanged = onQueueVisibilityChanged
    }

    func toggle(relativeTo button: NSStatusBarButton?, reserveQueueSpace: Bool) {
        guard let button = button else { return }

        if isPlaybackVisible {
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
        isPlaybackVisible = true
        onPlaybackVisibilityChanged(true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
    }

    func queueTriggerHovered(_ hovering: Bool) {
        isQueueTriggerHovered = hovering && isPlaybackVisible
        if isQueueTriggerHovered {
            showQueue()
        } else {
            scheduleQueueDismissal()
        }
    }

    func showQueue() {
        guard isPlaybackVisible, let screen = window.screen else { return }
        queueDismissTimer?.invalidate()
        if queueWindow != nil, queueCloseID == nil {
            scheduleQueueDismissal()
            return
        }

        let queue = queueWindow ?? makeQueueWindow { [weak self] hovering in
            guard let self, self.queueCloseID == nil else { return }
            if hovering {
                self.queueDismissTimer?.invalidate()
            } else {
                self.scheduleQueueDismissal()
            }
        }
        let origin = Self.queueOrigin(
            beside: window.frame, queueWidth: queue.frame.width, visibleFrame: screen.visibleFrame
        )
        if queueWindow == nil {
            queue.alphaValue = 0
            queue.setFrameOrigin(queueHiddenOrigin(queueWidth: queue.frame.width))
            queueWindow = queue
            window.addChildWindow(queue, ordered: .below)
            onQueueVisibilityChanged(true)
        }
        queueCloseID = nil
        queue.ignoresMouseEvents = false
        animateQueue(queue, to: origin, opacity: 1)
        scheduleQueueDismissal()
    }

    private func scheduleQueueDismissal() {
        queueDismissTimer?.invalidate()
        guard queueWindow != nil, queueCloseID == nil, !isQueueTriggerHovered else { return }
        queueDismissTimer = Timer.scheduledTimer(withTimeInterval: Self.queueDismissDelay, repeats: false) {
            [weak self] _ in
            guard let self, let queue = self.queueWindow,
                !self.isQueueTriggerHovered, !queue.frame.contains(NSEvent.mouseLocation)
            else { return }
            self.dismissQueue()
        }
    }

    func dismissQueue() {
        queueDismissTimer?.invalidate()
        queueDismissTimer = nil
        guard let queue = queueWindow, queueCloseID == nil else { return }

        let closeID = UUID()
        queueCloseID = closeID
        queue.ignoresMouseEvents = true
        let origin = queueHiddenOrigin(queueWidth: queue.frame.width)
        animateQueue(queue, to: origin, opacity: 0) { [weak self, weak queue] in
            guard let self, let queue, self.queueCloseID == closeID else { return }
            self.queueCloseID = nil
            self.queueWindow = nil
            self.window.removeChildWindow(queue)
            queue.orderOut(nil)
            self.onQueueVisibilityChanged(false)
        }
    }

    private func queueHiddenOrigin(queueWidth: CGFloat) -> CGPoint {
        CGPoint(x: window.frame.midX - queueWidth / 2, y: window.frame.minY)
    }

    private func animateQueue(
        _ queue: PopoverWindow, to origin: CGPoint, opacity: CGFloat, completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.queueSlideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            queue.animator().setFrame(NSRect(origin: origin, size: queue.frame.size), display: true)
            queue.animator().alphaValue = opacity
        }, completionHandler: completion)
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
        isQueueTriggerHovered = false
        dismissQueue()
        guard isPlaybackVisible else { return }
        isPlaybackVisible = false
        onPlaybackVisibilityChanged(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        } completionHandler: {
            guard !self.isPlaybackVisible else { return }
            self.window.orderOut(nil)
            self.window.alphaValue = 1
        }
    }
}

import AppKit
import SwiftUI

struct ZoomPanOverlay: NSViewRepresentable {
    let onZoom: (_ factor: CGFloat, _ center: CGPoint) -> Void
    let onPanDelta: (_ dx: CGFloat, _ dy: CGFloat) -> Void
    let onMiddleClick: (_ location: CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = OverlayNSView()
        context.coordinator.overlayView = view
        context.coordinator.onZoom = onZoom
        context.coordinator.onPanDelta = onPanDelta
        context.coordinator.onMiddleClick = onMiddleClick
        context.coordinator.installMonitors()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onZoom = onZoom
        context.coordinator.onPanDelta = onPanDelta
        context.coordinator.onMiddleClick = onMiddleClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitors()
    }

    final class OverlayNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator: @unchecked Sendable {
        // All access is from the main thread:
        // NSViewRepresentable methods + NSEvent monitor callbacks
        weak var overlayView: NSView?
        var onZoom: ((_ factor: CGFloat, _ center: CGPoint) -> Void)?
        var onPanDelta: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
        var onMiddleClick: ((_ location: CGPoint) -> Void)?

        private var monitors: [Any] = []
        private var middleMouseDownLocation: CGPoint?
        private var didDrag = false
        private let dragThreshold: CGFloat = 3.0

        func installMonitors() {
            guard monitors.isEmpty else { return }

            let middleDown = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                self?.handleOtherMouseDown(event)
                return event
            }
            let middleDrag = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDragged) { [weak self] event in
                self?.handleOtherMouseDragged(event)
                return event
            }
            let middleUp = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
                self?.handleOtherMouseUp(event)
                return event
            }
            let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                if self.locationInView(event) != nil {
                    self.handleScrollWheel(event)
                    return nil // Consume event so parent views don't scroll
                }
                return event
            }
            let magnify = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self else { return event }
                if let loc = self.locationInView(event) {
                    self.onZoom?(event.magnification, loc)
                    return nil
                }
                return event
            }

            monitors = [middleDown, middleDrag, middleUp, scroll, magnify].compactMap { $0 }
        }

        func removeMonitors() {
            for monitor in monitors {
                NSEvent.removeMonitor(monitor)
            }
            monitors.removeAll()
        }

        deinit {
            for monitor in monitors {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func locationInView(_ event: NSEvent) -> CGPoint? {
            guard let view = overlayView else { return nil }
            let locInWindow = event.locationInWindow
            // Event monitors always callback on the main thread, safe to access NSView
            return MainActor.assumeIsolated {
                let locInView = view.convert(locInWindow, from: nil)
                guard view.bounds.contains(locInView) else { return nil as CGPoint? }
                return CGPoint(x: locInView.x, y: view.bounds.height - locInView.y)
            }
        }

        private func handleOtherMouseDown(_ event: NSEvent) {
            guard event.buttonNumber == 2, let loc = locationInView(event) else { return }
            middleMouseDownLocation = loc
            didDrag = false
        }

        private func handleOtherMouseDragged(_ event: NSEvent) {
            guard event.buttonNumber == 2, middleMouseDownLocation != nil else { return }
            if !didDrag {
                if let loc = locationInView(event), let start = middleMouseDownLocation {
                    if hypot(loc.x - start.x, loc.y - start.y) > dragThreshold {
                        didDrag = true
                    }
                }
            }
            if didDrag {
                // deltaX positive = mouse moved right, deltaY positive = mouse moved up (AppKit)
                // SwiftUI Y increases downward, so negate deltaY
                onPanDelta?(event.deltaX, -event.deltaY)
            }
        }

        private func handleOtherMouseUp(_ event: NSEvent) {
            guard event.buttonNumber == 2 else { return }
            if !didDrag, let loc = middleMouseDownLocation {
                onMiddleClick?(loc)
            }
            middleMouseDownLocation = nil
            didDrag = false
        }

        private func handleScrollWheel(_ event: NSEvent) {
            guard let loc = locationInView(event) else { return }
            var delta = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                delta *= 3 // Amplify discrete scroll wheel clicks
            }
            onZoom?(delta * 0.01, loc)
        }
    }
}

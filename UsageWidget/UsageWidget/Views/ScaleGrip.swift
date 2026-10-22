import AppKit
import SwiftUI

/// Bottom-right grip that zooms the widget. Uses screen-space mouse positions, since the
/// view itself moves and scales while it's being dragged.
struct ScaleGrip: NSViewRepresentable {
    let scale: Double
    let onChange: (Double) -> Void

    final class GripView: NSView {
        var scale = 1.0
        var onChange: ((Double) -> Void)?
        private var startScale = 1.0
        private var startMouse = NSPoint.zero
        private var startSize = NSSize(width: 1, height: 1)

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            startScale = scale
            startMouse = NSEvent.mouseLocation
            startSize = window?.frame.size ?? NSSize(width: 1, height: 1)
        }

        override func mouseDragged(with event: NSEvent) {
            let mouse = NSEvent.mouseLocation
            // Right and down both grow; average the two so diagonal drags feel natural
            let grow = ((mouse.x - startMouse.x) / startSize.width + (startMouse.y - mouse.y) / startSize.height) / 2
            let range = StatsViewModel.scaleRange
            let newScale = min(max(startScale * (1 + grow), range.lowerBound), range.upperBound)
            onChange?((newScale * 100).rounded() / 100)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.35).setStroke()
            for inset in [3.0, 7.0] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + inset))
                path.line(to: NSPoint(x: bounds.minX + inset, y: bounds.maxY - 3))
                path.lineWidth = 1.2
                path.stroke()
            }
        }
    }

    func makeNSView(context: Context) -> GripView { GripView() }

    func updateNSView(_ view: GripView, context: Context) {
        view.scale = scale
        view.onChange = onChange
    }
}

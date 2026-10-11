import AppKit

/// Pure geometry, including displays to the left/below the primary display.
enum WindowGeometry {
    static func constrain(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        let width = min(max(1, frame.width), max(1, visibleFrame.width))
        let height = min(max(1, frame.height), max(1, visibleFrame.height))
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
    @MainActor static func screen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let x = frame.intersection(a.frame), y = frame.intersection(b.frame)
            return (x.isNull ? 0 : x.width*x.height) < (y.isNull ? 0 : y.width*y.height)
        } ?? NSScreen.main
    }
}

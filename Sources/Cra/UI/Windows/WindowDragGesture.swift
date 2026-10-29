import AppKit

/// A press on Arc's title-bar stand-ins (the toolbar, its URL, the sidebar's top strip): a
/// click acts, a drag past 3 pt moves the browser window. In the floating sidebar the press
/// lands in its child panel, and `performDrag` there tears the panel off the window, so the
/// browser window is moved by hand instead (the panel follows it as a child window).
@MainActor
struct WindowDragGesture {
    private var press: NSEvent?
    private var dragging = false
    private var lastMouse = NSPoint.zero

    mutating func begin(_ event: NSEvent) {
        press = event
        dragging = false
    }

    mutating func drag(_ event: NSEvent) {
        guard let press, let window = press.window else { return }
        if !dragging {
            guard hypot(event.locationInWindow.x - press.locationInWindow.x,
                        event.locationInWindow.y - press.locationInWindow.y) > 3 else { return }
            dragging = true
            guard window.parent != nil else {
                // A panel the sidebar has left meanwhile is no browser window.
                if !(window is NSPanel) { window.performDrag(with: press) }
                return
            }
            lastMouse = window.convertPoint(toScreen: press.locationInWindow)
        }
        guard let owner = window.parent, owner.isMovable, !owner.styleMask.contains(.fullScreen) else { return }
        let mouse = NSEvent.mouseLocation
        owner.setFrameOrigin(NSPoint(x: owner.frame.minX + mouse.x - lastMouse.x, y: owner.frame.minY + mouse.y - lastMouse.y))
        lastMouse = mouse
    }

    /// True when the press ended as a click. `performDrag` can swallow the mouse-up; the next
    /// `begin` starts over then.
    mutating func finish() -> Bool {
        defer { press = nil; dragging = false }
        return press != nil && !dragging
    }
}

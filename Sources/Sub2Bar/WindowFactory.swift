import AppKit

@MainActor
enum WindowFactory {
    static func settings() -> NSWindow {
        makeWindow(title: "Sub2Bar 设置", size: NSSize(width: 760, height: 620), miniaturizable: true)
    }

    private static func makeWindow(title: String, size: NSSize, miniaturizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if miniaturizable { style.insert(.miniaturizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.title = title
        // The visual effect belongs to the content area, not the window's
        // backing surface. A transparent titlebar over a clear window leaves
        // uncovered pixels that WindowServer can treat as click-through.
        // Keep native chrome painted and interactive, including traffic lights.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.ignoresMouseEvents = false
        window.isMovable = true
        window.isReleasedWhenClosed = false
        return window
    }
}

//
//  CursorOverlay.swift
//  DrawPad
//
//  A floating, click-through NSPanel that follows the synthesized mouse
//  position. macOS does not draw a system cursor for CGEventPost-synthesized
//  moves, so without this the user has no idea where the pen is hovering.
//
//  The dot color subtly tracks pressure so the artist has feedback.
//

import AppKit

/// A small, click-through, always-on-top window that renders a dot at the
/// last known pen position. Used as the visual cursor for the synthesized
/// mouse events.
@MainActor
final class CursorOverlay {

    private let panel: NSPanel
    private let dot: NSView
    private var lastPosition: CGPoint = .zero
    private var lastPressure: CGFloat = 0

    init() {
        let frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        self.panel = panel

        // A simple round dot. We make it a custom NSView so we can change
        // its alpha based on pressure.
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dot.layer?.borderWidth = 1
        dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.3).cgColor
        // Center the 12x12 dot inside the 24x24 panel.
        dot.frame.origin = NSPoint(x: 6, y: 6)
        panel.contentView?.addSubview(dot)
        self.dot = dot
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Move the cursor overlay to a screen position and update the dot
    /// size based on pressure (0..1).
    func update(position: CGPoint, pressure: CGFloat) {
        lastPosition = position
        lastPressure = pressure
        // Panel origin so the 12x12 dot is centered on `position`.
        let origin = NSPoint(x: position.x - 12, y: position.y - 12)
        panel.setFrameOrigin(origin)
        // Dot size scales 6..14 with pressure.
        let size: CGFloat = 6 + max(0, min(1, pressure)) * 8
        let dotSize = NSRect(x: 12 - size / 2, y: 12 - size / 2, width: size, height: size)
        dot.frame = dotSize
        dot.layer?.cornerRadius = size / 2
        // Brightness based on pressure: light gray at low, white at high.
        let brightness = 0.5 + max(0, min(1, pressure)) * 0.5
        dot.layer?.backgroundColor = NSColor(
            calibratedRed: brightness,
            green: brightness,
            blue: brightness,
            alpha: 0.9
        ).cgColor
    }
}

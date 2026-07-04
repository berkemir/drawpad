//
//  MouseSynthesizer.swift
//  DrawPad
//
//  Synthesizes macOS mouse events from incoming PenEvents. Uses CGEventPost
//  at the .cghidEventTap level so the events reach any app on the system.
//
//  Two driver modes:
//    - .absolute (default, Wacom "pen" mode): iPad position maps 1:1 to the
//      Mac screen. Touching the iPad at (0.5, 0.5) puts the cursor at the
//      middle of the Mac screen.
//    - .relative (Wacom "mouse" mode): the iPad acts like a touchpad.
//      Movement on the iPad is a delta applied to the current cursor
//      position. Useful for designers who don't want the cursor to jump.
//

import Foundation
import CoreGraphics
import AppKit
import os
import DrawPadProtocol

/// How the Mac receiver interprets iPad positions.
enum DriverMode: String, CaseIterable, Identifiable {
    case absolute
    case relative
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .absolute: return "Pen (absolute)"
        case .relative: return "Mouse (relative)"
        }
    }
    var subtitle: String {
        switch self {
        case .absolute: return "iPad position maps to screen position"
        case .relative: return "iPad motion moves the cursor by delta"
        }
    }
}

/// Converts PenEvents to CGEvent calls. The CGEvent path is the "easy" v1
/// strategy — see wiki/decisions/driver-strategy.md. Pressure is best-effort.
@MainActor
final class MouseSynthesizer {

    private let log = Logger(subsystem: "com.drawpad.mac", category: "Synth")

    /// One event source reused for every synthesized event, instead of
    /// passing `nil` (a fresh ad-hoc source) to each `CGEvent` call. Apple's
    /// own guidance for a synthesized *stream* of events is to share one
    /// source so the system's session-state tracking stays coherent;
    /// creating a new implicit source per event is a known cause of
    /// cursor-visibility glitches (the system cursor intermittently failing
    /// to (re)appear even though hover/hit-testing clearly still sees it).
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    /// The display we currently synthesize onto. Defaults to the main display.
    private(set) var display: NSScreen = NSScreen.main ?? NSScreen.screens[0]

    /// How iPad positions become Mac cursor positions.
    var mode: DriverMode = .absolute {
        didSet {
            guard oldValue != mode else { return }
            // Switching modes: forget the relative-mode tracking so the next
            // stroke re-primes from wherever the cursor currently is, instead
            // of applying a stale delta or jumping.
            lastIPadPos = nil
            relativeCursorPos = nil
        }
    }

    /// Relative-mode sensitivity: 1.0 means iPad (0..1) maps to the full
    /// display (one full screen-edge-to-edge motion per iPad pass). Higher
    /// = more sensitive. 0.1 = very slow, 5.0 = very fast.
    var sensitivity: Double = 1.0

    /// Last iPad position seen, in iPad space (0..1). Used to compute deltas
    /// in relative mode.
    private var lastIPadPos: CGPoint?

    /// In relative mode, the absolute iPad position doesn't map to the
    /// Mac cursor, so we keep the cursor at whatever position the user
    /// last had it at. We never move the cursor to the iPad's position
    /// in relative mode. Stored in Quartz global coordinates (top-left origin).
    private var relativeCursorPos: CGPoint?

    /// The last Quartz point we posted a move/drag to. `down` / `up` are
    /// posted here so the button event lands exactly where the cursor is,
    /// in both modes.
    private var lastCursor: CGPoint = .zero

    /// `t` (iPad monotonic ms) of the last hover/down/move/up sample we
    /// processed. Used only to detect a gap — see `staleGapMs`.
    private var lastSampleT: UInt64?

    /// If more than this many milliseconds (on the iPad's own clock, so
    /// network jitter can't trigger it) pass between two samples, we treat
    /// the next one as a fresh contact rather than a continuation. Without
    /// this, lifting the Pencil out of hover range and putting it down
    /// somewhere else — the ordinary "reposition for the next stroke"
    /// gesture — computes one huge delta from the stale last-known point and
    /// the relative-mode cursor jumps across the screen instead of resuming
    /// smoothly from where it was left. A real stroke samples at 60Hz+, so
    /// this is far above any gap that occurs during continuous contact.
    private static let staleGapMs: UInt64 = 200

    /// `lastCursor` converted to AppKit/Cocoa global coordinates (bottom-left
    /// origin) — the space `NSWindow`/`NSPanel` positioning expects. The
    /// cursor overlay reads this so its dot always matches wherever we
    /// actually placed the synthesized cursor, in either mode.
    var lastSyntheticPositionCocoa: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? display.frame.height
        return CGPoint(x: lastCursor.x, y: primaryHeight - lastCursor.y)
    }

    /// Calibrate against the main display. Idempotent.
    func recalibrate() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            self.display = screen
        }
    }

    // MARK: - Event dispatch

    func handle(_ event: PenEvent) {
        switch event {
        case .hello, .pong, .bye:
            return
        case .ping:
            return
        case .hover(let t, _, let x, let y, _):
            handleMove(t: t, iPadX: CGFloat(x), iPadY: CGFloat(y), pressure: nil, isStroke: false)
        case .down(let t, _, let x, let y, let pressure, _):
            handleMove(t: t, iPadX: CGFloat(x), iPadY: CGFloat(y), pressure: CGFloat(pressure), isStroke: true)
            handleDown(pressure: CGFloat(pressure))
        case .move(let t, _, let x, let y, let pressure, _):
            handleMove(t: t, iPadX: CGFloat(x), iPadY: CGFloat(y), pressure: CGFloat(pressure), isStroke: true)
        case .up(let t, _, let x, let y):
            // Move to the up event's own (x, y) before lifting. Confirmed
            // from a captured wire trace: the up event's own coordinate is
            // reliable (consistent with the preceding move samples) — the
            // actual source of drift is a stray hover sample that can land
            // *before* the up (a UIHoverGestureRecognizer/touch-ending
            // ambiguity on the iPad), which corrupts `lastCursor`. Using
            // up's own position corrects for that stray sample instead of
            // locking the lift in at the wrong spot.
            handleMove(t: t, iPadX: CGFloat(x), iPadY: CGFloat(y), pressure: nil, isStroke: true)
            handleUp()
        case .button(_, _, let kind, let state):
            if kind == .barrel {
                let p = NSEvent.mouseLocation
                if state == .down {
                    postButtonDown(at: p, button: .right)
                } else {
                    postButtonUp(at: p, button: .right)
                }
            }
        case .modifiers:
            return
        }
    }

    // MARK: - Mode-aware move / down / up

    private func handleMove(t: UInt64, iPadX x: CGFloat, iPadY y: CGFloat, pressure: CGFloat?, isStroke: Bool) {
        if let lastT = lastSampleT, t > lastT, (t - lastT) > Self.staleGapMs {
            // Contact/hover was lost and has just resumed (or a fresh touch
            // followed a real pause) — forget the old relative anchor so we
            // re-prime from the current cursor instead of jumping by the
            // physical distance covered while we weren't receiving samples.
            lastIPadPos = nil
        }
        lastSampleT = t

        let target: CGPoint

        switch mode {
        case .absolute:
            // Pen mode: the iPad position maps straight onto the screen.
            target = absoluteMacPoint(iPadX: x, iPadY: y)

        case .relative:
            // Mouse mode: iPad motion is a delta on the current cursor. On the
            // first sample of a stroke we only prime — the cursor stays put and
            // continues from wherever it already is (no jump to the iPad point).
            let iPadPos = CGPoint(x: x, y: y)
            guard let last = lastIPadPos else {
                relativeCursorPos = currentCursorQuartz()
                lastCursor = relativeCursorPos!
                lastIPadPos = iPadPos
                log.info("relative-mode: priming at cursor \(self.lastCursor.x, privacy: .public),\(self.lastCursor.y, privacy: .public)")
                return
            }
            let f = displayQuartzFrame
            // Both iPad Y and Quartz Y grow downward, so a downward iPad motion
            // (dy > 0) moves the cursor down — apply the delta directly.
            let dx = (iPadPos.x - last.x) * f.width * CGFloat(sensitivity)
            let dy = (iPadPos.y - last.y) * f.height * CGFloat(sensitivity)
            let base = relativeCursorPos ?? currentCursorQuartz()
            target = clampToDisplay(CGPoint(x: base.x + dx, y: base.y + dy))
            relativeCursorPos = target
            lastIPadPos = iPadPos
        }

        lastCursor = target
        if isStroke {
            postMouseDrag(to: target, pressure: pressure ?? 1.0)
        } else {
            postMouseMove(to: target)
        }
    }

    private func handleDown(pressure: CGFloat) {
        // Post at the point the preceding move already placed the cursor,
        // so down lands exactly under the pen in both modes.
        postMouseDown(at: lastCursor, pressure: pressure)
    }

    private func handleUp() {
        postMouseUp(at: lastCursor)
        // Reset so the next stroke re-primes in relative mode (continuing from
        // the current cursor) instead of jumping by a stale delta.
        lastIPadPos = nil
    }

    // MARK: - Coordinate helpers

    /// The target display's rect in **Quartz global** coordinates (origin at
    /// the top-left of the primary display, Y growing downward — the space
    /// `CGEvent` positions live in). `NSScreen.frame` is Cocoa (Y-up), so we
    /// flip it against the primary display's height.
    private var displayQuartzFrame: CGRect {
        let f = display.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? f.height
        // Cocoa top edge (f.maxY) becomes the Quartz top (smaller Y).
        let quartzTop = primaryHeight - f.maxY
        return CGRect(x: f.minX, y: quartzTop, width: f.width, height: f.height)
    }

    /// Map a normalized iPad point (0..1, Y-down) to a Quartz screen point.
    /// The iPad's Y already grows downward like Quartz, so there is no flip.
    private func absoluteMacPoint(iPadX x: CGFloat, iPadY y: CGFloat) -> CGPoint {
        let f = displayQuartzFrame
        return CGPoint(x: f.minX + x * f.width, y: f.minY + y * f.height)
    }

    /// The current cursor location in Quartz global coordinates (top-left
    /// origin) — the same space `CGEvent` positions use, so no conversion is
    /// needed before posting.
    private func currentCursorQuartz() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func clampToDisplay(_ p: CGPoint) -> CGPoint {
        let f = displayQuartzFrame
        return CGPoint(
            x: max(f.minX, min(f.maxX, p.x)),
            y: max(f.minY, min(f.maxY, p.y))
        )
    }

    // MARK: - CGEvent helpers

    /// Some app or system heuristic (typically "no real HID movement in a
    /// while") occasionally decides to hide the system cursor; our synthetic
    /// moves don't reliably reset whatever tracks that. `CGDisplayShowCursor`
    /// is refcounted but safe to over-call — calling it more often than any
    /// matching `CGDisplayHideCursor` just clamps at "visible" — so we call
    /// it defensively on every move/drag rather than trying to detect when
    /// it's actually needed.
    private func ensureCursorVisible() {
        CGDisplayShowCursor(CGMainDisplayID())
    }

    private func postMouseMove(to p: CGPoint) {
        ensureCursorVisible()
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: p,
            mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postMouseDown(at p: CGPoint, pressure: CGFloat) {
        ensureCursorVisible()
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: p,
            mouseButton: .left
        ) else { return }
        event.setDoubleValueField(.mouseEventPressure, value: Double(max(0, min(1, pressure))))
        event.post(tap: .cghidEventTap)
    }

    private func postMouseDrag(to p: CGPoint, pressure: CGFloat) {
        ensureCursorVisible()
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: p,
            mouseButton: .left
        ) else { return }
        event.setDoubleValueField(.mouseEventPressure, value: Double(max(0, min(1, pressure))))
        event.post(tap: .cghidEventTap)
    }

    private func postMouseUp(at p: CGPoint) {
        ensureCursorVisible()
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: p,
            mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postButtonDown(at p: CGPoint, button: CGMouseButton) {
        let mouseType: CGEventType = (button == .right) ? .rightMouseDown : .otherMouseDown
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: mouseType,
            mouseCursorPosition: p,
            mouseButton: button
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postButtonUp(at p: CGPoint, button: CGMouseButton) {
        let mouseType: CGEventType = (button == .right) ? .rightMouseUp : .otherMouseUp
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: mouseType,
            mouseCursorPosition: p,
            mouseButton: button
        ) else { return }
        event.post(tap: .cghidEventTap)
    }
}

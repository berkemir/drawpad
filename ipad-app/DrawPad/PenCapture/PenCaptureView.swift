//
//  PenCaptureView.swift
//  DrawPad
//
//  SwiftUI wrapper around a UIView that captures Apple Pencil events.
//
//  Hover: iOS 26 dropped `UIPencilHoverInteraction`, so we use
//  `UIHoverGestureRecognizer`, which is the general pointer-hover API
//  (iOS 13+) and works with Apple Pencil 2 / Pro above the screen.
//

import SwiftUI
import UIKit
import DrawPadProtocol

struct PenCaptureView: UIViewRepresentable {
    /// Called for every pencil event (down / move / up / hover / cancel).
    let onEvent: (PencilEvent) -> Void

    func makeUIView(context: Context) -> PenInputView {
        let view = PenInputView()
        view.onPencilEvent = onEvent
        return view
    }

    func updateUIView(_ uiView: PenInputView, context: Context) {
        uiView.onPencilEvent = onEvent
    }
}

/// One pencil event as the UIView layer sees it. Converted to a
/// `PenEvent` by the broadcaster.
enum PencilEvent {
    case down(x: Float, y: Float, pressure: Float, tilt: Tilt?)
    case move(x: Float, y: Float, pressure: Float, tilt: Tilt?)
    case up(x: Float, y: Float)
    case hover(x: Float, y: Float)
    case cancel(x: Float, y: Float)

    var point: CGPoint {
        switch self {
        case .down(let x, let y, _, _),
             .move(let x, let y, _, _),
             .up(let x, let y),
             .hover(let x, let y),
             .cancel(let x, let y):
            return CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
    }
}

final class PenInputView: UIView {

    var onPencilEvent: ((PencilEvent) -> Void)?

    /// `UIHoverGestureRecognizer` and touch tracking (`touchesBegan`/etc.)
    /// are two independent UIKit systems with no ordering guarantee between
    /// them. Captured wire traces showed a single, wildly-off-position
    /// `hover` sample landing in between the last real `move` and the `up`
    /// for a lift — i.e. UIKit called `handleHover` while the touch was
    /// still technically active/ending. `isTouchActive` + a short post-end
    /// settle window suppress hover at the source instead of trying to
    /// correct for the bad sample downstream.
    private var isTouchActive = false
    private var touchEndedAt: CFTimeInterval = 0
    private static let hoverSettleAfterTouchEnd: CFTimeInterval = 0.05

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        // Hover: works for any pointer (mouse, trackpad, Apple Pencil 2/Pro).
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where accepts(touch) {
            isTouchActive = true
            sendSamples(for: touch, in: event, phase: .began)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where accepts(touch) {
            sendSamples(for: touch, in: event, phase: .moved)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where accepts(touch) {
            sendSamples(for: touch, in: event, phase: .ended)
            isTouchActive = false
            touchEndedAt = CACurrentMediaTime()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where accepts(touch) {
            sendSamples(for: touch, in: event, phase: .cancelled)
            isTouchActive = false
            touchEndedAt = CACurrentMediaTime()
        }
    }

    // MARK: - Hover

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        // Only forward while actively hovering; .ended / .cancelled are
        // implicit (no more events = the pencil left the screen).
        switch recognizer.state {
        case .began, .changed:
            guard !isTouchActive,
                  CACurrentMediaTime() - touchEndedAt > Self.hoverSettleAfterTouchEnd else { return }
            let location = recognizer.location(in: self)
            let x = Float(location.x / bounds.width)
            let y = Float(location.y / bounds.height)
            onPencilEvent?(.hover(x: x, y: y))
        default:
            break
        }
    }

    // MARK: - Sample extraction

    private enum Phase: CustomStringConvertible {
        case began, moved, ended, cancelled
        var description: String {
            switch self {
            case .began: return "down"
            case .moved: return "move"
            case .ended: return "up"
            case .cancelled: return "cancel"
            }
        }
    }

    private func sendSamples(for touch: UITouch, in event: UIEvent?, phase: Phase) {
        guard accepts(touch) else { return }
        // Coalesced touches are Apple's high-frequency sample buffer for
        // *`.moved`* specifically ("For touches with phase .moved, you can
        // use this method to get this additional data" — UIEvent docs).
        // began/ended/cancelled are discrete, one-shot transitions; expanding
        // them through the same coalesced loop risked sending more than one
        // down/up/cancel for a single physical touch transition. An extra
        // `up` was the real bug here: each one is handled as a drag-to-point
        // *then* a lift (see MouseSynthesizer), so a stray second `up` with
        // a slightly different (drifted) coordinate — plausible right at
        // lift-off, when contact quality is dropping — drew a short phantom
        // stroke after the real one ended.
        let samples: [UITouch] = phase == .moved
            ? (event?.coalescedTouches(for: touch) ?? [touch])
            : [touch]
        for t in samples {
            let x = Float(t.location(in: self).x / bounds.width)
            let y = Float(t.location(in: self).y / bounds.height)
            // UITouch.force treats 1.0 as "an average touch" — a firm press
            // with Apple Pencil can report force > 1.0 (up to
            // maximumPossibleForce). The wire format and codec require
            // pressure in 0...1, so an unclamped value above 1.0 fails
            // validation and the *entire* down/move packet gets dropped —
            // which froze the cursor's X/Y (no packets = no move) exactly
            // when pressing hardest. Clamp here so a firm press still sends
            // a valid (saturated) packet instead of none at all.
            let pressure = min(1.0, max(0.0, Float(t.force)))
            let tilt = tiltFrom(touch: t)
            let wire: PencilEvent
            switch phase {
            case .began:    wire = .down(x: x, y: y, pressure: pressure, tilt: tilt)
            case .moved:    wire = .move(x: x, y: y, pressure: pressure, tilt: tilt)
            case .ended:    wire = .up(x: x, y: y)
            case .cancelled: wire = .cancel(x: x, y: y)
            }
            #if DEBUG
            NSLog("iPad pencil %@  raw=(%.0f,%.0f)/%.0fx%.0f  sent=(x=%.3f,y=%.3f)  p=%.2f",
                  String(describing: phase),
                  t.location(in: self).x, t.location(in: self).y,
                  bounds.width, bounds.height,
                  x, y, pressure)
            #endif
            onPencilEvent?(wire)
        }
    }

    /// In the iPad simulator, UITouch.type is `.indirect` (no Pencil), so we
    /// accept any touch type there to test the UI flow with a mouse/finger.
    /// On a **real device**, only `.pencil` touches make it through — this
    /// is our palm rejection, and it must hold regardless of build
    /// configuration. It used to be gated on `#if DEBUG`, which also
    /// disabled palm rejection on real hardware whenever testing a Debug
    /// build (i.e. every device test all session) — `#if
    /// targetEnvironment(simulator)` is the check that actually means
    /// "there's no real Pencil to filter for."
    private func accepts(_ touch: UITouch) -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return touch.type == .pencil
        #endif
    }

    private func tiltFrom(touch: UITouch) -> Tilt? {
        // altitudeAngle: 0 = parallel, π/2 = perpendicular to screen.
        // We send degrees, 0..90.
        let altitudeDeg = Float(touch.altitudeAngle * 180.0 / .pi)
        // azimuthAngle(in:) replaced azimuthAngle(to:) in iOS 17 / Xcode 15.
        let azimuthDeg = Float(touch.azimuthAngle(in: self) * 180.0 / .pi)
        return Tilt(altitude: altitudeDeg, azimuth: azimuthDeg)
    }
}

//
//  PenEvent.swift
//  DrawPadProtocol
//
//  The PenEvent enum. Each case carries its own `t` and `seq` so the
//  encoder/decoder can lift them onto the wire without a wrapper.
//
//  The factory methods (PenEvent.move(...), .ping(...), etc.) are the
//  recommended public API.
//

import Foundation

/// One event on the wire. Use the static factory methods to construct;
/// use `PenEvent.encode(_:)` / `PenEvent.decode(_:)` to serialize.
///
/// Each case carries its own `t` (monotonic ms, sender's clock) and `seq`
/// (per-sender monotonic sequence number).
public enum PenEvent: Sendable, Equatable {

    // MARK: - Session

    case hello(t: UInt64, seq: UInt32, payload: Hello)
    case ping(t: UInt64, seq: UInt32, nonce: String)
    case pong(t: UInt64, seq: UInt32, nonce: String)
    case bye(t: UInt64, seq: UInt32)

    // MARK: - Pen

    case hover(t: UInt64, seq: UInt32, x: Float, y: Float, tilt: Tilt?)
    case down(t: UInt64, seq: UInt32, x: Float, y: Float, pressure: Float, tilt: Tilt)
    case move(t: UInt64, seq: UInt32, x: Float, y: Float, pressure: Float, tilt: Tilt)
    case up(t: UInt64, seq: UInt32, x: Float, y: Float)

    // MARK: - Controls

    case button(t: UInt64, seq: UInt32, kind: ButtonKind, state: ButtonState)
    case modifiers(t: UInt64, seq: UInt32, mask: ModifierMask)
}

extension PenEvent {
    // MARK: - Ergonomic factory methods

    /// Build a `hello` event.
    public static func makeHello(
        t: UInt64, seq: UInt32,
        device: String, os: String, capabilities: Set<Capability>
    ) -> PenEvent {
        .hello(t: t, seq: seq, payload: Hello(device: device, os: os, capabilities: capabilities))
    }

    /// Build a `hover` event. Tilt is optional (Apple Pencil may report it on hover, or not).
    public static func makeHover(
        t: UInt64, seq: UInt32, x: Float, y: Float, tilt: Tilt? = nil
    ) -> PenEvent {
        .hover(t: t, seq: seq, x: x, y: y, tilt: tilt)
    }

    /// Build a `down` event. Tilt is required when the pen is in contact.
    public static func makeDown(
        t: UInt64, seq: UInt32, x: Float, y: Float, pressure: Float, tilt: Tilt
    ) -> PenEvent {
        .down(t: t, seq: seq, x: x, y: y, pressure: pressure, tilt: tilt)
    }

    /// Build a `move` event. Tilt is required when the pen is in contact.
    public static func makeMove(
        t: UInt64, seq: UInt32, x: Float, y: Float, pressure: Float, tilt: Tilt
    ) -> PenEvent {
        .move(t: t, seq: seq, x: x, y: y, pressure: pressure, tilt: tilt)
    }

    /// Build an `up` event.
    public static func makeUp(
        t: UInt64, seq: UInt32, x: Float, y: Float
    ) -> PenEvent {
        .up(t: t, seq: seq, x: x, y: y)
    }

    /// Build a `button` event.
    public static func makeButton(
        t: UInt64, seq: UInt32, kind: ButtonKind, state: ButtonState
    ) -> PenEvent {
        .button(t: t, seq: seq, kind: kind, state: state)
    }

    /// Build a `modifiers` event.
    public static func makeModifiers(
        t: UInt64, seq: UInt32, mask: ModifierMask
    ) -> PenEvent {
        .modifiers(t: t, seq: seq, mask: mask)
    }

    /// Build a `ping` event.
    public static func makePing(
        t: UInt64, seq: UInt32, nonce: String
    ) -> PenEvent {
        .ping(t: t, seq: seq, nonce: nonce)
    }

    /// Build a `pong` event.
    public static func makePong(
        t: UInt64, seq: UInt32, nonce: String
    ) -> PenEvent {
        .pong(t: t, seq: seq, nonce: nonce)
    }

    /// Build a `bye` event.
    public static func makeBye(t: UInt64, seq: UInt32) -> PenEvent {
        .bye(t: t, seq: seq)
    }

    /// Wire-level name of this event, e.g. "move", "ping", "hello".
    public var typeName: String {
        switch self {
        case .hello:    return "hello"
        case .ping:     return "ping"
        case .pong:     return "pong"
        case .bye:      return "bye"
        case .hover:    return "hover"
        case .down:     return "down"
        case .move:     return "move"
        case .up:       return "up"
        case .button:   return "button"
        case .modifiers: return "modifiers"
        }
    }

    /// The `t` field — monotonic ms on the sender's clock.
    public var t: UInt64 {
        switch self {
        case .hello(let t, _, _):    return t
        case .ping(let t, _, _):     return t
        case .pong(let t, _, _):     return t
        case .bye(let t, _):         return t
        case .hover(let t, _, _, _, _): return t
        case .down(let t, _, _, _, _, _): return t
        case .move(let t, _, _, _, _, _): return t
        case .up(let t, _, _, _):    return t
        case .button(let t, _, _, _): return t
        case .modifiers(let t, _, _): return t
        }
    }

    /// The `seq` field — per-sender monotonic sequence number.
    public var seq: UInt32 {
        switch self {
        case .hello(_, let s, _):    return s
        case .ping(_, let s, _):     return s
        case .pong(_, let s, _):     return s
        case .bye(_, let s):         return s
        case .hover(_, let s, _, _, _): return s
        case .down(_, let s, _, _, _, _): return s
        case .move(_, let s, _, _, _, _): return s
        case .up(_, let s, _, _):    return s
        case .button(_, let s, _, _): return s
        case .modifiers(_, let s, _): return s
        }
    }
}

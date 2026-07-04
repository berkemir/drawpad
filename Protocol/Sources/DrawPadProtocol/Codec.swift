//
//  Codec.swift
//  DrawPadProtocol
//
//  Wire format. JSON over UDP, v1. The codec converts between `PenEvent`
//  and the on-the-wire JSON. Use `PenEvent.encode(_:)` and
//  `PenEvent.decode(_:)` directly — `PenEventCodec` is a namespace.
//

import Foundation

public enum PenEventCodec {

    // MARK: - Public API

    /// Serialize a `PenEvent` to a JSON byte string. Compact (no whitespace).
    public static func encode(_ event: PenEvent) throws -> Data {
        let envelope = makeEnvelope(from: event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        return try encoder.encode(envelope)
    }

    /// Decode a JSON byte string to a `PenEvent`. Throws on bad version,
    /// unknown type, or missing required fields.
    public static func decode(_ data: Data) throws -> PenEvent {
        let envelope: WireEnvelope
        do {
            envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        } catch let DecodingError.dataCorrupted(ctx) {
            throw CodecError.malformed(ctx.debugDescription)
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw CodecError.malformed("type mismatch at \(ctx.codingPath.map { $0.stringValue }.joined(separator: ".")): \(ctx.debugDescription)")
        } catch {
            throw CodecError.malformed("\(error)")
        }

        // `appVersion` is decoded above as part of the envelope regardless
        // of whether `v` matches — it's what lets `incompatibleVersion`
        // name an actual version number instead of just a protocol integer,
        // even for a message we otherwise can't understand.
        guard envelope.v == ProtocolVersion.current else {
            throw CodecError.incompatibleVersion(
                peerProtocolVersion: envelope.v,
                peerAppVersion: envelope.appVersion
            )
        }
        return try makeEvent(from: envelope)
    }

    // MARK: - Errors

    public enum CodecError: Error, Equatable, CustomStringConvertible {
        case incompatibleVersion(peerProtocolVersion: UInt32, peerAppVersion: String?)
        case unknownType(String)
        case missingField(String)
        case invalidField(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .incompatibleVersion(let pv, let av):
                return "incompatible protocol version: peer is on \(pv) (app \(av ?? "unknown")), we are on \(ProtocolVersion.current)"
            case .unknownType(let t):        return "unknown event type: \(t)"
            case .missingField(let f):       return "missing required field: \(f)"
            case .invalidField(let f):       return "invalid value for field: \(f)"
            case .malformed(let m):          return "malformed message: \(m)"
            }
        }
    }

    // MARK: - Wire envelope (private)

    /// Mirrors the JSON shape one-to-one. The on-the-wire fields are exactly
    /// these property names; JSONEncoder uses them directly.
    ///
    /// `appVersion` is deliberately a plain top-level field rather than
    /// nested inside `hello`'s payload: it must stay decodable even when
    /// `v` doesn't match (that's the one case a human-readable "please
    /// update" message actually needs it) — nesting it in a type-specific
    /// payload would put it behind the same version gate it's meant to
    /// explain the failure of.
    private struct WireEnvelope: Codable {
        let v: UInt32
        let appVersion: String?
        let type: String
        let t: UInt64
        let seq: UInt32
        let x: Float?
        let y: Float?
        let p: Float?
        let alt: Float?
        let azi: Float?
        let kind: String?
        let state: String?
        let mask: UInt32?
        let device: String?
        let os: String?
        let capabilities: [String]?
        let nonce: String?
    }

    // MARK: - Encode: PenEvent → WireEnvelope

    private static func makeEnvelope(from event: PenEvent) -> WireEnvelope {
        switch event {
        case let .hello(t, seq, payload):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current,
                type: "hello",
                t: t, seq: seq,
                x: nil, y: nil, p: nil, alt: nil, azi: nil,
                kind: nil, state: nil, mask: nil,
                device: payload.device,
                os: payload.os,
                capabilities: payload.capabilities.map { $0.rawValue }.sorted(),
                nonce: nil
            )
        case let .ping(t, seq, nonce):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current, type: "ping",
                t: t, seq: seq,
                x: nil, y: nil, p: nil, alt: nil, azi: nil,
                kind: nil, state: nil, mask: nil,
                device: nil, os: nil, capabilities: nil,
                nonce: nonce
            )
        case let .pong(t, seq, nonce):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current, type: "pong",
                t: t, seq: seq,
                x: nil, y: nil, p: nil, alt: nil, azi: nil,
                kind: nil, state: nil, mask: nil,
                device: nil, os: nil, capabilities: nil,
                nonce: nonce
            )
        case let .bye(t, seq):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current, type: "bye",
                t: t, seq: seq,
                x: nil, y: nil, p: nil, alt: nil, azi: nil,
                kind: nil, state: nil, mask: nil,
                device: nil, os: nil, capabilities: nil,
                nonce: nil
            )
        case let .hover(t, seq, x, y, tilt):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current, type: "hover",
                t: t, seq: seq,
                x: x, y: y, p: nil,
                alt: tilt?.altitude, azi: tilt?.azimuth,
                kind: nil, state: nil, mask: nil,
                device: nil, os: nil, capabilities: nil,
                nonce: nil
            )
        case let .down(t, seq, x, y, pressure, tilt):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current, type: "down",
                t: t, seq: seq,
                x: x, y: y, p: pressure,
                alt: tilt.altitude, azi: tilt.azimuth,
                kind: nil, state: nil, mask: nil,
                device: nil, os: nil, capabilities: nil,
                nonce: nil
            )
        case let .move(t, seq, x, y, pressure, tilt):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current, type: "move",
                t: t, seq: seq,
                x: x, y: y, p: pressure,
                alt: tilt.altitude, azi: tilt.azimuth,
                kind: nil, state: nil, mask: nil,
                device: nil, os: nil, capabilities: nil,
                nonce: nil
            )
        case let .up(t, seq, x, y):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current, type: "up",
                t: t, seq: seq,
                x: x, y: y, p: nil, alt: nil, azi: nil,
                kind: nil, state: nil, mask: nil,
                device: nil, os: nil, capabilities: nil,
                nonce: nil
            )
        case let .button(t, seq, kind, state):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current, type: "button",
                t: t, seq: seq,
                x: nil, y: nil, p: nil, alt: nil, azi: nil,
                kind: kind.rawValue, state: state.rawValue, mask: nil,
                device: nil, os: nil, capabilities: nil,
                nonce: nil
            )
        case let .modifiers(t, seq, mask):
            return WireEnvelope(
                v: ProtocolVersion.current, appVersion: AppVersion.current, type: "modifiers",
                t: t, seq: seq,
                x: nil, y: nil, p: nil, alt: nil, azi: nil,
                kind: nil, state: nil, mask: mask.raw,
                device: nil, os: nil, capabilities: nil,
                nonce: nil
            )
        }
    }

    // MARK: - Decode: WireEnvelope → PenEvent

    private static func makeEvent(from w: WireEnvelope) throws -> PenEvent {
        switch w.type {
        case "hello":
            let device = try require(w.device, "device")
            let os = try require(w.os, "os")
            let capStrings = try require(w.capabilities, "capabilities")
            let caps: Set<Capability> = try Set(capStrings.map { s -> Capability in
                guard let c = Capability(rawValue: s) else {
                    throw CodecError.invalidField("capabilities contains '\(s)'")
                }
                return c
            })
            return .hello(t: w.t, seq: w.seq, payload: Hello(device: device, os: os, capabilities: caps))

        case "ping":
            let nonce = try require(w.nonce, "nonce")
            return .ping(t: w.t, seq: w.seq, nonce: nonce)

        case "pong":
            let nonce = try require(w.nonce, "nonce")
            return .pong(t: w.t, seq: w.seq, nonce: nonce)

        case "bye":
            return .bye(t: w.t, seq: w.seq)

        case "hover":
            let x = try require(w.x, "x")
            let y = try require(w.y, "y")
            try require01(x, "x"); try require01(y, "y")
            let tilt = try optionalTilt(w.alt, w.azi)
            return .hover(t: w.t, seq: w.seq, x: x, y: y, tilt: tilt)

        case "down":
            let x = try require(w.x, "x")
            let y = try require(w.y, "y")
            let p = try require(w.p, "p")
            try require01(x, "x"); try require01(y, "y"); try require01(p, "p")
            let tilt = try requiredTilt(w.alt, w.azi)
            return .down(t: w.t, seq: w.seq, x: x, y: y, pressure: p, tilt: tilt)

        case "move":
            let x = try require(w.x, "x")
            let y = try require(w.y, "y")
            let p = try require(w.p, "p")
            try require01(x, "x"); try require01(y, "y"); try require01(p, "p")
            let tilt = try requiredTilt(w.alt, w.azi)
            return .move(t: w.t, seq: w.seq, x: x, y: y, pressure: p, tilt: tilt)

        case "up":
            let x = try require(w.x, "x")
            let y = try require(w.y, "y")
            try require01(x, "x"); try require01(y, "y")
            return .up(t: w.t, seq: w.seq, x: x, y: y)

        case "button":
            let kindStr = try require(w.kind, "kind")
            let stateStr = try require(w.state, "state")
            guard let kind = ButtonKind(rawValue: kindStr) else {
                throw CodecError.invalidField("kind: '\(kindStr)'")
            }
            guard let state = ButtonState(rawValue: stateStr) else {
                throw CodecError.invalidField("state: '\(stateStr)'")
            }
            return .button(t: w.t, seq: w.seq, kind: kind, state: state)

        case "modifiers":
            let mask = try require(w.mask, "mask")
            return .modifiers(t: w.t, seq: w.seq, mask: ModifierMask(raw: mask))

        default:
            throw CodecError.unknownType(w.type)
        }
    }

    // MARK: - Validation helpers

    private static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw CodecError.missingField(name) }
        return value
    }

    private static func require01(_ value: Float, _ name: String) throws {
        if value.isNaN || value.isInfinite || value < 0.0 || value > 1.0 {
            throw CodecError.invalidField("\(name) must be in 0..1, got \(value)")
        }
    }

    private static func optionalTilt(_ alt: Float?, _ azi: Float?) throws -> Tilt? {
        switch (alt, azi) {
        case (nil, nil): return nil
        case (let a?, let b?):
            return Tilt(altitude: a, azimuth: b)
        default:
            throw CodecError.invalidField("tilt: both alt and azi must be set or both nil")
        }
    }

    private static func requiredTilt(_ alt: Float?, _ azi: Float?) throws -> Tilt {
        let a = try require(alt, "alt")
        let b = try require(azi, "azi")
        return Tilt(altitude: a, azimuth: b)
    }
}

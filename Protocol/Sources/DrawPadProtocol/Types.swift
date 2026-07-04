//
//  Types.swift
//  DrawPadProtocol
//
//  All payload types used by PenEvent. PenEvent itself lives in PenEvent.swift
//  with the factory methods; this file is the data model.
//

import Foundation

// MARK: - Tilt

/// Tilt of the pencil in 3D space.
///
/// - `altitude`: 0 = parallel to screen, 90 = perpendicular.
/// - `azimuth`: 0..360, the direction the pencil is pointing (around the screen normal).
public struct Tilt: Sendable, Equatable, Hashable, Codable {
    public var altitude: Float
    public var azimuth: Float

    public init(altitude: Float, azimuth: Float) {
        self.altitude = altitude
        self.azimuth = azimuth
    }
}

// MARK: - Button

public enum ButtonKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case barrel
    case eraser
    case squeeze
    case doubleTap
}

public enum ButtonState: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case down
    case up
}

// MARK: - Capability

/// What the sender can do. Reported in `hello`.
public enum Capability: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case hover
    case pressure
    case tilt
    case barrel
    case squeeze
    case doubleTap
    case eraser
}

// MARK: - Modifier mask

/// Bitfield of currently-held keyboard modifiers.
///
/// `1 = command`, `2 = shift`, `4 = option`, `8 = control`. Multiple may be set.
/// Use the named static constants for clarity.
public struct ModifierMask: Sendable, Equatable, Hashable, Codable {
    public var raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public static let command = ModifierMask(raw: 1 << 0)
    public static let shift   = ModifierMask(raw: 1 << 1)
    public static let option  = ModifierMask(raw: 1 << 2)
    public static let control = ModifierMask(raw: 1 << 3)
    public static let empty   = ModifierMask(raw: 0)

    public func contains(_ m: ModifierMask) -> Bool {
        (raw & m.raw) == m.raw
    }

    public func union(_ m: ModifierMask) -> ModifierMask {
        ModifierMask(raw: raw | m.raw)
    }

    public func subtracting(_ m: ModifierMask) -> ModifierMask {
        ModifierMask(raw: raw & ~m.raw)
    }

    public var isEmpty: Bool { raw == 0 }
}

// MARK: - Hello payload

public struct Hello: Sendable, Equatable, Codable {
    public var device: String
    public var os: String
    public var capabilities: Set<Capability>

    public init(device: String, os: String, capabilities: Set<Capability>) {
        self.device = device
        self.os = os
        self.capabilities = capabilities
    }
}

// MARK: - Ping / Pong payloads

public struct Ping: Sendable, Equatable, Hashable, Codable {
    public var nonce: String
    public init(nonce: String) { self.nonce = nonce }
}

public struct Pong: Sendable, Equatable, Hashable, Codable {
    public var nonce: String
    public init(nonce: String) { self.nonce = nonce }
}

// MARK: - Pen event payloads

public struct Hover: Sendable, Equatable, Hashable {
    public var x: Float
    public var y: Float
    public var tilt: Tilt?

    public init(x: Float, y: Float, tilt: Tilt? = nil) {
        self.x = x
        self.y = y
        self.tilt = tilt
    }
}

public struct Down: Sendable, Equatable, Hashable {
    public var x: Float
    public var y: Float
    public var pressure: Float
    public var tilt: Tilt

    public init(x: Float, y: Float, pressure: Float, tilt: Tilt) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tilt = tilt
    }
}

public struct Move: Sendable, Equatable, Hashable {
    public var x: Float
    public var y: Float
    public var pressure: Float
    public var tilt: Tilt

    public init(x: Float, y: Float, pressure: Float, tilt: Tilt) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tilt = tilt
    }
}

public struct Up: Sendable, Equatable, Hashable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

public struct ButtonEvent: Sendable, Equatable, Hashable {
    public var kind: ButtonKind
    public var state: ButtonState

    public init(kind: ButtonKind, state: ButtonState) {
        self.kind = kind
        self.state = state
    }
}

public struct ModifierEvent: Sendable, Equatable, Hashable {
    public var mask: ModifierMask

    public init(mask: ModifierMask) {
        self.mask = mask
    }
}

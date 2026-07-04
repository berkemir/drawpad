//
//  Version.swift
//  DrawPadProtocol
//
//  Schema version. Bump this when the wire format changes in a way that
//  receivers must understand (not when you add optional fields).
//

import Foundation

public enum ProtocolVersion {
    /// Current wire format version. Every outbound message has `v: 1`.
    public static let current: UInt32 = 1
}

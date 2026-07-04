//
//  Discovery.swift
//  DrawPadProtocol
//
//  Bonjour / mDNS service constants. The Mac receiver advertises; the iPad
//  app browses; they find each other without manual IP entry.
//

import Foundation

#if canImport(Network)
import Network

public enum Discovery {
    /// Bonjour service type. RFC 6335 form, with trailing dot.
    public static let serviceType: String = "_drawpad._udp."

    /// Default UDP port for the Wi-Fi transport. Hard-coded; receivers bind
    /// here, senders send here. See ADR-004.
    public static let defaultPort: UInt16 = 7359

    /// Fixed TCP port for the wired (USB) transport — see ADR-005. The iPad
    /// listens here; the Mac reaches it via a `usbmux` relay over the cable,
    /// not over the network, so this never needs Bonjour discovery. Chosen
    /// one above `defaultPort` and outside the registered-port range, same
    /// rationale as ADR-004.
    public static let wiredPort: UInt16 = 7360

    /// Bonjour service domain. Local network only.
    public static let serviceDomain: String = "local."

    /// Human-readable service name (the iPad app advertises its name so the
    /// user can see it in the Mac receiver's picker).
    public static func serviceName(for device: String) -> String {
        "DrawPad on \(device)"
    }
}
#endif

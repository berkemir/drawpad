//
//  SessionState.swift
//  DrawPad
//
//  Top-level state for the Mac receiver. Owns the UDP listener, the mouse
//  synthesizer, and the cursor overlay. Tracks connection state for the
//  menu bar UI.
//

import Foundation
import Network
import SwiftUI
import AppKit
import ApplicationServices
import DrawPadProtocol
import os

@Observable
@MainActor
final class SessionState {

    enum Connection: Equatable {
        case listening
        case connected(device: String, host: String)
        /// A peer sent a message we can't decode because its protocol
        /// version doesn't match ours. `weAreOlder` is true when the peer's
        /// protocol version is *ahead* of ours (we need to update this Mac
        /// app); false means the peer is behind (the iPad app needs
        /// updating).
        case incompatible(peerAppVersion: String?, peerProtocolVersion: UInt32, weAreOlder: Bool)
    }

    private(set) var connection: Connection = .listening
    private(set) var eventCount: Int = 0
    private(set) var lastEventSummary: String = ""
    private(set) var lastUpdate: Date = .init()

    /// UserDefaults keys for the settings that survive a quit/relaunch —
    /// currently just driver mode and sensitivity, the only two the menu
    /// bar lets the user change.
    private enum DefaultsKey {
        static let mode = "com.drawpad.mode"
        static let sensitivity = "com.drawpad.sensitivity"
    }

    /// Driver mode. Mutate via `setMode(_:)` — the didSet-based approach
    /// had issues with @Observable on macOS 14 / Swift 6. Restored from
    /// the last session's choice in `init()`.
    private(set) var mode: DriverMode = .absolute

    /// Relative-mode sensitivity. 0.1 = very slow, 5.0 = very fast.
    /// Restored from the last session's choice in `init()`.
    private(set) var sensitivity: Double = 1.0

    /// Update the driver mode. The synthesizer picks up the new value
    /// on the next event. Persisted immediately so it survives a quit.
    func setMode(_ m: DriverMode) {
        mode = m
        synthesizer.mode = m
        UserDefaults.standard.set(m.rawValue, forKey: DefaultsKey.mode)
        log.info("driver mode → \(m.rawValue, privacy: .public)")
    }

    /// Update the sensitivity (clamped to 0.05…10). Persisted immediately
    /// so it survives a quit.
    func setSensitivity(_ s: Double) {
        let clamped = max(0.05, min(10, s))
        sensitivity = clamped
        synthesizer.sensitivity = clamped
        UserDefaults.standard.set(clamped, forKey: DefaultsKey.sensitivity)
        log.info("sensitivity → \(clamped, privacy: .public)")
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    var isIncompatible: Bool {
        if case .incompatible = connection { return true }
        return false
    }

    var statusLine: String {
        switch connection {
        case .listening:
            return "Listening for iPad…"
        case .connected(let device, _):
            return "Connected to \(device)"
        case .incompatible(_, _, let weAreOlder):
            return weAreOlder ? "⚠️ Update this Mac app" : "⚠️ Update the iPad app"
        }
    }

    /// True if the process has the macOS Accessibility permission needed
    /// for CGEventPost. Without it, mouse synthesis silently does nothing.
    var hasAccessibilityPermission: Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options)
    }

    var subStatusLine: String {
        switch connection {
        case .listening:
            return "Bonjour: _drawpad._udp."
        case .connected(_, let host):
            return host
        case .incompatible(let peerAppVersion, let peerProtocolVersion, _):
            let peer = peerAppVersion.map { "app \($0)" } ?? "an older app version"
            return "iPad is on \(peer) (protocol \(peerProtocolVersion)); this Mac app speaks protocol \(ProtocolVersion.current)"
        }
    }

    let listener = UdpListener()
    let wiredListener = WiredUsbListener()
    let synthesizer = MouseSynthesizer()
    let overlay = CursorOverlay()

    /// True while a wired (USB) relay to the iPad is live. Independent of
    /// `connection` — Wi-Fi and wired both feed the same `handle(event:source:)`,
    /// so either can be the one currently marked `.connected`.
    private(set) var isWiredConnected = false

    private let log = Logger(subsystem: "com.drawpad.mac", category: "Session")
    private var lastHello: Date = .distantPast
    private var helloTimeoutTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let savedMode = defaults.string(forKey: DefaultsKey.mode),
           let restored = DriverMode(rawValue: savedMode) {
            mode = restored
        }
        let savedSensitivity = defaults.double(forKey: DefaultsKey.sensitivity)
        if savedSensitivity > 0 {
            sensitivity = savedSensitivity
        }

        listener.onEvent = { [weak self] event, endpoint in
            Task { @MainActor in
                self?.handle(event: event, source: self?.hostString(of: endpoint) ?? "?")
            }
        }
        listener.onIncompatiblePeer = { [weak self] peerAppVersion, peerProtocolVersion, _ in
            Task { @MainActor in
                self?.handleIncompatiblePeer(appVersion: peerAppVersion, protocolVersion: peerProtocolVersion)
            }
        }
        wiredListener.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event, source: "USB")
            }
        }
        wiredListener.onIncompatiblePeer = { [weak self] peerAppVersion, peerProtocolVersion in
            Task { @MainActor in
                self?.handleIncompatiblePeer(appVersion: peerAppVersion, protocolVersion: peerProtocolVersion)
            }
        }
        wiredListener.onConnectionChange = { [weak self] connected in
            Task { @MainActor in
                self?.isWiredConnected = connected
                self?.log.info("wired connection → \(connected, privacy: .public)")
            }
        }
        start()
    }

    /// A peer's message failed to decode because its protocol version
    /// doesn't match ours. Surfaces a "please update" state instead of
    /// just silently dropping the packet.
    private func handleIncompatiblePeer(appVersion: String?, protocolVersion: UInt32) {
        connection = .incompatible(
            peerAppVersion: appVersion,
            peerProtocolVersion: protocolVersion,
            weAreOlder: protocolVersion > ProtocolVersion.current
        )
        log.error("incompatible peer: app \(appVersion ?? "unknown", privacy: .public), protocol \(protocolVersion, privacy: .public)")
    }

    func start() {
        do {
            try listener.start()
            wiredListener.start()
            overlay.show()
            // Push current mode/sensitivity into the synthesizer in case
            // they were set before `start` ran.
            synthesizer.mode = mode
            synthesizer.sensitivity = sensitivity
            log.info("started")
        } catch {
            log.error("listener start failed: \(error.localizedDescription)")
        }
    }

    /// `source` is a human-readable transport/origin label (a Wi-Fi host
    /// string, or "USB" for the wired relay) — the two transports are
    /// otherwise handled identically from here on.
    private func handle(event: PenEvent, source: String) {
        eventCount += 1
        lastUpdate = Date()
        lastEventSummary = eventSummary(event)

        // Update connection state on hello.
        if case .hello(_, _, let payload) = event {
            connection = .connected(
                device: payload.device,
                host: source
            )
            lastHello = Date()
            scheduleHelloTimeout()
            return
        }

        // Synthesize first, then read back where the synthesizer actually put
        // the cursor. The overlay must track that — not an independent
        // absolute iPad→screen mapping — otherwise the dot shows the wrong
        // spot in relative ("mouse") mode, where the cursor moves by delta
        // rather than jumping to the iPad's raw position.
        synthesizer.handle(event)

        switch event {
        case .hover:
            overlay.update(position: synthesizer.lastSyntheticPositionCocoa, pressure: 0)
        case .down(_, _, _, _, let pressure, _),
             .move(_, _, _, _, let pressure, _):
            overlay.update(position: synthesizer.lastSyntheticPositionCocoa, pressure: CGFloat(pressure))
        default:
            break
        }
    }

    private func scheduleHelloTimeout() {
        helloTimeoutTask?.cancel()
        helloTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                guard let self else { return }
                if Date().timeIntervalSince(self.lastHello) > 4.5 {
                    self.connection = .listening
                }
            }
        }
    }

    private func eventSummary(_ event: PenEvent) -> String {
        switch event {
        case .hello(_, _, let p):
            return "hello from \(p.device)"
        case .ping(_, _, let n):
            return "ping \(n)"
        case .pong(_, _, let n):
            return "pong \(n)"
        case .bye:
            return "bye"
        case .hover(_, _, let x, let y, _):
            return String(format: "hover  (%.2f, %.2f)", x, y)
        case .down(_, _, let x, let y, let p, _),
             .move(_, _, let x, let y, let p, _):
            return String(format: "%@  (%.2f, %.2f) p=%.2f",
                          (event.typeName as NSString).uppercased, x, y, p)
        case .up(_, _, let x, let y):
            return String(format: "up     (%.2f, %.2f)", x, y)
        case .button(_, _, let k, let s):
            return "\(k.rawValue)=\(s.rawValue)"
        case .modifiers(_, _, let m):
            return "modif mask=\(m.raw)"
        }
    }

    private nonisolated func hostString(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let ip): return "\(ip)"
            case .ipv6(let ip): return "\(ip)"
            case .name(let n, _): return n
            @unknown default: return "?"
            }
        }
        return "?"
    }
}

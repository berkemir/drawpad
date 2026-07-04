//
//  UdpListener.swift
//  DrawPad
//
//  Listens on UDP port 7359 and advertises the service via Bonjour.
//  Each incoming datagram is decoded as a PenEvent and forwarded to `onEvent`.
//

import Foundation
import Network
import DrawPadProtocol
import os

/// A UDP listener bound to the Drawing Pad port and advertising the
/// Bonjour service. Callbacks are dispatched on the main queue; internal
/// state is protected by a serial queue.
final class UdpListener {

    private let log = Logger(subsystem: "com.drawpad.mac", category: "UdpListener")
    private let queue = DispatchQueue(label: "com.drawpad.udp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Called for every decoded event. Invoked on the main queue.
    @MainActor var onEvent: ((PenEvent, NWEndpoint) -> Void)?

    /// Called when a message arrives whose protocol version we can't
    /// decode — the peer's app version (if it sent one) and protocol
    /// version, plus which endpoint it came from. Invoked on the main queue.
    @MainActor var onIncompatiblePeer: ((_ peerAppVersion: String?, _ peerProtocolVersion: UInt32, _ endpoint: NWEndpoint) -> Void)?

    /// Whether the listener is currently active.
    var isListening: Bool { listener != nil }

    func start() throws {
        try queue.sync {
            try startLocked()
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    // MARK: - Locked state mutations

    private func startLocked() throws {
        guard listener == nil else { return }

        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        // Let a fresh launch rebind immediately even if the previous
        // instance's socket on this port hasn't fully released yet (e.g.
        // quit-and-relaunch during dev, or a crash) — without this, restarts
        // can intermittently fail to bind at all.
        parameters.allowLocalEndpointReuse = true

        // Bind to the fixed, well-known port (see ADR-004) instead of
        // letting the OS hand out a random ephemeral one. `NWListener
        // (service:using:)` — the previous approach — does exactly that
        // (a fresh random port every launch), which meant a Mac restart
        // silently orphaned any iPad that had already resolved the old
        // port: it had to be force-quit and relaunched to re-browse and
        // pick up the new one. Binding first, then attaching Bonjour
        // advertising via `.service`, keeps the port stable across restarts
        // so previously-resolved clients keep working without intervention.
        // `Discovery.defaultPort` (7359) is a non-zero compile-time constant,
        // so `NWEndpoint.Port(rawValue:)` — which only fails for 0 — always
        // succeeds here.
        let port = NWEndpoint.Port(rawValue: Discovery.defaultPort)!
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            log.error("NWListener init failed: \(error.localizedDescription)")
            throw error
        }
        listener.service = NWListener.Service(
            type: Discovery.serviceType,
            domain: Discovery.serviceDomain
        )
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener?.port {
                    self.log.info("listening on port \(port.rawValue), advertising \(Discovery.serviceType)")
                }
            case .failed(let error):
                self.log.error("listener failed: \(error.debugDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.acceptLocked(connection: connection)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        for (_, c) in connections { c.cancel() }
        connections = [:]
    }

    // MARK: - Per-connection receive loop

    private func acceptLocked(connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.queue.async {
                    self.connections[id]?.cancel()
                    self.connections.removeValue(forKey: id)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLocked(on: connection)
    }

    private func receiveLocked(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let endpoint = connection.endpoint
                do {
                    let event = try PenEventCodec.decode(data)
                    self.log.info("decoded \(event.typeName, privacy: .public) \(data.count)B")
                    Task { @MainActor in
                        self.onEvent?(event, endpoint)
                    }
                } catch let PenEventCodec.CodecError.incompatibleVersion(peerProtocolVersion, peerAppVersion) {
                    self.log.error("incompatible peer: protocol \(peerProtocolVersion), app \(peerAppVersion ?? "unknown", privacy: .public)")
                    Task { @MainActor in
                        self.onIncompatiblePeer?(peerAppVersion, peerProtocolVersion, endpoint)
                    }
                } catch {
                    self.log.error("decode failed: \(error.localizedDescription)")
                }
            }
            if error == nil {
                self.queue.async {
                    self.receiveLocked(on: connection)
                }
            }
        }
    }
}

//
//  WiredTcpServer.swift
//  DrawPad
//
//  TCP listener for the wired (USB) transport (ADR-005). The Mac reaches
//  this over the cable via a `usbmux` relay, not over the network — so
//  unlike the Wi-Fi path, this needs no Bonjour advertising, just a
//  listener bound to the fixed wired port.
//

import Foundation
import Network
import DrawPadProtocol
import os

/// Accepts a single active TCP connection from the Mac (relayed over USB by
/// usbmuxd) and sends length-framed `PenEvent` payloads over it.
/// `isConnected` tracks whether a live connection currently exists, so
/// callers can prefer this transport over Wi-Fi when it's up and fall back
/// to Wi-Fi when it isn't.
@MainActor
final class WiredTcpServer {
    private let log = Logger(subsystem: "com.drawpad.ipad", category: "WiredTcpServer")
    private var listener: NWListener?
    private var activeConnection: NWConnection?

    private(set) var isConnected = false

    /// Called on the main actor whenever `isConnected` changes.
    var onConnectionChange: ((Bool) -> Void)?

    func start() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: Discovery.wiredPort) else {
            log.error("wired listener: invalid port \(Discovery.wiredPort)")
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            log.error("wired listener init failed: \(error.localizedDescription)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in
                    self?.log.error("wired listener failed: \(error.debugDescription)")
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        log.info("wired listener bound to port \(Discovery.wiredPort)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        activeConnection = nil
        setConnected(false)
    }

    private func accept(_ connection: NWConnection) {
        // Only one active client makes sense here — a single Mac receiver
        // over a single cable. Replace any previous connection.
        activeConnection?.cancel()
        activeConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleState(state, for: connection)
            }
        }
        connection.start(queue: .main)
    }

    private func handleState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .ready:
            setConnected(true)
            log.info("wired: Mac connected")
        case .failed, .cancelled:
            guard connection === activeConnection else { return }
            activeConnection = nil
            setConnected(false)
            log.info("wired: Mac disconnected")
        default:
            break
        }
    }

    private func setConnected(_ value: Bool) {
        guard isConnected != value else { return }
        isConnected = value
        onConnectionChange?(value)
    }

    /// Frame and send `payload` (an already-`PenEventCodec`-encoded event)
    /// over the active wired connection. No-op if nothing is connected.
    func send(_ payload: Data) {
        guard let connection = activeConnection else { return }
        let framed = FramedMessage.frame(payload)
        connection.send(content: framed, completion: .contentProcessed { [log] error in
            if let error {
                log.error("wired send failed: \(error.localizedDescription)")
            }
        })
    }
}

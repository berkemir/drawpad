//
//  UdpSender.swift
//  DrawPad
//
//  Sends UDP packets to a single endpoint. We don't need a "connected" UDP
//  socket per se — we just need to write to the same host:port repeatedly.
//  Network framework's NWConnection over UDP gives us that with the usual
//  completion-based send API.
//

import Foundation
import Network
import os

/// Sends `Data` blobs to one host:port over UDP. Thread-safe.
actor UdpSender {
    private var connection: NWConnection?
    private let log = Logger(subsystem: "com.drawpad.ipad", category: "UdpSender")
    private(set) var endpoint: NWEndpoint?

    /// Open a connection to a host:port. Replaces any previous connection.
    func connect(host: String, port: UInt16) {
        disconnect()
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(integerLiteral: port)
        let endpoint = NWEndpoint.hostPort(host: nwHost, port: nwPort)
        let connection = NWConnection(to: endpoint, using: .udp)
        self.connection = connection
        self.endpoint = endpoint
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.markReady() }
            case .failed(let error):
                Task { await self.markFailed(error) }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInteractive))
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        endpoint = nil
    }

    func send(_ data: Data) {
        guard let connection else {
            log.warning("send: no connection")
            return
        }
        connection.send(content: data, completion: .contentProcessed { [log] error in
            if let error {
                log.error("send failed: \(error.localizedDescription)")
            }
        })
    }

    private func markReady() {
        log.info("UDP connection ready → \(self.endpoint?.debugDescription ?? "?")")
    }

    private func markFailed(_ error: NWError) {
        log.error("UDP connection failed: \(error.debugDescription)")
        connection?.cancel()
        connection = nil
    }
}

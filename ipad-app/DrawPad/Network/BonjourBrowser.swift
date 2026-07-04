//
//  BonjourBrowser.swift
//  DrawPad
//
//  Browses for the Mac receiver's Bonjour service. Calls back with the
//  resolved host:port when found. Re-resolves if the service moves.
//

import Foundation
import Network
import DrawPadProtocol
import os

/// Browses for `_drawpad._udp.` services and resolves them to a host:port.
@MainActor
final class BonjourBrowser {

    struct Resolved: Equatable {
        let name: String
        let host: String
        let port: UInt16
    }

    /// Called whenever a new service is resolved, or an existing one vanishes.
    var onChange: (([Resolved]) -> Void)?

    private var browser: NWBrowser?
    private var connections: [NWEndpoint: NWConnection] = [:]
    /// Keyed by the abstract Bonjour service endpoint (stable across the
    /// service's lifetime even if its resolved host:port changes), so a
    /// fresh resolution *replaces* the old one instead of piling up next to
    /// a stale entry that `resolved.first` would keep returning forever.
    private var resolved: [NWEndpoint: Resolved] = [:]
    private let log = Logger(subsystem: "com.drawpad.ipad", category: "BonjourBrowser")
    private let queue = DispatchQueue(label: "com.drawpad.bonjour")

    func start() {
        stop()
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: Discovery.serviceType, domain: Discovery.serviceDomain),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                await self?.handleResults(results)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.log.error("browser failed: \(error.debugDescription)")
            case .waiting(let error):
                self.log.warning("browser waiting: \(error.debugDescription)")
            default:
                break
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for (_, c) in connections { c.cancel() }
        connections = [:]
        resolved = [:]
        onChange?([])
    }

    // MARK: - Resolution

    private func handleResults(_ results: Set<NWBrowser.Result>) async {
        // Drop connections *and* resolutions for endpoints no longer
        // advertised — otherwise a Mac that quit stays in `resolved` forever
        // and keeps winning `resolved.first` over any real, live receiver.
        let currentEndpoints = Set(results.map { $0.endpoint })
        for (endpoint, conn) in connections where !currentEndpoints.contains(endpoint) {
            conn.cancel()
            connections.removeValue(forKey: endpoint)
        }
        for endpoint in resolved.keys where !currentEndpoints.contains(endpoint) {
            resolved.removeValue(forKey: endpoint)
        }

        // Resolve any endpoint we don't currently have a live probe
        // connection for. This covers brand-new services *and* ones whose
        // previous probe failed (see `resolve`, which removes itself from
        // `connections` on failure so we retry here on the next browse tick
        // — e.g. after the Mac receiver restarts and rebinds).
        for result in results where connections[result.endpoint] == nil {
            await resolve(result: result)
        }
        publish()
    }

    private func resolve(result: NWBrowser.Result) async {
        let endpoint = result.endpoint
        let parameters = NWParameters.udp
        let conn = NWConnection(to: endpoint, using: parameters)
        connections[endpoint] = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let inner = conn.currentPath?.remoteEndpoint {
                    let host = Self.hostString(of: inner)
                    let port = Self.port(of: inner) ?? Discovery.defaultPort
                    let name = Self.nameString(of: endpoint) ?? "?"
                    Task { @MainActor in
                        // Replace (keyed by the stable service endpoint) so a
                        // re-resolution after the Mac restarts on a fresh
                        // connection overwrites the old host:port instead of
                        // sitting next to it as a second, stale entry.
                        self.resolved[endpoint] = Resolved(name: name, host: host, port: port)
                        self.publish()
                    }
                }
            case .failed, .cancelled:
                Task { @MainActor in
                    // The probe connection died — most likely the Mac quit
                    // or dropped off the network. Forget it so the next
                    // browse tick retries and can pick up a fresh host:port
                    // once the receiver comes back, without needing the
                    // app to be relaunched.
                    self.connections.removeValue(forKey: endpoint)
                    self.resolved.removeValue(forKey: endpoint)
                    self.publish()
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func publish() {
        onChange?(Array(resolved.values))
    }

    // MARK: - Endpoint inspection

    private nonisolated static func hostString(of endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let ip): return "\(ip)"
            case .ipv6(let ip): return "\(ip)"
            case .name(let n, _): return n
            @unknown default: return "?"
            }
        default:
            return "?"
        }
    }

    private nonisolated static func port(of endpoint: NWEndpoint) -> UInt16? {
        if case .hostPort(_, let port) = endpoint { return port.rawValue }
        return nil
    }

    private nonisolated static func nameString(of endpoint: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = endpoint { return name }
        return nil
    }
}

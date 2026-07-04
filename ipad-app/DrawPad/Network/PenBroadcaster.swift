//
//  PenBroadcaster.swift
//  DrawPad
//
//  Converts PencilEvent from the capture view into PenEvent on the wire,
//  sends via the UdpSender. Owns the seq counter and the monotonic clock.
//

import Foundation
import UIKit
import DrawPadProtocol
import os

/// On the iPad side: takes raw pencil events, normalizes them to the
/// protocol's PenEvent, and sends over whichever transport is currently
/// active — wired (USB, via `WiredTcpServer`) when connected, Wi-Fi (UDP)
/// otherwise. See ADR-005: only one transport is ever used to *send* at a
/// time, since sending the same event over both would double-process it on
/// the Mac (e.g. two `down`s for one touch).
@MainActor
final class PenBroadcaster {

    /// Called after every send, with a one-line human summary for the UI.
    var onSend: ((String) -> Void)?

    /// Called on the main actor whenever the wired transport's connection
    /// state changes, so the UI can show which transport is active.
    var onWiredChange: ((Bool) -> Void)?

    private let sender = UdpSender()
    private let wired = WiredTcpServer()
    private let clock = MonotonicClock()
    private var seq: UInt32 = 0
    private let log = Logger(subsystem: "com.drawpad.ipad", category: "Broadcaster")

    private var capabilities: Set<Capability> = []

    /// Every operation that touches the wire (connect, disconnect, hello,
    /// each pencil event) is chained onto this instead of being spawned as
    /// its own independent `Task`. Independent unstructured Tasks are not
    /// guaranteed to *complete* — and therefore send on the wire — in the
    /// order they were created, once any of them suspends (every send does,
    /// via the actor-isolated `UdpSender`/wired connection). That let a
    /// hover or move sample generated right as the pencil lifted race ahead
    /// of, or land after, the `up` event it should have preceded — the Mac
    /// would then process a stray drag *after* lift-off, drawing a short
    /// stroke toward wherever the pencil was heading as it left the screen.
    /// Chaining each new unit of work after the previous one's completion
    /// guarantees wire order matches call order, which already matches
    /// touch-generation order (UIKit's touch callbacks are synchronous).
    private var sendChain: Task<Void, Never>?

    init() {
        capabilities = detectCapabilities()
        wired.onConnectionChange = { [weak self] connected in
            self?.onWiredChange?(connected)
            // A transport just came up — the Mac's receive pipeline on that
            // transport hasn't seen a `hello` yet (it may have only ever
            // seen one over the *other* transport), so announce ourselves
            // fresh on whichever side just connected.
            guard connected else { return }
            self?.enqueue { await self?.sendHello() }
        }
        wired.start()
    }

    /// Appends `work` to the strict FIFO send chain (see `sendChain`).
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = sendChain
        sendChain = Task {
            _ = await previous?.value
            await work()
        }
    }

    // MARK: - Connection lifecycle

    func connect(host: String, port: UInt16) {
        enqueue { [weak self] in
            guard let self else { return }
            await self.sender.connect(host: host, port: port)
            await self.sendHello()
        }
    }

    func disconnect() {
        enqueue { [weak self] in
            await self?.sender.disconnect()
        }
    }

    // MARK: - Event ingestion

    func process(_ event: PencilEvent) {
        enqueue { [weak self] in
            await self?.sendPencilEvent(event)
        }
    }

    private func sendHello() async {
        let device = UIDevice.current.name
        let os = "iPadOS \(UIDevice.current.systemVersion)"
        let event = PenEvent.makeHello(
            t: clock.nowMs(),
            seq: nextSeq(),
            device: device,
            os: os,
            capabilities: capabilities
        )
        await send(event, summary: "hello")
    }

    private func sendPencilEvent(_ event: PencilEvent) async {
        let now = clock.nowMs()
        let s = nextSeq()
        let wire: PenEvent
        let summary: String
        switch event {
        case let .down(x, y, p, tilt):
            let t = tilt ?? Tilt(altitude: 90, azimuth: 0)
            wire = .makeDown(t: now, seq: s, x: x, y: y, pressure: p, tilt: t)
            summary = "down   (\(x), \(y)) p=\(p)"
        case let .move(x, y, p, tilt):
            let t = tilt ?? Tilt(altitude: 90, azimuth: 0)
            wire = .makeMove(t: now, seq: s, x: x, y: y, pressure: p, tilt: t)
            summary = "move   (\(x), \(y)) p=\(p)"
        case let .up(x, y):
            wire = .makeUp(t: now, seq: s, x: x, y: y)
            summary = "up     (\(x), \(y))"
        case let .hover(x, y):
            wire = .makeHover(t: now, seq: s, x: x, y: y)
            summary = "hover  (\(x), \(y))"
        case let .cancel(x, y):
            // Treat cancellation as up — never leave a pen-down hanging.
            wire = .makeUp(t: now, seq: s, x: x, y: y)
            summary = "cancel (\(x), \(y))"
        }
        await send(wire, summary: summary)
    }

    private func send(_ event: PenEvent, summary: String) async {
        do {
            let data = try PenEventCodec.encode(event)
            if wired.isConnected {
                wired.send(data)
            } else {
                await sender.send(data)
            }
            onSend?(summary)
        } catch {
            log.error("encode failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func nextSeq() -> UInt32 {
        seq &+= 1
        return seq
    }

    private func detectCapabilities() -> Set<Capability> {
        var caps: Set<Capability> = [.pressure, .tilt]
        if #available(iOS 16.4, *) {
            caps.insert(.hover)
        }
        if #available(iOS 17.5, *) {
            caps.insert(.barrel)
            caps.insert(.doubleTap)
            caps.insert(.squeeze)
        }
        return caps
    }
}

/// Monotonic clock. ms since boot.
struct MonotonicClock: Sendable {
    func nowMs() -> UInt64 {
        let ns = mach_absolute_time()
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ms = (ns &* UInt64(info.numer)) / (UInt64(info.denom) &* 1_000_000)
        return ms
    }
}

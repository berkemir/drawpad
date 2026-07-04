//
//  WiredUsbListener.swift
//  DrawPad
//
//  Mac-side half of the wired (USB) transport (ADR-005). Watches for a
//  USB-attached iPad via `UsbmuxClient`, opens a raw relay to the iPad's
//  wired TCP listener over the cable once it's up, and decodes
//  length-framed PenEvent messages from the stream — feeding them into the
//  exact same pipeline as the Wi-Fi `UdpListener`. Losing the cable just
//  means events stop arriving on this path; Wi-Fi keeps working regardless.
//

import Foundation
import Darwin
import DrawPadProtocol
import os

final class WiredUsbListener {
    private let log = Logger(subsystem: "com.drawpad.mac", category: "WiredUsb")
    private let usbmux = UsbmuxClient()
    private let queue = DispatchQueue(label: "com.drawpad.wired")

    /// Called for every decoded event. Invoked on the main queue.
    @MainActor var onEvent: ((PenEvent) -> Void)?

    /// Called on the main queue whenever the wired relay connects or drops.
    @MainActor var onConnectionChange: ((Bool) -> Void)?

    /// Called when a message arrives whose protocol version we can't
    /// decode. Invoked on the main queue.
    @MainActor var onIncompatiblePeer: ((_ peerAppVersion: String?, _ peerProtocolVersion: UInt32) -> Void)?

    private var relayFd: Int32 = -1
    private var currentDevice: UsbmuxClient.Device?
    private var retryWorkItem: DispatchWorkItem?
    /// Bumped on every device change / stop(); lets a stale retry or a
    /// just-finished read loop recognize it's been superseded and no-op
    /// instead of acting on out-of-date state. Only ever read or written
    /// while on `queue`.
    private var generation = 0

    func start() {
        usbmux.startMonitoring { [weak self] devices in
            self?.queue.async { self?.handleDevices(devices) }
        }
    }

    func stop() {
        usbmux.stopMonitoring()
        queue.async { [weak self] in self?.teardownRelay() }
    }

    // MARK: - Device tracking (all on `queue`)

    private func handleDevices(_ devices: [UsbmuxClient.Device]) {
        let usbDevice = devices.first { $0.isUSB }
        if let usbDevice, usbDevice != currentDevice {
            teardownRelay()
            currentDevice = usbDevice
            generation += 1
            attemptRelay(to: usbDevice, generation: generation)
        } else if usbDevice == nil, currentDevice != nil {
            teardownRelay()
        }
    }

    private func attemptRelay(to device: UsbmuxClient.Device, generation: Int) {
        queue.async { [weak self] in
            guard let self, self.generation == generation else { return }
            do {
                let fd = try self.usbmux.openRelay(to: device, port: Discovery.wiredPort)
                self.relayFd = fd
                self.log.info("wired: relay established to \(device.serial, privacy: .public)")
                self.setConnected(true)
                let thread = Thread { [weak self] in
                    self?.readLoop(fd: fd, generation: generation)
                }
                thread.name = "com.drawpad.wired.read"
                thread.start()
            } catch {
                // Most likely: the iPad app isn't running (or hasn't
                // started its wired listener) yet, even though the cable
                // is plugged in. Keep retrying — there's no signal that
                // tells us when the app launches other than trying again.
                self.log.info("wired: relay not ready yet (\(String(describing: error))), retrying")
                self.scheduleRetry(to: device, generation: generation)
            }
        }
    }

    private func scheduleRetry(to device: UsbmuxClient.Device, generation: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.attemptRelay(to: device, generation: generation)
        }
        retryWorkItem = work
        queue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - Read loop (runs on its own dedicated thread, NOT `queue` —
    // it blocks for the life of the connection, and `queue` must stay free
    // to keep handling device attach/detach in the meantime)

    private func readLoop(fd: Int32, generation: Int) {
        let reader = FrameReader()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                log.info("wired: relay read ended: \(String(cString: strerror(errno)))")
                break
            }
            if n == 0 {
                log.info("wired: relay closed by peer")
                break
            }
            let chunk = Data(buf[0..<n])
            for message in reader.feed(chunk) {
                do {
                    let event = try PenEventCodec.decode(message)
                    Task { @MainActor [weak self] in
                        self?.onEvent?(event)
                    }
                } catch let PenEventCodec.CodecError.incompatibleVersion(peerProtocolVersion, peerAppVersion) {
                    log.error("wired: incompatible peer: protocol \(peerProtocolVersion), app \(peerAppVersion ?? "unknown", privacy: .public)")
                    Task { @MainActor [weak self] in
                        self?.onIncompatiblePeer?(peerAppVersion, peerProtocolVersion)
                    }
                } catch {
                    log.error("wired: decode failed: \(error.localizedDescription)")
                }
            }
        }
        // `close(fd)` from `teardownRelayFd()` (called on `queue`, possibly
        // concurrently) is exactly what unblocks a `read()` call in
        // progress on this thread — that's the intended shutdown path, not
        // a race to guard against.
        queue.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.teardownRelayFd()
            self.setConnected(false)
            if let device = self.currentDevice {
                self.scheduleRetry(to: device, generation: generation)
            }
        }
    }

    // MARK: - Teardown

    private func teardownRelay() {
        generation += 1
        retryWorkItem?.cancel()
        retryWorkItem = nil
        currentDevice = nil
        teardownRelayFd()
        setConnected(false)
    }

    private func teardownRelayFd() {
        if relayFd >= 0 {
            close(relayFd)
            relayFd = -1
        }
    }

    private func setConnected(_ value: Bool) {
        Task { @MainActor [weak self] in
            self?.onConnectionChange?(value)
        }
    }
}

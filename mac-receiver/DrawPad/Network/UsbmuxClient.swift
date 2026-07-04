//
//  UsbmuxClient.swift
//  DrawPad
//
//  Minimal client for Apple's `usbmuxd` protocol — the same daemon macOS
//  already runs for Xcode/iTunes device connectivity (socket at
//  /var/run/usbmuxd). Lets us detect a USB-attached iPad and relay a raw
//  TCP tunnel to a fixed port on it over the cable, for the wired transport
//  (ADR-005).
//
//  Deliberately reimplements the small documented subset of the plist-based
//  usbmux wire protocol in plain Swift/Darwin sockets rather than depending
//  on libimobiledevice: that library isn't installed by default (confirmed:
//  no Homebrew install, no `iproxy` on this machine), and requiring end
//  users to install it via Homebrew is a poor shipping story for a
//  consumer app. This keeps the wired path dependency-free.
//
//  Protocol shape (stable since iOS 5, used by every usbmuxd client
//  including Xcode itself): every message is a 16-byte little-endian
//  header (length, version=1, message=8 for "plist", tag) followed by an
//  XML plist body. `Connect` is special: on a `Number: 0` (success)
//  response, the *same* socket stops speaking usbmux framing and becomes a
//  raw, bidirectional byte pipe straight to the requested port on the
//  device.
//

import Foundation
import Darwin
import os

public final class UsbmuxClient {

    public struct Device: Equatable, Hashable {
        public let id: Int
        public let serial: String
        public let connectionType: String // "USB" or "Network"
        public var isUSB: Bool { connectionType == "USB" }
    }

    public enum UsbmuxError: Error, CustomStringConvertible {
        case io(String)
        case malformed(String)
        case connectRejected(Int)

        public var description: String {
            switch self {
            case .io(let m): return "usbmux I/O error: \(m)"
            case .malformed(let m): return "usbmux malformed response: \(m)"
            case .connectRejected(let code): return "usbmux Connect rejected (code \(code))"
            }
        }
    }

    private static let socketPath = "/var/run/usbmuxd"
    private static let plistVersion: UInt32 = 1
    private static let plistMessageType: UInt32 = 8

    private let log = Logger(subsystem: "com.drawpad.mac", category: "Usbmux")

    private var tagCounter: UInt32 = 0
    private let tagLock = NSLock()

    private var monitorThread: Thread?
    private let monitorLock = NSLock()
    private var monitorSocket: Int32 = -1
    private var knownDevices: [Int: Device] = [:]

    public init() {}

    // MARK: - One-shot requests

    /// Devices usbmuxd currently knows about (USB-attached or
    /// network-paired). Blocks the calling thread — call off the main queue.
    public func listDevices() throws -> [Device] {
        let fd = try openSocket(readTimeoutSeconds: 3)
        defer { close(fd) }
        try sendPlistMessage(fd, [
            "MessageType": "ListDevices",
            "ClientVersionString": "DrawPad",
            "ProgName": "DrawPad",
            "kLibUSBMuxVersion": 3,
        ], tag: nextTag())
        let response = try readPlistMessage(fd)
        guard let list = response["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap(Self.parseDeviceEntry)
    }

    /// Opens a raw TCP relay to `port` on `device`, over the USB cable via
    /// usbmuxd. On success, the returned file descriptor is a plain
    /// bidirectional byte pipe to that port on the device — no more usbmux
    /// framing on it, no more plist messages. The caller owns the fd from
    /// this point on and must `close()` it. Blocks the calling thread.
    public func openRelay(to device: Device, port: UInt16) throws -> Int32 {
        let fd = try openSocket(readTimeoutSeconds: 3)
        do {
            try sendPlistMessage(fd, [
                "MessageType": "Connect",
                "ClientVersionString": "DrawPad",
                "ProgName": "DrawPad",
                "DeviceID": device.id,
                // usbmuxd wants the port in network byte order, encoded as
                // a normal (host-endian) plist integer — i.e. you byte-swap
                // the port value itself, you don't change how the integer
                // is written. Easy to get backwards; this is the
                // well-documented gotcha of this protocol.
                "PortNumber": Int(port.byteSwapped),
            ], tag: nextTag())
            let response = try readPlistMessage(fd)
            let code = (response["Number"] as? Int) ?? -1
            guard code == 0 else { throw UsbmuxError.connectRejected(code) }
            // Relay is live: disable the handshake read timeout so normal
            // stream reads (which can legitimately idle) don't spuriously
            // time out.
            setReadTimeout(fd, seconds: 0)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    // MARK: - Continuous monitoring ("Listen")

    /// Starts watching for device attach/detach on a background thread.
    /// Calls `onChange` on the main queue with the full current device list
    /// every time it changes. Call `stopMonitoring()` before starting again.
    public func startMonitoring(onChange: @escaping ([Device]) -> Void) {
        stopMonitoring()
        let thread = Thread { [weak self] in
            self?.monitorLoop(onChange: onChange)
        }
        thread.name = "com.drawpad.usbmux.monitor"
        thread.start()
        monitorThread = thread
    }

    public func stopMonitoring() {
        monitorLock.lock()
        let fd = monitorSocket
        monitorSocket = -1
        monitorLock.unlock()
        if fd >= 0 { close(fd) }
        monitorThread = nil
        knownDevices = [:]
    }

    private func monitorLoop(onChange: @escaping ([Device]) -> Void) {
        let fd: Int32
        do {
            fd = try openSocket(readTimeoutSeconds: 3)
        } catch {
            log.error("usbmux monitor: failed to open socket: \(String(describing: error))")
            return
        }
        monitorLock.lock()
        monitorSocket = fd
        monitorLock.unlock()

        do {
            try sendPlistMessage(fd, [
                "MessageType": "Listen",
                "ClientVersionString": "DrawPad",
                "ProgName": "DrawPad",
            ], tag: nextTag())
            // The first response just acknowledges the Listen request.
            _ = try readPlistMessage(fd)
            // Attach/detach notifications can be arbitrarily far apart —
            // block indefinitely waiting for them instead of timing out.
            setReadTimeout(fd, seconds: 0)

            while true {
                monitorLock.lock()
                let stillActive = (monitorSocket == fd)
                monitorLock.unlock()
                guard stillActive else { break }

                let message = try readPlistMessage(fd)
                guard let type = message["MessageType"] as? String else { continue }
                switch type {
                case "Attached":
                    if let entry = Self.parseDeviceEntry(message) {
                        knownDevices[entry.id] = entry
                        publish(onChange)
                    }
                case "Detached":
                    if let id = message["DeviceID"] as? Int {
                        knownDevices.removeValue(forKey: id)
                        publish(onChange)
                    }
                default:
                    break
                }
            }
        } catch {
            log.info("usbmux monitor loop ended: \(String(describing: error))")
        }
    }

    private func publish(_ onChange: @escaping ([Device]) -> Void) {
        let devices = Array(knownDevices.values)
        DispatchQueue.main.async { onChange(devices) }
    }

    // MARK: - Parsing

    private static func parseDeviceEntry(_ entry: [String: Any]) -> Device? {
        guard let id = entry["DeviceID"] as? Int,
              let props = entry["Properties"] as? [String: Any],
              let serial = props["SerialNumber"] as? String else { return nil }
        let connType = props["ConnectionType"] as? String ?? "?"
        return Device(id: id, serial: serial, connectionType: connType)
    }

    // MARK: - Socket plumbing

    private func nextTag() -> UInt32 {
        tagLock.lock(); defer { tagLock.unlock() }
        tagCounter += 1
        return tagCounter
    }

    /// `readTimeoutSeconds`: 0 disables the timeout (block indefinitely) —
    /// matches `SO_RCVTIMEO` semantics.
    private func openSocket(readTimeoutSeconds: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UsbmuxError.io("socket() failed: \(String(cString: strerror(errno)))")
        }

        // Without this, the peer (usbmuxd, or the device on the other end
        // of a relay) closing the connection while we're mid-`write` sends
        // us SIGPIPE, whose default action is to kill the whole process —
        // unacceptable for a long-running receiver app.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: CChar.self)
            for (i, byte) in Self.socketPath.utf8CString.enumerated() where i < buf.count {
                buf[i] = byte
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, len)
            }
        }
        guard rc == 0 else {
            let err = String(cString: strerror(errno))
            close(fd)
            throw UsbmuxError.io("connect() to \(Self.socketPath) failed: \(err) — is usbmuxd running?")
        }

        setReadTimeout(fd, seconds: readTimeoutSeconds)
        return fd
    }

    private func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func sendPlistMessage(_ fd: Int32, _ dict: [String: Any], tag: UInt32) throws {
        let body: Data
        do {
            body = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        } catch {
            throw UsbmuxError.malformed("failed to encode request plist: \(error)")
        }
        var header = Data()
        for v: UInt32 in [UInt32(16 + body.count), Self.plistVersion, Self.plistMessageType, tag] {
            header.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) })
        }
        try writeAll(fd, header + body)
    }

    private func readPlistMessage(_ fd: Int32) throws -> [String: Any] {
        let header = try readExact(fd, count: 16)
        let base = header.startIndex
        let length = UInt32(header[base])
            | (UInt32(header[base + 1]) << 8)
            | (UInt32(header[base + 2]) << 16)
            | (UInt32(header[base + 3]) << 24)
        guard length >= 16 else { throw UsbmuxError.malformed("header length \(length) < 16") }
        let bodyLength = Int(length) - 16
        let body = bodyLength > 0 ? try readExact(fd, count: bodyLength) : Data()
        guard
            let plist = try PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any]
        else {
            throw UsbmuxError.malformed("response body isn't a plist dictionary")
        }
        return plist
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UsbmuxError.io("write failed: \(String(cString: strerror(errno)))")
                }
                if n == 0 { throw UsbmuxError.io("write returned 0 (peer closed)") }
                offset += n
            }
        }
    }

    private func readExact(_ fd: Int32, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buf = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base.advanced(by: offset), count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw UsbmuxError.io("read failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 { throw UsbmuxError.io("connection closed by peer") }
            offset += n
        }
        return Data(buf)
    }
}

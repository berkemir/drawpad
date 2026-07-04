//
//  FramedStream.swift
//  DrawPadProtocol
//
//  Length-prefixed message framing for the TCP-based wired transport
//  (ADR-005). UDP already preserves datagram boundaries — one `send()` is
//  exactly one `receive()` — but TCP is a raw byte stream with no message
//  boundaries at all, so a wired PenEvent (encoded the same way as the
//  Wi-Fi path, via `PenEventCodec`) needs an explicit length prefix so the
//  reader knows where one message ends and the next begins.
//

import Foundation

public enum FramedMessage {
    /// Prefix `payload` with its length as a 4-byte big-endian `UInt32`.
    /// The event encoding itself (JSON, via `PenEventCodec`) is unchanged —
    /// this only adds the delimiter TCP doesn't provide for free.
    public static func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: length) { Data($0) }
        framed.append(payload)
        return framed
    }
}

/// Accumulates raw bytes as they arrive from a TCP stream and yields
/// complete, length-prefixed payloads as they become available. Feed it
/// every chunk read from the socket, in order; a single `feed` call may
/// yield zero, one, or several messages depending on how the stream
/// happened to chunk them.
///
/// Deliberately indexes off `buffer.startIndex` rather than literal `0`
/// throughout: `Data.removeSubrange` does not guarantee the remaining
/// value's `startIndex` resets to 0, and assuming it does is a well-known
/// source of silent corruption bugs with `Data` buffers.
public final class FrameReader {
    private var buffer = Data()

    public init() {}

    public func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while true {
            let base = buffer.startIndex
            guard buffer.count >= 4 else { break }
            let length = Int(buffer[base]) << 24
                | Int(buffer[base + 1]) << 16
                | Int(buffer[base + 2]) << 8
                | Int(buffer[base + 3])
            guard buffer.count >= 4 + length else { break }
            let payloadStart = base + 4
            let payloadEnd = payloadStart + length
            messages.append(buffer.subdata(in: payloadStart..<payloadEnd))
            buffer.removeSubrange(base..<payloadEnd)
        }
        return messages
    }
}

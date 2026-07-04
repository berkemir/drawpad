//
//  LatencyProbe.swift
//  DrawPadProtocol
//
//  Round-trip latency measurement. Either side can ping; the other pongs.
//  LatencyProbe tracks outstanding nonces and reports RTT.
//

import Foundation

public actor LatencyProbe {
    private struct Pending {
        let sentAt: UInt64
    }

    private var pending: [String: Pending] = [:]
    private var counter: UInt32 = 0
    private let clock: () -> UInt64

    public init(clock: @escaping () -> UInt64 = { LatencyProbe.now() }) {
        self.clock = clock
    }

    /// Generate a unique nonce for an outgoing ping, and remember the send
    /// time so we can compute RTT when the pong arrives.
    public func makePing() -> (nonce: String, t: UInt64) {
        counter &+= 1
        let nonce = "n\(counter)"
        let t = clock()
        pending[nonce] = Pending(sentAt: t)
        return (nonce, t)
    }

    /// Call when you receive a `pong`. Returns the RTT in ms, or nil if the
    /// nonce wasn't one of ours (or was already consumed).
    public func receivePong(nonce: String) -> UInt64? {
        guard let p = pending.removeValue(forKey: nonce) else { return nil }
        return clock() &- p.sentAt
    }

    /// Monotonic ms on the sender's clock. Override for tests.
    public static func now() -> UInt64 {
        // mach_absolute_time gives us monotonic ns. Convert to ms.
        let ns = mach_absolute_time()
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ms = (ns &* UInt64(info.numer)) / (UInt64(info.denom) &* 1_000_000)
        return ms
    }
}

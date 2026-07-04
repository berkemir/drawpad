//
//  LatencyProbeTests.swift
//  DrawPadProtocolTests
//

import XCTest
@testable import DrawPadProtocol

final class LatencyProbeTests: XCTestCase {

    func testMakePingReturnsUniqueNonces() async {
        let probe = LatencyProbe(clock: { 0 })
        let a = await probe.makePing()
        let b = await probe.makePing()
        XCTAssertNotEqual(a.nonce, b.nonce)
    }

    func testReceivePongReturnsRTT() async {
        var clockValue: UInt64 = 100
        let probe = LatencyProbe(clock: { clockValue })
        let ping = await probe.makePing()
        clockValue = 108
        let rtt = await probe.receivePong(nonce: ping.nonce)
        XCTAssertEqual(rtt, 8)
    }

    func testReceivePongUnknownNonceReturnsNil() async {
        let probe = LatencyProbe(clock: { 0 })
        let rtt = await probe.receivePong(nonce: "nope")
        XCTAssertNil(rtt)
    }

    func testEachPongIsConsumedOnce() async {
        let probe = LatencyProbe(clock: { 0 })
        let ping = await probe.makePing()
        _ = await probe.receivePong(nonce: ping.nonce)
        // Second receive returns nil — the nonce was consumed.
        let rtt2 = await probe.receivePong(nonce: ping.nonce)
        XCTAssertNil(rtt2)
    }
}

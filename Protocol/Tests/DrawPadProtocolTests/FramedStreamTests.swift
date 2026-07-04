//
//  FramedStreamTests.swift
//  DrawPadProtocolTests
//

import XCTest
@testable import DrawPadProtocol

final class FramedStreamTests: XCTestCase {

    func testFrameThenFeedWholeYieldsOneMessage() {
        let payload = "hello".data(using: .utf8)!
        let framed = FramedMessage.frame(payload)
        let reader = FrameReader()
        XCTAssertEqual(reader.feed(framed), [payload])
    }

    func testEmptyPayloadRoundTrips() {
        let payload = Data()
        let framed = FramedMessage.frame(payload)
        let reader = FrameReader()
        XCTAssertEqual(reader.feed(framed), [payload])
    }

    func testMultipleMessagesInOneChunk() {
        let a = "one".data(using: .utf8)!
        let b = "two".data(using: .utf8)!
        let c = "three".data(using: .utf8)!
        let chunk = FramedMessage.frame(a) + FramedMessage.frame(b) + FramedMessage.frame(c)
        let reader = FrameReader()
        XCTAssertEqual(reader.feed(chunk), [a, b, c])
    }

    func testMessageSplitAcrossManyTinyChunks() {
        let payload = "a somewhat longer payload to split into pieces".data(using: .utf8)!
        let framed = FramedMessage.frame(payload)
        let reader = FrameReader()

        var collected: [Data] = []
        for byte in framed {
            collected.append(contentsOf: reader.feed(Data([byte])))
        }
        XCTAssertEqual(collected, [payload])
    }

    func testLengthPrefixSplitFromPayload() {
        // Split right in the middle of the 4-byte length prefix itself.
        let payload = "x".data(using: .utf8)!
        let framed = FramedMessage.frame(payload)
        let reader = FrameReader()

        XCTAssertEqual(reader.feed(framed.prefix(2)), [])
        XCTAssertEqual(reader.feed(framed.suffix(from: 2)), [payload])
    }

    func testPartialMessageThenCompletion() {
        let payload = "partial-then-complete".data(using: .utf8)!
        let framed = FramedMessage.frame(payload)
        let splitPoint = framed.count - 3
        let reader = FrameReader()

        XCTAssertEqual(reader.feed(framed.prefix(splitPoint)), [])
        XCTAssertEqual(reader.feed(framed.suffix(from: splitPoint)), [payload])
    }

    func testTrailingBytesOfNextMessageStayBuffered() {
        let a = "first".data(using: .utf8)!
        let b = "second".data(using: .utf8)!
        let framedA = FramedMessage.frame(a)
        let framedB = FramedMessage.frame(b)
        let reader = FrameReader()

        // Feed message A plus the first few bytes of message B's frame.
        let firstChunk = framedA + framedB.prefix(3)
        XCTAssertEqual(reader.feed(firstChunk), [a])

        // Now the rest of B arrives.
        XCTAssertEqual(reader.feed(framedB.suffix(from: 3)), [b])
    }

    func testFrameLengthPrefixIsBigEndian() {
        let payload = Data([0x01, 0x02, 0x03])
        let framed = FramedMessage.frame(payload)
        // 3 bytes -> 0x00000003, big-endian bytes: 00 00 00 03
        XCTAssertEqual(Array(framed.prefix(4)), [0x00, 0x00, 0x00, 0x03])
    }

    func testRoundTripsRealPenEventEncoding() throws {
        let event = PenEvent.makeMove(
            t: 1234, seq: 1, x: 0.5, y: 0.5, pressure: 0.8,
            tilt: Tilt(altitude: 45, azimuth: 90)
        )
        let encoded = try PenEventCodec.encode(event)
        let framed = FramedMessage.frame(encoded)
        let reader = FrameReader()
        let messages = reader.feed(framed)
        XCTAssertEqual(messages.count, 1)
        let decoded = try PenEventCodec.decode(messages[0])
        XCTAssertEqual(decoded, event)
    }
}

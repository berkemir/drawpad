//
//  CodecTests.swift
//  DrawPadProtocolTests
//

import XCTest
@testable import DrawPadProtocol

final class CodecTests: XCTestCase {

    // MARK: - Round-trip: every event type

    func testRoundTripHello() throws {
        let event = PenEvent.makeHello(
            t: 100, seq: 1,
            device: "iPad Pro 12.9 (5th gen)",
            os: "iPadOS 17.4",
            capabilities: [.hover, .pressure, .tilt, .barrel, .squeeze]
        )
        let data = try PenEventCodec.encode(event)
        let json = String(data: data, encoding: .utf8)!
        let decoded = try PenEventCodec.decode(data)
        XCTAssertEqual(decoded, event)
        // Spot-check the wire shape.
        XCTAssertTrue(json.contains("\"v\":1"))
        XCTAssertTrue(json.contains("\"type\":\"hello\""))
        XCTAssertTrue(json.contains("\"device\":\"iPad Pro 12.9 (5th gen)\""))
    }

    func testRoundTripPing() throws {
        let event = PenEvent.makePing(t: 200, seq: 5, nonce: "abc123")
        let data = try PenEventCodec.encode(event)
        XCTAssertEqual(try PenEventCodec.decode(data), event)
    }

    func testRoundTripPong() throws {
        let event = PenEvent.makePong(t: 250, seq: 6, nonce: "abc123")
        let data = try PenEventCodec.encode(event)
        XCTAssertEqual(try PenEventCodec.decode(data), event)
    }

    func testRoundTripBye() throws {
        let event = PenEvent.makeBye(t: 1000, seq: 100)
        let data = try PenEventCodec.encode(event)
        XCTAssertEqual(try PenEventCodec.decode(data), event)
    }

    func testRoundTripHover() throws {
        let event = PenEvent.makeHover(
            t: 100, seq: 1,
            x: 0.42, y: 0.31,
            tilt: Tilt(altitude: 32.5, azimuth: 145.0)
        )
        let data = try PenEventCodec.encode(event)
        XCTAssertEqual(try PenEventCodec.decode(data), event)
    }

    func testRoundTripHoverWithoutTilt() throws {
        let event = PenEvent.makeHover(t: 100, seq: 1, x: 0.42, y: 0.31)
        let data = try PenEventCodec.encode(event)
        let decoded = try PenEventCodec.decode(data)
        XCTAssertEqual(decoded, event)
        // Tilt fields should be absent from the wire.
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("alt"))
        XCTAssertFalse(json.contains("azi"))
    }

    func testRoundTripDown() throws {
        let event = PenEvent.makeDown(
            t: 200, seq: 2,
            x: 0.5, y: 0.5,
            pressure: 0.87,
            tilt: Tilt(altitude: 45, azimuth: 90)
        )
        let data = try PenEventCodec.encode(event)
        XCTAssertEqual(try PenEventCodec.decode(data), event)
    }

    func testRoundTripMove() throws {
        let event = PenEvent.makeMove(
            t: 250, seq: 3,
            x: 0.51, y: 0.49,
            pressure: 0.6,
            tilt: Tilt(altitude: 50, azimuth: 95)
        )
        let data = try PenEventCodec.encode(event)
        XCTAssertEqual(try PenEventCodec.decode(data), event)
    }

    func testRoundTripUp() throws {
        let event = PenEvent.makeUp(t: 300, seq: 4, x: 0.6, y: 0.4)
        let data = try PenEventCodec.encode(event)
        XCTAssertEqual(try PenEventCodec.decode(data), event)
    }

    func testRoundTripButton() throws {
        let event = PenEvent.makeButton(t: 100, seq: 1, kind: .barrel, state: .down)
        let data = try PenEventCodec.encode(event)
        let decoded = try PenEventCodec.decode(data)
        XCTAssertEqual(decoded, event)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"kind\":\"barrel\""))
        XCTAssertTrue(json.contains("\"state\":\"down\""))
    }

    func testRoundTripModifiers() throws {
        let mask: ModifierMask = .command.union(.shift)
        let event = PenEvent.makeModifiers(t: 100, seq: 1, mask: mask)
        let data = try PenEventCodec.encode(event)
        let decoded = try PenEventCodec.decode(data)
        XCTAssertEqual(decoded, event)
        let json = String(data: data, encoding: .utf8)!
        // command (1) | shift (2) = 3
        XCTAssertTrue(json.contains("\"mask\":3"))
    }

    // MARK: - Wire shape spot-checks

    func testMoveWireFormatMatchesSpec() throws {
        let event = PenEvent.makeMove(
            t: 1234, seq: 51,
            x: 0.42, y: 0.31,
            pressure: 0.87,
            tilt: Tilt(altitude: 32.5, azimuth: 145.0)
        )
        let data = try PenEventCodec.encode(event)
        let json = String(data: data, encoding: .utf8)!
        // Field order in JSONEncoder is implementation-defined; check presence + types.
        XCTAssertTrue(json.contains("\"v\":1"))
        XCTAssertTrue(json.contains("\"type\":\"move\""))
        XCTAssertTrue(json.contains("\"t\":1234"))
        XCTAssertTrue(json.contains("\"seq\":51"))
        XCTAssertTrue(json.contains("\"x\":0.42"))
        XCTAssertTrue(json.contains("\"y\":0.31"))
        XCTAssertTrue(json.contains("\"p\":0.87"))
        XCTAssertTrue(json.contains("\"alt\":32.5"))
        XCTAssertTrue(json.contains("\"azi\":145"))
    }

    // MARK: - Decoder errors

    func testDecoderRejectsBadVersion() {
        let json = #"{"v":99, "appVersion":"9.9", "type":"ping", "t":1, "seq":1, "nonce":"x"}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data)) { error in
            guard case PenEventCodec.CodecError.incompatibleVersion(let pv, let av) = error else {
                XCTFail("expected incompatibleVersion, got \(error)")
                return
            }
            XCTAssertEqual(pv, 99)
            XCTAssertEqual(av, "9.9")
        }
    }

    func testDecoderRejectsBadVersionEvenWithoutAppVersionField() {
        // Older senders (before appVersion existed) still get a clean
        // incompatibleVersion error, just with a nil app version.
        let json = #"{"v":99, "type":"ping", "t":1, "seq":1, "nonce":"x"}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data)) { error in
            guard case PenEventCodec.CodecError.incompatibleVersion(let pv, let av) = error else {
                XCTFail("expected incompatibleVersion, got \(error)")
                return
            }
            XCTAssertEqual(pv, 99)
            XCTAssertNil(av)
        }
    }

    func testDecoderRejectsUnknownType() {
        let json = #"{"v":1, "type":"wiggle", "t":1, "seq":1}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data)) { error in
            guard case PenEventCodec.CodecError.unknownType("wiggle") = error else {
                XCTFail("expected unknownType(\"wiggle\"), got \(error)")
                return
            }
        }
    }

    func testDecoderRejectsMissingRequiredField() {
        // hover without x
        let json = #"{"v":1, "type":"hover", "t":1, "seq":1, "y":0.3}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data)) { error in
            guard case PenEventCodec.CodecError.missingField("x") = error else {
                XCTFail("expected missingField(\"x\"), got \(error)")
                return
            }
        }
    }

    func testDecoderRejectsMalformedJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data)) { error in
            guard case PenEventCodec.CodecError.malformed = error else {
                XCTFail("expected malformed, got \(error)")
                return
            }
        }
    }

    // MARK: - Validation: 0..1 ranges

    func testDecoderRejectsXOutOfRange() {
        let json = #"{"v":1, "type":"hover", "t":1, "seq":1, "x":1.5, "y":0.3}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data)) { error in
            guard case PenEventCodec.CodecError.invalidField = error else {
                XCTFail("expected invalidField, got \(error)")
                return
            }
        }
    }

    func testDecoderRejectsYOutOfRange() {
        let json = #"{"v":1, "type":"up", "t":1, "seq":1, "x":0.5, "y":-0.1}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data)) { error in
            guard case PenEventCodec.CodecError.invalidField = error else {
                XCTFail("expected invalidField, got \(error)")
                return
            }
        }
    }

    func testDecoderRejectsPressureOutOfRange() {
        let json = #"{"v":1, "type":"down", "t":1, "seq":1, "x":0.5, "y":0.5, "p":2.0, "alt":45, "azi":90}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data))
    }

    // MARK: - Tilt validation

    func testDecoderRejectsPartialTilt() {
        // alt present, azi missing on hover (where tilt is optional,
        // but partial is still invalid)
        let json = #"{"v":1, "type":"hover", "t":1, "seq":1, "x":0.5, "y":0.5, "alt":45}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data)) { error in
            guard case PenEventCodec.CodecError.invalidField = error else {
                XCTFail("expected invalidField for partial tilt, got \(error)")
                return
            }
        }
    }

    func testDecoderRejectsDownWithoutTilt() {
        // down requires tilt
        let json = #"{"v":1, "type":"down", "t":1, "seq":1, "x":0.5, "y":0.5, "p":0.5}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try PenEventCodec.decode(data)) { error in
            guard case PenEventCodec.CodecError.missingField("alt") = error else {
                XCTFail("expected missingField(\"alt\"), got \(error)")
                return
            }
        }
    }

    // MARK: - Capabilities round-trip

    func testCapabilitiesSortedOnWire() throws {
        let event = PenEvent.makeHello(
            t: 1, seq: 1,
            device: "test",
            os: "iPadOS",
            capabilities: [.tilt, .pressure, .hover, .barrel]
        )
        let data = try PenEventCodec.encode(event)
        let json = String(data: data, encoding: .utf8)!
        // capabilities should be sorted: barrel, hover, pressure, tilt
        XCTAssertTrue(json.contains("\"capabilities\":[\"barrel\",\"hover\",\"pressure\",\"tilt\"]"))
    }

    // MARK: - Modifiers

    func testModifierMaskBitOps() {
        let combined: ModifierMask = .command.union(.shift)
        XCTAssertTrue(combined.contains(.command))
        XCTAssertTrue(combined.contains(.shift))
        XCTAssertFalse(combined.contains(.option))
        XCTAssertEqual(combined.raw, 0b0011)

        let cleared = combined.subtracting(.shift)
        XCTAssertTrue(cleared.contains(.command))
        XCTAssertFalse(cleared.contains(.shift))
    }
}

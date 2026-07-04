//
//  DiscoveryTests.swift
//  DrawPadProtocolTests
//

import XCTest
@testable import DrawPadProtocol

final class DiscoveryTests: XCTestCase {
    func testServiceTypeMatchesSpec() {
        XCTAssertEqual(Discovery.serviceType, "_drawpad._udp.")
    }

    func testDefaultPortMatchesSpec() {
        XCTAssertEqual(Discovery.defaultPort, 7359)
    }

    func testServiceDomainIsLocal() {
        XCTAssertEqual(Discovery.serviceDomain, "local.")
    }

    func testServiceNameForDevice() {
        XCTAssertEqual(
            Discovery.serviceName(for: "Berk's iPad"),
            "DrawPad on Berk's iPad"
        )
    }
}

//
//  SessionState.swift
//  DrawPad
//
//  Top-level state for the iPad app. Owns the broadcaster and the Bonjour
//  browser. Tracks the connection state for the UI.
//

import Foundation
import SwiftUI
import UIKit
import DrawPadProtocol
import os

@Observable
@MainActor
final class SessionState {

    enum Connection: Equatable {
        case disconnected
        case searching
        case connected(host: String)
    }

    private(set) var connection: Connection = .disconnected
    private(set) var isWiredConnected = false
    private(set) var eventCount: Int = 0
    private(set) var lastEventSummary: String = "—"

    /// True if either transport — Wi-Fi or wired (USB) — is currently
    /// connected. The two are independent: wired can be up while Wi-Fi is
    /// still searching, or vice versa.
    var isConnected: Bool {
        if case .connected = connection { return true }
        return isWiredConnected
    }

    let broadcaster: PenBroadcaster
    private let browser = BonjourBrowser()
    private let log = Logger(subsystem: "com.drawpad.ipad", category: "Session")

    init() {
        let broadcaster = PenBroadcaster()
        self.broadcaster = broadcaster
        broadcaster.onSend = { [weak self] summary in
            Task { @MainActor in
                self?.eventCount += 1
                self?.lastEventSummary = summary
            }
        }
        broadcaster.onWiredChange = { [weak self] connected in
            Task { @MainActor in
                self?.isWiredConnected = connected
                self?.updateIdleTimer()
            }
        }
        browser.onChange = { [weak self] resolved in
            Task { @MainActor in
                self?.handleResolved(resolved)
            }
        }
        browser.start()
        connection = .searching
    }

    private func handleResolved(_ resolved: [BonjourBrowser.Resolved]) {
        if let first = resolved.first {
            connection = .connected(host: first.name)
            broadcaster.connect(host: first.host, port: first.port)
        } else {
            connection = .searching
            broadcaster.disconnect()
        }
        updateIdleTimer()
    }

    /// Keep the screen awake while acting as a tablet on either transport —
    /// the iPad has no touch/keyboard activity of its own to reset the idle
    /// timer during a long drawing session, so without this it locks
    /// mid-stroke. iOS resets this to false automatically when the app
    /// backgrounds or terminates, so there's nothing to restore beyond
    /// this flag.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isConnected
    }
}

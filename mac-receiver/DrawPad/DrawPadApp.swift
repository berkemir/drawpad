//
//  DrawPadApp.swift
//  DrawPad
//
//  macOS receiver. Menu-bar-only app: advertises `_drawpad._udp.`,
//  receives pen events, synthesizes mouse events via CGEventPost, and shows
//  a small floating cursor overlay.
//

import SwiftUI
import DrawPadProtocol

@main
struct DrawPadApp: App {
    @State private var session = SessionState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(session)
        } label: {
            Image(systemName: "applepencil.tip")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContent: View {
    @Environment(SessionState.self) private var session

    var body: some View {
        if !session.hasAccessibilityPermission {
            Text("⚠️ Accessibility permission required")
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
        }

        // Connection status
        Text(session.statusLine)
            .foregroundStyle(session.isIncompatible ? .red : .primary)
        Text(session.subStatusLine)
            .font(.caption)
            .foregroundStyle(.secondary)
        if session.isWiredConnected {
            Text("⚡ Wired (USB) active")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Divider()

        // Mode selector — Buttons in menu style work where Picker(.inline)
        // doesn't (MenuBarExtra's .menu style doesn't render an inline
        // picker properly).
        Text("Mode")
        ForEach(DriverMode.allCases) { m in
            Button {
                NSLog("menu click: mode = %@", m.rawValue)
                session.setMode(m)
            } label: {
                let isActive = session.mode == m
                Text("\(isActive ? "●" : "○")  \(m.displayName)")
            }
        }

        if session.mode == .relative {
            Divider()
            Text(String(format: "Sensitivity: %.2fx", session.sensitivity))
                .font(.caption)
            // Use a menu of discrete values for sensitivity, since Sliders
            // don't render in MenuBarExtra's .menu style either.
            ForEach([0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) { v in
                Button {
                    NSLog("menu click: sensitivity = %f", v)
                    session.setSensitivity(v)
                } label: {
                    let isActive = abs(session.sensitivity - v) < 0.01
                    Text("\(isActive ? "●" : "○")  \(String(format: "%.2fx", v))")
                }
            }
        }

        Divider()

        // Stats
        Text("Events: \(session.eventCount)")
        if !session.lastEventSummary.isEmpty {
            Text("Last: \(session.lastEventSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Divider()

        SettingsLink {
            Text("Settings…")
        }
        Divider()

        Button("Quit DrawPad") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

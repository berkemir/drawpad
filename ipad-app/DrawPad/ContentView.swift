//
//  ContentView.swift
//  DrawPad
//

import SwiftUI
import DrawPadProtocol

struct ContentView: View {
    @Environment(SessionState.self) private var session

    var body: some View {
        ZStack {
            // Full-screen capture view (a UIView that catches UITouch events)
            PenCaptureView { event in
                session.broadcaster.process(event)
            }
            .ignoresSafeArea()

            // UI overlay on top
            VStack {
                ConnectionBar()
                Spacer()
                if !session.isConnected {
                    HintOverlay()
                }
                Spacer()
                StatusFooter()
            }
            .padding()
        }
    }
}

private struct ConnectionBar: View {
    @Environment(SessionState.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor)
                .frame(width: 12, height: 12)
            Text(stateText)
                .font(.system(.body, design: .monospaced))
            if session.isWiredConnected {
                Text("⚡ Wired")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.yellow)
            }
            Spacer()
            if session.eventCount > 0 {
                Text("\(session.eventCount) events")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var stateColor: Color {
        switch session.connection {
        case .connected:    return .green
        case .searching:    return .yellow
        case .disconnected: return .red
        }
    }

    private var stateText: String {
        switch session.connection {
        case .connected(let host):
            return "Connected to \(host)"
        case .searching:
            return "Searching for Mac…"
        case .disconnected:
            return "Not connected"
        }
    }
}

private struct HintOverlay: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "applepencil.tip")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Draw with your Apple Pencil")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open the Mac app and start drawing")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct StatusFooter: View {
    @Environment(SessionState.self) private var session

    var body: some View {
        HStack {
            Text(session.lastEventSummary)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

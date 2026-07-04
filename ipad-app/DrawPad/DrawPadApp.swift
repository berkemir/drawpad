//
//  DrawPadApp.swift
//  DrawPad
//
//  The iPad-side entry point. Opens a full-screen capture view that sends
//  Apple Pencil events to the Mac receiver over the local network.
//

import SwiftUI
import DrawPadProtocol

@main
struct DrawPadApp: App {
    @State private var session = SessionState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

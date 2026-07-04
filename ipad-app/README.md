# DrawPad — iPad app

The iPad-side input-capture app. Captures Apple Pencil events (down / move / up / hover / pressure / tilt) and streams them to the Mac receiver over the local network, using the [`Protocol/`](../Protocol/) wire format.

## Run from Xcode

1. Open `DrawPad.xcodeproj` in Xcode.
2. Select the **DrawPad** scheme and an iPad target (your iPad or a simulator).
3. Hit **Run**.

> **Note:** the iPad simulator has no Apple Pencil. When running in the simulator specifically, the app accepts any touch (finger taps become "pencil down"), so you can verify the UI flow there. On a real device it only ever accepts `touch.type == .pencil` — regardless of build configuration — which is also our palm rejection. Real Apple Pencil capture only works on a real iPad with iPadOS 17+ and an Apple Pencil 1 / 2 / Pro / USB-C.

## Architecture

```
DrawPad/
├── DrawPadApp.swift              # @main SwiftUI app
├── ContentView.swift                # top-level UI: capture + status overlay
├── PenCapture/
│   └── PenCaptureView.swift         # UIViewRepresentable + UIInputView subclass
│                                   # - touchesBegan/Moved/Ended/Cancelled
│                                   # - UIHoverGestureRecognizer for hover
│                                   # - coalescedTouches for high-rate samples
├── Network/
│   ├── UdpSender.swift              # NWConnection over UDP
│   ├── BonjourBrowser.swift         # NWBrowser for `_drawpad._udp.`
│   └── PenBroadcaster.swift         # PencilEvent → PenEvent → UDP
├── ViewModel/
│   └── SessionState.swift           # @Observable, top-level state
├── Info.plist                       # NSLocalNetworkUsageDescription, NSBonjourServices
└── Assets.xcassets/
```

The `DrawPadProtocol` SwiftPM package is at `../Protocol/`. The Xcode project references it as a local Swift package; the framework is embedded in the app.

## Wire format

One event per UDP datagram. The full spec is in [`Protocol/README.md`](../Protocol/README.md). The iPad emits:

- `hello` once on connect (device name, OS, capabilities)
- `down` / `move` / `up` for each stroke
- `hover` when the pencil is above the screen
- `ping` for round-trip latency measurement

The iPad never sends `pong`, `bye`, `button`, or `modifiers` in v0.1. (We'll add barrel button and modifier forwarding in a later version.)

## Build from CLI

```bash
xcodebuild -project DrawPad.xcodeproj \
           -scheme DrawPad \
           -sdk iphonesimulator \
           -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
           build
```

## Debug touch capture in the simulator

The `accepts(_:)` helper in `PenCaptureView.swift` returns `true` for any touch type when running in the simulator (`#if targetEnvironment(simulator)`), so you can drag with the mouse and see events flow. Switch to a real iPad for the real experience.

## Status

v0.1 — works end-to-end on the iPad side. Awaiting the Mac receiver to complete the bridge.

See [`../wiki/architecture/ipad-input-surface.md`](../wiki/architecture/ipad-input-surface.md) for the design doc.

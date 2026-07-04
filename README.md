# DrawPad

Turn an iPad + Apple Pencil into a Wacom-style graphics tablet for your Mac.

```
   ┌────────────────┐                  ┌──────────────────┐
   │  iPad app      │   Wi-Fi (UDP)    │  Mac receiver    │
   │  (SwiftUI)     │  or USB (usbmux) │  (Swift/AppKit)  │
   │                │ ───────────────▶ │                  │
   │  Apple Pencil  │                  │  CGEventPost     │
   │  + hover       │                  │  → mouse / HID   │
   └────────────────┘                  └──────────────────┘
```

The iPad app captures Apple Pencil input — hover, touch, pressure, tilt, barrel
button — and streams it to the Mac over the local network or a USB cable. The Mac
receiver decodes that stream and synthesizes mouse/pointer events, so any app on the
Mac (Photoshop, Krita, Figma, Procreate...) sees the iPad as a real graphics tablet,
complete with a floating cursor overlay for hover feedback.

## Repo layout

| Path | What |
|---|---|
| [`Protocol/`](Protocol/) | Shared Swift package: the wire format both apps speak (`DrawPadProtocol`), plus a `draw-pad-decode` CLI for inspecting captured traffic. |
| [`ipad-app/`](ipad-app/) | The iPad app — captures Pencil input, sends it over Wi-Fi (Bonjour + UDP) or USB. |
| [`mac-receiver/`](mac-receiver/) | The Mac menu-bar app — receives, decodes, and turns events into synthesized mouse input. |
| [`scripts/`](scripts/) | Misc tooling. |

Each app directory has its own README with build instructions and architecture notes.

## How it works

- **Transport**: Wi-Fi (UDP, Bonjour-discovered, fixed port) by default; if the iPad
  is plugged into the Mac via USB, the apps automatically switch to a `usbmuxd`
  relay instead — lower jitter, no Wi-Fi dependency. Whichever transport is active,
  the same event stream and decode path handles it.
- **Input fidelity**: hover (Pencil 2/Pro), pressure, tilt, barrel button, palm
  rejection (only `.pencil`-type touches are ever forwarded on a real device).
- **Driver modes**: *Absolute* (Wacom "pen" mode — iPad position maps 1:1 to the
  screen) and *Relative* (Wacom "mouse" mode — iPad motion moves the cursor by
  delta, continuing from wherever it was left).
- **Version compatibility**: every message carries the sender's protocol version and
  app version. If the iPad and Mac apps ever drift out of sync, the Mac shows a
  "please update" warning instead of silently failing.

## Getting started

**Protocol package** (no Xcode needed):

```bash
cd Protocol
swift build
swift test
```

**iPad app**: open `ipad-app/DrawPad.xcodeproj` in Xcode, select the `DrawPad` scheme
and a real iPad (Apple Pencil input doesn't work in the Simulator), and run.

**Mac receiver**: open `mac-receiver/DrawPad.xcodeproj` in Xcode, run it, then grant
Accessibility permission when prompted (**System Settings → Privacy & Security →
Accessibility**) — required for `CGEventPost` to actually move the cursor. See
[`mac-receiver/README.md`](mac-receiver/README.md) for why this only needs to
happen once per code-signing identity.

Both apps need to be on the same Wi-Fi network (or connected via USB cable) to find
each other.

## Status

Actively developed. The protocol, both transports (Wi-Fi + USB), pressure/hover/tilt
capture, absolute/relative driver modes, and version-compatibility checking are
implemented and tested. See the per-app READMEs for finer-grained status.

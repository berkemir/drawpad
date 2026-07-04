# DrawPad — Mac receiver

The macOS-side receiver. Listens for `_drawpad._udp.`, decodes incoming `PenEvent` messages, and synthesizes mouse events via `CGEventPost` so any app sees the iPad as a graphics tablet.

## First-time setup: grant Accessibility

The Mac receiver uses `CGEventPost` to inject mouse events into the system. macOS requires explicit user consent for this — it cannot be granted programmatically.

1. Run the app once. (Just double-click `DrawPad.app` or `open` it from the terminal.)
2. The menu bar shows ⚠️ "Accessibility permission required". Click "Open System Settings".
3. In **System Settings → Privacy & Security → Accessibility**, toggle **DrawPad** on.
4. You may need to quit and relaunch DrawPad after granting the permission.

**Why this only needs to happen once:** `DEVELOPMENT_TEAM` is set (`9795GHCHDZ`) so Xcode signs
with the real "Apple Development" certificate instead of falling back to ad-hoc ("Sign to Run
Locally") signing. macOS's Accessibility grant is keyed off the code signature's designated
requirement; an ad-hoc signature has no stable certificate anchor, so it changes on every build
and macOS treats each rebuild as a new, unapproved app. With a real certificate + fixed
`PRODUCT_BUNDLE_IDENTIFIER`, the designated requirement stays identical across rebuilds
(`codesign -d -r- DrawPad.app` should print the same requirement every time), so the grant
survives. If it ever needs to be reset — e.g. after changing `DEVELOPMENT_TEAM` again —
run `tccutil reset Accessibility com.drawpad.mac` and re-grant once.

Without this, the menu bar status will say "Connected" but the cursor will not move (the events arrive and decode correctly, but `CGEventPost` is a no-op).

## Run from Xcode

1. Open `DrawPad.xcodeproj`.
2. Select the **DrawPad** scheme and **My Mac** as the destination.
3. Hit **Run**.

The app is a menu-bar-only app (`LSUIElement = YES` in `Info.plist`), so there is no Dock icon. Look for the applepencil.tip icon in the menu bar.

## Run from CLI

```bash
xcodebuild -project DrawPad.xcodeproj -scheme DrawPad -sdk macosx build
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "DrawPad.app" -path "*Debug*" -not -path "*Index*" | grep -v iphonesimulator | head -1)
codesign --force --deep --sign - "$APP"   # ad-hoc sign for local use
open "$APP"
```

## Architecture

```
DrawPad/
├── DrawPadApp.swift                  # @main, MenuBarExtra
├── Network/
│   └── UdpListener.swift                # NWListener + Bonjour advertise + receive loop
├── Driver/
│   ├── MouseSynthesizer.swift           # CGEventPost for hover/down/move/up/buttons
│   └── CursorOverlay.swift              # NSPanel that follows synthesized cursor
├── ViewModel/
│   └── SessionState.swift               # @Observable, top-level state
├── Info.plist                           # LSUIElement, NSBonjourServices, NSLocalNetworkUsageDescription
└── Assets.xcassets/
```

The `DrawPadProtocol` SwiftPM package is at `../Protocol/`. The Xcode project references it as a local Swift package; the framework is embedded in the app.

## What it does

1. **Advertises** itself as `_drawpad._udp.` on the local network via Bonjour (`NWListener.Service`).
2. **Listens** on the fixed UDP port **7359** (see ADR-004), then attaches Bonjour advertising to that already-bound listener via `.service` — the port stays stable across restarts, so a client that already resolved it keeps working without re-browsing.
3. **Decodes** each incoming datagram as a `PenEvent` using the shared protocol package.
4. **Synthesizes mouse events** via `CGEventPost(.cghidEventTap)`:
   - `hover` / `move` → `mouseMoved`
   - `down` → `leftMouseDown` (with pressure field)
   - `move` (during a stroke) → `leftMouseDragged`
   - `up` → `leftMouseUp`
   - `button barrel down/up` → `rightMouseDown/Up`
5. **Renders a cursor overlay** — an `NSPanel` that follows the synthesized cursor position. macOS does not draw a system cursor for `mouseMoved` events synthesized by `CGEventPost`, so without this the user has no idea where the pen is hovering. The dot also changes size with pressure.

## Driver modes

Two modes, switchable from the menu bar — same setting Wacom tablets call "Pen mode" vs "Mouse mode":

- **Absolute (default, Wacom "Pen" mode)** — iPad position maps 1:1 to the Mac screen. Touching the iPad at (0.5, 0.5) puts the cursor at the middle of the screen.
- **Relative (Wacom "Mouse" mode)** — iPad acts like a touchpad. Motion on the iPad is a delta applied to the current cursor position. The cursor doesn't jump to where you touch. Adjust the **sensitivity** slider in the menu to control how much cursor travel each iPad motion produces.

Mode is a Mac-side setting. The iPad app always sends absolute positions; the receiver decides how to interpret them.

## Status

- ✅ Listens + advertises via Bonjour
- ✅ Decodes all event types
- ✅ Synthesizes mouse events
- ✅ Absolute + Relative modes (Wacom pen / mouse)
- ✅ Sensitivity slider
- ✅ Cursor overlay
- ✅ Menu-bar UI
- ⚠️ Requires Accessibility permission (one-time setup, see above)

## Test from the command line

You can simulate a pen event without the iPad:

```bash
PORT=$(lsof -nP -iUDP | grep DrawPad | grep -oE ':[0-9]+' | head -1 | tr -d ':')
echo '{"v":1,"type":"hover","t":1,"seq":1,"x":0.3,"y":0.3}' | nc -u -w 1 127.0.0.1 $PORT
```

The cursor should move to ~30% across and ~30% **down from the top** of the screen (iPad Y maps straight to screen Y, no flip) — **after** Accessibility is granted.

Decode a captured stream:

```bash
cat some-stream.jsonl | ../Protocol/.build/debug/draw-pad-decode
```

See [`../Protocol/README.md`](../Protocol/README.md) for the full spec.

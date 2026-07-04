# DrawPad Protocol

The wire format and shared types for the **iPad → Mac input bridge** that turns an
iPad into a Wacom-class graphics tablet for the host computer.

- **Human-readable spec (authoritative):** [`wiki/architecture/network-protocol.md`](../wiki/architecture/network-protocol.md) — field-by-field wire schema, versions, and rationale.
- **Executable source of truth:** the `DrawPadProtocol` Swift package in this directory. When the spec and the code disagree, the code wins — file a fix against the spec.

This README is a developer's quick reference for the package.

## What's in here

```
Protocol/
├── README.md                                # this file
├── Package.swift                            # SwiftPM manifest
├── Sources/
│   ├── DrawPadProtocol/                  # the library — both apps link this
│   │   ├── PenEvent.swift                   # enum + factory methods
│   │   ├── Types.swift                      # payload structs
│   │   ├── Codec.swift                      # encode / decode + validation
│   │   ├── Discovery.swift                  # Bonjour constants
│   │   ├── LatencyProbe.swift               # round-trip measurement
│   │   └── Version.swift                    # schema version
│   └── draw-pad-decode/                  # CLI for debugging wire traffic
│       └── main.swift
├── Tests/
│   └── DrawPadProtocolTests/
│       ├── CodecTests.swift                 # round-trip + validation
│       ├── DiscoveryTests.swift             # Bonjour constants
│       └── LatencyProbeTests.swift          # RTT probe
└── examples/
    └── sample-messages.jsonl                # sample wire messages, one per line
```

## Event types

Ten event types, split into session control and pen input. See
[`PenEvent.swift`](Sources/DrawPadProtocol/PenEvent.swift) for the enum and the
`make*` factory methods (the recommended construction API).

| Type | Purpose | Required fields (besides `v`,`type`,`t`,`seq`) |
|---|---|---|
| `hello` | Sender announces itself + capabilities | `device`, `os`, `capabilities[]` |
| `ping` / `pong` | Round-trip latency probe | `nonce` |
| `bye` | Graceful session end | — |
| `hover` | Pen position with no contact | `x`, `y` (tilt `alt`/`azi` optional) |
| `down` | Pen contacts the surface | `x`, `y`, `p`, `alt`, `azi` |
| `move` | Pen drags while in contact | `x`, `y`, `p`, `alt`, `azi` |
| `up` | Pen lifts off | `x`, `y` |
| `button` | Barrel / eraser / squeeze / double-tap | `kind`, `state` |
| `modifiers` | Keyboard modifier bitmask | `mask` |

Units and ranges (validated by the codec): `x`, `y`, `p` are `Float` in `0..1`;
`alt`/`azi` are **degrees** (`alt` 0–90, `azi` 0–360); `t` is monotonic ms on the
sender's clock; `mask` is a bitfield (`1`=cmd, `2`=shift, `4`=option, `8`=control).
Full schema: [`wiki/architecture/network-protocol.md#wire-schema`](../wiki/architecture/network-protocol.md#wire-schema).

## Build & test

```bash
swift build
swift test
```

## Public API

```swift
import DrawPadProtocol

let event = PenEvent.makeMove(
    t: 1234, seq: 1,
    x: 0.42, y: 0.31,
    pressure: 0.87,
    tilt: Tilt(altitude: 32.5, azimuth: 145.0)
)

let data    = try PenEventCodec.encode(event)   // → compact JSON bytes
let decoded = try PenEventCodec.decode(data)     // → PenEvent (throws on bad input)
```

## CLI decoder

```bash
# Pipe tcpdump / ngrep output through the decoder
sudo ngrep -l -W byline -d en0 '' 'udp and port 7359' \
  | grep '^{' \
  | .build/debug/draw-pad-decode
```

Output:

```
[1] hello t=0 seq=1
[2] hover  t=1234 seq=50 (0.42, 0.31) alt=32.5 azi=145.0
[3] down   t=1235 seq=51 (0.42, 0.31) p=0.87 alt=32.5 azi=145.0
[4] move   t=1240 seq=52 (0.43, 0.32) p=0.75 alt=35.0 azi=148.0
[5] move   t=1245 seq=53 (0.45, 0.35) p=0.6 alt=40.0 azi=150.0
[6] up     t=1250 seq=54 (0.46, 0.36)
[7] button t=1260 seq=55 barrel=down
[8] button t=1265 seq=56 barrel=up
[9] ping   t=5000 seq=60 nonce=n42
[10] pong  t=5002 seq=61 nonce=n42
[11] modif t=6000 seq=70 mask=3 (0b11)
[12] modif t=6001 seq=71 mask=0 (0b0)
[13] bye   t=99999 seq=1000
```

## Use as a dependency

In the iPad app or Mac receiver's `Package.swift`:

```swift
dependencies: [
    .package(path: "../Protocol")           // or git URL once published
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "DrawPadProtocol", package: "Protocol")
        ]
    )
]
```

Then `import DrawPadProtocol` in the app code.

## Versioning

The wire format has a `v` field. The current version is **1**. See
[`Version.swift`](Sources/DrawPadProtocol/Version.swift). Any change to the schema
bumps `ProtocolVersion.current`; a receiver rejects messages whose `v` doesn't match
(`CodecError.unsupportedVersion`). The changelog lives in the wiki spec:
[`network-protocol.md#versions`](../wiki/architecture/network-protocol.md#versions).

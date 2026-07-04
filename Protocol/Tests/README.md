# DrawPadProtocol tests

Test suite for the `DrawPadProtocol` package. For the package overview, the
wire schema, and the CLI decoder, see the package README one level up:
[`Protocol/README.md`](../README.md).

## Run

```bash
swift test                 # from the Protocol/ directory
```

## Suites

| File | Covers |
|---|---|
| `CodecTests.swift` | Round-trip encode/decode for every `PenEvent` type; version rejection; unknown-type, missing-field, and out-of-range (`0..1`) validation errors; tilt both-or-neither rule. |
| `DiscoveryTests.swift` | Bonjour service type, domain, default port, and service-name formatting. |
| `LatencyProbeTests.swift` | Unique nonces, RTT computation on `pong`, and unknown-nonce handling. |

The `examples/sample-messages.jsonl` fixtures mirror the on-the-wire shape and are a
handy reference when adding cases.

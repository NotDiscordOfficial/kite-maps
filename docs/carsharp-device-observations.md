# CAR# receiver observations

This note summarizes a volunteer's CAR# 1.2 (12) diagnostic archive and photographs from 2026-10-30. The archive is private and is not included here. Its identifiers, network names, addresses, credentials and images must not be copied into public fixtures.

## Observed on one device

- An aftermarket wireless receiver returned a cached /info plist describing a 1024 × 600 display, 209 × 116 mm, 30 fps, feature flags 0xa, and touch/HID devices. A live log reports the same display dimensions. The archive does not contain an RTSP transcript, so the /info request and response headers and session sequence cannot be reconstructed.
- CAR# reported joining the receiver network, finding a box with mDNS, then streaming to the box. The log does not identify the mDNS service type, receiver host, or port.
- The iPhone's own CarPlay session became active at the iPhone's Wi-Fi address, port 7000. This is the local receiver leg: do not assume that this is the box's port.
- AirPlay mirroring started and the supplied photographs show the phone display on the receiver. Touch down/up events were recorded and layout controls changed. The log says Zoom was off and mirrored-phone touches would not land; successful interactive control of Kite was not established.
- During mirroring the log reported dropped canvas frames and varying processing times. A screen-send counter is not a measurement of end-to-end latency or presentation FPS.

## Next evidence needed

Collect a redacted packet trace or explicit diagnostics that distinguish the phone's loopback leg from the head unit leg and capture service type, resolved host/port, message order, RTSP status/headers, plist schemas, negotiation, session teardown, and video/input transport. Never log credentials, tokens, personal addresses, device identifiers or location histories by default. Do not infer pairing or cryptographic requirements from the successful session alone. Compare receiver behavior with no active CarPlay session and after normal handoff, with user consent and the vehicle parked.

Test CAR# mirroring Kite with Accessibility Zoom enabled, then record whether taps, drags, orientation, audio and reconnect actually work. CAR# is a separate TestFlight app; this observation does not implement a native Kite transmitter, and the archive contains logs and a plist, not an IPA or executable.

CAR# guide: https://github.com/rPlayAI/carcast-public/blob/main/docs/carsharp-user-guide.md

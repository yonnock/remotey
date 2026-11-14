<p align="center">
  <img src="docs/logo.svg" width="112" alt="Remotey logo">
</p>

<h1 align="center">Remotey</h1>

<p align="center">
  Use your iPhone as trackpad, keyboard and media remote for your Mac.<br>
  No iOS app to install: a web page on your home screen, reachable only inside your tailnet.
</p>

<p align="center">
  <img src="docs/remote.png" width="250" alt="Remote: the live view is the trackpad, with the media keys below">
  &nbsp;
  <img src="docs/keys.png" width="250" alt="Keys page with a modifier armed">
  &nbsp;
  <img src="docs/full.png" width="250" alt="Full view: the keys fold away and the display takes the phone">
</p>

## How it works

<img src="docs/how-it-works.svg" width="968" alt="The iPhone connects over HTTPS and WSS, tailnet only, to tailscale serve on port 8443 on the Mac. It forwards / to the agent's HTTP port 47800, which serves the web UI, and /ws to its WebSocket port 47801, which receives input, injects it via CGEvent and streams the optional live view back. The agent listens on 127.0.0.1 only.">

The live view uses hardware-encoded H.264 at up to 120 fps with a 4 Mbit/s average bitrate target. Safari 16.4+ can decode it through WebCodecs; unsupported browsers or encoders fall back to JPEG at up to 30 fps. The client measures its rendering cadence and requests up to 120 fps; the rate is also capped by the refresh rate of the fastest Mac display. A Mac with 60 Hz displays or Safari limited to 60 Hz stays at 60 fps. With several displays, each one is captured and the view is composed from those around the pointer, so it pans across the seam between two displays instead of switching; space no display covers is black.

The stream is built for a short way from finger to picture and for doing nothing whenever possible:

- The pointer is not part of the picture. The phone gets its place with every message and its image when the shape changes, and draws it itself, so pointer and marker cannot drift apart.
- A pointer move needs no screen capture. The agent cuts the new view from the frames it already holds the moment it posts the move. A move inside a view held by the display's edges sends 22 bytes and no picture.
- A still screen sends nothing, and neither does a change outside the view, such as a clock in the menu bar.
- One key frame starts the stream. The link is reliable, so no later one interrupts it.
- Pictures await a draw acknowledgement: two at first, up to six for a phone whose answers take several frame intervals even at their best. A slow connection lowers the frame rate instead of building up a queue.

The agent is a small Swift menu bar app with no dependencies. The UI is an HTML page with a small decoder module (labels are in German).

## Security

An input remote is remote control of your Mac, so the agent is locked down in three layers:

- It binds to `127.0.0.1` only. Nothing is reachable from your Wi-Fi.
- `tailscale serve` terminates TLS and admits only devices in your tailnet.
- Every WebSocket must authenticate with a 256-bit token first. This also stops web pages in your Mac's browser from talking to the loopback port. The token travels in the URL fragment of the pairing link, which is never sent to the server, and can be rotated from the menu.

The live view sends screen content only to an authenticated client, only while it is switched on, over the same TLS connection.

Connections that have not authenticated are closed after five seconds and limited to 32 at a time, so nobody without the token can exhaust the agent's sockets. The app is signed with the hardened runtime, so other processes on the Mac cannot load code into it and borrow its Accessibility and Screen Recording permissions.

Known limit: the token is a file in `~/Library/Application Support/Remotey`, readable by every unsandboxed process running as you. Such a process can connect to the loopback port and gets the same input and screen access as the phone.

## Setup

Requirements: macOS 14+, Xcode command line tools, Tailscale on the Mac and the iPhone (same account).

1. Build, sign and start the app:
   ```sh
   ./scripts/build.sh --install
   ```
2. Allow Remotey under System Settings → Privacy & Security → Accessibility.
   For the live view, also allow it under Screen & System Audio Recording and restart Remotey.
3. Publish the agent inside your tailnet (asks you to enable Serve once):
   ```sh
   ./scripts/tailscale-serve.sh
   ```
4. Click the menu bar icon → "iPhone koppeln (QR-Code)…" and scan the code with the iPhone camera.
5. In Safari, choose Share → Add to Home Screen.

The build signs with your "Apple Development" identity so macOS keeps the Accessibility permission across rebuilds. Set `REMOTEY_SIGN_IDENTITY` to use another one.

## Usage

| Gesture | Action |
|---|---|
| One finger | Move the pointer |
| Tap | Click |
| Two fingers | Scroll |
| Two-finger tap | Right click |
| Hold "Links" and swipe with a second finger | Drag |
| ⌘ ⌥ ⌃ ⇧ | Applies to the next key, e.g. ⌘ then `w` |
| "Bild" | Live view: the trackpad shows the screen around the pointer, so you steer on the picture itself |
| Zoom switch | Tap a position or slide across them (0.25× to 2×) |
| Readout next to "Bild" | Updates of the live view per second and the delay of a pointer move in milliseconds, measured from sending the move until the picture that shows it is drawn. Green is good, amber middling, red poor; grey while the screen is still |
| Full view key | The keys fold away and the display takes the phone; the keyboard key opens typing. Turning the phone sideways does the same with the controls beside the display |
| "Medien" / "Tasten" | Slides between the media keys and the key page (Esc, Tab, modifiers, arrows) |

The dot left of the zoom switch is the connection: blinking amber while connecting, green when connected, red when not. The screenshots above show a placeholder instead of a real Mac screen.

Text typed on the iOS keyboard is replayed on the Mac key by key.

## Development

```sh
swift run                          # agent from the source tree, Web/ is re-read on every request
swift test                         # encoder, pointer, view, send window, wire format; server: auth and limits
node --test scripts/live-view.test.mjs  # client decode, acknowledgements, pointer, readout and JPEG fallback
node scripts/smoke.mjs              # running agent: HTTP, auth, pointer and JPEG flow control
node scripts/smoke.mjs --h264       # same checks for H.264, including IDR after restart/resize
node scripts/smoke.mjs --h264 --fps=120  # request 120 fps (requires a 120 Hz source display)
node scripts/bench.mjs --fps=60     # running agent: frame rate, delay from move to picture, CPU, bursts of moves
```

`Sources/Remotey/Wire.swift` and `Web/live-view.js` are the two halves of what agent and page say to each other; a change to one belongs in the other. Every file in `Web/` is served and bundled. A page that was loaded from an older agent reloads itself when it reconnects.

The smoke tests and the benchmark move the pointer, so keep your hands off the mouse while they run. Close Remotey on the phone first, since the most recent viewer owns the stream. They measure the Mac's side: received frames, not displayed frames on the phone. The 4 Mbit/s setting is an average target, not a hard cap; the readout on the phone shows the frame rate and delay that actually arrive there.

The hardware encoder takes one picture at a time. On an M3 Max a picture for a full phone display (780 × 1688 pixels) needs about 7 ms to encode and 2.5 ms to compose, so that size tops out at 90 to 100 fps; the smaller display above the keys reaches 120 fps.

Known limits: untested on the Mac lock screen, and characters without a key in the active layout (emoji, for example) are sent as Unicode events, which some terminals ignore.

## License

MIT

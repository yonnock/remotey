# Roadmap

What comes next, and what was put off on purpose. Each item says why and what it waits for. The order follows the
analysis that started the glass interface, the setup assistant and pairing per device; what was built since is
recorded in [decisions.md](decisions.md), rounds 18 to 20.

## 1. Measure on a real iPhone

Everything since round 18 ran in Chromium with touch emulation, in Node and in Swift tests. One session with a
real iPhone settles the open questions below, and the performance work in section 3 waits for its numbers.

| What | Why | Waits for |
|---|---|---|
| Finger to photon, filmed in 240 fps slow motion, about 20 samples per case (same Wi-Fi and relay; pointer alone and with the picture following) | The baseline for every later change. The readout on the phone measures only from sending a move to drawing the picture; the time before and after it is estimated, not measured | An iPhone, a camera with 240 fps, an hour |
| The GPU cost of the glass over the running picture: frame rate, battery and heat, with "Durchsichtige Flächen" on and off | Blur over a picture that changes 60 times a second is computed anew for every frame. The blur is kept to the still capsules for that reason, but nobody has measured it | The same session |
| Whether iOS carries the device cookie into the Home Screen app | If it does not, every Home Screen app asks once for the six digits. The page and the assistant are built for both cases | The same session |
| Whether Safari returns the second PRF value, and the one for that salt | Only then does the passkey's secret rotate with every unlock. Without it the unlock works and the secret stays as fixed as before | The same session, with a locked Mac |
| Whether the lock screen takes special characters | Characters that need Shift or Option now go as their key with those modifiers. The events match; what the login window reads was never seen. Two refusals delete the stored password | The same session, with a test password that has `! ? @ € { }` in it |

Also open from the same rounds, cheaper to check at the same time: Dynamic Type at the largest size, the capsules
in the corners of a real display sideways, `prefers-reduced-transparency`, iOS offering the code from the
notification for `one-time-code`, and the first run of the Mac's menu panel, assistant and settings on a real
screen (decisions.md, "Not verified", round 20).

## 2. Distribution, blocked on the paid Apple Developer Program

Installing means building from source with an "Apple Development" identity today. Everything below needs a
"Developer ID Application" certificate, which comes only with the paid membership (99 USD a year). One purchase
settles all of it, and also the native app (section 4).

1. **Developer ID signing** of the release build, with the hardened runtime as now.
2. **Notarisation** and stapling, so Gatekeeper opens a downloaded app.
3. **A DMG** on GitHub Releases from a release workflow, with the bundle version taken from the tag instead of the
   fixed `0.1.0` in `Support/Info.plist`, and an app icon.
4. **A Homebrew cask** in the own tap ([#1](https://github.com/yonnock/remotey/issues/1)). Casks have to pass
   Gatekeeper, so this needs step 2. The assistant already sets up `tailscale serve`, which #1 named as its
   dependency.
5. **An updater**, so an installed app learns of a new release.

Changing the signature resets both permissions once: everyone who built from source grants Accessibility and Screen
Recording again after moving to the signed release. Say so in the release notes.

## 3. Next features

Ordered by worth for the effort, after the analysis's ranking. None of them is blocked; they wait for the measurement only where it
would change the design.

1. **Clipboard both ways.** A 2FA code from the Mac into an iPhone app, a link from the phone into the Mac. The
   largest gap to comparable tools. `NSPasteboard` on the Mac, the clipboard API on a tap on the phone; pasting as
   one block with ⌘V instead of key by key also helps terminals and dictation.
2. **Direct touch.** In a fitted window, tap the button itself instead of steering the pointer to it. The page
   knows the cut and the zoom from each picture's header; it needs a command in picture coordinates. A switch, the
   trackpad stays the default.
3. **The menu bar as a list.** Accessibility hands over the Mac's menu bar; a sheet like the switcher lists it and a
   tap triggers the item. Large menus load one level at a time.
4. **A launcher with search.** Type "Rechner" and the app starts. The switcher shows only running apps today;
   LaunchServices knows the rest.
5. **Quick actions and macros.** Keys that run a key sequence, text, a URL, an app or a Shortcut (`shortcuts
   run`). Text snippets and a presentation mode come with it.
6. **Files to the Mac.** A photo from the phone straight into the presentation: file picker, authenticated upload,
   saved to Downloads, with a size limit.
7. **Window arranging.** Two windows side by side, hide or quit an app, as an action on a long press. The agent
   already sets frames for "An iPhone anpassen".
8. **Real volume and the output device.** CoreAudio's public interface gives the value and the devices, so the
   volume can become a slider and the HomePod a choice.

Related open issues: notifications from the Mac on the phone ([#14](https://github.com/yonnock/remotey/issues/14)),
fitting and scaling for reading on the phone ([#13](https://github.com/yonnock/remotey/issues/13); fitting and the
phone's shape are built, scaling the Mac's display is not), and virtual displays and a Mac with its display off
([#11](https://github.com/yonnock/remotey/issues/11), a private API and a spike first).

### Performance, after the measurement

Each of these is backed by the code, but its gain is an estimate until section 1 gives a baseline to compare with.

- **Capture in 420v instead of BGRA.** About 62 % less memory and bandwidth for the capture; on a 6016 × 3384
  display the capture holds three buffers of 81 MB each today.
- **The Constrained High profile** instead of Baseline, which Apple names for low-latency encoding: 10 to 15 % fewer
  bits at the same quality.
- **A fast path for composing.** Where one display covers the view, copy it straight into the encoder's buffer
  (Metal or a pixel transfer). 2 to 4 ms per picture, enough to reach 120 fps on a full phone display.
- **Input off the main thread.** Every connection, every input, every picture sent and the Accessibility queries run
  there; an app that hangs on Accessibility holds back the pointer for 100 to 700 ms.

## 4. The native iPhone app

[#16](https://github.com/yonnock/remotey/issues/16). A native app wins clearly on input (120 Hz touches, haptics,
a hardware keyboard), on secrets (a key in the Secure Enclave instead of a passkey bound to the host name) and on
the system (Control Centre, the Action button, Shortcuts, Watch). On the picture's delay alone the gain is smaller
than the Wi-Fi's jitter. It costs a second client, its upkeep and the membership from section 2.

**Experiments first**, each a day or two, before any app code:

- Does the web close the gap cheaply? Safari with "Prefer Page Rendering Updates near 60fps" off, so the page asks
  for 120 fps, filmed before and after in 240 fps.
- Do 120 Hz touches arrive? A minimal app that logs touch timestamps, ten minutes for heat and battery.
- Which drawing path: one recording of the agent's stream fed to both, arrival to display measured.
- The keyboard: dictation, umlauts, emoji, Japanese, backspace in an empty field.
- A Control "Lock Mac" in the background: 20 tries with the app closed, the phone locked and the VPN asleep.
- Unlocking with the Secure Enclave: one Face ID prompt for two operations, and what a new face does.
- A direct path on the same Wi-Fi (Bonjour, pinned certificates from the QR code) against `tailscale serve`.

**Stages**, in person-weeks, 14 to 20 in all:

| Stage | Content | Weeks |
|---|---|---|
| M0 | A shared Swift package: the wire format, the gesture state machine, trust | 1 to 1.5 |
| M1 | Trackpad, keys, media; then decide | 3 to 4 |
| M2 | Live view | 2.5 to 3.5 |
| M3 | Apps, displays, unlocking | 2.5 to 3.5 |
| M4 | System integration: Controls, Live Activity, Shortcuts | 2 to 3 |
| M5 | iPad and Watch | 2.5 to 4 |

**Stop criterion after M1:** if after a week of own use it does not feel clearly better, and the answer without a
picture is not at least 10 ms faster, Remotey stays on the web. Every later stage has its own.

The web page stays either way, as the route without an install: another phone, Android, an iPad, an expired build.

## 5. Setup without Tailscale on the same network

[#2](https://github.com/yonnock/remotey/issues/2), part 1 (the app sets up `tailscale serve`) is built; the
assistant's Tailscale keys have not yet run against the real tool, and `scripts/tailscale-serve.sh` stays until
they have. Part 2, the same Wi-Fi without Tailscale, is blocked on the web: WebCodecs and WebAuthn need a trusted
certificate. It waits for a WebTransport spike on a real iPhone, and otherwise for the native app.

## 6. Stays rejected

- **Tap, then drag.** On a Mac it turns into a double click and opens files in the Finder. Three fingers and
  holding "Klick" cover dragging; the tour teaches both.
- **Keeping the Mac's display awake while the picture runs.** A phone left lying would defeat the Mac's automatic
  lock. The phone's own wake lock is let go three minutes after the last touch for the same reason.
- **Public reachability**: Tailscale Funnel, an own relay, or plain HTTP on the Wi-Fi. A key would be the only thing
  between the internet and full control of the Mac. The agent refuses Funnel requests, and the assistant shows a
  Funnel on its port as an error.

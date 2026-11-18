<p align="center">
  <img src="docs/logo.svg" width="112" alt="Remotey logo">
</p>

<h1 align="center">Remotey</h1>

<p align="center">
  Use your iPhone as trackpad, keyboard and media remote for your Mac.<br>
  No iOS app to install: a web page on your home screen, reachable only inside your tailnet.
</p>

<p align="center">
  <img src="docs/remote.png" width="250" alt="Remote: the live view is the trackpad, here fitted to the window in front by Auto, with the mouse keys and the dock under the thumb">
  &nbsp;
  <img src="docs/apps.png" width="250" alt="Switcher: the Mac's open apps as icons, the one in front marked, a number where there are several windows, the key for the phone's shape above them and the Mac's two displays under them, as they are arranged">
  &nbsp;
  <img src="docs/keys.png" width="250" alt="Tray with the key page, a modifier armed, and the keys for an app's zoom">
</p>

## How it works

<img src="docs/how-it-works.svg" width="968" alt="The iPhone connects over HTTPS and WSS, tailnet only, to tailscale serve on port 8443 on the Mac. It forwards / to the agent's HTTP port 47800, which serves the web UI, and /ws to its WebSocket port 47801, which receives input, injects it via CGEvent and streams the optional live view back. The agent listens on 127.0.0.1 only.">

The live view uses hardware-encoded H.264 at up to 120 fps with a 4 Mbit/s average bitrate target. Safari 16.4+ can decode it through WebCodecs; unsupported browsers or encoders fall back to JPEG at up to 30 fps. The client measures its rendering cadence and requests up to 120 fps; the rate is also capped by the refresh rate of the fastest Mac display. A Mac with 60 Hz displays or Safari limited to 60 Hz stays at 60 fps. With several displays, each one is captured and the view is composed from those around the pointer, so it pans across the seam between two displays instead of switching; space no display covers is black. Zoomed out beyond the pointer's display, the view holds still and shows that display whole, then its neighbours, and at most the whole desktop.

The stream is built for a short way from finger to picture and for doing nothing whenever possible:

- The pointer is not part of the picture. The phone gets its place with every message and its image when the shape changes, and draws it itself, so pointer and marker cannot drift apart.
- A pointer move needs no screen capture. The agent cuts the new view from the frames it already holds the moment it posts the move. A move inside a view held by the display's edges sends 22 bytes and no picture.
- A still screen sends nothing, and neither does a change outside the view, such as a clock in the menu bar.
- One key frame starts the stream. The link is reliable, so no later one interrupts it.
- Pictures await a draw acknowledgement: two at first, then the agent sends while the oldest unanswered picture is younger than the fastest answer plus 200 ms. A jittery link keeps its frame rate, a slow one lowers it instead of building up a queue.

The agent is a small Swift menu bar app with no dependencies. The UI is an HTML page with a stylesheet and a few modules, split by what they change for: gestures (`touchpad.js`), the visible area and keyboard (`viewport.js`), the text field (`typing.js`), the passkey (`passkey.js`), decoding and drawing (`live-view.js`), the app switcher (`apps.js`), the display picker (`displays.js`) and the wiring (`remote.js`). Labels are in German.

## Security

An input remote is remote control of your Mac, so the agent is locked down in three layers:

- It binds to `127.0.0.1` only. Nothing is reachable from your Wi-Fi.
- `tailscale serve` terminates TLS and admits only devices in your tailnet.
- Every WebSocket must authenticate with a 256-bit token first. This also stops web pages in your Mac's browser from talking to the loopback port. The token travels in the URL fragment of the pairing link, which is never sent to the server, and can be rotated from the menu.

The live view sends screen content only to an authenticated client, only while it is switched on, over the same TLS connection. The same holds for the app switcher: the names of the open apps, their icons, the titles of their windows and the names of the displays leave the Mac only when an authenticated client opens it.

Connections that have not authenticated are closed after five seconds and limited to 32 at a time, so nobody without the token can exhaust the agent's sockets. The app is signed with the hardened runtime, so other processes on the Mac cannot load code into it and borrow its Accessibility and Screen Recording permissions.

A locked Mac stays within reach: the pointer, the keys and the live view work on its lock screen as on the desktop, so whoever holds the token can try passwords there, as someone at its keyboard can. Unlocking needs the password of the Mac's user. The phone sends it over the same TLS connection, the agent types it into the lock screen's password field and keeps no copy; it is in no log and no file on the Mac. Nothing is typed unless that field has the keyboard, so the password cannot land in an app on a Mac that is open.

Unlocking with Face ID is off until you set it up from the menu at the Mac, where you type the Mac's password once. The phone then holds a passkey for this page, and the agent keeps the password in `~/Library/Application Support/Remotey/face-unlock`, encrypted with a key that only this passkey gives out, and only after iOS has verified you (WebAuthn's PRF extension). The file alone opens nothing, so it needs no secrecy: whoever reads it, or the token, has no password. To unlock, the phone signs a fresh challenge from the agent and sends the passkey's secret over the same TLS connection; the agent checks the signature, decrypts, types the password into the lock screen and keeps neither. Every unlock asks iOS anew, a recorded answer is refused, and a password the Mac refuses twice in a row is deleted.

What Face ID changes: whoever holds your iPhone and can unlock it can unlock the Mac. iOS takes the phone's code where Face ID fails, unless Stolen Device Protection is on. The passkey syncs through iCloud Keychain to your other devices, which still need the token and the tailnet. An enrolment takes the first phone that answers within two minutes, so start it only while nobody else holds the token.

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
| Two fingers together | Scroll. Lifting one finger ends the scroll; the other one does not move the pointer |
| Two fingers apart | Zoom the live view (pinch). The point the view is cut around stays in place |
| Two-finger tap | Right click |
| Three fingers | Drag: the left button is held while they move and let go when one lifts |
| Hold "Links" and swipe with a second finger | Drag |
| ‹ › | Back and forward, clicked as a mouse's side buttons (buttons 4 and 5). Chromium browsers and Firefox navigate on them; Safari and Finder ignore these buttons from any mouse unless a helper app translates them |
| ⌘ ⌥ ⌃ ⇧ | Applies to the next key or click, e.g. ⌘ then `w`, or ⌥ then a tap. Armed before holding "Links", it stays for the whole drag |
| "Bild" | Live view: the trackpad shows the screen around the pointer, so you steer on the picture itself |
| − / + (top right of the display) | Zoom the live view in steps up to 4×, and out until every display of the Mac is in the picture, upright or sideways; the readout between them shows the zoom. Upright and sideways each keep their own zoom |
| "Auto" (the readout between − and +) | Fits the live view to the window in front on the Mac: it fills the display's width or its height, whichever limits, at twice its size at most. The view fits again when another window comes forward, by the switcher, ⌘Tab or a click, and when the phone is turned; a window that is moved or resized is fitted once it holds still. The lamp "Auto" is lit and the readout shows the zoom that took. The pointer goes to the middle of a window that comes forward, unless it is inside already, as after the switcher. Near an edge of the picture the pointer pushes the view, so the menu bar and what lies beside the window stay within reach. A pinch or − / + ends it and goes on from the zoom on show; another tap on the readout returns to the zoom set by hand. Needs the Accessibility permission; without a window in front (the Finder's desktop, the lock screen) the zoom set by hand counts |
| "Folgt Text" | While you type, the live view shows the text cursor on the Mac (or the focused field, if the app reports no cursor), and waits until the cursor nears an edge. Moving the pointer or clicking ends it. Neither the pointer nor the focus on the Mac moves |
| Readout at the top left of the display | Updates of the live view per second and the delay of a pointer move in milliseconds, measured from sending the move until the picture that shows it is drawn. Green is good, amber middling, red poor; grey while the screen is still |
| Dock | Under the thumb: ‹ and ›, "Links" and "Rechts", then "Tippen…", "Apps", the grid key and "Bild". Sideways it stands as a rail right of the display |
| "Apps" | Opens the switcher: the Mac's open apps as icons, the most recently used first. The app in front has an amber mark, a hidden one is dimmed. Tap an app and it comes to the front with the keyboard focus; a minimized window comes out of the Dock, a hidden app is shown. Put the switcher away like the tray: with its key, a tap on the display or a swipe down from its top edge |
| An app with a number | The app has that many windows. A tap shows their titles instead of switching, the one in front marked amber, minimized ones named so; tap the window you want. Nothing on the Mac moves before that choice. ‹ returns to the apps |
| After switching | With the live view on, the pointer goes to the middle of the window that came forward, unless it is inside it already, so the view shows that window. Without the live view the pointer stays where it is |
| "Telefonform" (head of the switcher) | With "Auto", the window in front also takes the phone's shape on the Mac, so it fills the display instead of a band of it; the lamp on the readout says "Form". The zoom is the window's size then: − / + and a pinch ask the Mac for a smaller or larger window, which stays whole in the picture, and upright and sideways each keep their own. A window is no larger than its display has room for and no smaller than its app allows. It gets the frame it had back when another window comes forward, with "Auto" or the live view off, when the page goes out of sight and when the phone disconnects. Only document and main windows are shaped, no dialogs and none in full screen. Switching it on switches "Auto" on; switching "Auto" off keeps it for the next time |
| The displays under the apps | On a Mac with more than one display the switcher shows them as they are arranged, the one with the pointer lit amber. Tap one and the pointer goes there, and the live view with it: back to where it was when it last left that display this way, else to its middle. The map follows a display that is plugged in or removed |
| Grid key | Opens media keys, key page and Regler as a tray that comes up out of the display's lower edge; the display keeps its size, so the live view runs on. Put it away with the grid key, a tap on the display (no click reaches the Mac) or a swipe down from its top edge |
| "Tippen…" | Opens the keyboard. Esc, Tab, ⌘ ⌥ ⌃ ⇧ and the arrows sit in a row right above it |
| Padlock under the mute key ("Medien") | The Mac's lock: open while the Mac is open, shut and lit while it is locked. A tap locks the Mac, as ⌃⌘Q on its keyboard does; an armed modifier is not part of it and stays armed. On a locked Mac a tap unlocks, as "Entsperren…" does: with Face ID if that is set up, else with the field for the password |
| "Entsperren…" (a padlock) | The Mac is locked, and the same key opens the field for its password. iOS masks it and offers the one saved for this page. Nothing leaves the phone while you type; the send key hands it to the Mac, which types it into its lock screen. The key says "Tippen…" again once the Mac is open; if it stays locked, the field says so. With the live view on you see the password field of the Mac meanwhile |
| Menu bar icon → "Entsperren mit Face ID einrichten…" | Sets up unlocking with Face ID, at the Mac: type the Mac's password, then tap "Einrichten" on the card that lies over the phone's display for two minutes, and save the passkey in Passwords. The window at the Mac closes itself once the phone is enrolled. "Entsperren mit Face ID entfernen" in the same menu deletes the password kept for it; the passkey itself you delete in Passwords on the phone |
| "Entsperren…" with Face ID set up | The key asks the phone for its passkey instead of opening the field: Face ID, and the Mac types its password itself. If you decline, or the Mac refuses the password ("Abgelehnt"), the next tap opens the field for the password; putting the field away leaves the tap after that to Face ID again. After a changed password on the Mac, set it up again |
| A Mac whose display sleeps | Any move, click, scroll or key from the phone, and switching the live view on, wakes the display as a key on the Mac's keyboard does. The media keys leave it dark |
| "Medien" / "Tasten" / "Regler" | Slides between the media keys, the key page (Esc, Tab, modifiers, arrows) and the settings |
| ⌘− / ⌘0 / ⌘+ (key page) | The zoom of the app in front: browsers, editors and terminals scale their content. With "Auto" this is how text gets larger while the window stays whole |
| "Regler" | Three sliders: pointer speed, acceleration (how much further a fast move reaches; "aus" is linear) and scroll speed. Touch the track where you want the value or slide along it; the thumb snaps to the detents, the longer tick marks the default. Each counts from the next move and is kept on the phone. "Std." restores the defaults |

The dot at the top left of the display is the connection: blinking amber while connecting, green when connected, red when not. The screenshots above show a placeholder instead of a real Mac screen, and made-up apps and displays.

Text typed on the iOS keyboard is replayed on the Mac key by key.

## Development

```sh
swift run                          # agent from the source tree, Web/ is re-read on every request
REMOTEY_PORT=47820 swift run       # beside the installed app: page on 47820, socket on 47821
swift test                         # encoder, pointer, input, view, fitted view, send window, wire format, order of apps, displays, unlocking, passkey, sealed password; server: auth, limits, lists of apps and displays, Face ID
node --test scripts/               # client decode, pointer, zoom preview, gestures, viewport, text field, switcher, display picker, passkey
node scripts/ui-verify.mjs         # the page in headless Chromium: reachable controls, pinch, keyboard, pointer, scroll, Regler, tray, side buttons, switcher, locked Mac, Auto, display picker, Telefonform, Face ID
node scripts/ui-verify.mjs --shots=DIR  # also saves pictures of the key page, Auto, the display picker and Telefonform
node scripts/smoke.mjs              # running agent: HTTP, auth, pointer, lists of apps and displays, JPEG flow control, a view fitted to the window in front
node scripts/smoke.mjs --focus      # also brings another app's window to the front and the one before back
node scripts/smoke.mjs --display    # also puts the pointer on another display and back
node scripts/smoke.mjs --h264       # same checks for H.264, including IDR after restart/resize
node scripts/smoke.mjs --h264 --fps=120  # request 120 fps (requires a 120 Hz source display)
node scripts/bench.mjs --fps=60     # running agent: frame rate, delay from move to picture, CPU, bursts of moves
node scripts/lock.mjs               # running agent: locks the Mac, then pointer, live view, display wake and a refused password on the lock screen; you unlock at the end
```

`Sources/Remotey/Wire.swift` holds the agent's half of what agent and page say to each other. On the page each message lives in the module it serves: `Web/live-view.js` reads the live view's updates, `Web/apps.js` the switcher's lists, `Web/displays.js` the list of displays, `Web/passkey.js` writes what the phone's passkey says, and `Web/remote.js` sends the commands and routes what arrives. A change to one half belongs in the other. Every file in `Web/` is served and bundled. A page that was loaded from an older agent reloads itself when it reconnects.

The scripts talk to the agent on `REMOTEY_PORT` (default 47800). The smoke tests and the benchmark move the pointer, so keep your hands off the mouse while they run. Close Remotey on the phone first, since the most recent viewer owns the stream. They measure the Mac's side: received frames, not displayed frames on the phone. The 4 Mbit/s setting is an average target, not a hard cap; the readout on the phone shows the frame rate and delay that actually arrive there.

The hardware encoder takes one picture at a time. On an M3 Max a picture for a full phone display (780 × 1688 pixels) needs about 7 ms to encode and 2.5 ms to compose, so that size tops out at 90 to 100 fps; the smaller display above the keys reaches 120 fps.

Known limits: characters without a key in the active layout (emoji, for example) are sent as Unicode events, which some terminals ignore. On the lock screen, Esc puts the display to sleep, and macOS does so itself about 30 seconds after the last input; the picture on the phone then stands still until the next input wakes the display. A Mac that sleeps itself, not only its display, is out of reach until something wakes it. After a restart nothing runs before the first login, so the login window (and FileVault's) cannot be reached. A screen saver over the lock screen is untested. Unlocking with Face ID needs iOS 18 or later and a passkey that gives out a PRF secret, as those in Apple's Passwords do; a phone whose passkey gives none is not enrolled. The passkey belongs to the Mac's name in the tailnet, so a renamed Mac is set up again. The switcher learns an app's windows from Accessibility, which reports those of the current Space and the minimized ones. An app whose windows are on another Space or in full screen shows no number; a tap brings it forward as a click in the Dock does, which switches to its Space, and from there the switcher lists its windows. "Auto" shows a window whole, so a window as wide as its display is small on an upright phone: switch "Telefonform" on, turn the phone, or enlarge the app's content with ⌘+. A window that has the phone's shape keeps it if the agent crashes or is killed; quitting it from its menu puts the frame back. ⌘+ is sent as the key that carries the plus sign; on a layout where that needs Shift (US), it goes as a Unicode event, which is untested.

## License

MIT

# Decision log: layout, input and structure (baseline 668541b)

Baseline measured with `scripts/ui-verify.mjs` (verifier v2, headless Chromium with touch emulation, a fake
socket and a visual viewport the script resizes). Line numbers refer to 668541b.

## Findings

Hidden links
- H1 `Web/index.html:287` hard-codes the WebSocket port 47801 next to `Server.swift:8`; a second agent on other ports is unreachable for the page, so every test of a build talks to the installed app.
- H2 `index.html:406` `ZOOMS` and `index.html:191-193` (five spans, `--n: 5`, `aria-valuemax=4`) must change together; `ScreenView.Request` clamps zoom to 0.25...4 on its own.
- H3 `index.html:584-588` `fit()` sizes `#app` from `visualViewport.height` but places it at the layout viewport's top; iOS offsets the visual viewport (`offsetTop`) while the keyboard is open, so the top of the page sits outside the visible area. Measured: live view 0 px visible with a 120 px offset (small phone).
- H4 `index.html:580-581` keyboard state = focus. Layout, key page and "Fertig" all hang on the `kb` class, which a focus with an external keyboard also sets.
- H5 The aim/marker is placed in percent of `#screen` (`live-view.js:135`) while the picture is drawn with `object-fit: cover` (`index.html:44`); both agree only while the picture has the element's aspect, not during a resize.
- H6 Storage keys `remotey-view|zoom|page|token` are read and written in four places with four validations.
- H7 `Input.scroll` posts with `.post(tap:)` itself (`Input.swift:110`) while every other event goes through the injected `post`; scrolling is invisible to the tests.

Needless links
- N1 `index.html` holds look, markup, gestures, transfer function, keyboard diffing, viewport, settings and connection: one file for eight reasons to change; the gesture code cannot be tested without a browser.
- N2 Gesture recognition and transfer are fused in the `touchmove` handler (`index.html:365-390`): the acceleration (`:382`) and scroll factor (`:388`) are constants inside the recogniser.

Surplus
- S1 `index.html:5` `maximum-scale=1, user-scalable=no` (ignored by iOS Safari since iOS 10) and `:591` a global `gesturestart` block: browser zoom is forbidden everywhere, not only where the pad needs the touches.
- S2 `index.html:587` `scrollTo(0, 0)` on every viewport event for a body that is `position: fixed`.

Special cases
- C1 `index.html:379` dead zone: the first 8 px of every one-finger gesture are dropped, also after the tap window. Measured: a 5 px nudge after holding moves 0 points, 30 px slow moves 23.
- C2 `index.html:381-388` the number of fingers decides per event: lifting one finger of a scroll turns the rest into pointer moves. Measured: 9 moves after a lift.
- C3 `index.html:175` `body.wide.kb #console { display: none }` hides the live view while typing in landscape. Measured: 0 px.
- C4 `index.html:160` `body.wide #deck { display: none }` hides media keys and key page in landscape. Measured: 5 of 9 main actions reachable.
- C5 Two fingers always scroll; there is no pinch. A spreading pinch only cancels out by symmetry.
- C6 `ScreenView` cuts the view around the pointer only (`ScreenView.swift:453, 498`), so typed text can be off-screen.
- Kept as platform constraints: the zero-width sentinel in the text field (iOS sends no input event for backspace in an empty field), `preventDefault` on `touchstart` (keeps the iOS keyboard open), focus on `touchend` for the type key (iOS opens the keyboard only from a user gesture), the reconnect timer and `visibilitychange` reconnect (iOS suspends sockets).

## Decisions

1. Split the page by reason to change: `remote.css` (look), `touchpad.js` (touches to pointer, scroll and zoom gestures, with the transfer function), `viewport.js` (visible frame and keyboard geometry), `typing.js` (field diffing), `live-view.js` (decoding, drawing, aim, zoom preview), `remote.js` (wiring, connection, settings, keys). `Web.swift` serves `.css`; `script-src`/`style-src` drop `'unsafe-inline'`.
   Solves N1, N2, S2, H6 (one `store`), and makes C1, C2, C5 testable in Node. Contract kept: every file in `Web/` is served, bundled and hashed into `Web.version`.
2. One gesture state machine per touch sequence: `pending` (tap possible), `pointing`, `two` (undecided), `scrolling`, `pinching`, `done` (ignore the rest until every finger is up). Two fingers are decided once by comparing centroid travel with change of spread. The pointer dead zone only applies while a tap is still possible, and the held-back motion is sent once it is a move. Scroll uses the centroid of all touches and carries a phase (`began`, `changed`, `ended`) to the Mac.
   Solves C1, C2, C5, H7 (scroll goes through `post`, with phases). Contract kept: tap = click, two-finger tap = right click, Links + second finger = drag with armed modifiers.
3. Transfer function `gain(speed)` with persistent settings: pointer speed, acceleration (0 = linear) and scroll speed, independent, with reset. Speed is measured over the last ~32 ms of touch timestamps, so the event rate does not change the gain. No smoothing of the motion itself.
4. Visible frame from `visualViewport` including `offsetTop`, only while the page is not browser-zoomed; keyboard = geometry (frame shorter than the layout viewport by more than 120 px), typing = focus. Solves H3, H4, S1 (browser zoom allowed outside the pad; the pad keeps `touch-action: none`).
5. Landscape gets its own layout: live view plus a control rail (status, zoom, Bild, keyboard, deck drawer, Links/Rechts); the deck opens as a drawer over the live view. With the keyboard open the live view stays, next to the key page if there is height for it. Solves C3, C4.
6. Zoom is continuous (0.25 to 4): pinch on the live view, `−`/`+` in geometric steps, the readout returns to 1×. While pinching, and until a picture of the new zoom is drawn, `LiveView` scales the picture it has around the view's focus by the wanted zoom over the drawn picture's own zoom (display width / width in Mac points); the Mac is asked once at the end. The update header names the view request it was cut for (`v`), so the page knows when the Mac could not zoom out further and adopts that value. Solves H2 (one step list on the page; the agent only clamps), C5, H5 (aim placed in picture coordinates).
7. The view follows the text caret while the phone types: `TextFocus` asks Accessibility for the focused element's selected-range bounds, falls back to the element's frame when it fits in the view, then to the pointer. A pointer move or click from the phone (or the Mac's own mouse) returns to the pointer. Neither the pointer nor keyboard focus is moved. The header carries the focus point and a flag, so the page can anchor zoom there and show that the view follows the text. Solves C6.
8. Agent ports are one base port (`REMOTEY_PORT`, default 47800; WebSocket = base + 1); the page derives the WebSocket port from its own. Solves H1 and lets tests run a second agent beside the installed one.

## Rounds

Verifier: `node scripts/ui-verify.mjs [--web=DIR]`, headless Chromium 1248 (chrome-headless-shell from the
Playwright cache), touch emulation at 3x, fake socket, scripted visual viewport. Version 3 (v2 released a lifted
finger correctly, v3 added a 320 px phone and the full view key); round 5 uses version 4, round 6 version 5 (T6 Regler, T7 tray). Baseline = `git archive 668541b Web`, run with
the same verifier version. Keyboard heights: 336 px upright, 208 px sideways; "iOS scrolled" adds an offsetTop of
120 / 80 px.

1. Layout and viewport (decisions 1, 4, 5). Hypothesis: following `offsetTop` and a landscape layout of its own
   make every main action reachable and keep the live view visible while typing. Kept.
   - Main actions reachable: baseline 9/10 upright, 3/9 to 5/9 sideways; candidate 10/10 and 9/9 on 320, 375 and 440 px.
   - Live view visible while typing: small upright 84 → 154 px; with iOS offset 0 → 60 px; sideways 0 → 160 px; sideways with offset 0 → 80 px.
   - Cost: the rail and the drawer key take width sideways, live view share 88 → 75 % (375 px) and 92 → 82 % (440 px).
2. Gestures (decisions 2, 3). Hypothesis: one state machine per touch sequence removes the cursor moves after a
   lifted finger and the lost first pixels. Kept.
   - Moves after lifting one of two fingers: 9 → 0. Slow 30 px: 23 → 30 points. 5 px nudge after resting: 0 → 5.
   - Small slow 4 px scroll: 1.6 → 6.4 (= 4 × 1.6). Scroll with one finger reported per event: 156.8 → 160.
   - Fast 250 px in 150 ms (3 runs each): baseline 741–759, candidate 767–817 points. At the slower real pace the
     verifier manages for "120 Hz", baseline 505–510, candidate 423–434: the curve is flatter at middle speeds on
     purpose; "Beschl." raises it. Event-rate independence is shown in `scripts/remote.test.mjs` with exact timestamps
     (60 vs 120 Hz within 5 %); the browser verifier cannot pace 120 Hz exactly.
   - Not added: inertia and axis lock. Diagonal drift of 10 % still scrolls 10 % sideways (16 of 160); with scroll
     phases, AppKit scroll views can lock the axis themselves. No evidence collected that either helps.
3. Zoom (decision 6). Pinch spreading 60 → 260 px: zoom 0.5 → 2.17 with no move, scroll or click sent (baseline: no
   zoom). Back to 1×: one tap on the readout (baseline: one tap on the middle detent). Kept.
4. Review round (two read-only reviewers, Web and agent/protocol). Fixed: two fingers landing in one event counted as
   one (left click instead of right click, pointer moves instead of scroll); zoom preview state split over two files
   (now measured from the drawn picture); `full` meaning two things; page index in three places; strip overflow at
   320 px; AX lookups uncoalesced on the main thread; scroll not ending text following; observer kept after a failed
   registration; port overflow at 65535.

5. Ergonomics (after trying it on the phone: "not better"). Hypothesis: the round-1 layout kept the old stack of
   strip, mouse keys, media page and text slot upright, so the pad, the thing used most, got half the phone; moving
   status and zoom onto the display, the rest into a dock under the thumb and the deck into a tray over the display
   gives the pad most of the phone without hiding anything. Verifier v4 (no full view key), same runs for all three:
   - Live view share upright: baseline 44/51/65 %, round 1 44/51/65 %, now 69/73/80 % (320/375/440 px). Sideways
     71/75/82 % → 72/76/82 %. Main actions reachable: 9/9 everywhere (baseline upright 8/9, sideways 3–5/9).
   - Live view visible while typing, small upright: 84 → 154 → 206 px; with iOS offset 0 → 60 → 86 px; sideways
     0 → 160 → 164 px.
   - The tray lies over the display (same grid area), so opening it does not resize the display or restart the stream.
     The full view key is gone: the dock leaves the display what full view gave it, minus the mouse keys.
   - The keys the iOS keyboard lacks (Esc, Tab, ⌘ ⌥ ⌃ ⇧, arrows) sit in one row above it instead of a key page of two
     rows; both modifier keys show the same armed state.
   - Three fingers drag (left button held while they move), so a drag needs no second hand on "Links". The third finger
     only counts before two fingers chose to scroll or pinch. Tap then drag was rejected: the tap's click and the drag's
     press would reach the Mac as a double click (Input.swift counts clicks), which opens files in Finder.
   - Also fixed on the way: a view request sent mid-rotation could leave the zoom raised for good (adopted only for a
     request of the display's current size now), and an exception in the page while placing a picture switched the
     stream to JPEG at 30 fps (only decoder faults do now).

6. Schublade, Regler, Gestaltung (nach dem Test am iPhone: „das Schließen ist mega scheiße", „Tempo und so funktioniert
   gar nicht"). Verifier v5 (neu: T6 Regler, T7 Schublade), alle Läufe mit v5, Basis = Stand vor Runde 6.
   - Ursache Schließen: die Schublade lag als eigenes Rasterelement über dem Display und fuhr beim Schließen nur um ihre
     eigene Höhe plus 12 px nach unten. Dort blieb sie undurchsichtig über Links/Rechts und „Tippen…" stehen, bis
     `visibility` nach 300 ms umschlug. Die Ausfahrt nutzte dieselbe Abbremskurve wie die Einfahrt: nach etwa 100 ms war
     sie unten und stand dann noch 200 ms still. Gemessen (T7, 375 px): 314 ms sichtbar, bis zu 114 px über dem Dock.
   - Entscheidung: die Schublade sitzt im Display und wird vom Rahmen beschnitten, sie fährt in die Unterkante hinein.
     Einfahrt 280 ms abbremsend, Ausfahrt 190 ms beschleunigend, `visibility` schlägt genau am Ende um, `will-change`.
     Zu auch durch Tippen aufs Display (der Tipp klickt dann nicht am Mac; Ziehen und Scrollen steuern weiter) und durch
     Wischen nach unten von der Oberkante (folgt dem Finger, fällt ab 56 px oder schnell, sonst federt sie zurück).
     Gemessen: 196 ms sichtbar, 0 px über dem Dock; Tipp aufs Display schließt, 0 Klicks (vorher: blieb offen, 1 Klick);
     Wischen schließt (vorher: nichts). `prefers-reduced-motion`: ohne Übergänge.
   - Ursache Regler, belegt in Chromium: der Wert, den man verstellt, war abgeschnitten. Legende und Wert teilten sich
     eine Zeile mit `overflow: hidden`; bei 320 px schon bei 1× („Beschl. 1×" 73 von 64 px), bei 375 px ab dem ersten
     Schritt („Beschl. 1,25×" 92 von 82 px). Die LED-Leiste sah aus wie ein Schieber, nahm aber keine Berührung an.
     Gehaltene −/+ wiederholten nach 400 ms mit 14 Schritten pro Sekunde, also in unter einer Sekunde ans Ende. Die
     Tasten waren bei 320 px 30 px breit, „Std." ragte aus der Schublade. Die Werte selbst kamen an: in Chromium setzten
     4 Tipps Tempo auf 2×, die nächste langsame Bewegung war doppelt so lang (T6: 30 → 60 Punkte).
   - Nicht gefunden: ein iOS-eigener Fehler, der die Berührungen schluckt. Ausgeschlossen: das installierte App-Bundle
     liefert dieselben Dateien wie der Arbeitsstand, die Werte erreichen `gain` (Tests). Nicht prüfbar, weil kein
     WebKit mit Touch lief (iOS-Simulator per safaridriver brach jede Sitzung beim Laden ab, Playwright-WebKit lud nicht
     herunter): `inert` auf den verschobenen Seiten und Trefferprüfung im transformierten, beschnittenen Band.
   - Entscheidung: Schieber statt Tasten. Der Finger setzt den Wert, wo er die Spur berührt, und beim Gleiten; der Knopf
     rastet in den Stufen ein, ein längerer Strich zeigt den Standard, der Wert steht groß über der Legende und wird nie
     beschnitten. Eigene Touch-Behandlung mit `touch-action: none`, Maus und Pfeiltasten als Ersatz, `role=slider`.
     Nur die gewählte Seite wird gelegt (`hidden` statt `inert` plus verschobenem Band), alle Seiten gleich hoch.
     Gemessen (T6): Tempo auf 2× mit 1 Berührung statt 4 Tipps, nächste Bewegung 2,0-fach.
     Stufenlogik in `touchpad.js` (`detents`, `settingAt`, `stepSetting`, `settingText`), Tests in `remote.test.mjs`:
     jede Stufe erreichbar, Enden halten, jede Stufe ändert, was der Mac bekommt.
   - Gestaltung: eine Signalfarbe (Amber: aktiv, Indexstrich des Schiebers), Radien 16/14/10/8, Kappen mit heller
     Oberkante auf dunklem Sockel, gedrückt 2 px tiefer, Fokusring nur bei Tastatur, Griff an der Schublade,
     Medientasten bei 320 px schmaler (Play 66 px statt eng an Vor/Zurück).
   - Unverändert (T1 bis T5): Display-Anteil 69/73/80 % hochkant, 72/76/82 % quer, 9/9 erreichbar überall; Live-Bild
     beim Tippen 206/86/164/84 px; Zeiger und Scrollen gleich (schnell 250 px bei 60 Hz 769 → 795, Streuung des Laufs).

7. Runde 6: Bildrate (nach „die FPS sind sooo langsam“ am iPhone). Messaufbau ohne Bild auf dem Mac:
   `REMOTEY_TEST_PATTERN=1` ersetzt die Bildschirmaufnahme durch ein ständig bewegtes Muster in Größe und Takt der
   Aufnahme, `REMOTEY_STATS=1` schreibt je Sekunde Aufnahme, Kodierung (davon Zusammensetzen), Verworfenes,
   geschlossenes Fenster, Bilder, Mbit/s und Antworten nach stderr, dazu Ansichtsanfragen und HTTP-Zeilen.
   `bench.mjs --still` misst ohne Zeigerbewegung, `--link=wifi` und `--link=3mbit` modellieren die Strecke zum Telefon.
   - Ausgeschlossen: Agent bei 60 fps 59 bis 60 Bilder/s, 4 Mbit/s, 8 bis 9 KB je Bild, nichts verworfen. Chrome
     (WebCodecs, VideoToolbox) 60 dekodiert, 1,5 ms je Bild. Safari im iOS-Simulator 27.2 mit der echten Seite:
     60/s dekodiert und gezeichnet, 2,5 ms je Bild, kein Rückfall auf JPEG, keine wiederholten Ansichtsanfragen.
     Safari hält kein Bild zurück: das SPS von VideoToolbox trägt `bitstream_restriction` mit
     `max_num_reorder_frames = 0`, das WebKit (`H264Utilities.cpp`, `GPUVideoDecoderVTB.mm`) für seine
     Umordnungs-Warteschlange liest. Safari zeichnet auf dem iPhone mit 60 Hz (`PreferPageRenderingUpdatesNear60FPSEnabled`
     ist außer auf visionOS an), die Seite fordert also 60 fps an; 120 fps sind für das iPhone ohne Belang.
   - Ursache (am Mac gezeigt, am iPhone nicht gemessen): das Sendefenster ließ höchstens sechs Bilder unterwegs sein,
     bemessen an der schnellsten Antwort. Bilder/s ≤ 6 / Antwortzeit, also unter 60 fps, sobald eine Antwort länger als
     100 ms braucht. 30 `tailscale ping` zum iPhone des Nutzers (direkt im WLAN) brauchten 16 bis 777 ms, Median
     104 ms (Telefon ruhend). Und sechs große Bilder auf einer langsamen Strecke standen für eine Sekunde Verzug.
   - Änderung: das Fenster ist eine Zeit. Bilder gehen, solange das älteste unbeantwortete jünger ist als die
     schnellste Antwort plus 200 ms (zwei bis zur ersten Antwort, höchstens 64). A/B direkt hintereinander, Testmuster,
     60 fps, „zeigt“ = neue Bilder je 60-Hz-Takt des Telefons, „Alter“ = Alter des sichtbaren Bilds:

     | Strecke | vorher zeigt/s | nachher zeigt/s | Alter Median vorher → nachher | p90 vorher → nachher |
     |---|---|---|---|---|
     | WLAN-Modell (3 Läufe) | 8,6 / 9,1 / 13,7 | 18,0 / 19,3 / 23,3 | 121–226 → 128–285 ms | 459–555 → 463–551 ms |
     | 3 Mbit/s | 6,7 | 19,4 | 985 → 392 ms | 1123 → 468 ms |
     | 8 Mbit/s | 51,6 | 47,4 | 31 → 28 ms | 36 → 42 ms |
     | sofortige Antwort (gesendet/s) | 56,9 | 59,5 | | |

   - Seite: der Wächter fiel auf JPEG (30 fps) zurück, sobald zwei Sekunden lang ununterbrochen ein Bild im Decoder
     stand, auch wenn laufend Bilder herauskamen. Jetzt nur, wenn zwei Sekunden lang keins herauskommt. Die Kadenz wird
     auf 5 gerundet: der Simulator maß 59 Hz, die zweite Anfrage startete den Strom samt Schlüsselbild neu.
   - 120 fps: je Bild 6 bis 9 ms, davon etwa 5 ms Zusammensetzen in Core Image, der Rest Kodierung, nacheinander. Das
     erklärt die Lücke bei 120 fps (91 bis 114 statt 120). Ohne Arbeitsfarbraum keine Änderung (4,8 ms), verworfen.
     Nicht angegangen, weil Safari mit 60 Hz zeichnet.
   - Offen, nicht behoben: die Bitrate ist fest 4 Mbit/s und VideoToolbox verteilt sie über die Zeit. Kommen weniger
     Bilder durch, wird jedes größer (3 Mbit/s: 14 KB statt 8 KB). Eine Anpassung der Bitrate an die Antworten würde
     langsame Strecken (DERP) entlasten.

8. Rauszoomen (nach „ich will mehr rauszoomen können! horizontaler modus und vertikaler!“). Ursache: der Ausschnitt
   wurde verkleinert, bis er auf das kleinste Display passte (`ScreenView.region`), mit dem Seitenverhältnis des
   Telefons. Am Mac des Nutzers (2056 × 1329 unter zwei Displays mit je 3008 × 1692) gemessen mit der installierten
   App: hochkant (370 × 560) höchstens 878 × 1329 Punkte, also 0,42×, quer (700 × 330) höchstens 2056 × 969, 0,34×.
   Auf einem der großen Displays war damit hochkant nie mehr als 29 % der Breite zu sehen. Dazu fragte die Seite nie
   unter 0,25× an.
   - Entscheidung: die Grenze ist der ganze Schreibtisch. Der Ausschnitt behält das Seitenverhältnis des Telefons und
     wächst, bis der Kasten um alle Displays hineinpasst; was kein Display bedeckt, bleibt schwarz. Verworfen: Grenze
     am Display des Zeigers (die Ausschnittgröße hinge dann am Ort des Zeigers, jeder Wechsel des Displays würde
     Encoder und Zoomwert neu setzen) und ein gedrehtes Bild hochkant (die Richtungen des Trackpads stimmten nicht mehr).
   - Lage je Achse (`ScreenView.origin`): passt der Ausschnitt in seine Grenzen, folgt er wie bisher dem Zeiger.
     Ist er länger, steht er still mit dem Display in der Mitte und rückt davon nur ab, um ein Nachbardisplay statt
     Leerraum zu zeigen; länger als der Schreibtisch, liegt dieser in der Mitte. Stetig in Zeiger und Zoom, also kein
     Sprung an der Naht und keiner am Anschlag. Ein Display, das der Ausschnitt zeigt, läuft mit voller Rate, auch wenn
     der Zeiger weiter als einen halben Ausschnitt entfernt ist.
   - Grenzen an der Naht: bisher wuchsen sie für jedes nahe Display vom Display des Zeigers aus. Mit drei Displays
     zählt ein drittes dann auf beiden Seiten einer Naht von einer anderen Kante, was erst auffällt, seit der
     Ausschnitt größer als sein Display sein darf: 700 × 330 bei 0,25× sprang um 327 Punkte, wenn der Zeiger vom
     kleinen Display nach oben wechselte (im Review gefunden). Jetzt wächst jedes nahe Display von dem aus, was die
     übrigen erlauben, berechnet für jede Teilmenge der nahen Displays. Bei zwei Displays ist das die alte Rechnung.
   - Seite: Stufen bis 0,02× (der Agent begrenzt nur die Rechnung, der Anschlag kommt wie bisher mit dem Bild zurück
     und wird übernommen, jetzt auf drei Stellen). Anzeige und Vorschau gehen nur bis zum zuletzt gemeldeten
     Anschlag, während der Zange und solange der Mac gefragt wird; die Anfrage selbst fragt trotzdem nach allem,
     damit ein dazugekommenes Display den Anschlag löst. Der Anschlag gilt für eine Displaygröße des Telefons.
   - Gemessen, Test-Agent mit Testmuster an denselben Displays: hochkant bis 6016 × 9105 Punkte (0,062×), quer bis
     6408 × 3021 (0,109×), Zeiger an der erwarteten Stelle. Verifier v7 (T2): Zange und −-Taste fragen hochkant und
     quer unter 0,25× an (vorher 0,25×), der Anschlag eines Macs mit 3008 Punkten Breite wird übernommen (0,122× und
     0,237×), eine weitere Zange zeigt keine kleinere Vorschau, auch nicht nach dem Loslassen. T1 und T3 bis T8
     unverändert.

9. Zoom je Ausrichtung (nach „merk dir den zoom pro ausrichtung“). Der Zoom ist CSS-Pixel je Mac-Punkt, das Display
   des Telefons ist quer etwa doppelt so breit wie hochkant: derselbe Wert zeigt quer doppelt so viel Breite, und der
   Anschlag liegt woanders (am Mac des Nutzers 0,062× hochkant, 0,109× quer). Nach hochkant ganz raus, drehen und
   zurückdrehen stand der Wert deshalb auf dem Anschlag der anderen Ausrichtung.
   - Entscheidung: zwei Werte, `zoom` (hochkant, der bisherige Schlüssel) und `zoom-wide` (Telefon quer, dieselbe
     Abfrage wie das Layout). Gelesen wird der Wert der aktuellen Ausrichtung bei jedem Zugriff, nicht beim
     Drehereignis, damit eine Anfrage mitten in der Drehung nie den falschen Wert trägt oder speichert. Quer beginnt
     beim gespeicherten Hochkant-Wert, also dort, wo eine ältere Seite stand.
   - Gemessen (Verifier v8, T2): − hochkant 0,35×, drehen 0,5×, + quer 0,7×, zurück 0,35×, wieder quer 0,7×, beide
     gespeichert. Vorher: der Wert wanderte mit (0,35 → 0,35 → 0,5 → 0,5 → 0,5).

10. Programme und Fenster (Issue 4: „Liste mit offenen Apps, bei Klick Auswahl des Fensters, in den Vordergrund und in
   den Fokus"). Verifier v9 (neu: T9 Umschalter, „Apps" zählt als Hauptaktion); Agent geprüft mit zwei Test-Apps mit je
   zwei Fenstern, damit keine echte App angefasst wird.
   - Gemessen am Mac (14 offene Apps): Accessibility nennt nur die Fenster des aktuellen Space und die minimierten.
     8 der 14 Apps meldeten kein Fenster, obwohl sie welche haben. Alle Apps nacheinander zu fragen dauerte 46 bis
     827 ms (die erste Frage an eine App ist die teure), nebeneinander 20 bis 64 ms. Ein Symbol mit 120 px ist 5 bis
     8 KB groß, alle zusammen etwa 110 KB.
   - Entscheidung Agent: `Apps.swift` fragt nebeneinander und abseits des Hauptthreads, der den Zeiger trägt. Die
     Liste geht sofort, die Symbole folgen einzeln und je Verbindung einmal. Reihenfolge: die App im Vordergrund, dann
     nach vorderstem Fenster auf dem Bildschirm, dann der Rest nach Startzeit. Ein Fenster behält seine Nummer von
     Liste zu Liste. Gemessen: Antwort auf `apps` nach 48 bis 216 ms.
   - Entscheidung Fokus: ein Fenster wird über Accessibility angehoben, zum Hauptfenster gemacht und die App nach vorn
     geholt (`AXFrontmost` und `activate`, weil macOS `activate` einer Hintergrund-App nur als Wunsch nimmt). Ohne
     Fenster wie ein Klick im Dock: aktivieren und das Bundle öffnen, damit eine App ohne Fenster eins aufmacht.
     Keine privaten Schnittstellen (wie bei den Seitentasten): Fenster auf anderen Spaces lassen sich damit nicht
     einzeln wählen; der Tipp auf die App wechselt den Space, danach listet der Umschalter ihre Fenster.
   - Zwei Fehler, die erst der Lauf am Mac zeigte: `openApplication` auf einen Prozess ohne App-Bundle startet dessen
     Datei im Terminal (vier Rückfragen von Ghostty), jetzt nur für `.app`. Und `NSRunningApplication(processIdentifier:)`
     kennt eine eben gestartete App oft nicht (die meisten Läufe ohne vorherige Liste scheiterten); das Ziel kommt jetzt aus
     der zuletzt gesendeten Liste, was zugleich nur zulässt, was die Liste anbot.
   - Gemessen am Endstand: 17 bzw. 18 Prüfungen in drei Läufen bestanden (Fenster einer App im Hintergrund, anderes
     Fenster derselben App, minimiert, ausgeblendet, ohne Fenster, Nummer ohne Fenster, beendete App, Prozess außerhalb
     des Docks), einmal mit einer Test-App ohne Bundle. 24 von 24 Wechseln nach 700 ms vorn, je mit einer
     Zeigerbewegung 300 ms davor und laufendem Live-Bild.
   - Entscheidung Zeiger: das Live-Bild ist um den Zeiger geschnitten, ein Fenster auf dem anderen Display wäre nach dem
     Wechsel nicht zu sehen. Mit Live-Bild geht der Zeiger in die Mitte des geholten Fensters, außer er liegt schon
     darin oder hält eine Taste; ohne Live-Bild bleibt er. Gemessen: 10 von 10, ohne Live-Bild keine Bewegung.
   - Entscheidung Seite: eine eigene Taste „Apps" im Dock statt einer vierten Seite der Schublade (die merkt sich ihre
     Seite, der Weg wäre drei Tipps statt zwei). Beschriftet statt bebildert, weil das Rasterzeichen schon die
     Schublade öffnet. Das Blatt fährt wie die Schublade aus der Unterkante und lässt die oberste Zeile des Displays
     frei. Symbole im Raster statt einer Liste: 12 Apps ohne Scrollen bei 375 px. Ein Tipp wechselt sofort; nur eine
     App mit mehreren Fenstern (Zahl am Symbol) zeigt erst die Titel, und bis zur Wahl bewegt sich am Mac nichts.
     Was der Mac meldet, steht auf dunklem Glas, Amber markiert die App und das Fenster im Vordergrund.
     Titel und Namen werden als Text gesetzt, nie als Markup (T9 prüft einen Titel mit `<img onerror>`).
   - Gemessen (T9): je Reihe 3/4/5 Symbole hochkant (320/375/440 px), 5 quer; kleinste Tippfläche 68 px; Blatt nie über
     den Zoomtasten; 12 von 12 Apps ohne Scrollen bei 375 und 440 px, 9 bei 320 px. Unverändert (T1 bis T8):
     Display-Anteil 69/73/80 % hochkant, 72/76/82 % quer, 12/12 erreichbar überall.
   - Nach dem Review (zwei Leser, Standards und Issue): beim Öffnen stand kurz die Liste vom letzten Mal im Blatt, und
     die frische kam 50 bis 200 ms später in anderer Reihenfolge, weil die Reihenfolge der Nutzung folgt. Ein schneller
     Tipp traf dann eine andere App. Jetzt stehen bis zur Antwort so viele Leerplätze, wie der Mac zuletzt Apps hatte,
     und nehmen keinen Tipp an (T9 mit 400 ms Antwortzeit: vorher öffnete der Tipp die Fensterwahl der alten Liste).
     Das Blatt lässt sich auch am Raster nach unten wischen, solange die Liste nicht scrollt (vorher nur am Kopf).
     Taste und Blatt heißen beide „Apps". Titel laufen in ihrer eigenen Schreibrichtung.
   - Nicht gebaut: Beenden oder Ausblenden einer App vom Telefon, laufende Aktualisierung bei offenem Blatt (die Liste
     wird bei jedem Öffnen gefragt, das Blatt schließt nach der Wahl). Die App im Vordergrund steht oben links, wie
     bei Command-Tab; näher am Daumen wäre die unterste Reihe, das bricht aber die Leserichtung.

11. Gesperrter Mac (Issue 6: „eval ob möglich mit gesperrtem Bildschirm", dazu „den Mac dann auch remote entsperren").
   Gemessen mit einem Messprogramm als Nutzerprozess auf macOS 27.0.1 (MacBook Pro, internes Display und zwei externe),
   das sperrt, eingibt, aufnimmt und nie Return drückt; danach mit dem Agenten selbst (`scripts/lock.mjs`).
   - Sperre erkennen: `CGSSessionScreenIsLocked` im Sitzungsverzeichnis ist beim Sperren 0,25 s nach dem Kürzel gesetzt,
     die Benachrichtigung `com.apple.screenIsLocked` kommt 0,6 s danach. Beim Entsperren ist es umgekehrt: die
     Benachrichtigung kommt zuerst, das Verzeichnis sagte 0,2 s später noch „gesperrt". Der Schlüssel fehlt, wenn offen.
   - Eingabe: Zeigerbewegung (+60/+40 Punkte, angekommen), Tasten per Tastencode (drei Punkte im Passwortfeld), ein
     Zeichen als Unicode-Text (vierter Punkt), Umschalt+1 (fünfter), acht Rückschritte (leer). Alles über denselben
     `CGEvent`-Weg wie sonst. Accessibility meldet das Feld als `AXSecureTextField` von `com.apple.loginwindow` mit Fokus.
   - Bild: ScreenCaptureKit liefert den Sperrbildschirm, mit einem Strom von vor dem Sperren wie mit einem, der
     gesperrt startet; beide laufen über Sperren und Entsperren weiter.
   - Display aus: Esc auf dem Sperrbildschirm schaltet es nach 0,2 s ab. Beide Ströme enden mit `SCStreamError` -3815,
     `SCShareableContent` nennt keine Displays mehr (ohne Fehler), `NSScreen.screens` weiter drei. Eine gepostete
     Bewegung und eine gepostete Taste weckten es in je 2 s nicht. `IOPMAssertionDeclareUserActivity` weckte es in
     unter 0,5 s; die alten Ströme bleiben tot, ein neuer liefert sofort. Das erklärt die Notiz aus Runde 7
     („Mac gesperrt, ScreenCaptureKit lieferte keine Displays"): nicht die Sperre, das schlafende Display.
   - Entscheidung Wecken: jede Eingabe vom Telefon (Bewegung, Scrollen, Klick, Taste, Text, App-Wechsel, Entsperren)
     und das Einschalten des Live-Bilds melden Nutzeraktivität, höchstens einmal je Sekunde, bei schlafendem Display
     sofort (`UserActivity.swift`). Die Medientasten nicht: Musik anhalten soll ein dunkles Display dunkel lassen.
     Den Neuaufbau der Aufnahme gab es schon (jede Sekunde ein Versuch, solange das Bild gewünscht ist).
     Verworfen: das Display wach halten, solange das Live-Bild läuft. Die Meldung setzt auch die Leerlaufzeit zurück,
     ein offen liegendes Telefon würde die automatische Sperre des Macs aushebeln.
   - Entscheidung Entsperren: macOS hat keinen Aufruf dafür, also tippt der Agent das Passwort ins Feld und drückt
     Return (`LockScreen.swift`), wie es auch RustDesk tut. Getippt wird nur, wenn das Passwortfeld von loginwindow den
     Fokus hat und ein Display an ist; darauf wartet er bis 5 s und weckt dabei das Display. Bei den ersten beiden
     Messläufen war der Mac 2 s nach dem Sperren wieder offen (von Hand entsperrt): ein Passwort, das dann Taste für Taste
     ankommt, stünde in der App im Vordergrund. Was im Feld steht, wird vorher gelöscht. Bleibt der Mac 6 s nach Return
     gesperrt, hört die Seite `unlock` mit dem Grund (`field`: nichts getippt, `password`: getippt und abgelehnt).
   - Entscheidung Seite: kein eigenes Blatt. Ist der Mac gesperrt (`lock`, nach dem `ok` und bei jedem Wechsel), öffnet
     die Tipptaste dasselbe Feld als Passwortfeld: Vorhängeschloss und „Entsperren…" statt Tastatur und „Tippen…". iOS
     verdeckt die Eingabe, lernt sie nicht und bietet das gespeicherte Passwort der Seite an. Nichts geht Taste für
     Taste hinaus, die Sendetaste schickt alles in einer Nachricht. Das Layout beim Tippen (Live-Bild über der
     Tastatur, Sondertasten) bleibt, wie es gemessen ist; das Live-Bild zeigt dabei das Passwortfeld des Macs
     („Folgt Text"). Verworfen: ein Hinweis im Display, der bei 320 px neben „Folgt Text" keinen Platz hat.
   - Gemessen mit dem Agenten (ein Lauf, JPEG, Entwicklungs-Build): Sperre nach 0,8 s gemeldet; gesperrt folgt der
     Zeiger, 59 Bilder in 1,3 s Bewegung; Display per `pmset displaysleepnow` aus, eine Bewegung vom „Telefon" weckt es
     (0,13 s), das nächste Bild kommt 0,34 s nach der Bewegung (der Neuaufbau läuft im Sekundentakt, also bis etwa
     1,5 s); falsches Passwort: Feld leer gemeldet, getippt, nach 6,1 s als abgelehnt gemeldet; Entsperren von Hand
     gemeldet, Bild läuft weiter (41 Bilder). Das Stromprotokoll (`pmset -g log`) bestätigt: Display aus 22:37:44, an
     22:37:46 durch die Meldung von Remotey, wieder aus 22:38:19.
   - Daraus: der Sperrbildschirm schaltet das Display etwa 30 s nach der letzten Eingabe ab, wenn keine App das
     verhindert (im Messlauf davor hielt ein Browser es 110 s an). Das Bild auf dem Telefon bleibt dann stehen, bis
     die nächste Eingabe weckt. Am Mac war das Display nach dem Test schwarz, bis zum Entsperren von Hand (22:41:03).
   - Verifier v10 (T10): gesperrt wird das Feld zum Passwortfeld, sechs getippte Zeichen senden nichts, Enter sendet
     eine Nachricht `unlock`, eine Absage steht rot im Feld, nach `lock: false` ist es wieder das Textfeld und leitet
     weiter. T1 bis T9 unverändert (Display-Anteil 69/73/80 % hochkant, 72/76/82 % quer, 12/12 erreichbar).
   - Nach dem Review (ein Leser, zwei Runden): der Agent nimmt ein Passwort zur Zeit und antwortet auf ein falsches
     erst nach 6 s. Ein korrigiertes, das in dieser Zeit abgeschickt wurde, verwarf er stumm, und die Seite hatte das
     Feld schon geleert. Jetzt hält die Seite es im Feld, bis der Mac geantwortet hat (T10: zweites Enter sendet
     nichts, nach der Absage sendet Enter es), und der Agent sagt einem zweiten Telefon sofort ab. Nicht geändert:
     mehr als 100 Zeichen im Feld löscht er nicht ganz (`Input.key` begrenzt), das Feld hält nur, was ein Versuch ließ.

12. Lesbar am Telefon, Displays, ein Fenster (Issues 13, 12, 5). Gebaut: Auto (13 A), die App-Zoom-Tasten (13 E), die
   Display-Auswahl (12). Nicht gebaut: 13 B, C und F, wie dort empfohlen erst nach A. Verifier v11 (neu: T11 Auto,
   T12 Display-Auswahl, T8 mit den Zoom-Tasten, T2 ohne die 1×-Taste).
   - Entscheidung Protokoll: die Ansichtsanfrage trägt `fit: "window"` neben dem Zoom, der Agent wählt den Ausschnitt.
     Der Zoom bleibt in der Anfrage und gilt, wenn vorn kein Fenster ist (Schreibtisch des Finders, fehlende
     Bedienungshilfen, Sperrbildschirm). Jedes Bild sagt im Kopf (Flag 2), ob es eingepasst ist: nur dann übernimmt die
     Seite seinen Zoom in die Anzeige, ohne ihn als Anschlag zu nehmen und ohne neu anzufragen.
   - Entscheidung Ausschnitt (`ScreenView.fitted`): Seitenverhältnis des Telefons, so groß, dass das Fenster Breite
     oder Höhe füllt, höchstens 2× (ein kleiner Dialog bleibt klein), höchstens der ganze Schreibtisch. Lage wie beim
     Zeiger: um das Fenster, innerhalb der Displays, auf denen es liegt, und über `origin` mittig, wenn der Ausschnitt
     länger ist als diese.
   - Entscheidung Zeiger außerhalb (Frage aus Issue 13): der Zeiger schiebt den Ausschnitt. Er bleibt 20 Telefonpixel
     vom Bildrand, der Ausschnitt rückt nur so weit wie nötig und kehrt mit dem Zeiger zurück, bei gleicher Bildgröße,
     also ohne neuen Strom. So bleiben Menüleiste, Dock und Nachbarfenster erreichbar. Verworfen: Zeiger verlässt das
     Bild (man steuert blind) und Ausschnitt wächst (jede Bewegung setzte Encoder und Aufnahmedichte neu).
   - Entscheidung „Folgt Text" im eingepassten Bild: dieselbe Regel, statt des Zeigers hält der Ausschnitt die
     Schreibmarke. Im Fenster ändert sich nichts, außerhalb rückt das Bild zu ihr.
   - Entscheidung Ende: Zange und − / + beenden Auto und gehen vom gezeigten Zoom aus weiter. Die Anzeige zwischen
     − und + ist die Taste dafür, „Auto" darüber die Lampe. Sie setzte bisher auf 1×; das geht jetzt mit − / + (T2:
     3 Tipps von 2,17× statt 1). Verworfen: eine vierte Taste, bei 320 px ist neben Anzeige und Messwert kein Platz.
   - Entscheidung Fenster (`FrontWindow`): das fokussierte Fenster der vorderen App, wenn es ein Fenster oder Dialog
     ist (`Apps.isChoice`), sonst ihr Hauptfenster. Ein anderes Fenster gilt sofort, ein bewegtes oder in der Größe
     geändertes erst nach 0,15 s Ruhe: beim Ziehen liefe sonst das Bild mit dem Fenster mit, und jede Größe baute
     Encoder und Aufnahme neu. Die Beobachtung der vorderen App teilt es sich mit `TextFocus` (`FrontApp`).
   - Entscheidung Issue 5: Auto ist die Einzel-App-Ansicht. Ein eigenes Bild nur des Fensters
     (`SCContentFilter(desktopIndependentWindow:)`) zeigte auch ein verdecktes Fenster, aber Klicks träfen, was davor
     liegt; die Menüleiste fehlte. Der Umschalter holt das Fenster ohnehin nach vorn.
   - Entscheidung Displays: eine Karte unter den Apps im selben Blatt, nur ab zwei Displays, Kacheln in der Anordnung
     des Macs, das Display mit dem Zeiger amber. Kein eigenes Blatt und keine zweite Seite: ein Tipp mehr. Der Agent
     merkt sich je Display, wo der Zeiger war, als er es über die Karte verließ (als Anteil, damit der Ort eine neue
     Anordnung übersteht), sonst die Mitte. Wer die Liste einmal fragte, bekommt jede Änderung der Displays.
   - Entscheidung Tasten: ⌘−, ⌘0, ⌘+ in der ersten Reihe der Tastenseite. Dafür sind Leer, ⌫ und ↵ nur noch eine
     Spalte breit statt zwei (375 px: 34 statt 74 px). Eine dritte Reihe hätte alle Tasten auf 35 px Höhe gedrückt.
   - Gemessen am Mac (Entwicklungs-Agent auf 47840, echte Aufnahme, Laptop 2056 × 1329 unter zwei Displays mit
     3008 × 1692): Fenster 2056 × 1210 hochkant (390 × 844) 2056 Punkte breit, 0,19×; quer (844 × 390) 2619 Punkte,
     0,32×, Fenster ganz. Fenster 1028 × 606 einer anderen App über den Umschalter geholt: 1311 Punkte, 0,64×, erstes
     eingepasstes Bild 88 ms nach `focus`. Auto aus: 0,5× wie angefragt. `smoke.mjs --display`: Zeiger auf das zweite Display und
     zurück auf den Punkt genau.
   - Gemessen (T11): Auto an fragt `fit: "window"` mit unverändertem Zoom; ein Fenster mit 1512 Punkten zeigt 0,24×,
     eines mit 900 Punkten 0,41×, je ohne neue Anfrage und ohne Vorschau; gedreht fragt die Seite wieder mit `fit`;
     + geht auf 0,5× und schaltet Auto aus; eine Zange aufs Doppelte fragt 0,484× ohne `fit`, keine Bewegung, kein
     Klick; ohne Fenster bleibt die Anzeige auf dem Zoom von Hand. T12: drei Kacheln in der Anordnung, kleinste Seite
     46 px hochkant und 32 px quer (die Karte ist quer 72 statt 104 px hoch), Apps in Sicht mit Karte 6/12/12 hochkant
     und 5/5/10 quer (ohne: 9/12/12 und 10/10/12); ein Tipp sendet `display` und schließt das Blatt; ein abgezogenes
     Display verschwindet ohne Nachfrage; ein Display: keine Karte. T1, T3 bis T7, T9, T10 unverändert
     (Display-Anteil 69/73/80 % hochkant, 72/76/82 % quer, 12/12 erreichbar).
   - Bekannte Grenze: ein Fenster so breit wie sein Display ist hochkant klein (im Lauf oben 0,19×), und über und
     unter ihm steht, was dort am Schreibtisch liegt. Dagegen helfen Drehen, ⌘+ und später 13 B oder C.

13. Telefonform (Issue 13 B, nach „jetzt 13 B bauen"). Verifier v12 (neu: T13).
   - Entscheidung Größe: nicht „so groß wie das Display erlaubt", sondern ein Zoom. Das Fenster bekommt die Größe des
     Telefondisplays geteilt durch diesen Zoom, also dessen Seitenverhältnis, und zeigt sich bei genau diesem Zoom.
     Die größte passende Größe hinge am Display des Macs (hochkant 0,44× am Laptop, 0,34× an 3008 × 1692) und ließe
     Text klein. Standard 0,5×, je Ausrichtung gespeichert (`form`, `form-wide`).
   - Entscheidung Zoomtasten: mit Telefonform ist der Zoom die Fenstergröße. − / + und die Zange bitten den Mac um
     ein größeres oder kleineres Fenster, das ganz im Bild bleibt, und Auto bleibt an. Ohne Telefonform beenden sie
     Auto wie bisher. Die Seite rechnet den nächsten Schritt vom gezeigten Zoom aus, nicht vom gewünschten: lehnt die
     App ab (Mindestgröße) oder das Display (kein Platz), bleibt die Anzeige stehen und die Taste fragt nichts Neues.
   - Entscheidung Schalter: eine Rasttaste „Telefonform" im Kopf des Apps-Blatts, weil sie bestimmt, wie die Apps
     darunter nach vorn kommen, und weil das Display bei 320 px keine weitere Taste fasst. Sie weicht der Fensterzahl,
     solange die Fenster einer App gelistet sind. An schaltet auch Auto an; Auto aus behält sie fürs nächste Mal. Die
     Lampe der Anzeige sagt dann „Form" statt „Auto".
   - Entscheidung Agent (`FrontWindow.shape`): ein Fenster zur Zeit. Es bekommt seinen alten Rahmen zurück, wenn ein
     anderes nach vorn kommt, wenn Telefonform, Auto oder das Live-Bild enden, beim Sperren, beim Trennen und beim
     Beenden über das Menü (`applicationWillTerminate`). Gefragt wird ein Fenster je gewünschtem Rahmen einmal: was
     die App daraus macht oder der Nutzer danach, bleibt. Nur Dokument- und Hauptfenster (`AXStandardWindow`) mit
     setzbarer Größe, keine Dialoge, kein Vollbild. Lage: wo das Fenster ist, nur so weit verschoben, dass es in den
     sichtbaren Teil seines Displays passt (ohne Menüleiste und Dock). Der neue Rahmen gilt sofort, ohne die 0,15 s
     Ruhe, weil der Agent ihn selbst gesetzt hat.
   - Entscheidung Seite außer Sicht: bei `visibilitychange` nach „hidden" schaltet die Seite das Live-Bild ab. iOS
     friert die Seite ein, ohne den Socket zu schließen; das Fenster bliebe sonst in Telefonform, bis der Socket
     abläuft. Zurück im Blick verbindet die Seite wie bisher neu und fragt wieder an.
   - Fehler aus Runde 12, im Lauf am Mac gefunden: kam ein Fenster ohne den Umschalter nach vorn (⌘Tab, eine App
     startet), blieb der Zeiger draußen und schob das eingepasste Bild vom Fenster weg. Gemessen: Bild in Fenstergröße,
     aber auf dem Display, auf dem die Maus lag. Jetzt geht der Zeiger in die Mitte eines Fensters, das unter Auto
     neu nach vorn kommt, außer er liegt schon darin oder hält eine Taste, wie nach dem Umschalter. Danach gemessen:
     Zeiger bei 0,50/0,50 im Bild.
   - Gemessen am Mac (Entwicklungs-Agent auf 47840, eigene Testfenster 1200 × 732, damit keine echte App angefasst
     wird; Laptop-Display): hochkant (390 × 844) bei 0,5 gibt das Display nur 559 × 1210 her, das Bild zeigt 0,70×;
     bei 1,0 genau 390 × 844, erstes Bild 113 ms nach der Anfrage; quer (844 × 390) bei 0,5 genau 1688 × 780, 121 ms.
     Telefonform aus: alter Rahmen auf den Punkt. Zweites Fenster nach vorn: das erste hat den alten Rahmen, das
     zweite die Form. Socket zu: alter Rahmen. Fenster mit Mindestgröße 900 × 600 bei 1,0: 900 × 844, Bild 0,43×,
     danach keine weitere Änderung in 1 s. Live-Bild aus: alter Rahmen.
   - Gemessen (T13): die Taste ist auf allen Telefonen 111 × 36 px, im Kopf, neben dem Titel; an fragt
     `fit: "window", shape: 0.5` und lässt das Blatt offen; + fragt 0,7 mit Auto an; zeigt der Mac danach nur 0,6×,
     sendet ein weiteres + nichts; eine Zange aufs Doppelte fragt 1,2 ohne Bewegung oder Klick; quer fragt 0,5; die
     Anzeige-Taste fragt ohne `fit` und `shape`, die Rasttaste bleibt; außer Sicht sendet `view` aus, zurück fragt
     wieder mit `shape`; Rasttaste aus fragt nur `fit`. T1 bis T12 unverändert.

14. Sperrtaste und Passkey-Probe (Issue 15, erster Teil). Verifier v13 (T10 erweitert).
   - Entscheidung Ort: ein Vorhängeschloss unter der Stummtaste auf der Medienseite, beide teilen sich deren Breite.
     Die Tastenseite ist mit 16 Tasten in zwei Reihen voll, das Dock fasst bei 320 px keine weitere Taste, und die
     Transporttasten sind bei 320 px schon 39 px schmal, eine weitere Spalte nähme ihnen den Rest.
   - Entscheidung Senden: die Seite schickt `key q` mit `ctrl` und `cmd`, wie `scripts/lock.mjs` seit Runde 11 sperrt,
     ohne die gerasteten Sondertasten: ⇧⌘Q meldet den Nutzer ab. Sie bleiben für die nächste Taste gerastet. Kein
     eigener Befehl im Agenten.
   - Gemessen (T10): Schloss und Stumm je 48 px (320 px hochkant), 46 px (320 px quer), sonst 53 px, 10 px
     auseinander, auf der Seite; ein Tipp mit gerasteter ⇧ sendet genau `key q ctrl cmd 1`, ⇧ bleibt gerastet.
   - Entscheidung Entsperren mit Face ID: PRF von Anfang an, kein Schlüsselbund. Das Passwort liegt dann mit einem
     Schlüssel versiegelt, den nur der Passkey nach Face ID herausgibt; die Datei braucht keine Geheimhaltung und
     liegt neben dem Token. Ein Schlüsselbundeintrag hinge an der Signatur „Apple Development", die jeder Prozess
     nachmachen kann, der dieses Zertifikat benutzen darf, und `swift run` käme ohne Nachfrage nicht an ihn.
   - Probe (`Web/spike.html`, `spike.js`, `spike.css`, nicht Teil der Fernbedienung, geht mit dem Bau des Ablaufs):
     legt einen Passkey „Remotey Spike" an und ruft ihn ab, je mit PRF, prüft die Signatur mit dem Schlüssel aus
     `getPublicKey()` (WebCrypto, wie später CryptoKit) und ruft einmal 2 s nach dem Tipp ab. In Chromium mit
     virtuellem Authenticator (CDP `WebAuthn.addVirtualAuthenticator`, `hasPrf`) unter der CSP des Agenten: PRF schon
     beim Anlegen, derselbe Wert bei jedem Abruf und nach geleertem Speicher, Signatur gültig. Das sagt nichts über
     iOS; es zeigt, dass die Seite stimmt und dass `ui-verify` den Ablauf später mit PRF prüfen kann.

15. Entsperren mit Face ID (Issue 15, zweiter Teil). Verifier v14 (neu: T14). Die Probe aus Runde 14 ist entfernt.
   - Die Probe am iPhone (iOS 27, Safari und Web-App vom Home-Bildschirm, Passkey in „Passwörter"): beides legt einen
     Passkey an und ruft ihn mit Face ID ab (Flags UP UV BE BS, also synchronisiert). PRF kommt schon beim Anlegen und
     ist bei jedem Abruf gleich. Die Signatur ist mit dem Schlüssel aus `getPublicKey()` gültig. Ein Abruf 2 s nach
     dem Tipp zeigt Face ID trotzdem. Safari nennt beim Abruf auch `second`, ohne Wert. Ein doppelter Tipp startete
     zwei Abrufe, von denen einer nie antwortete.
   - Daraus: ein Face ID beim Einrichten; kein CBOR im Agenten, die Seite reicht `getPublicKey()` und
     `getAuthenticatorData()` weiter; die Seite nimmt keinen Tipp an, solange iOS fragt. Die Challenge kommt trotzdem
     mit `lock` voraus: das spart den Umlauf und hängt nicht daran, wie lange iOS einen Tipp gelten lässt.
   - Entscheidung Ablage (`FaceUnlock.swift`): eine Datei `face-unlock` neben dem Token, 0600. Sie hält Passkey-ID,
     öffentlichen Schlüssel, Origin, Salt und das Passwort, mit AES-GCM unter HKDF-SHA256 des PRF-Werts versiegelt.
     Ein Agent auf anderem Port hat eine eigene Datei, weil er unter anderem Origin erreicht wird.
   - Entscheidung Prüfung (`Passkey.swift`): Signatur über eine Challenge je Verbindung, die genau einmal gilt, dazu
     Typ, Origin, Hash des Hosts, UP und UV. Der PRF-Wert allein öffnete das Passwort auch, wäre aber aufgezeichnet
     wieder verwendbar; die Signatur macht jeden Versuch frisch. Das Origin wird beim Einrichten genommen, wie der
     Browser es nennt, und danach verlangt: der Agent kennt seinen Namen im Tailnet nur über `tailscale status`.
   - Entscheidung Einrichten: am Mac über das Menü. Das Fenster prüft das Passwort gegen das Verzeichnis
     (OpenDirectory), damit kein Tippfehler versiegelt wird, hält es bis zu zwei Minuten im Speicher und bietet in
     der Zeit jedem verbundenen Telefon „Face ID einrichten" an. Das erste, das antwortet, ist eingerichtet. Wer in
     der Zeit das Token hat, könnte seinen Passkey einrichten; er steuert dann ohnehin einen offenen Mac. Ein
     gesperrter Mac richtet nichts ein.
   - Entscheidung Fehlversuche: eine Antwort, die nicht zum Passkey passt, tippt nichts und bekommt eine neue
     Challenge; ein Limit braucht es dafür nicht, die Signatur lässt sich nicht raten. Lehnt der Mac das versiegelte
     Passwort zweimal in Folge ab, ist es nicht mehr sein Passwort: die Datei wird gelöscht, statt bei jedem Versuch
     ein falsches zu tippen. Ein Entsperren mit dem versiegelten Passwort setzt die Zählung zurück.
   - Entscheidung Seite: dieselbe Taste. Nennt `lock` einen Passkey, fragt „Entsperren…" das Telefon, statt das
     Feld zu öffnen; die Taste sagt „Face ID…", „Entsperre…", „Abgelehnt" oder „Nicht bereit". Nach Ablehnen oder
     Absage öffnet der nächste Tipp das Passwortfeld (die Tastatur kommt nur aus einem Tipp heraus); das Feld
     wegzulegen überlässt den Tipp danach wieder Face ID. Ein Mac, der nicht bereit war, wird gleich wieder mit
     Face ID gefragt.
   - Nach dem ersten Lauf am iPhone (Einrichten und Entsperren gingen) drei Wünsche des Nutzers:
     Das Angebot ist eine Karte über dem abgedunkelten Display statt einer einzelnen Taste: Zeichen, Titel, ein Satz
     mit dem Namen des Macs, „Nicht jetzt" und „Einrichten"; quer steht das Zeichen links neben dem Text. Sie sagt
     auch, wenn es nicht ging, und zeigt 2,5 s lang „Eingerichtet".
     Das Fenster am Mac zeigt je Schritt nur, was er braucht (Passwort, Warten, Eingerichtet), ist so hoch wie sein
     Inhalt und schließt sich 2,5 s nach dem Einrichten selbst.
     Die Sperrtaste ist das Schloss des Macs: offen, solange er offen ist, zu und gerastet (amber), solange er
     gesperrt ist. Auf einem gesperrten Mac entsperrt ein Tipp wie „Entsperren…". Sie wirkt deshalb wie die Tipptaste
     beim Abheben des Fingers, weil iOS nur dann die Tastatur öffnet und nach Face ID fragt.
   - Gemessen (T14, Chromiums virtueller Authenticator mit PRF als Passkey): die Karte liegt auf allen drei
     Telefonen hochkant und quer ganz im Display, ihre Tasten sind 44 px hoch; „Nicht jetzt" legt sie weg; ein
     abgelehnter Passkey zeigt „Nochmal" und sendet nichts; die Sperrtaste fragt gesperrt den Passkey (T14) und
     öffnet ohne Passkey das Passwortfeld (T10); ein Tipp sendet `enrol` für die Challenge des Angebots; gesperrt sendet ein Tipp `unlock` mit
     Signatur und PRF-Wert, ohne das Feld zu öffnen, die Signatur ist mit dem eingerichteten Schlüssel gültig; nach
     „Abgelehnt" öffnet der Tipp das Feld, danach fragt er wieder den Passkey mit der nächsten Challenge; ohne
     verifizierten Nutzer geht nichts hinaus. Passkey und Antwort aus einem solchen Lauf stehen als fester Vektor in
     `PasskeyTests`. `FaceUnlockServerTests` richtet über den Socket ein und entsperrt gegen einen Sperrbildschirm,
     den es nur im Test gibt.

16. Zeiger voraus, Bitrate nach der Strecke (nach „von außerhalb meines Netzwerks geisteskrank langsam, übelst hoher
    Ping“ und „im Code etwas ändern, ohne Server und ohne IPv6“). Gemessen am Mac des Nutzers: `tailscale ping` zum
    iPhone im Mobilfunk lief über `DERP(par)`, 30 Pings 84 bis 285 ms, dazu einer mit 590 und einer mit 1695 ms, „direct
    connection not established“. Der Mac hängt an einem 5G-Router (Carrier-NAT, `MappingVariesByDestIP: true`, kein
    IPv6), das Telefon ebenso: ohne Relay kommt keine direkte Verbindung zustande. Den Weg kürzt kein Code; was er kann,
    ist, weniger davon spüren zu lassen. Verifier v15 (neu: T15).
    - Ursache 1, Zeiger: jede Bewegung wartete den Hin- und Rückweg ab, weil die Seite den Zeiger erst dort zeichnete,
      wo eine Meldung des Macs ihn nannte, und eine Meldung ohne Bild stand hinter den Bildern in derselben Verbindung.
    - Entscheidung: die Seite zeichnet den Zeiger sofort, wohin die Bewegung ihn bringt (`Ahead` in `live-view.js`),
      und zählt die Bewegungen, die noch unterwegs sind, zu jedem Ort, den der Mac nennt: jede Meldung nennt die letzte
      Bewegung, die ihr Ort enthält. Dafür braucht die Seite den Ort des Zeigers am Mac und die Kanten, an denen der Mac
      ihn hält: der Kopf einer Meldung trägt jetzt Lage und Höhe des Ausschnitts (47 statt 35 Bytes), die Displays
      kommen aus der Meldung des Display-Wählers, die die Seite beim Verbinden einmal erfragt. Das Bild folgt einen
      Hin- und Rückweg später; ein Zeiger, der ihm davonläuft, wartet an dessen Rand.
    - Verworfen: den Ausschnitt mit vorauszurechnen (das Bild verschieben, bis das neue kommt). Das hieße, `viewport`
      und `fitted` auf der Seite ein zweites Mal zu halten, und der Rand bliebe leer. Verworfen: nur Grenzen des
      Ausschnitts im Kopf zu senden; ein Schreibtisch aus mehreren Displays ist kein Rechteck.
    - Dabei gefunden (vom Smoke-Test, 1 Punkt daneben mit Bewegungen unterwegs): der Mac führt Bruchteile eines Punkts
      selbst mit, auch die eines früheren Absenders, die Seite kannte den Rest nicht. Jetzt schickt die Seite ganze
      Punkte und behält den Rest (`touchpad.js`); eine Bewegung in ganzen Punkten macht der Mac so, wie sie ist.
      Und: Ort und Nummer der letzten Bewegung wurden getrennt gelesen; sie werden jetzt unter einer Sperre gesetzt
      und gelesen (`ScreenView.move`), sonst nennt eine Meldung eine Bewegung, die ihr Ort noch nicht hat. Das
      Zweite ließ sich im Smoke-Test nicht auslösen (drei Läufe ohne Sperre, alle grün): es ist nach Bauart behoben.
      Und: eine Bewegung gegen die Displaykante ließ den Zeiger stehen, also kam keine Meldung, und die Seite hätte
      sie zum nächsten Ort gezählt, den der Mac nennt. Jetzt nennt eine Meldung auch eine Bewegung, die nichts
      bewegt hat (Testmuster in Ruhe: nach 2 bis 7 ms genannt, ohne die Änderung erst nach 330 ms mit dem nächsten Bild).
    - Ursache 2, Bitrate (in Runde 6 als offen notiert): fest 4 Mbit/s. Auf einer Strecke, die weniger trägt, hielt das
      Sendefenster die Schlange bei gut 200 ms und die Bildrate bei einem Drittel. Der Encoder hält sich bei einem
      Schlüsselbild und bei einem Szenenwechsel nicht an die Bitrate (Seite Text, 780 × 1688: 317 KB bei 4 Mbit/s,
      205 KB bei 1 Mbit/s, auch mit `DataRateLimits`; mit `MinAllowedFrameQP` 42 noch 145 KB) und wirft danach Bilder
      weg, bis die Schuld bezahlt ist.
    - Entscheidung: `LinkRate` passt die Bitrate an, allein aus den Antworten des Telefons. Eine Schlange ist, wenn
      auch die promptste Antwort einer halben Sekunde belegter Strecke 60 ms später kommt als die schnellste bisher,
      die Antworten gleichmäßig kommen (eine Strecke am Anschlag gibt nie schneller ab, als sie trägt; eine, die Pakete
      nur zurückhielt, gibt sie auf einmal ab) und der Strom die Strecke auch füllt. Dann geht die Rate auf 85 % dessen,
      was die Strecke trug, höchstens auf die Hälfte je Schritt, und steigt wieder, solange der Strom sie nutzt: 1 % je
      halbe Sekunde nahe an dem, was die Strecke zuletzt trug, sonst 5 %. Bleiben die Antworten drei Intervalle unter
      dem Getragenen so spät, war es keine Schlange (längerer Weg, andere Zelle): die Antworten gelten dann, wie sie
      kommen. Jede dieser Regeln hat einen Test, der ohne sie fehlschlägt (16 Abwandlungen von `LinkRate`, je eine
      Regel entfernt).
    - Die erste Antwort hat nichts, woran sie spät wäre: sie gilt als spät, wenn sie länger als 300 ms brauchte. Danach
      lässt das Sendefenster die Strecke einmal leerlaufen, sonst mäße es die Schlange an der Zeit des Schlüsselbilds
      (gemessen: „fastest answer 2165 ms“, 24 Bilder unterwegs).
    - Größe: unter 0,75 Bit je Pixel und Sekunde geht das Bild auf drei Viertel oder die Hälfte seiner Breite, und
      erst mit dem 1,5-Fachen wieder hinauf. Grund ist das Schlüsselbild und jeder Szenenwechsel: sie kosten nach
      Pixeln, nicht nach Bitrate, auf 1 Mbit/s also Sekunden. Nur für H.264. Die Größe wird für jede neue Ansicht
      neu gewählt, nicht nur bei neuer Bitrate (im Review gefunden): mit offener Tastatur ist das Bild klein und geht
      bei derselben Bitrate ganz (gemessen bei 1 Mbit/s: 390 × 844 mit 0,75, 390 × 300 mit 1,0, zurück mit 0,75).
    - Schärfe in Ruhe: ein Bild in Bewegung bekommt die Bits eines Frames, und das letzte blieb so stehen, weil eine
      Aufnahme nichts liefert, solange sich nichts ändert. Jetzt wird ein Bild, dem 150 ms keines folgte, erneut
      kodiert, bis zwei Durchgänge in Folge unter 0,02 Bit je Pixel bleiben (höchstens 30). Gemessen mit einem Muster,
      das zwei Sekunden läuft und zwei ruht (`REMOTEY_TEST_PATTERN=rests`), PSNR gegen das letzte Bild der Ruhe:
      bei 1 Mbit/s 30,7 → 54,1 dB in 12 Durchgängen (2,0 s), ohne Grenze 32,8 → 65 dB in 8 (1,3 s, einmal etwa 240 KB).
      Auch bei 4 Mbit/s stand das Bild also vorher weicher, als es sein konnte.
    - Gemessen (`bench.mjs --still --seconds=30 --size=390x844 --fps=60`, Testmuster, vorher = ffcf2f0 (main),
      je ein Lauf; „zeigt“ = neue Bilder je 60-Hz-Takt des Telefons, „Alter“ = Alter des sichtbaren Bilds):

      | Strecke | zeigt/s vorher → nachher | Alter Median | Alter p90 | Mbit/s |
      |---|---|---|---|---|
      | 1 Mbit/s | 14,1 → 51,8 | 767 → 37 ms | 1250 → 104 ms | 1,02 → 0,94 |
      | 2 Mbit/s | 18,9 → 53,2 | 412 → 41 ms | 792 → 101 ms | 2,02 → 1,90 |
      | 3 Mbit/s | 19,9 → 49,8 | 378 → 43 ms | 452 → 77 ms | 2,94 → 2,79 |
      | Relay-Pings, mit 2 Mbit/s | 24,5 → 45,1 | 405 → 73 ms | 679 → 191 ms | 1,76 → 1,65 |
      | Relay-Pings ohne Grenze | 50,9 → 54,1 | 54 → 46 ms | 84 → 79 ms | 3,80 → 3,51 |
      | WLAN-Modell aus Runde 6 | 18,1 → 17,3 | 256 → 295 ms | 542 → 554 ms | 2,17 → 2,10 |
      | Antwort nach 30 ms | 60,1 → 60,1 gesendet | | | 4,02 → 4,03 |

      Die beiden Zeilen ohne Grenze und das WLAN-Modell sind die Gegenprobe: dort darf sich nichts ändern, und die
      Bitrate blieb im WLAN-Modell 41 von 41 Sekunden bei 4000 kbit/s. Bei den Relay-Pings ohne Grenze kostet der
      Stillstand der ersten Sekunde (1,7 s) einen Schritt auf die Hälfte, nach 8 s ist die Rate zurück. Anlauf auf
      1 Mbit/s: erstes Bild nach 1,24 s wie vorher (das Schlüsselbild), ab Sekunde 3 60 Bilder/s mit 27 ms Alter und
      zwei Schlüsselbilder insgesamt; vorher blieben es 21 Bilder/s mit 700 ms.
    - Das Relay-Modell (`--link=relay`) spielt die 30 gemessenen Pings in ihrer Reihenfolge ab, einen je Sekunde: was
      gesendet wird, während ein Ping unterwegs ist, kommt mit ihm an. Jeder Lauf hat so dieselbe Strecke.
    - Zeiger: T15 in Chromium (20 px Bewegung zeigt 40 Punkte weiter, bevor der falsche Mac antwortet; die Antwort
      lässt ihn stehen; ein Wisch über die Kante hält an ihr). Am echten Agenten prüft `smoke.mjs`, dass jede Meldung
      samt der Bewegungen, die sie noch nicht enthält, dorthin führt, wo der Zeiger landet: 120 Bewegungen, je Lauf
      7 bis 10 Meldungen (H.264) und 3 bis 5 (JPEG) mit Bewegungen unterwegs, dazu fünf Stöße gegen die Displaykante,
      auch im eingepassten Bild.
    - Nebenbei: `smoke.mjs` scheiterte mit einem Fenster vorn in einem von drei Läufen an „pictures still fitted“,
      auch auf main: ein Bild der vorigen Anfrage war noch unterwegs, als der Test zu zählen begann. Er zählt jetzt
      nur Bilder der neuesten Anfrage.

17. Zeiger voraus nur in Telefonform (nach dem Test am iPhone: mit Telefonform „nicht schlecht“, mit „Auto“ allein
    „wirklich horrible, es laggt noch mehr“). Ursache: in Telefonform steht das Bild, und der Zeiger bewegt sich darin;
    was die Seite vorauszeichnet, stimmt dann mit dem, was der Mac antwortet, überein. Folgt das Bild dem Zeiger (Zoom
    von Hand) oder schiebt der Zeiger es an den Rändern (Auto), läuft der vorausgezeichnete Zeiger dem Bild davon, bis
    an dessen Rand, und kommt zurück, wenn das Bild nachzieht: die Hand steuert gegen ein Bild, das einen Hin- und
    Rückweg alt ist, und der Zeiger wandert unter ihr.
    - Entscheidung: die Seite zeichnet den Zeiger nur voraus, solange Telefonform an ist (`LiveView.lead`, von
      `syncView` gesetzt) und das Bild auf ein Fenster eingepasst ist. Ohne Fenster vorn schneidet der Mac auch mit
      Telefonform um den Zeiger; dann wartet der Zeiger wie zuvor. Alles andere aus Runde 16 gilt in jedem Modus:
      Bitrate und Größe nach der Strecke, Schärfe in Ruhe, ganze Punkte, die Antwort auf eine Bewegung an der Kante.
    - Kein Schalter in der Oberfläche: der Modus entscheidet. Verifier v16: T15 prüft erst, dass der Zeiger ohne
      Telefonform auf den Mac wartet (17 Bewegungen gesendet, Zeiger unverändert), dann wie bisher mit Telefonform.

18. Einrichtungsassistent, das Modell ohne Oberfläche (Issue 2, Teil 1). Heute sind es etwa 15 Schritte von Hand und
    vier Befehle im Terminal, sechs davon scheitern still. Der Assistent ist eine Liste, die sich etwa einmal je Sekunde
    selbst prüft; jede Zeile hat genau einen Zustand und höchstens eine Taste. Diese Runde baut nur das Modell darunter,
    in neuen Dateien; Fenster, Menü und Einstellungen kommen danach darauf.
    - Entscheidung Form: drei Schichten. `Tailscale` (Werte aus dem Werkzeug) und `TailscaleCLI` (das Werkzeug, hinter
      dem Protokoll `TailscaleClient`), `Permissions` und `LoginItem`, und `Setup` (reine Logik: `Facts` hinein,
      `[Row]` heraus) mit `SetupAssistant` (sammelt die Fakten, führt die Tasten aus). Eine Zeile hat `state`
      (`ok`, `actionNeeded`, `working`, `failed`), in jedem Zustand einen Satz (`detail`) und höchstens eine `Action`
      mit eigenem Titel; `SetupAssistant.perform` führt sie aus, die Oberfläche muss keine kennen. Für das Menü gibt es
      `summary` (eine Zeile), für das Fenster `rows` und `changed`, für die Einstellungen `facts.tailscale`
      (Name, Besitzer, Version, Freigabe) und die Tasten `.removeServe` und `.setLoginItem`.
    - Entscheidung Pflicht: Bedienungshilfen, Tailscale, HTTPS und die Freigabe müssen grün sein; ist eine nicht grün,
      öffnet sich der Assistent beim Start von selbst (`launchCheck`), sonst nur beim ersten Start. Bildschirmaufnahme
      (nur fürs Live-Bild), Kopplung, erste Bewegung und Anmeldeobjekt sind es nicht: wer sie beim ersten Mal ließ,
      wird nicht bei jedem Start gefragt, und ob schon ein Telefon gekoppelt war, weiß nur der Server. Eine Zeile, die
      noch prüft (`working`), öffnet ihn nicht, sie kann einen Augenblick später grün sein.
    - Entscheidung Takt: der Assistent schaut nur, solange ihn jemand ansieht (`watch`/`unwatch` gezählt), dann jede
      Sekunde, mit einem Timer im Modus `.common`, damit er auch bei offenem Menü läuft. Tailscale wird nie doppelt
      gefragt; was sich währenddessen änderte, holt ein Blick danach nach. `changed` kommt nur, wenn sich etwas
      änderte, nicht jede Sekunde. Werkzeug und Abruf laufen im Hintergrund mit Zeitgrenze: lesen 5 s, ändern 20 s,
      warten auf eine Person (Zustimmung, Anmeldung) 600 s, Abruf 30 s. An der Grenze bekommt das Werkzeug `SIGTERM`,
      nach einer Sekunde `SIGKILL`; stdin ist leer, damit keine Frage es aufhält.
    - Tailscale: gesucht in `/opt/homebrew/bin`, `/usr/local/bin`, dann im Binary der App. Aus `status --json`:
      `BackendState`, `Version` (ab 1.52, da kam `serve --bg --set-path`), `Self.DNSName` ohne Punkt am Ende, der
      `LoginName` zu `Self.UserID`, `CertDomains` (leer: HTTPS im Tailnet aus) und `AuthURL`. Aus
      `serve status --json`: unsere Freigabe ist es, wenn auf Port 8443 `/` auf `127.0.0.1` oder `localhost` mit dem
      Port der Seite zeigt und `/ws` auf den danach; ein Port mit anderem Ziel heißt „zeigt auf …“ und wird beim
      Freigeben umgestellt. `AllowFunnel` für `…:8443` ist ein eigener, roter Zustand: die Fernbedienung wäre aus dem
      Internet erreichbar; seine Taste entfernt die Freigabe.
    - Freigeben führt dieselben zwei Befehle aus wie scripts/tailscale-serve.sh. Ist Serve im Tailnet noch nicht
      erlaubt, druckt das Werkzeug einen Link und wartet, bis jemand zustimmt; der Läufer reicht deshalb die Ausgabe
      weiter, während es läuft, und die Zeile bietet den Link, bis das Werkzeug von selbst fertig wird. Gelesen wird
      der Link nur aus ganzen Zeilen: der Test mit einem Link, der über zwei Stücke der Pipe kam, schlug zuerst fehl
      (`…/f/se`). Entfernen nimmt nur die beiden Pfade weg, damit anderes auf dem Port bleibt, und liest danach nach,
      ob sie weg sind, statt die Meldungen des Werkzeugs zu deuten. Anmelden (`login`) geht wie Freigeben über den
      gedruckten Link. Ein Homebrew-Dienst, der nicht läuft, braucht `sudo`: die Taste kopiert den Befehl.
    - Selbsttest: einmal je Name, sobald die Freigabe steht und kein Funnel an ist, wieder nach jedem Freigeben und auf
      Tastendruck, nicht jede Sekunde. Er holt `https://<Name>:8443/` und vergleicht den Inhalt mit der eigenen Seite,
      eine andere Seite oder 502 (Tailscale erreicht den Agenten nicht) ist rot.
    - Gemessen am Mac des Nutzers, nur lesend (Homebrew-tailscale 1.104.7, macOS 27): Form von `status --json` und
      `serve status --json` wie oben; die echte Ausgabe ergab „läuft, Name, Besitzer, Zertifikat, unsere Freigabe, kein
      Funnel“. Die Testdaten im Repo sind erfunden. Und: vom Mac an seinen eigenen Namen nimmt tailscaled die Verbindung
      an und schließt sie vor dem TLS-Handschlag (curl: „Connection reset by peer“, `URLSession`: -1200 mit
      Stream-Fehler -9816, `errSSLClosedNoNotify`; tailscaled schreibt „TLS handshake error … socket is not
      connected“), während das iPhone über dieselbe Adresse kommt (so in den Runden davor). Der Selbsttest kann am Mac
      also nicht gelingen. Dieser eine Fall heißt `inconclusive`: die Zeile ist grün und sagt, dass erst das iPhone
      zeigt, ob die Adresse antwortet. Ein Handschlag, der mit einer Meldung endet (ein Zertifikat, das Tailscale nicht
      bekommt), bleibt rot. Damit holt der Selbsttest hier auch kein Zertifikat vorab: der Handschlag kommt nie so weit
      (gefolgert aus dem Protokoll von tailscaled).
    - Bildschirmaufnahme: `CGPreflightScreenCaptureAccess` behält seine erste Antwort bis zum Neustart. Ohne die
      Erlaubnis lässt der Window Server die Titel der Fenster anderer Apps weg (`kCGWindowName`), mit ihr hat jedes
      einen, wenn auch leeren. Gemessen mit einem kleinen Programm auf macOS 27, einmal aus der Shell (Erlaubnis da:
      Preflight `true`, 14 von 14 fremden Fenstern mit Titel) und einmal als launchd-Job (keine Erlaubnis: `false`,
      1 von 14, und das eine gehört WindowManager, einem Systemprozess). Die Prüfung zählt deshalb nur Fenster regulärer
      Apps (`activationPolicy == .regular`): eines mit Titel heißt erlaubt, keines heißt nicht erlaubt, ohne ein
      solches Fenster gilt Preflight. In keinem Lauf kam eine Abfrage. Das Fragen ist eine eigene Taste:
      `CGRequestScreenCaptureAccess` beim ersten Druck (Dialog, und Remotey steht danach in der Liste), danach öffnet
      sie den Bereich in den Einstellungen; Bedienungshilfen ebenso mit `AXIsProcessTrustedWithOptions`.
    - Server.swift fragt vor dem Live-Bild weiter Preflight (diese Runde ändert keine bestehende Datei). Solange es so
      ist, sagt die Zeile bei einer Erlaubnis nach dem Start „Neustart nötig“ (`needsRestart`) mit der Taste
      „Remotey neu starten“. Fragt der Server `Permissions.screenRecording`, entfällt das.
    - Anmeldeobjekt: `SMAppService.mainApp` mit vier Zuständen; „braucht Erlaubnis“ öffnet die Anmeldeobjekte, und
      ohne Bundle (`swift run`) gibt es keines.
    - Tests: `SetupTests` (jede Zeile in jedem Zustand, Zusammenfassung, wann der Assistent aufgeht), `SetupAssistantTests`
      (Takt, Zustimmungslink, Selbsttest einmal, Fehler bis zum nächsten Versuch, mit Warteschlangen, die sofort
      laufen), `TailscaleTests` (aufgezeichnete Ausgaben, die Befehle des Skripts), `PermissionsTests`,
      `CommandTests` (gegen /bin/sh: Grenze, Ausgabe während des Laufs).

## Not verified

- No real iPhone. iOS Simulator 27.2 (Safari, portrait only: no Simulator GUI is installed, so no rotation, taps or
  keyboard) renders baseline and candidate portrait correctly. Landscape, keyboard, safe areas sideways, Home Screen
  mode and real touch are checked only in Chromium emulation.
- Live view at runtime: the development agent has no Screen Recording permission, so smoke and bench skipped the
  stream; header, preview and caret framing are covered by unit tests only. Caret bounds were read for real from an
  AppKit text view through `TextFocus`; other apps (Electron, browsers, terminals) report differently.
- Scroll phases are checked on the posted events, not in apps.
- Runde 6: Schublade und Schieber nur in Chromium mit Touch-Emulation und gegen einen Test-Agenten auf Port 47830
  (Seite, CSP, Speichern der Werte) geprüft, nicht auf einem iPhone. Ob iOS die neue Ausfahrt flüssig zeigt und ob
  die Schieber dort Berührungen annehmen, ist offen; ebenso, ob der alte Regler-Fehler auf iOS eine weitere Ursache
  hatte.
- Runde 6 Bildrate: kein Messwert vom iPhone. Die WLAN-Zahlen sind ein Modell aus 30 Pings an ein ruhendes Telefon;
  beim Streamen bleibt das Funkmodul wach und die Zeiten sind vermutlich kürzer. Am iPhone zeigt die Anzeige links oben
  die Verzögerung: lag sie vorher deutlich über 100 ms, war das Fenster die Grenze. Echte Bildschirmaufnahme nach den
  Änderungen nicht gemessen (Mac gesperrt, ScreenCaptureKit lieferte keine Displays); Smoke lief mit Testmuster.
- Runde 10: der Umschalter lief nur in Chromium mit Touch-Emulation, nicht auf einem iPhone: ob Safari die gedrückte
  Kachel zeigt und die Liste im Blatt flüssig scrollt, ist offen. Der Wechsel auf einen anderen Space und in ein
  Vollbild-Fenster wurde nicht ausgelöst (er hätte den Bildschirm des Nutzers umgeschaltet); er folgt aus dem
  dokumentierten Verhalten von `activate` und `openApplication`. Mehrere Displays: der Zeigersprung ist nur auf einem
  Display gemessen.
- Runde 11: das richtige Passwort hat der Agent nie getippt (nur ein falsches, derselbe Weg). Offen sind damit
  Zeichen, die im aktiven Layout keine Taste ohne Umschalten haben: sie gehen als Umschalt+Taste oder als
  Unicode-Text, und im Passwortfeld ist nur zu sehen, dass ein Zeichen ankommt, nicht welches. Kein iPhone: ob Safari
  das Feld beim Wechsel zum Passwortfeld richtig umstellt und das gespeicherte Passwort anbietet, ist offen. Nicht
  geprüft: Bildschirmschoner über der Sperre, Entsperren per Apple Watch, schneller Benutzerwechsel, ein Mac, dessen
  Display beim Wecken länger braucht als die 5 s, die der Agent auf das Feld wartet.
- Runde 12: kein iPhone. Auto lief am Mac nur über den Umschalter (ein Wechsel hin, einer zurück), nicht mit ⌘Tab
  oder einem Klick am Mac; beide lösen dieselbe Meldung von macOS aus. Das Warten auf ein ruhendes Fenster, der
  Sperrbildschirm unter Auto und „Folgt Text" im eingepassten Bild sind nur in Tests gerechnet, nicht gelaufen.
  `TextFocus` beobachtet die vordere App jetzt über `FrontApp`; „Folgt Text" wurde danach nicht am Mac geprüft.
  Displays an- und abstecken wurde nicht ausgelöst, nur die Liste und der Sprung. ⌘+ auf einer Belegung, auf der
  das Plus Umschalt braucht (US), ist ungeprüft; hier ist die Belegung deutsch.
- Runde 13: gemessen wurde Telefonform nur mit eigenen AppKit-Testfenstern. Die installierte App wurde danach am
  iPhone ausprobiert und für gut befunden, ohne Protokoll: wie einzelne Browser, Electron-Apps oder Terminals die neue
  Größe annehmen (Animation, Raster in Zeichenbreite, Seitenleisten mit Mindestbreite), ist nicht festgehalten. ⌘Tab selbst wurde nicht gedrückt; ein Testfenster, das sich selbst nach vorn holt, geht denselben Weg.
  Ob Safari auf iOS `visibilitychange` vor dem Einfrieren noch sendet, ist nicht geprüft; bleibt es aus, behält das
  Fenster die Form, bis der Socket schließt. Ein abgestürzter Agent lässt das Fenster in Telefonform.
- Runde 14: die Sperrtaste sperrte den Mac vom iPhone aus (vom Nutzer gemeldet, ohne Protokoll).
- Runde 15: Einrichten über das Menü und Entsperren mit Face ID gingen am iPhone und am echten Sperrbildschirm (vom
  Nutzer gemeldet, ohne Protokoll), mit der ersten Fassung von Taste und Fenster. Die Karte, das neue Fenster und
  die zweiseitige Sperrtaste liefen danach nur in Chromium und als gerenderte Bilder des Fensters, nicht am iPhone.
  Nicht versucht: ein abgelehntes versiegeltes Passwort am echten Mac, das Ende des Angebots nach zwei Minuten,
  Passkeys aus anderen Passwortmanagern (1Password).
- Runde 16: kein iPhone, keine echte Relay-Strecke. Die Bitrate ist gegen modellierte Strecken gemessen (Rate, die
  Relay-Pings, das WLAN-Modell), mit dem Testmuster statt echtem Bildschirminhalt; was DERP wirklich trägt und wie
  regelmäßig seine Antworten kommen, ist offen. Der Zeiger voraus lief in Chromium und gegen den echten Agenten am
  Mac, nicht in Safari. Die Sperre um Ort und Nummer einer Bewegung ließ sich ohne sie nicht zum Fehler bringen.
  Nicht gemessen: ein Mac mit mehreren Displays (die Kante zwischen zweien ist nur in Tests gerechnet), ein Telefon,
  das langsamer dekodiert, als die Strecke liefert (es sähe aus wie eine Schlange), und ein Weg zum Telefon von mehr
  als 300 ms von Anfang an (kostet einen Schritt auf die Hälfte, wie der Stillstand im Relay-Modell).
- Runde 17: nur in Chromium und in Tests. Ob „Auto“ allein am iPhone wieder so läuft wie vor Runde 16, ist dort nicht
  geprüft; der Zeiger nimmt denselben Weg wie vorher (der Ort aus der Meldung des Macs).
- Runde 18: am Mac des Nutzers wurde keine Erlaubnis umgeschaltet und nichts an Tailscale geändert. Dass die
  Prüfung über Fenstertitel einer Erlaubnis im laufenden Prozess ohne Neustart folgt, ist gefolgert (zwei Prozesse,
  einer mit, einer ohne Erlaubnis) und gelesen, nicht an einem Schalter gemessen; ebenso, dass Preflight seine erste
  Antwort behält. macOS 14 bis 26 nicht geprüft, auch nicht, dass `CGWindowListCopyWindowInfo` dort nie fragt.
  Die Links in die Einstellungen wurden nicht geöffnet. Freigeben, Entfernen, Anmelden und `up` liefen nie gegen das
  echte Werkzeug: Wortlaut und Warten nach dem Zustimmungslink stammen aus dem Gedächtnis an Tailscales Quelltext,
  geprüft nur an erfundenen Ausgaben; ob das Entfernen des letzten Pfads auch `AllowFunnel` löscht, ist offen (die
  Zeile bleibt rot, bis der nächste Blick es zeigt). Tailscale.app ist hier nicht installiert: der Pfad ihres
  Werkzeugs, seine Meldungen ohne laufende App und ob der Mac mit ihr seinen eigenen Namen erreicht, sind ungeprüft;
  der Weg `answered` des Selbsttests lief nie echt. Die Grenze 1.52 ist aus dem Gedächtnis.

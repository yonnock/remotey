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

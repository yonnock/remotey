// Every word the page shows or says to a screen reader, in German and English, picked by the phone's language.
// The markup names its words by key (`data-text`, `data-label`, `data-tip`); the modules ask `t(key, ...)`.
// A value is a string, or a function of what goes into it. Names and titles from the Mac never pass through
// here: they are set as text where they are shown.

const de = {
  'lang': 'de',
  'decimal': ',',
  'pad': 'Trackpad',

  // Connection: a short state for the chip on the display, and a notice with its likely cause and one action.
  'status.connecting': 'Verbinde…',
  'status.connected': 'Verbunden',
  'status.unreachable': 'Nicht verbunden',
  'status.stopped': 'Nicht verbunden',
  'status.noAccess': 'Kein Zugriff',
  'status.denied': 'Nicht gekoppelt',
  'status.offline': 'Offline',
  'status.unpaired': 'Nicht gekoppelt',
  'notice.unreachable.title': 'Mac nicht erreichbar',
  'notice.unreachable.text': 'Ist Tailscale auf diesem iPhone verbunden und der Mac wach? Remotey versucht es weiter.',
  'notice.stopped.title': 'Remotey läuft nicht',
  'notice.stopped.text': 'Der Mac ist erreichbar, aber Remotey antwortet dort nicht. Remotey am Mac öffnen, dann verbindet sich das iPhone von selbst.',
  'notice.noAccess.title': 'Steuern nicht erlaubt',
  'notice.noAccess.text': 'Am Mac fehlt die Freigabe für Remotey unter Systemeinstellungen › Datenschutz & Sicherheit › Bedienungshilfen.',
  'notice.denied.title': 'Kopplung ungültig',
  'notice.denied.text': 'Der Schlüssel dieses iPhones gilt am Mac nicht mehr, etwa weil er dort erneuert wurde. Neu koppeln.',
  'notice.offline.title': 'iPhone offline',
  'notice.offline.text': 'Dieses iPhone ist mit keinem Netz verbunden. Remotey verbindet sich, sobald es wieder online ist.',
  'notice.retry': 'Erneut versuchen',
  'notice.recheck': 'Erneut prüfen',
  'notice.howto': 'So geht’s',
  'notice.permission.title': 'Live-Bild nicht erlaubt',
  'notice.permission.text': 'Am Mac fehlt die Freigabe „Bildschirmaufnahme“ für Remotey. Dort erlauben und Remotey neu starten.',
  'notice.taken.title': 'Live-Bild auf einem anderen Gerät',
  'notice.taken.text': 'Ein anderes Gerät zeigt jetzt das Live-Bild. Das Trackpad steuert weiter.',
  'notice.takeBack': 'Hierher holen',

  // The first start, without a key. A step is a list item; more steps or another way to pair go here.
  'welcome.title': 'Mit dem Mac verbinden',
  'welcome.text': 'Remotey steuert deinen Mac über dein Tailnet.',
  'welcome.steps': ['Remotey am Mac öffnen', 'Im Menü „iPhone koppeln (QR‑Code)…“ wählen', 'Den Code mit der Kamera dieses iPhones scannen'],
  'welcome.note': 'Beide Geräte brauchen Tailscale mit demselben Konto.',
  'welcome.back': 'Zurück',

  // The display's glass.
  'meter.idle': 'Live-Bild: noch keine Messung',
  'meter.label': (fps, ms) => `Live-Bild: ${fps} Bilder pro Sekunde${ms === null ? '' : `, ${ms} Millisekunden Verzögerung`}`,
  'follow': 'Folgt Text',
  'follow.label': 'Das Live-Bild folgt dem Text, den du schreibst',
  'zoom.group': 'Zoom des Live-Bilds',
  'zoom.out': 'Verkleinern',
  'zoom.in': 'Vergrößern',
  'zoom.label': (zoom, fit, shape) => `Zoom ${zoom}. Fenster einpassen ${!fit ? 'aus' : shape ? 'an, angepasst an das iPhone' : 'an'}`,

  // Face ID.
  'enrol.title': 'Mit Face ID entsperren',
  'enrol.offer': (mac) => `Dieses iPhone entsperrt dann „${mac}“. Den Passkey dafür in „Passwörter“ sichern.`,
  'enrol.failed': 'Das hat nicht geklappt. Den Passkey bitte in „Passwörter“ sichern.',
  'enrol.done': 'Eingerichtet',
  'enrol.doneText': 'Ist der Mac gesperrt, fragt „Mit Face ID entsperren“ jetzt nach Face ID.',
  'enrol.later': 'Nicht jetzt',
  'enrol.go': 'Einrichten',
  'enrol.busy': 'Richte ein…',
  'enrol.again': 'Erneut versuchen',

  // The tray.
  'pages': 'Steuerung',
  'page.media': 'Medien',
  'page.keys': 'Tasten',
  'page.settings': 'Einstellungen',
  'media.prev': 'Vorheriger Titel',
  'media.play': 'Wiedergabe oder Pause',
  'media.next': 'Nächster Titel',
  'media.mute': 'Ton aus',
  'media.volume': 'Lautstärke',
  'media.up': 'Lauter',
  'media.down': 'Leiser',
  'lock.lock': 'Mac sperren',
  'lock.unlock': 'Mac entsperren',
  'key.escape': 'esc',
  'key.tab': 'tab',
  'key.space': 'Leertaste',
  'key.backspace': 'Löschen',
  'key.return': 'Zeilenschalter',
  'key.zoomOut': 'App verkleinern, Befehl Minus',
  'key.zoomReset': 'App in Originalgröße, Befehl 0',
  'key.zoomIn': 'App vergrößern, Befehl Plus',
  'key.cmd': 'Befehl',
  'key.alt': 'Wahl',
  'key.ctrl': 'Control',
  'key.shift': 'Umschalt',
  'key.left': 'Pfeil nach links',
  'key.down': 'Pfeil nach unten',
  'key.up': 'Pfeil nach oben',
  'key.right': 'Pfeil nach rechts',
  'setting.speed': 'Zeigertempo',
  'setting.acceleration': 'Beschleunigung',
  'setting.accelerationLabel': 'Beschleunigung: schnelle Bewegungen reichen weiter',
  'setting.scroll': 'Scrolltempo',
  'setting.off': 'aus',
  'setting.reset': 'Zurücksetzen',
  'setting.resetLabel': 'Zeigertempo, Beschleunigung und Scrolltempo zurücksetzen',
  'setting.meter': 'Messwerte',
  'setting.meterLabel': 'Bildrate und Verzögerung zeigen',

  // The switcher.
  'apps.sheet': 'Apps am Mac',
  'apps.back': 'Zurück zu allen Apps',
  'apps.title': 'Offene Apps',
  'apps.shape': 'An iPhone anpassen',
  'apps.shapeLabel': 'An iPhone anpassen: das vordere Fenster nimmt am Mac die Form des iPhones an',
  'apps.waiting': 'Die Apps erscheinen, sobald der Mac verbunden ist.',
  'apps.choice': (n) => `${n} Fenster zur Auswahl`,
  'apps.front': 'im Vordergrund',
  'apps.hidden': 'ausgeblendet',
  'apps.windows': (n) => `${n} Fenster`,
  'apps.minimized': 'Minimiert',
  'displays': 'Displays des Macs',
  'display.label': (name, here) => `Display ${name}${here ? ', mit dem Zeiger' : ''}`,

  // The dock.
  'mouse.side': 'Seitentasten der Maus',
  'mouse.back': 'Zurück',
  'mouse.forward': 'Vorwärts',
  'mouse.left': 'Klick',
  'mouse.leftLabel': 'Klick, halten zum Ziehen',
  'mouse.right': 'Rechtsklick',
  'type': 'Auf dem Mac schreiben',
  'type.short': 'Schreiben',
  'type.label': 'Auf dem Mac schreiben: Tastatur öffnen',
  'apps': 'Apps',
  'apps.key': 'Apps und Fenster am Mac',
  'deck.key': 'Steuerung: Medien, Tasten und Einstellungen',
  'view': 'Live-Bild',

  // Typing, and the password of a locked Mac.
  'typebar': 'Sondertasten',
  'field': 'Text an den Mac senden',
  'done': 'Fertig',
  'unlock.face': 'Mit Face ID entsperren',
  'unlock.faceShort': 'Face ID',
  'unlock.plain': 'Mac entsperren',
  'unlock.plainShort': 'Entsperren',
  'unlock.asking': 'Face ID…',
  'unlock.busy': 'Entsperre…',
  'unlock.refused': 'Abgelehnt',
  'unlock.unready': 'Nicht bereit',
  'unlock.field': 'Passwort zum Entsperren des Macs',
  'unlock.hint': 'Passwort des Macs',
  'unlock.offline': 'Keine Verbindung zum Mac',
  'unlock.again': 'Nicht entsperrt, nochmal?',
  'unlock.notReady': 'Mac nicht bereit, nochmal?',
};

const en = {
  'lang': 'en',
  'decimal': '.',
  'pad': 'Trackpad',

  'status.connecting': 'Connecting…',
  'status.connected': 'Connected',
  'status.unreachable': 'Not connected',
  'status.stopped': 'Not connected',
  'status.noAccess': 'No access',
  'status.denied': 'Not paired',
  'status.offline': 'Offline',
  'status.unpaired': 'Not paired',
  'notice.unreachable.title': 'Can’t reach the Mac',
  'notice.unreachable.text': 'Is Tailscale connected on this iPhone, and is the Mac awake? Remotey keeps trying.',
  'notice.stopped.title': 'Remotey isn’t running',
  'notice.stopped.text': 'The Mac can be reached, but Remotey doesn’t answer there. Open Remotey on the Mac and this iPhone connects by itself.',
  'notice.noAccess.title': 'Control not allowed',
  'notice.noAccess.text': 'Allow Remotey on the Mac in System Settings › Privacy & Security › Accessibility.',
  'notice.denied.title': 'Pairing no longer valid',
  'notice.denied.text': 'The Mac no longer accepts this iPhone’s key, for example because it was renewed there. Pair again.',
  'notice.offline.title': 'iPhone is offline',
  'notice.offline.text': 'This iPhone isn’t connected to a network. Remotey connects as soon as it’s back online.',
  'notice.retry': 'Try Again',
  'notice.recheck': 'Check Again',
  'notice.howto': 'How to Pair',
  'notice.permission.title': 'Live view not allowed',
  'notice.permission.text': 'Remotey needs Screen Recording permission on the Mac. Allow it there and restart Remotey.',
  'notice.taken.title': 'Live view on another device',
  'notice.taken.text': 'Another device is showing the live view now. The trackpad still works.',
  'notice.takeBack': 'Show It Here',

  'welcome.title': 'Connect to Your Mac',
  'welcome.text': 'Remotey controls your Mac through your tailnet.',
  'welcome.steps': ['Open Remotey on the Mac', 'Choose “iPhone koppeln (QR‑Code)…” in its menu', 'Scan the code with this iPhone’s camera'],
  'welcome.note': 'Both devices need Tailscale with the same account.',
  'welcome.back': 'Back',

  'meter.idle': 'Live view: nothing measured yet',
  'meter.label': (fps, ms) => `Live view: ${fps} frames per second${ms === null ? '' : `, ${ms} milliseconds delay`}`,
  'follow': 'Follows text',
  'follow.label': 'The live view follows the text you type',
  'zoom.group': 'Live view zoom',
  'zoom.out': 'Zoom out',
  'zoom.in': 'Zoom in',
  'zoom.label': (zoom, fit, shape) => `Zoom ${zoom}. Fit window ${!fit ? 'off' : shape ? 'on, fitted to iPhone' : 'on'}`,

  'enrol.title': 'Unlock with Face ID',
  'enrol.offer': (mac) => `This iPhone will then unlock “${mac}”. Save the passkey for it in Passwords.`,
  'enrol.failed': 'That didn’t work. Please save the passkey in Passwords.',
  'enrol.done': 'Set Up',
  'enrol.doneText': 'When the Mac is locked, “Unlock with Face ID” now asks for Face ID.',
  'enrol.later': 'Not Now',
  'enrol.go': 'Set Up',
  'enrol.busy': 'Setting up…',
  'enrol.again': 'Try Again',

  'pages': 'Controls',
  'page.media': 'Media',
  'page.keys': 'Keys',
  'page.settings': 'Settings',
  'media.prev': 'Previous track',
  'media.play': 'Play or pause',
  'media.next': 'Next track',
  'media.mute': 'Mute',
  'media.volume': 'Volume',
  'media.up': 'Louder',
  'media.down': 'Quieter',
  'lock.lock': 'Lock Mac',
  'lock.unlock': 'Unlock Mac',
  'key.escape': 'esc',
  'key.tab': 'tab',
  'key.space': 'Space',
  'key.backspace': 'Delete',
  'key.return': 'Return',
  'key.zoomOut': 'Zoom app out, Command Minus',
  'key.zoomReset': 'App at actual size, Command 0',
  'key.zoomIn': 'Zoom app in, Command Plus',
  'key.cmd': 'Command',
  'key.alt': 'Option',
  'key.ctrl': 'Control',
  'key.shift': 'Shift',
  'key.left': 'Left arrow',
  'key.down': 'Down arrow',
  'key.up': 'Up arrow',
  'key.right': 'Right arrow',
  'setting.speed': 'Pointer speed',
  'setting.acceleration': 'Acceleration',
  'setting.accelerationLabel': 'Acceleration: fast moves reach further',
  'setting.scroll': 'Scroll speed',
  'setting.off': 'off',
  'setting.reset': 'Reset',
  'setting.resetLabel': 'Reset pointer speed, acceleration and scroll speed',
  'setting.meter': 'Stats',
  'setting.meterLabel': 'Show frame rate and delay',

  'apps.sheet': 'Apps on the Mac',
  'apps.back': 'Back to all apps',
  'apps.title': 'Open Apps',
  'apps.shape': 'Fit to iPhone',
  'apps.shapeLabel': 'Fit to iPhone: the front window on the Mac takes the iPhone’s shape',
  'apps.waiting': 'The apps appear once the Mac is connected.',
  'apps.choice': (n) => `${n} windows to choose from`,
  'apps.front': 'in front',
  'apps.hidden': 'hidden',
  'apps.windows': (n) => `${n} windows`,
  'apps.minimized': 'Minimized',
  'displays': 'The Mac’s displays',
  'display.label': (name, here) => `Display ${name}${here ? ', has the pointer' : ''}`,

  'mouse.side': 'Mouse side buttons',
  'mouse.back': 'Back',
  'mouse.forward': 'Forward',
  'mouse.left': 'Click',
  'mouse.leftLabel': 'Click, hold to drag',
  'mouse.right': 'Right-click',
  'type': 'Type on the Mac',
  'type.short': 'Type',
  'type.label': 'Type on the Mac: open the keyboard',
  'apps': 'Apps',
  'apps.key': 'Apps and windows on the Mac',
  'deck.key': 'Controls: media, keys and settings',
  'view': 'Live view',

  'typebar': 'Special keys',
  'field': 'Send text to the Mac',
  'done': 'Done',
  'unlock.face': 'Unlock with Face ID',
  'unlock.faceShort': 'Face ID',
  'unlock.plain': 'Unlock Mac',
  'unlock.plainShort': 'Unlock',
  'unlock.asking': 'Face ID…',
  'unlock.busy': 'Unlocking…',
  'unlock.refused': 'Refused',
  'unlock.unready': 'Not ready',
  'unlock.field': 'Password to unlock the Mac',
  'unlock.hint': 'The Mac’s password',
  'unlock.offline': 'Not connected to the Mac',
  'unlock.again': 'Still locked. Try again?',
  'unlock.notReady': 'Mac not ready. Try again?',
};

export const TABLES = { de, en };

/** The first of the phone's languages the page speaks; English for every other. */
export function pick(languages) {
  for (const tag of languages ?? []) {
    const lang = String(tag).toLowerCase().split('-')[0];
    if (lang in TABLES) return lang;
  }
  return 'en';
}

let table = TABLES[pick(globalThis.navigator?.languages ?? [globalThis.navigator?.language])];

/** For tests: speak `lang` from now on. */
export function speak(lang) { table = TABLES[lang]; }

/** The words for `key`, filled with `args` where the entry takes them. */
export function t(key, ...args) {
  const value = table[key] ?? TABLES.en[key];
  if (value === undefined) throw new Error(`no words for ${key}`);
  return typeof value === 'function' ? value(...args) : value;
}

/** A number as the language writes it: 0,5 or 0.5. */
export const number = (n) => String(n).replace('.', t('decimal'));

/** Writes the words into every element under `root` that names a key: its text, its label and its title. */
export function localize(root = document) {
  document.documentElement.lang = t('lang');
  for (const el of root.querySelectorAll('[data-text]')) el.textContent = t(el.dataset.text);
  for (const el of root.querySelectorAll('[data-label]')) el.setAttribute('aria-label', t(el.dataset.label));
}

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { TABLES, number, pick, speak, t } from '../Web/strings.js';

test('the phone\'s first language the page speaks wins; any other gets English', () => {
  assert.equal(pick(['de-DE', 'en-US']), 'de');
  assert.equal(pick(['de-CH']), 'de');
  assert.equal(pick(['fr-FR', 'de-AT']), 'de');
  assert.equal(pick(['en-GB', 'de-DE']), 'en');
  assert.equal(pick(['fr-FR']), 'en');
  assert.equal(pick([]), 'en');
  assert.equal(pick(undefined), 'en');
});

test('both languages have the same words, of the same kind', () => {
  const de = TABLES.de, en = TABLES.en;
  assert.deepEqual(Object.keys(de).sort(), Object.keys(en).sort());
  for (const key of Object.keys(de)) {
    assert.equal(typeof de[key], typeof en[key], key);
    if (Array.isArray(de[key])) assert.equal(de[key].length, en[key].length, key);
  }
});

test('every key the markup names is in the table', () => {
  const html = readFileSync(new URL('../Web/index.html', import.meta.url), 'utf8');
  const keys = [...html.matchAll(/data-(?:text|label)="([^"]+)"/g)].map((m) => m[1]);
  assert.ok(keys.length > 60);
  for (const key of keys) assert.ok(key in TABLES.de, key);
});

test('every key the modules ask for is in the table', () => {
  const modules = ['remote.js', 'apps.js', 'displays.js', 'touchpad.js']
    .map((name) => readFileSync(new URL(`../Web/${name}`, import.meta.url), 'utf8')).join('\n');
  const keys = [...modules.matchAll(/\bt\('([^']+)'/g)].map((m) => m[1]);
  assert.ok(keys.length > 30);
  for (const key of keys) assert.ok(key in TABLES.de, key);
  // Keys put together at run time: the states of the connection and the notices.
  for (const state of ['connecting', 'connected', 'unreachable', 'stopped', 'noAccess', 'denied', 'offline', 'unpaired']) assert.ok(`status.${state}` in TABLES.de, state);
  for (const kind of ['unreachable', 'stopped', 'noAccess', 'denied', 'offline', 'permission', 'taken']) {
    assert.ok(`notice.${kind}.title` in TABLES.de && `notice.${kind}.text` in TABLES.de, kind);
  }
});

test('no German is left in markup or script outside the table', () => {
  const html = readFileSync(new URL('../Web/index.html', import.meta.url), 'utf8').replace(/<!--[\s\S]*?-->/g, '');
  // Text between tags, apart from signs on keys.
  const words = [...html.matchAll(/>([^<]+)</g)].map((m) => m[1].trim()).filter((w) => /[a-zäöüß]{3}/i.test(w));
  assert.deepEqual(words, ['Remotey', 'fps'], 'only the title, and a unit that is the same in every language');
  assert.doesNotMatch(html, /aria-label="/, 'every label comes from the table');
});

test('words with numbers in them, in both languages', () => {
  speak('de');
  assert.equal(t('apps.choice', 3), '3 Fenster zur Auswahl');
  assert.equal(number(0.25), '0,25');
  assert.equal(t('zoom.label', '0,5×', true, false), 'Zoom 0,5×. Fenster einpassen an');
  speak('en');
  assert.equal(t('apps.choice', 3), '3 windows to choose from');
  assert.equal(number(0.25), '0.25');
  assert.equal(t('zoom.label', '0.5×', false, false), 'Zoom 0.5×. Fit window off');
  assert.equal(t('welcome.steps').length, 3);
  speak('de');
});

test('the new names stand in the table', () => {
  speak('de');
  assert.deepEqual(['mouse.left', 'mouse.right', 'type', 'view', 'apps.shape', 'page.settings', 'setting.speed', 'setting.acceleration',
    'setting.scroll', 'setting.reset', 'unlock.face', 'pages'].map((k) => t(k)),
  ['Klick', 'Rechtsklick', 'Auf dem Mac schreiben', 'Live-Bild', 'An iPhone anpassen', 'Einstellungen', 'Zeigertempo', 'Beschleunigung',
    'Scrolltempo', 'Zurücksetzen', 'Mit Face ID entsperren', 'Steuerung']);
});

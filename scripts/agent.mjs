// What the scripts need to talk to a running agent on this Mac.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

export const HTTP = 'http://127.0.0.1:47800', WS = 'ws://127.0.0.1:47801/ws';
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const fail = (msg) => { console.error('FAIL', msg); process.exit(1); };
/** The agent writes the pairing token when it first starts. */
export const token = (() => {
  try { return readFileSync(`${homedir()}/Library/Application Support/Remotey/token`, 'utf8').trim(); }
  catch { return fail('no pairing token: start Remotey once'); }
})();

/** The Mac's pointer in AppKit coordinates (origin bottom left, y up). */
export const pointer = () => execFileSync('osascript', ['-l', 'JavaScript', '-e',
  'ObjC.import("AppKit"); const p = $.NSEvent.mouseLocation; p.x + " " + p.y'], { encoding: 'utf8' }).trim().split(' ').map(Number);

/**
 * Opens a socket and sends `first`. `reply` resolves with the first answer, or null once the socket closed
 * without one. Every later message goes to `onMessage` of the returned connection, as the socket's event.
 */
export function open(first) {
  const ws = new WebSocket(WS);
  ws.binaryType = 'arraybuffer';
  let answer;
  const closed = new Promise((r) => { ws.onclose = () => r(null); });
  const reply = new Promise((r) => { answer = r; });
  const connection = { closed, reply: Promise.race([reply, closed]), onMessage: null,
    send: (msg) => ws.send(JSON.stringify(msg)), close: () => ws.close() };
  ws.onmessage = (e) => {
    if (answer) { answer(JSON.parse(e.data)); answer = null; } else connection.onMessage?.(e);
  };
  ws.onopen = () => connection.send(first);
  ws.onerror = () => {}; // a refused connection also closes the socket
  return connection;
}

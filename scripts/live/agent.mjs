// What the scripts need to talk to a running agent on this Mac. Import `guard.mjs` before this module.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

/** REMOTEY_PORT names the agent to talk to, as it does for the agent itself; the socket is on the port after it. */
const port = /^\d+$/.test(process.env.REMOTEY_PORT ?? '') ? Number(process.env.REMOTEY_PORT) : 0;
export const PORT = port > 0 && port < 65535 ? port : 47800; // as Server.swift reads it
export const HTTP = `http://127.0.0.1:${PORT}`, WS = `ws://127.0.0.1:${PORT + 1}/ws`;
/** How often the scripts say they are alive, as the page does while it is visible. */
export const PING_MS = 5000;
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const fail = (msg) => { console.error('FAIL', msg); process.exit(1); };
/**
 * The old shared token, which the agent writes when it first starts. The scripts still use it: a paired device
 * needs the Mac's pairing window, which no script may open. Each agent keeps its own devices file and switch
 * (`devices-<port>`), so a development agent on another port takes the token until someone switches it off
 * there, whatever the installed one does; switched off, the agent answers `denied` with `why: "token"`.
 */
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
  let answer, heartbeat;
  const closed = new Promise((r) => { ws.onclose = () => { clearInterval(heartbeat); r(null); }; });
  const reply = new Promise((r) => { answer = r; });
  const connection = { closed, reply: Promise.race([reply, closed]), onMessage: null,
    send: (msg) => ws.send(JSON.stringify(msg)), close: () => ws.close() };
  ws.onmessage = (e) => {
    if (answer) {
      const hello = JSON.parse(e.data);
      // Only for the real token: smoke.mjs sends a wrong one on purpose.
      if (hello.t === 'denied' && hello.why === 'token' && first?.token === token) {
        console.error(`the agent on ${PORT} does not take the token (switched off, or another token): run a development agent with REMOTEY_PORT`);
      }
      answer(hello);
      answer = null;
      // As the page does: the agent drops a phone that is silent for 15 s. Its answers stay here.
      heartbeat = setInterval(() => { if (ws.readyState === WebSocket.OPEN) connection.send({ t: 'ping' }); }, PING_MS);
    } else if (typeof e.data !== 'string' || JSON.parse(e.data).t !== 'pong') connection.onMessage?.(e);
  };
  ws.onopen = () => connection.send(first);
  ws.onerror = () => {}; // a refused connection also closes the socket
  return connection;
}

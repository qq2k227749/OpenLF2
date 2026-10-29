// SPDX-License-Identifier: MIT
//
// Runs the JavaScript halves of the EM_JS functions in src/adapters/web/transport.cpp (read from
// the source file) against the real online.js and the relay, with a byte array standing in for
// WebAssembly memory. Together with the C++ harness this covers the whole chain the browser build
// uses: game scripts -> C++ transport -> EM_JS glue -> online.js -> WebSocket -> relay.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {
  OnlineTransport, transportPath, startRelay, peer, until, startRoom, playFrames,
} = require('./helpers.js');

// EM_JS(ret, name, (params), { body }) -> { name: { params, body } }
function extractEmJs(source) {
  const functions = {};
  const pattern = /EM_JS\(\s*[^,]+,\s*(\w+)\s*,\s*\(([^)]*)\)\s*,\s*\{/g;
  let match;
  while ((match = pattern.exec(source))) {
    const open = pattern.lastIndex - 1;
    let depth = 0;
    let close = -1;
    for (let index = open; index < source.length && close < 0; index += 1) {
      const character = source[index];
      if (character === '"') {
        for (index += 1; source[index] !== '"'; index += 1) if (source[index] === '\\') index += 1;
      } else if (character === '{') depth += 1;
      else if (character === '}' && --depth === 0) close = index;
    }
    const params = match[2].split(',').map((part) => part.trim()).filter(Boolean)
      .map((part) => part.match(/(\w+)$/)[1]); // Emscripten keeps the parameter names only
    functions[match[1]] = { params, body: source.slice(open, close + 1).replace(/\/\/[^\n]*/g, '') };
  }
  return functions;
}

// One browser page: its own globalThis.OpenLF2Online and its own WebAssembly memory.
function page(functions, online) {
  const HEAPU8 = new Uint8Array(1 << 16);
  let top = 16;
  const alloc = (size) => {
    if (top + size > HEAPU8.length) top = 16;
    const pointer = top;
    top += size;
    return pointer;
  };
  const runtime = {
    globalThis: { OpenLF2Online: online },
    HEAPU8,
    UTF8ToString: (pointer) => {
      let end = pointer;
      while (HEAPU8[end]) end += 1;
      return Buffer.from(HEAPU8.subarray(pointer, end)).toString('utf8');
    },
    lengthBytesUTF8: (text) => Buffer.byteLength(text, 'utf8'),
    stringToUTF8: (text, pointer, capacity) => {
      const bytes = Buffer.from(text, 'utf8').subarray(0, capacity - 1);
      HEAPU8.set(bytes, pointer);
      HEAPU8[pointer + bytes.length] = 0;
      return bytes.length;
    },
  };
  const glue = {};
  for (const [name, { params, body }] of Object.entries(functions)) {
    glue[name] = new Function(...Object.keys(runtime), `return function ${name}(${params.join(', ')}) ${body}`)(
      ...Object.values(runtime));
  }
  // The C++ BrowserTransport's calls into the glue, in the same order and with the same limits.
  const error = (fallback) => {
    const length = glue.online_error_length_js();
    if (length <= 0) return fallback;
    const pointer = alloc(length + 1);
    glue.online_error_copy_js(pointer, length + 1);
    return Buffer.from(HEAPU8.subarray(pointer, pointer + length)).toString('utf8');
  };
  const cString = (text) => {
    const bytes = Buffer.from(text + '\0', 'utf8');
    const pointer = alloc(bytes.length);
    HEAPU8.set(bytes, pointer);
    return pointer;
  };
  const status = () => ['idle', 'listening', 'connecting', 'connected'][glue.online_status_js()] || 'idle';
  const start = (host, address) => {
    const started = glue.online_start_js(host ? 1 : 0, cString(address));
    if (started < 0) return 'Network play needs online.js on the game page';
    if (started === 0) return error('Network could not start');
    return null;
  };
  return {
    glue,
    engine: {
      host: () => start(true, ''),
      join: (address) => start(false, address),
      send: (bytes) => {
        if (status() !== 'connected') return 'Network peer is not connected';
        if (bytes.length > 65536) return 'Network send queue exceeds 64 KiB';
        const pointer = alloc(bytes.length);
        HEAPU8.set(bytes, pointer);
        return glue.online_send_js(pointer, bytes.length) === 1 ? null : error('Network send failed');
      },
      poll: () => {
        const available = glue.online_available_js();
        if (available < 0) {
          const message = error('Network peer disconnected');
          glue.online_close_js();
          return { error: message };
        }
        if (available === 0) return { bytes: Buffer.alloc(0) };
        const size = Math.min(available, 8192);
        const pointer = alloc(size);
        const taken = glue.online_take_js(pointer, size);
        return { bytes: Buffer.from(HEAPU8.slice(pointer, pointer + taken)) };
      },
      status,
      close: () => glue.online_close_js(),
    },
  };
}

const functions = extractEmJs(fs.readFileSync(transportPath, 'utf8'));

test('transport.cpp declares the expected EM_JS functions', () => {
  assert.deepEqual(Object.keys(functions).sort(), [
    'online_available_js', 'online_close_js', 'online_error_copy_js', 'online_error_length_js',
    'online_send_js', 'online_start_js', 'online_status_js', 'online_take_js',
  ]);
});

test('a match runs through the EM_JS glue exactly as through online.js', async () => {
  const relay = await startRelay();
  try {
    const make = (room, names) => {
      const online = new OnlineTransport({ relay: relay.url, room, WebSocket: globalThis.WebSocket });
      const browser = page(functions, online);
      return peer(relay.url, room, names, { online, makeEngine: () => browser.engine });
    };
    const host = make('777001', ['Davis', '', '', '']);
    const guest = make('777001', ['Woody', '', '', '']);
    await startRoom([host, guest]);
    assert.ok(host.network.sharedRandom.equals(guest.network.sharedRandom));
    const hostLog = [];
    const guestLog = [];
    await Promise.all([playFrames(host, 120, hostLog), playFrames(guest, 120, guestLog)]);
    const strip = (log) => log.map(({ time, ...frame }) => frame);
    assert.deepEqual(strip(hostLog), strip(guestLog));

    guest.online.close(); // the friend closes the tab
    await until(() => (host.network.poll(), host.network.left.length > 0));
    assert.deepEqual(host.network.left, [1]);
    host.online.close();
    const outcome = host.network.engine.poll();
    assert.deepEqual(outcome, { bytes: Buffer.alloc(0) }, 'closing by choice is no error');
  } finally { await relay.close(); }
});

test('errors cross the glue with their text, and a page without online.js is reported', () => {
  const online = new OnlineTransport({ relay: 'wss://relay.example.com/relay', WebSocket: globalThis.WebSocket });
  const browser = page(functions, online);
  assert.equal(browser.engine.join('10.0.0.2'), 'Network: type the room code, not an IP address');
  assert.equal(browser.engine.send(Buffer.from([1])), 'Network peer is not connected');

  const empty = page(functions, undefined);
  assert.equal(empty.engine.host(), 'Network play needs online.js on the game page');
  assert.equal(empty.glue.online_available_js(), -1);
  assert.equal(empty.glue.online_status_js(), 0);
  empty.glue.online_close_js(); // must not throw
});

// SPDX-License-Identifier: MIT
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { WebSocket } = require('ws');
const { createRelay, CLOSE } = require('../server.js');

async function startRelay(overrides = {}) {
  const relay = createRelay({ quiet: true, port: 0, host: '127.0.0.1', ...overrides });
  const address = await relay.listen(0, '127.0.0.1');
  relay.url = `ws://127.0.0.1:${address.port}${relay.config.path}`;
  relay.http = `http://127.0.0.1:${address.port}`;
  return relay;
}

// A test client that records control messages, binary data and the close event.
function client(url, options = {}) {
  const ws = new WebSocket(url, options);
  const state = { ws, controls: [], binary: [], waiters: [] };
  const notify = () => { for (const waiter of state.waiters.splice(0)) waiter(); };
  ws.on('message', (data, isBinary) => {
    if (isBinary) state.binary.push(Buffer.from(data));
    else state.controls.push(JSON.parse(data.toString()));
    notify();
  });
  state.closed = new Promise((resolve) => ws.on('close', (code, reason) => {
    state.closeInfo = { code, reason: reason.toString() };
    notify();
    resolve(state.closeInfo);
  }));
  state.opened = new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  state.until = async (predicate, timeout = 3000) => {
    const deadline = Date.now() + timeout;
    while (!predicate()) {
      if (Date.now() > deadline) throw new Error('timed out waiting for condition');
      await new Promise((resolve) => { state.waiters.push(resolve); setTimeout(resolve, 50); });
    }
  };
  state.control = async (type) => {
    await state.until(() => state.controls.some((message) => message.t === type));
    return state.controls.find((message) => message.t === type);
  };
  state.bytes = () => Buffer.concat(state.binary);
  return state;
}

const room = () => String(100000 + crypto.randomInt(900000));

test('health endpoint answers', async () => {
  const relay = await startRelay();
  try {
    const response = await fetch(`${relay.http}/healthz`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true, rooms: 0, clients: 0, installer: false, protocols: [1, 2], players: 8, packs: false });
  } finally { await relay.close(); }
});

test('host then guest are paired and bytes flow both ways unchanged and in order', async () => {
  // This burst is far above the game's ~30 packets per second, so the rate limits are off here.
  const relay = await startRelay({ messagesPerSecond: 0, bytesPerSecond: 0 });
  const code = room();
  try {
    const host = client(`${relay.url}?role=host&room=${code}`);
    assert.equal((await host.control('waiting')).room, code);
    const guest = client(`${relay.url}?role=join&room=${code}`);
    await Promise.all([host.control('paired'), guest.control('paired')]);

    // Many small packets plus a few large ones, as the game's handshake and lockstep frames.
    const sentByHost = [];
    const sentByGuest = [];
    for (let index = 0; index < 600; index += 1) {
      const size = index % 100 === 0 ? 3078 : 22;
      const a = crypto.randomBytes(size);
      const b = crypto.randomBytes(size);
      sentByHost.push(a);
      sentByGuest.push(b);
      host.ws.send(a);
      guest.ws.send(b);
    }
    const expectedAtGuest = Buffer.concat(sentByHost);
    const expectedAtHost = Buffer.concat(sentByGuest);
    await guest.until(() => guest.bytes().length >= expectedAtGuest.length);
    await host.until(() => host.bytes().length >= expectedAtHost.length);
    assert.ok(guest.bytes().equals(expectedAtGuest));
    assert.ok(host.bytes().equals(expectedAtHost));
    host.ws.close();
    guest.ws.close();
  } finally { await relay.close(); }
});

test('game-like traffic, even at fast-forward pace, stays within the default limits', async () => {
  const relay = await startRelay();
  const code = room();
  try {
    const host = client(`${relay.url}?role=host&room=${code}`);
    const guest = client(`${relay.url}?role=join&room=${code}`);
    await Promise.all([host.control('paired'), guest.control('paired')]);
    // Handshake sizes of OpenLF2's protocol: profile 78, greeting 14, names 77, names + random table 3078.
    host.ws.send(crypto.randomBytes(78));
    guest.ws.send(crypto.randomBytes(78));
    host.ws.send(crypto.randomBytes(14));
    guest.ws.send(crypto.randomBytes(77));
    host.ws.send(crypto.randomBytes(3078));
    // Then one 22-byte packet per frame each way at 3x the normal 33 ms pace, for two seconds.
    for (let frame = 0; frame < 180; frame += 1) {
      host.ws.send(crypto.randomBytes(22));
      guest.ws.send(crypto.randomBytes(22));
      await new Promise((resolve) => setTimeout(resolve, 11));
    }
    await guest.until(() => guest.bytes().length === 78 + 14 + 3078 + 180 * 22);
    await host.until(() => host.bytes().length === 78 + 77 + 180 * 22);
    assert.equal(host.closeInfo, undefined);
    assert.equal(guest.closeInfo, undefined);
    host.ws.close();
  } finally { await relay.close(); }
});

test('guest may arrive before the host', async () => {
  const relay = await startRelay();
  const code = room();
  try {
    const guest = client(`${relay.url}?role=join&room=${code}`);
    await guest.control('waiting');
    const host = client(`${relay.url}?role=host&room=${code}`);
    await Promise.all([host.control('paired'), guest.control('paired')]);
    host.ws.send(Buffer.from('u can connect\0'));
    await guest.until(() => guest.bytes().length === 14);
    assert.equal(guest.bytes().toString(), 'u can connect\0');
    host.ws.close();
  } finally { await relay.close(); }
});

test('a second host for the same room is refused', async () => {
  const relay = await startRelay();
  const code = room();
  try {
    const first = client(`${relay.url}?role=host&room=${code}`);
    await first.control('waiting');
    const second = client(`${relay.url}?role=host&room=${code}`);
    const info = await second.closed;
    assert.equal(info.code, CLOSE.hostTaken[0]);
    assert.equal(info.reason, CLOSE.hostTaken[1]);
    first.ws.close();
  } finally { await relay.close(); }
});

test('malformed requests are closed with a reason', async () => {
  const relay = await startRelay();
  try {
    for (const query of ['?role=host&room=12', '?role=spectator&room=123456', '?role=join&room=12ab56', '']) {
      const bad = client(`${relay.url}${query}`);
      const info = await bad.closed;
      assert.equal(info.code, CLOSE.badRequest[0], query);
    }
  } finally { await relay.close(); }
});

test('when one player leaves the other is told, and the room code is free again', async () => {
  const relay = await startRelay();
  const code = room();
  try {
    const host = client(`${relay.url}?role=host&room=${code}`);
    const guest = client(`${relay.url}?role=join&room=${code}`);
    await Promise.all([host.control('paired'), guest.control('paired')]);
    guest.ws.close();
    const info = await host.closed;
    assert.equal(info.code, CLOSE.peerLeft[0]);
    assert.equal(info.reason, CLOSE.peerLeft[1]);
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(relay.rooms.size, 0);
    const again = client(`${relay.url}?role=host&room=${code}`);
    await again.control('waiting');
    again.ws.close();
  } finally { await relay.close(); }
});

test('data sent before pairing is refused', async () => {
  const relay = await startRelay();
  try {
    const host = client(`${relay.url}?role=host&room=${room()}`);
    await host.control('waiting');
    host.ws.send(Buffer.from([1, 2, 3]));
    assert.equal((await host.closed).code, CLOSE.earlyData[0]);
  } finally { await relay.close(); }
});

test('text frames from clients are not forwarded', async () => {
  const relay = await startRelay();
  const code = room();
  try {
    const host = client(`${relay.url}?role=host&room=${code}`);
    const guest = client(`${relay.url}?role=join&room=${code}`);
    await Promise.all([host.control('paired'), guest.control('paired')]);
    host.ws.send('{"t":"paired"}');
    host.ws.send(Buffer.from([7]));
    await guest.until(() => guest.bytes().length === 1);
    assert.equal(guest.controls.length, 1);
    host.ws.close();
  } finally { await relay.close(); }
});

test('a waiting player is released after the wait limit', async () => {
  const relay = await startRelay({ roomWaitMs: 150 });
  try {
    const host = client(`${relay.url}?role=host&room=${room()}`);
    assert.equal((await host.closed).code, CLOSE.timeout[0]);
  } finally { await relay.close(); }
});

test('flooding closes both players', async () => {
  const relay = await startRelay({ messagesPerSecond: 10 });
  const code = room();
  try {
    const host = client(`${relay.url}?role=host&room=${code}`);
    const guest = client(`${relay.url}?role=join&room=${code}`);
    await Promise.all([host.control('paired'), guest.control('paired')]);
    for (let index = 0; index < 100; index += 1) host.ws.send(Buffer.from([index]));
    assert.equal((await host.closed).code, CLOSE.rateLimited[0]);
    assert.equal((await guest.closed).code, CLOSE.rateLimited[0]);
  } finally { await relay.close(); }
});

test('origin allow-list', async () => {
  const relay = await startRelay({ allowedOrigins: ['https://friends.example'] });
  try {
    const denied = client(`${relay.url}?role=host&room=${room()}`, { origin: 'https://other.example' });
    assert.equal((await denied.closed).code, CLOSE.originDenied[0]);
    const allowed = client(`${relay.url}?role=host&room=${room()}`, { origin: 'https://friends.example' });
    await allowed.control('waiting');
    allowed.ws.close();
  } finally { await relay.close(); }
});

test('the installer copy is served for the game page, with CORS and a download limit', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-relay-'));
  const file = path.join(dir, 'lf2-installer.data');
  const bytes = crypto.randomBytes(300000);
  fs.writeFileSync(file, bytes);
  const relay = await startRelay({ installerFile: file, installerDownloadsPerHour: 3 });
  try {
    const health = await (await fetch(`${relay.http}/healthz`)).json();
    assert.equal(health.installer, true);

    const head = await fetch(`${relay.http}/lf2-installer.data`, { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.equal(head.headers.get('content-length'), String(bytes.length));
    assert.equal(head.headers.get('access-control-allow-origin'), '*');

    const response = await fetch(`${relay.http}/lf2-installer.data`, { headers: { origin: 'https://friend.github.io' } });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'application/octet-stream');
    assert.equal(response.headers.get('content-disposition'), null, 'nothing that makes it look like a download');
    assert.ok(Buffer.from(await response.arrayBuffer()).equals(bytes));

    // Three downloads per hour in this test: two more pass, the next is refused.
    for (let index = 0; index < 2; index += 1) assert.equal((await fetch(`${relay.http}/lf2-installer.data`)).status, 200);
    const refused = await fetch(`${relay.http}/lf2-installer.data`);
    assert.equal(refused.status, 429);
    assert.ok(Number(refused.headers.get('retry-after')) > 0);
    assert.equal((await fetch(`${relay.http}/lf2-installer.data`, { method: 'POST' })).status, 405);
  } finally {
    await relay.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the installer copy honours the origin allow-list and is absent when not configured', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-relay-'));
  const file = path.join(dir, 'lf2-installer.data');
  fs.writeFileSync(file, 'data');
  const relay = await startRelay({ installerFile: file, allowedOrigins: ['https://friends.github.io'] });
  const bare = await startRelay();
  try {
    const allowed = await fetch(`${relay.http}/lf2-installer.data`, { headers: { origin: 'https://friends.github.io' } });
    assert.equal(allowed.headers.get('access-control-allow-origin'), 'https://friends.github.io');
    const other = await fetch(`${relay.http}/lf2-installer.data`, { headers: { origin: 'https://other.example' } });
    assert.equal(other.headers.get('access-control-allow-origin'), null, 'a browser on another site cannot read it');
    assert.equal((await fetch(`${bare.http}/lf2-installer.data`)).status, 404);
    assert.equal((await (await fetch(`${bare.http}/healthz`)).json()).installer, false);
  } finally {
    await relay.close();
    await bare.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('behind a proxy, the address the proxy added counts, not one the client made up', async () => {
  const relay = await startRelay({ trustProxy: true, maxConnectionsPerIp: 1 });
  try {
    // A client claims other addresses; the proxy (Apache) appends the real one, which stays the same.
    const first = client(`${relay.url}?role=host&room=${room()}`, { headers: { 'x-forwarded-for': '10.0.0.1, 198.51.100.7' } });
    await first.control('waiting');
    const spoofed = client(`${relay.url}?role=host&room=${room()}`, { headers: { 'x-forwarded-for': '10.0.0.2, 198.51.100.7' } });
    assert.equal((await spoofed.closed).code, CLOSE.tooManyConnections[0]);
    const other = client(`${relay.url}?role=host&room=${room()}`, { headers: { 'x-forwarded-for': '198.51.100.8' } });
    await other.control('waiting');
    first.ws.close();
    other.ws.close();
  } finally { await relay.close(); }
});

test('connections per address are limited', async () => {
  const relay = await startRelay({ maxConnectionsPerIp: 2 });
  try {
    const a = client(`${relay.url}?role=host&room=${room()}`);
    const b = client(`${relay.url}?role=host&room=${room()}`);
    await Promise.all([a.control('waiting'), b.control('waiting')]);
    const c = client(`${relay.url}?role=host&room=${room()}`);
    assert.equal((await c.closed).code, CLOSE.tooManyConnections[0]);
    a.ws.close();
    await a.closed;
    await new Promise((resolve) => setTimeout(resolve, 50));
    const d = client(`${relay.url}?role=host&room=${room()}`);
    await d.control('waiting');
    b.ws.close();
    d.ws.close();
  } finally { await relay.close(); }
});

// SPDX-License-Identifier: MIT
//
// End-to-end check of the browser side (dist/web/online.js) through the relay, driven the way
// OpenLF2 drives a network transport: the C++ adapter's poll/send/status semantics and a room
// client speaking protocol 2 (scripts/base/game/room.lua; room-game.test.js runs the script itself).
// Uses Node's built-in WebSocket client, the same API browsers have.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  OnlineTransport, STATUS, startRelay, engineNetwork, peer, until, startRoom, playFrames,
} = require('./helpers.js');

test('browsers meet in a room, start together and receive the same frames', async (t) => {
  const relay = await startRelay();
  try {
    const host = peer(relay.url, '482913', ['Alice', 'Bob', 'Carol', 'Dan']);
    const guest = peer(relay.url, '999999', ['Linh', 'Minh', 'Nam', 'Quan']);
    const third = peer(relay.url, '482913', ['Tuan', '', '', '']);
    assert.equal(host.network.start(true, '0.0.0.0'), true);
    assert.equal(host.online.status(), STATUS.listening);
    await until(() => host.network.poll() === false && host.network.players.length === 1);
    assert.equal(host.online.status(), STATUS.connected);
    // A friend types the host's room code into the address field; another opened the invite link.
    assert.equal(guest.network.start(false, '482913'), true);
    assert.equal(guest.online.status(), STATUS.connecting);
    assert.equal(third.network.start(false, ''), true);
    await until(() => {
      for (const side of [host, guest, third]) side.network.poll();
      return host.network.players.length === 3;
    });
    assert.deepEqual(host.network.players.map((player) => player.info.split('\0')[0]), ['Alice', 'Linh', 'Tuan']);
    assert.deepEqual([host.online.players, host.online.started], [3, false]);
    host.network.begin();
    await until(() => [host, guest, third].every((side) => side.network.poll() === true));
    assert.ok(guest.network.sharedRandom.equals(host.network.randomTable), 'everyone has the host\'s random table');
    assert.ok(third.network.sharedRandom.equals(host.network.randomTable));
    assert.deepEqual([guest.network.index, third.network.index], [1, 2]);

    const logs = [[], [], []];
    const started = Date.now();
    await Promise.all([host, guest, third].map((side, index) => playFrames(side, 150, logs[index])));
    t.diagnostic(`150 frames in ${Date.now() - started} ms`);
    const strip = (log) => log.map(({ time, ...frame }) => frame);
    assert.deepEqual(strip(logs[1]), strip(logs[0]), 'identical frames');
    assert.deepEqual(strip(logs[2]), strip(logs[0]), 'identical frames');
    assert.deepEqual(logs[0].map((frame) => frame.number), [...Array(150).keys()]);

    // A friend leaves: the others are told and play on.
    guest.network.engine.close();
    await until(() => (host.network.poll(), host.network.left.length > 0));
    assert.deepEqual(host.network.left, [1]);
    assert.equal(host.online.status(), STATUS.connected);
    assert.equal(host.online.players, 2);
  } finally { await relay.close(); }
});

// The relay keeps the beat: the frame rate never depends on how far the other players are.
test('frame rate with a distant friend', async (t) => {
  const relay = await startRelay();
  try {
    const { WebSocket } = require('ws');
    const distant = (oneWay) => class extends WebSocket {
      send(data) { setTimeout(() => { if (this.readyState === 1) super.send(data); }, oneWay); }
    };
    for (const oneWay of [0, 50, 150]) {
      const host = peer(relay.url, String(246810 + oneWay), ['A', '', '', '']);
      const guest = peer(relay.url, String(246810 + oneWay), ['B', '', '', ''], { WebSocket: distant(oneWay) });
      await startRoom([host, guest]);
      const log = [];
      await Promise.all([playFrames(host, 60, log), playFrames(guest, 60, [])]);
      const fps = ((log.length - 1) * 1000) / (log.at(-1).time - log[0].time);
      t.diagnostic(`friend ${oneWay} ms away -> ${fps.toFixed(1)} frames per second for the host`);
      assert.ok(fps > 28 && fps < 32, `${fps} frames per second`);
      host.online.close();
      guest.online.close();
    }
  } finally { await relay.close(); }
});

test('problems the player can fix are reported before anything is sent', () => {
  const online = new OnlineTransport({ relay: 'ws://127.0.0.1:9/relay', room: '123456', WebSocket: globalThis.WebSocket });
  assert.equal(online.start(false, '192.168.1.20'), false);
  assert.equal(online.error(), 'Network: type the room code, not an IP address');
  assert.equal(online.start(false, '12'), false);
  assert.equal(online.error(), 'Network: type the room code (4-12 digits)');
  assert.equal(online.send(new Uint8Array([1])), false);
  assert.equal(online.error(), 'Network: type the room code (4-12 digits)'); // the earlier failure stays first
  online.close();
  assert.equal(online.send(new Uint8Array([1])), false);
  assert.equal(online.error(), 'Network peer is not connected');

  const noRelay = new OnlineTransport({ room: '123456', WebSocket: globalThis.WebSocket });
  assert.equal(noRelay.start(true), false);
  assert.equal(noRelay.error(), 'Network: set the relay address above the game');

  const insecure = new OnlineTransport({ relay: 'ws://relay.example.com/relay', room: '123456', pageProtocol: 'https:', WebSocket: globalThis.WebSocket });
  assert.equal(insecure.start(true), false);
  assert.equal(insecure.error(), 'Network: this https page needs a wss:// relay address');

  const noRoom = new OnlineTransport({ relay: 'wss://relay.example.com/relay', WebSocket: globalThis.WebSocket });
  assert.equal(noRoom.start(true), false);
  assert.equal(noRoom.error(), 'Network: set a room code (4-12 digits) above the game');
});

test('relay addresses are accepted the way people paste them', () => {
  const online = new OnlineTransport({ WebSocket: globalThis.WebSocket });
  const cases = [
    ['wss://203-0-113-5.sslip.io/relay', 'wss://203-0-113-5.sslip.io/relay'],
    ['  https://203-0-113-5.sslip.io  ', 'wss://203-0-113-5.sslip.io'],
    ['HTTPS://relay.example.com/relay', 'wss://relay.example.com/relay'],
    ['http://192.168.1.10:8787/relay', 'ws://192.168.1.10:8787/relay'],
    ['203-0-113-5.sslip.io', 'wss://203-0-113-5.sslip.io'],
    ['ws://localhost:8787/relay', 'ws://localhost:8787/relay'],
    ['', ''],
  ];
  for (const [typed, expected] of cases) {
    online.setRelay(typed);
    assert.equal(online.relay, expected, typed);
  }
});

test('an https relay address pasted into the panel reaches the relay', async () => {
  const relay = await startRelay();
  try {
    const port = new URL(relay.url).port;
    // The relay serves WebSockets on "/" too, so an address without /relay works.
    const host = peer(`http://127.0.0.1:${port}`, '555123', ['A', '', '', '']);
    const guest = peer(`http://127.0.0.1:${port}/relay`, '555123', ['B', '', '', '']);
    assert.equal(host.online.relay, `ws://127.0.0.1:${port}`);
    await startRoom([host, guest]);
    host.online.close();
    guest.online.close();
  } finally { await relay.close(); }
});

test('a relay that only pairs two players is reported as too old', async () => {
  const { WebSocketServer } = require('ws');
  const server = new WebSocketServer({ port: 0, host: '127.0.0.1' });
  await new Promise((resolve) => server.once('listening', resolve));
  server.on('connection', (ws) => ws.send(JSON.stringify({ t: 'waiting', room: '123456' })));
  try {
    const online = new OnlineTransport({ relay: `ws://127.0.0.1:${server.address().port}/relay`, room: '123456', WebSocket: globalThis.WebSocket });
    const engine = engineNetwork(online);
    assert.equal(engine.host(), null);
    const result = await until(() => {
      const polled = engine.poll();
      return polled.error ? polled : null;
    });
    assert.equal(result.error, 'Relay: this relay is too old for this game page; update it (install-vps.sh)');
  } finally { await new Promise((resolve) => server.close(resolve)); }
});

test('an unreachable relay is reported through poll', async () => {
  const online = new OnlineTransport({ relay: 'ws://127.0.0.1:9/relay', room: '123456', WebSocket: globalThis.WebSocket });
  const engine = engineNetwork(online);
  assert.equal(engine.host(), null);
  const result = await until(() => {
    const polled = engine.poll();
    return polled.error ? polled : null;
  });
  assert.equal(result.error, 'Network: cannot reach the relay');
  assert.equal(online.status(), STATUS.idle);
});

test('received bytes are handed out in order across chunk boundaries and capacity limits', () => {
  const online = new OnlineTransport({});
  const socket = {};
  online.socket = socket;
  online.state = STATUS.connected;
  const parts = [Buffer.from([1, 2, 3]), Buffer.from([4]), Buffer.from([5, 6, 7, 8, 9])];
  for (const part of parts) online.onMessage(socket, { data: part.buffer.slice(part.byteOffset, part.byteOffset + part.length) });
  assert.equal(online.available(), 9);
  assert.deepEqual([...online.take(2)], [1, 2]);
  assert.deepEqual([...online.take(3)], [3, 4, 5]);
  online.onClose(socket, { code: 4013, reason: '' });
  assert.equal(online.available(), 4, 'bytes that arrived before the close are still delivered');
  assert.deepEqual([...online.take(100)], [6, 7, 8, 9]);
  assert.equal(online.available(), -1);
  assert.equal(online.error(), 'Relay: the host left the room');
});

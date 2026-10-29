// SPDX-License-Identifier: MIT
//
// Shared by the end-to-end tests: a relay on a free port, what the web build's C++ transport does
// with online.js, and a small room client speaking protocol 2 over it the way the game does
// (scripts/base/game/room.lua; room-game.test.js runs that script itself).
'use strict';

const crypto = require('node:crypto');
const path = require('node:path');
const { createRelay, KIND, packet } = require('../server.js');

// tools/relay/test -> the repository root
const repository = path.join(__dirname, '..', '..', '..');
const onlinePath = process.env.OPENLF2_ONLINE_JS || path.join(repository, 'dist', 'web', 'online.js');
const transportPath = process.env.OPENLF2_TRANSPORT_CPP
  || path.join(repository, 'src', 'adapters', 'web', 'transport.cpp');
const { OnlineTransport, STATUS } = require(onlinePath);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function startRelay(overrides = {}) {
  const relay = createRelay({ quiet: true, ...overrides });
  const address = await relay.listen(0, '127.0.0.1');
  relay.url = `ws://127.0.0.1:${address.port}/relay`;
  return relay;
}

// What src/adapters/web/transport.cpp does with online.js, as seen by the Lua scripts.
function engineNetwork(online) {
  return {
    host: () => (online.start(true, '0.0.0.0') ? null : online.error()),
    join: (address) => (online.start(false, address) ? null : online.error()),
    send: (bytes) => (online.send(bytes) ? null : online.error()),
    poll: () => {
      const available = online.available();
      if (available < 0) {
        const message = online.error();
        online.close();
        return { error: message };
      }
      return { bytes: Buffer.from(online.take(Math.min(available, 8192))) };
    },
    status: () => ['idle', 'listening', 'connecting', 'connected'][online.status()],
    close: () => online.close(),
  };
}

// The player list of LOBBY and STARTED.
function readPlayers(payload, at = 0) {
  const players = [];
  let offset = at + 1;
  for (let index = 0; index < payload[at]; index += 1) {
    const length = payload[offset + 2];
    players.push({ id: payload[offset], host: payload[offset + 1] === 1, info: payload.subarray(offset + 3, offset + 3 + length).toString('latin1') });
    offset += 3 + length;
  }
  return { players, at: offset };
}

function readFrame(payload) {
  const frame = { number: payload.readUInt32LE(0), fresh: payload[5], present: payload[6], inputs: [] };
  for (let index = 0, at = 7; index < payload[4]; index += 1) {
    frame.inputs.push(payload.subarray(at + 1, at + 1 + payload[at]).toString('hex'));
    at += 1 + payload[at];
  }
  return frame;
}

// A game in a room, reduced to what the transport carries: hello, lobby, start, inputs and frames.
class RoomClient {
  constructor(engine, { names, randomTable, profile = `OpenLF2 Room 1\n${'a'.repeat(64)}\n7\n48879` }) {
    this.engine = engine;
    this.names = names;
    this.randomTable = randomTable;
    this.profile = Buffer.from(profile, 'latin1');
    this.phase = 'idle';
  }
  failed(message) {
    this.engine.close();
    this.phase = 'failed';
    this.error = message;
    return { error: message };
  }
  send(kind, payload = Buffer.alloc(0)) {
    const problem = this.engine.send(packet(kind, Buffer.from(payload)));
    if (problem) { this.failed(problem); return false; }
    return true;
  }
  start(host, address) {
    this.engine.close();
    Object.assign(this, { host, error: undefined, received: Buffer.alloc(0), players: [], frames: [], left: [] });
    const problem = host ? this.engine.host() : this.engine.join(address);
    if (problem) return this.failed(problem);
    this.phase = 'connecting';
    return true;
  }
  handle(kind, payload) {
    if (kind === KIND.welcome) {
      this.id = payload[0];
      this.code = payload.subarray(5).toString('latin1');
    } else if (kind === KIND.lobby) {
      this.players = readPlayers(payload).players;
    } else if (kind === KIND.started) {
      const { players, at } = readPlayers(payload);
      this.players = players;
      this.index = players.findIndex((player) => player.id === this.id);
      this.sharedRandom = Buffer.from(payload.subarray(at + 2));
      this.phase = 'ready';
      this.send(KIND.ready);
    } else if (kind === KIND.frame) {
      this.frames.push(readFrame(payload));
    } else if (kind === KIND.left) {
      this.left.push(payload[0]);
    }
  }
  // Like room.poll: true once the game started, false while waiting, or { error }.
  poll() {
    if (this.phase === 'failed') return { error: this.error };
    const result = this.engine.poll();
    if (result.error) return this.failed(result.error);
    this.received = Buffer.concat([this.received, result.bytes]);
    while (this.received.length >= 3 && this.received.length >= 3 + this.received.readUInt16LE(1)) {
      const length = this.received.readUInt16LE(1);
      this.handle(this.received[0], Buffer.from(this.received.subarray(3, 3 + length)));
      this.received = this.received.subarray(3 + length);
      if (this.phase === 'failed') return { error: this.error };
    }
    if (this.phase === 'connecting' && this.engine.status() === 'connected') {
      const hello = Buffer.concat([Buffer.from([this.profile.length]), this.profile, Buffer.from(this.names.join('\0'), 'latin1')]);
      if (!this.send(KIND.hello, hello)) return { error: this.error };
      this.phase = 'lobby';
    }
    return this.phase === 'ready';
  }
  begin() { return this.send(KIND.start, this.randomTable); }
  // One tick of a started game: sends the input when it changed (or every 25 ms, as the game
  // does) and returns the next frame, or null.
  exchange(input) {
    const ready = this.poll();
    if (ready && ready.error) return ready;
    if (!ready) return null;
    const now = performance.now();
    if (input && (!this.sent || !input.equals(this.sent) || now - this.sentAt >= 25)) {
      if (!this.send(KIND.input, input)) return { error: this.error };
      this.sent = input;
      this.sentAt = now;
    }
    return this.frames.shift() || null;
  }
}

// One player: an online.js instance (one per browser page) and a room client over it.
// `makeEngine` turns the online.js instance into what the scripts call (engine.network).
function peer(relayUrl, room, names, { makeEngine = engineNetwork, online, WebSocket = globalThis.WebSocket } = {}) {
  const transport = online || new OnlineTransport({ relay: relayUrl, room, WebSocket });
  const random = crypto.randomBytes(3000).map((value) => value || 1); // the table never holds a 0 byte
  const network = new RoomClient(makeEngine(transport), { names, randomTable: Buffer.from(random) });
  return { online: transport, network };
}

async function until(fn, timeout = 10000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const result = fn();
    if (result) return result;
    if (Date.now() > deadline) throw new Error('timed out');
    await sleep(1); // as emscripten_sleep(1) in the game loop: lets socket events in
  }
}

// Host and guests in one room, started by the host; resolves when every game runs.
async function startRoom(players) {
  const [host, ...guests] = players;
  if (host.network.start(true, '0.0.0.0') !== true) throw new Error(host.network.error);
  await until(() => host.network.poll() === false && host.network.players.length === 1);
  for (const guest of guests) {
    if (guest.network.start(false, '') !== true) throw new Error(guest.network.error);
  }
  await until(() => {
    for (const side of players) {
      const result = side.network.poll();
      if (result && result.error) throw new Error(result.error);
    }
    return host.network.players.length === players.length;
  });
  host.network.begin();
  await until(() => players.every((side) => {
    const result = side.network.poll();
    if (result && result.error) throw new Error(result.error);
    return result === true;
  }));
}

// An input as the game sends it: events, function keys, then one byte per slot of the computer.
function randomInput() {
  return Buffer.from([crypto.randomInt(4), crypto.randomInt(256), crypto.randomInt(2), crypto.randomInt(128) * 2, crypto.randomInt(128) * 2]);
}

// Runs a game for `frames` frames, its keys changing every 100 ms or so; the frames go to `log`.
async function playFrames(side, frames, log) {
  let input = randomInput();
  let changed = performance.now();
  while (log.length < frames) {
    const frame = await until(() => {
      if (performance.now() - changed > 100) {
        input = randomInput();
        changed = performance.now();
      }
      const result = side.network.exchange(input);
      if (result && result.error) throw new Error(result.error);
      return result;
    });
    log.push({ ...frame, time: performance.now() });
  }
}

module.exports = {
  OnlineTransport, STATUS, transportPath, sleep, startRelay, engineNetwork, RoomClient, peer, until, startRoom,
  randomInput, playFrames, readFrame, readPlayers,
};

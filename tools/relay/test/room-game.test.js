// SPDX-License-Identifier: MIT
//
// The game's own room protocol (scripts/base/game/room.lua, run by a Lua 5.2 interpreter as in the
// web build) through dist/web/online.js and the relay: several games in one room, a distant player,
// a player whose tab stalls, a desync, a player leaving and hidden characters one player came with.
// Skipped without a Lua interpreter (set LUA=/path/to/lua5.2 to choose one).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');
const readline = require('node:readline');
const { spawn, spawnSync } = require('node:child_process');
const { WebSocket } = require('ws');
const { createRelay } = require('../server.js');

const repository = path.join(__dirname, '..', '..', '..');
const harness = path.join(__dirname, 'room-harness.lua');
const { OnlineTransport } = require(path.join(repository, 'dist', 'web', 'online.js'));

const lua = [process.env.LUA, 'lua5.2', 'lua5.1', 'luajit', 'lua'].filter(Boolean)
  .find((candidate) => spawnSync(candidate, ['-v']).status === 0);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const fromHex = (text) => Buffer.from(text === '-' ? '' : text, 'hex').toString('latin1');

async function startRelay(overrides = {}) {
  const relay = createRelay({ quiet: true, ...overrides });
  const address = await relay.listen(0, '127.0.0.1');
  relay.url = `ws://127.0.0.1:${address.port}${relay.config.path}`;
  return relay;
}

// A WebSocket whose traffic takes `oneWay` ms each way: a player far from the relay.
function distantWebSocket(oneWay) {
  return class DistantWebSocket {
    constructor(url) {
      this.inner = new WebSocket(url);
      this.inner.binaryType = 'arraybuffer';
      const later = (handler) => (event) => {
        const copy = { data: event.data, code: event.code, reason: event.reason };
        setTimeout(() => { if (this[handler]) this[handler](copy); }, oneWay);
      };
      this.inner.onopen = later('onopen');
      this.inner.onmessage = later('onmessage');
      this.inner.onclose = later('onclose');
      this.inner.onerror = later('onerror');
    }
    get readyState() { return this.inner.readyState; }
    get bufferedAmount() { return this.inner.bufferedAmount; }
    send(data) {
      const copy = Buffer.from(data);
      setTimeout(() => { if (this.inner.readyState === WebSocket.OPEN) this.inner.send(copy); }, oneWay);
    }
    close(code, reason) { this.inner.close(code, reason); }
  };
}

// One game: a Lua process running room.lua, its engine network calls answered by online.js.
class Game {
  constructor(relay, room, { oneWay = 0, names = ['A', '', '', ''], checksum } = {}) {
    this.online = new OnlineTransport({ WebSocket: oneWay ? distantWebSocket(oneWay) : WebSocket, relay: relay.url, room });
    const env = { ...process.env, ROOM_SEED: String(crypto.randomInt(1000000)) };
    if (checksum !== undefined) env.ROOM_DATA_CHECKSUM = String(checksum);
    this.process = spawn(lua, [harness, repository], { stdio: ['pipe', 'pipe', 'inherit'], env });
    this.waiting = [];
    this.frames = [];
    readline.createInterface({ input: this.process.stdout }).on('line', (line) => this.onLine(line));
    this.ready = this.command(`names ${names.map((name) => name || '_').join(' ')}`);
  }

  onLine(line) {
    if (line.startsWith('E ')) {
      const [, operation, value = ''] = line.split(' ');
      this.process.stdin.write(`${this.engine(operation, Buffer.from(value, 'hex'))}\n`);
    } else if (line.startsWith('R ')) {
      this.waiting.shift()(line.slice(2).split(' '));
    }
  }

  // What src/adapters/web/transport.cpp does with online.js.
  engine(operation, value) {
    const ok = (bytes = []) => `ok ${Buffer.from(bytes).toString('hex')}`;
    const fail = (message) => `err ${Buffer.from(message || 'failed').toString('hex')}`;
    if (operation === 'time') return ok(Buffer.from(String(performance.now())));
    if (operation === 'host' || operation === 'join') {
      return this.online.start(operation === 'host', value.toString()) ? ok() : fail(this.online.error());
    }
    if (operation === 'send') return this.online.send(new Uint8Array(value)) ? ok() : fail(this.online.error());
    if (operation === 'poll') {
      const available = this.online.available();
      if (available < 0) {
        const message = this.online.error();
        this.online.close();
        return fail(message);
      }
      return ok(this.online.take(Math.min(available, 8192)));
    }
    if (operation === 'status') return ok(Buffer.from(['idle', 'listening', 'connecting', 'connected'][this.online.status()]));
    if (operation === 'close') { this.online.close(); return ok(); }
    return fail(`unknown operation ${operation}`);
  }

  command(text) {
    return new Promise((resolve) => {
      this.waiting.push(resolve);
      this.process.stdin.write(`${text}\n`);
    });
  }

  async lobby() {
    const [joined, host, canStart, code, list] = await this.command('lobby');
    const players = list === '-' ? [] : list.split(',').map((entry) => {
      const [name, flag] = entry.split(':');
      return { name: fromHex(name), host: flag === 'h' };
    });
    return { joined: joined === '1', host: host === '1', canStart: canStart === '1', code, players };
  }

  async pollUntilReady(timeout = 5000) {
    const deadline = Date.now() + timeout;
    for (;;) {
      const [result, detail] = await this.command('poll');
      if (result === 'ready') return fromHex(detail);
      if (result === 'err') throw new Error(fromHex(detail));
      if (Date.now() > deadline) throw new Error('not started in time');
      await sleep(10);
    }
  }

  // The game loop of a page: one tick every few milliseconds, as the engine does while a room paces it.
  // `display`: the refresh interval (ms) of a display the page tells the game about, as the web build does.
  async play({ until, input = () => ({}), hp = (frame) => (frame * 37) % 3000, pause, display }) {
    for (;;) {
      if (until(this)) return;
      if (pause) await pause(this);
      const keys = input(this) || {};
      const next = this.frames.length ? this.frames.at(-1).number + 1 : 0;
      const age = display ? ` ${Math.round(performance.now() % display)}` : '';
      const line = `exchange ${(keys.players || ['-', '-', '-', '-']).map((one) => one || '-').join(',')} ${keys.functions || '-'} ${keys.unlock || 0} ${hp(next, this)}${age}`;
      const reply = await this.command(line);
      if (reply[0] === 'frame') {
        this.frames.push({ number: Number(reply[1]), slots: reply[2], functions: reply[3], sources: reply[4], unlock: Number(reply[5]),
          status: fromHex(reply[6] || '-'), time: performance.now() });
      } else if (reply[0] === 'err') {
        this.error = fromHex(reply[1]);
        return;
      }
      await sleep(3);
    }
  }

  async quit() {
    if (this.process.exitCode === null && !this.quitting) {
      this.quitting = true;
      await Promise.race([this.command('quit'), sleep(2000)]);
    }
    this.process.stdin.end();
    this.process.kill();
    this.online.close();
  }
}

// Players who joined one room in order, the first one hosting, and the started game.
async function startedGames(relay, count, options = [], games = []) {
  const code = String(100000 + crypto.randomInt(900000));
  for (let index = 0; index < count; index += 1) {
    const game = new Game(relay, code, { names: [`P${index + 1}`, `Q${index + 1}`, '', ''], ...options[index] });
    await game.ready;
    assert.deepEqual(await game.command(`start ${index === 0 ? 'host' : 'join'}`), ['ok']);
    for (let tries = 0; !(await game.lobby()).joined; tries += 1) {
      await game.command('poll');
      if (tries > 200) throw new Error('never joined');
      await sleep(10);
    }
    games.push(game);
  }
  // The host starts once his list shows everyone (a distant player's hello takes a while).
  for (let tries = 0; (await games[0].lobby()).players.length < count; tries += 1) {
    for (const game of games) await game.command('poll');
    if (tries > 200) throw new Error('the host can never start');
    await sleep(10);
  }
  assert.deepEqual(await games[0].command('begin'), ['ok']);
  const random = await Promise.all(games.map((game) => game.pollUntilReady()));
  assert.deepEqual(random, games.map((game, index) => (index === 0 ? 'own' : 'other')), 'everyone uses the host\'s random table');
  return games;
}

// Frames every game ran must hold the same input everywhere.
function assertLockstep(games) {
  const shortest = Math.min(...games.map((game) => game.frames.length));
  assert.ok(shortest > 0, 'frames ran');
  for (const game of games) {
    game.frames.forEach((frame, index) => assert.equal(frame.number, index, 'frames run in order, none skipped'));
  }
  for (let index = 0; index < shortest; index += 1) {
    const reference = games[0].frames[index];
    for (const game of games.slice(1)) {
      const frame = game.frames[index];
      assert.deepEqual([frame.slots, frame.functions, frame.sources, frame.unlock],
        [reference.slots, reference.functions, reference.sources, reference.unlock], `frame ${index}`);
    }
  }
}

function pacing(game, from = 10) {
  const times = game.frames.slice(from).map((frame) => frame.time);
  const gaps = times.slice(1).map((time, index) => time - times[index]);
  const mean = gaps.reduce((sum, gap) => sum + gap, 0) / gaps.length;
  return { mean, worst: Math.max(...gaps) };
}

const skip = lua ? false : 'no Lua interpreter (set LUA)';

test('three games share the room: slots, names, the host\'s random table and identical frames', { skip }, async () => {
  const relay = await startRelay();
  const games = [];
  try {
    await startedGames(relay, 3, [], games);
    const slots = await Promise.all(games.map((game) => game.command('slots')));
    assert.deepEqual(slots.map(([offset, count]) => [Number(offset), Number(count)]), [[0, 3], [3, 3], [6, 2]]);
    assert.deepEqual(slots[0][2].split(',').map(fromHex), ['P1', 'Q1', '', 'P2', 'Q2', '', 'P3', 'Q3']);
    // Each game holds keys that change every 100 ms; its first player is the one that moves.
    const patterns = ['r', 'lc', 'ub'];
    await Promise.all(games.map((game, index) => game.play({
      until: (self) => self.frames.length >= 90,
      input: () => ({ players: [Math.floor(performance.now() / 100) % 2 ? patterns[index] : '-', index === 2 ? 'd' : '-'],
        functions: index === 1 && Math.floor(performance.now() / 300) % 2 ? '7' : '-' }),
    })));
    assertLockstep(games);
    const frames = games[0].frames;
    for (const [index, slot] of [[0, 0], [1, 3], [2, 6]]) {
      assert.ok(frames.some((frame) => frame.slots.split(',')[slot] === [...patterns[index]].sort((a, b) => 'udlrcbf'.indexOf(a) - 'udlrcbf'.indexOf(b)).join('')),
        `game ${index + 1}'s keys reach slot ${slot + 1}`);
    }
    assert.ok(frames.some((frame) => frame.slots.split(',')[7] === 'd'), 'the third game\'s second player has slot 8');
    assert.ok(frames.some((frame) => frame.functions === '7' && frame.sources === '-,7,-'), 'function keys keep their source');
    const { mean, worst } = pacing(games[0]);
    assert.ok(mean > 31 && mean < 36, `frames every ${mean.toFixed(1)} ms`);
    assert.ok(worst < 80, `longest gap ${worst.toFixed(1)} ms`);
  } finally {
    await Promise.all(games.map((game) => game.quit()));
    await relay.close();
  }
});

test('hidden characters one computer came with turn on for the whole room, on the same frame', { skip }, async () => {
  const relay = await startRelay();
  const games = [];
  try {
    await startedGames(relay, 3, [{}, {}, { oneWay: 60 }], games);
    // The distant guest had them unlocked: its first input carries the news.
    assert.deepEqual(await games[2].command('share'), ['ok']);
    await Promise.all(games.map((game) => game.play({ until: (self) => self.frames.length >= 60 })));
    assertLockstep(games);
    const toggles = games[0].frames.filter((frame) => frame.unlock === 1);
    assert.equal(toggles.length, 1, 'one frame turns them on (as LF2.NET typed)');
    assert.ok(toggles[0].number < 30, `early: frame ${toggles[0].number}`);
    // Once they are on, more news changes nothing (a toggle would turn them off again).
    for (const game of games) assert.deepEqual(await game.command('characters 1'), ['ok']);
    assert.deepEqual(await games[1].command('share'), ['ok']);
    await Promise.all(games.map((game) => game.play({ until: (self) => self.frames.length >= 120 })));
    assertLockstep(games);
    assert.equal(games[0].frames.slice(60).filter((frame) => frame.unlock !== 0).length, 0);
  } finally {
    await Promise.all(games.map((game) => game.quit()));
    await relay.close();
  }
});

test('the beat is 33 1/3 ms; in a browser frames start just after a display refresh, two refreshes apart', { skip }, async () => {
  const relay = await startRelay();
  const games = [];
  const refresh = 1000 / 60;
  try {
    await startedGames(relay, 2, [], games);
    assert.deepEqual(await games[0].command('tick'), ['33.3333']);
    await Promise.all(games.map((game) => game.play({ until: (self) => self.frames.length >= 100, display: refresh })));
    assertLockstep(games);
    for (const game of games) {
      const frames = game.frames.slice(20);
      // Each frame starts (its reply arrives) within a few milliseconds after a refresh...
      const late = frames.map((frame) => frame.time % refresh).sort((a, b) => a - b);
      assert.ok(late[Math.floor(late.length * 0.9)] < 9, `90% start within ${late[Math.floor(late.length * 0.9)].toFixed(1)} ms of a refresh`);
      // ...and the next one two refreshes later (rarely one or three).
      const gaps = frames.slice(1).map((frame, index) => Math.round((frame.time - frames[index].time) / refresh));
      const two = gaps.filter((gap) => gap === 2).length;
      assert.ok(two >= gaps.length * 0.85, `${two} of ${gaps.length} frames two refreshes apart (${gaps.join(' ')})`);
    }
  } finally {
    await Promise.all(games.map((game) => game.quit()));
    await relay.close();
  }
});

test('a distant player is not waited for: the others keep the beat and his keys arrive later', { skip }, async () => {
  const relay = await startRelay();
  const games = [];
  try {
    await startedGames(relay, 3, [{}, {}, { oneWay: 120 }], games);
    let pressed = 0;
    await Promise.all(games.map((game, index) => game.play({
      until: (self) => self.frames.length >= 120,
      input: (self) => {
        if (index !== 2) return {};
        // The distant player presses attack when he sees frame 40.
        if (!pressed && self.frames.length && self.frames.at(-1).number >= 40) pressed = self.frames.at(-1).number;
        return { players: [pressed ? 'c' : '-'] };
      },
    })));
    assertLockstep(games);
    const { mean, worst } = pacing(games[0]);
    assert.ok(mean > 31 && mean < 36, `near players run a frame every ${mean.toFixed(1)} ms`);
    assert.ok(worst < 80, `longest gap ${worst.toFixed(1)} ms`);
    const used = games[0].frames.find((frame) => frame.slots.split(',')[6] === 'c').number;
    // He saw frame 40 about 120 ms late, and his key took 120 ms back: about 8 frames later.
    assert.ok(used - pressed >= 6 && used - pressed <= 14, `pressed on frame ${pressed}, used on frame ${used}`);
  } finally {
    await Promise.all(games.map((game) => game.quit()));
    await relay.close();
  }
});

test('a game that stalls (a hidden tab) catches up and stays in step', { skip }, async () => {
  const relay = await startRelay();
  const games = [];
  try {
    await startedGames(relay, 2, [], games);
    let resumed = 0;
    await Promise.all(games.map((game, index) => game.play({
      until: (self) => self.frames.length >= 150,
      input: () => ({ players: [Math.floor(performance.now() / 70) % 2 ? 'f' : 'u'] }),
      pause: async (self) => {
        if (index === 1 && !resumed && self.frames.length === 30) {
          await sleep(1500);
          resumed = performance.now();
        }
      },
    })));
    assertLockstep(games);
    // About 45 frames piled up during the stall; they run quickly once the game wakes up.
    const numberAt = (time) => games[0].frames.filter((frame) => frame.time <= time).length - 1;
    const caughtUp = games[1].frames.find((frame) => frame.time > resumed && numberAt(frame.time) - frame.number <= 2);
    assert.ok(caughtUp, 'caught up');
    assert.ok(caughtUp.time - resumed < 1000, `caught up ${(caughtUp.time - resumed).toFixed(0)} ms after waking up`);
  } finally {
    await Promise.all(games.map((game) => game.quit()));
    await relay.close();
  }
});

test('a desync is noticed by everyone', { skip }, async () => {
  const relay = await startRelay();
  const games = [];
  try {
    await startedGames(relay, 3, [], games);
    await Promise.all(games.map((game, index) => game.play({
      until: (self) => self.frames.length >= 120,
      hp: (frame) => (index === 1 && frame === 48 ? 999 : (frame * 37) % 3000),
    })));
    for (const game of games) assert.equal(game.error, 'Network HP synchronization mismatch');
    for (const game of games) assert.ok(game.frames.length < 70, 'stopped soon after frame 48');
  } finally {
    await Promise.all(games.map((game) => game.quit()));
    await relay.close();
  }
});

test('a player who leaves is announced; the others play on without him', { skip }, async () => {
  const relay = await startRelay();
  const games = [];
  try {
    await startedGames(relay, 3, [], games);
    await Promise.all(games.map(async (game, index) => {
      await game.play({ until: (self) => self.frames.length >= (index === 2 ? 40 : 100), input: () => ({ players: ['r'] }) });
      if (index === 2) await game.quit();
    }));
    // Games 1 and 2 ran on; P3 left after frame 40 or so.
    const frames = games[0].frames;
    const notice = frames.find((frame) => frame.status);
    assert.equal(notice.status, 'P3 left the game');
    assert.equal(games[1].frames.find((frame) => frame.status).status, 'P3 left the game');
    assert.equal(frames.at(-1).slots.split(',')[6], '-');
    assert.equal(frames.at(-1).slots.split(',')[0], 'r');
    assertLockstep(games.slice(0, 2));
  } finally {
    await Promise.all(games.map((game) => game.quit()));
    await relay.close();
  }
});

test('another version of the game cannot join the room', { skip }, async () => {
  const relay = await startRelay();
  const code = String(100000 + crypto.randomInt(900000));
  const host = new Game(relay, code);
  const other = new Game(relay, code, { checksum: 42 });
  try {
    await Promise.all([host.ready, other.ready]);
    await host.command('start host');
    for (let tries = 0; !(await host.lobby()).players.length; tries += 1) { await host.command('poll'); await sleep(10); }
    await other.command('start join');
    let reply;
    for (let tries = 0; tries < 300; tries += 1) {
      reply = await other.command('poll');
      if (reply[0] === 'err') break;
      await sleep(10);
    }
    assert.equal(fromHex(reply[1]), 'Relay: this room plays another game version or mod');
  } finally {
    await host.quit();
    await other.quit();
    await relay.close();
  }
});

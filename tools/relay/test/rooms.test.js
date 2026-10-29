// SPDX-License-Identifier: MIT
//
// Protocol 2: rooms of up to 8 players where the relay keeps the beat.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { WebSocket } = require('ws');
const { createRelay, CLOSE, KIND, packet } = require('../server.js');

async function startRelay(overrides = {}) {
  const relay = createRelay({ quiet: true, ...overrides });
  const address = await relay.listen(0, '127.0.0.1');
  relay.url = `ws://127.0.0.1:${address.port}${relay.config.path}`;
  return relay;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const room = () => String(100000 + crypto.randomInt(900000));

// The player list of LOBBY and STARTED.
function readPlayers(payload, at = 0) {
  const count = payload[at];
  const players = [];
  let offset = at + 1;
  for (let index = 0; index < count; index += 1) {
    const length = payload[offset + 2];
    players.push({ id: payload[offset], host: payload[offset + 1] === 1, info: payload.subarray(offset + 3, offset + 3 + length).toString('latin1') });
    offset += 3 + length;
  }
  return { players, at: offset };
}

function readFrame(payload) {
  const frame = { number: payload.readUInt32LE(0), count: payload[4], fresh: payload[5], present: payload[6], inputs: [] };
  let at = 7;
  for (let index = 0; index < frame.count; index += 1) {
    frame.inputs.push([...payload.subarray(at + 1, at + 1 + payload[at])]);
    at += 1 + payload[at];
  }
  assert.equal(at, payload.length, 'frame length');
  return frame;
}

// A game in a room: records every message, in order, with the time it arrived.
function player(relay, code, role = 'join') {
  const ws = new WebSocket(`${relay.url}?v=2&role=${role}&room=${code}`);
  const state = { ws, messages: [], controls: [], waiters: [], read: 0 };
  const notify = () => { for (const waiter of state.waiters.splice(0)) waiter(); };
  ws.on('message', (data, isBinary) => {
    if (!isBinary) state.controls.push(JSON.parse(data.toString()));
    else {
      for (let at = 0; at < data.length;) {
        const length = data.readUInt16LE(at + 1);
        state.messages.push({ kind: data[at], payload: Buffer.from(data.subarray(at + 3, at + 3 + length)), time: performance.now() });
        at += 3 + length;
      }
    }
    notify();
  });
  state.closed = new Promise((resolve) => ws.on('close', (closeCode, reason) => {
    state.closeInfo = { code: closeCode, reason: reason.toString() };
    notify();
    resolve(state.closeInfo);
  }));
  state.until = async (predicate, timeout = 4000) => {
    const deadline = Date.now() + timeout;
    while (!predicate()) {
      if (Date.now() > deadline) throw new Error('timed out waiting for condition');
      await new Promise((resolve) => { state.waiters.push(resolve); setTimeout(resolve, 50); });
    }
  };
  // The next message of this kind after the last one taken (others are skipped).
  state.next = async (kind) => {
    let found;
    await state.until(() => {
      const index = state.messages.findIndex((message, position) => position >= state.read && message.kind === kind);
      if (index < 0) return false;
      found = state.messages[index];
      state.read = index + 1;
      return true;
    });
    return found;
  };
  state.send = (kind, payload = Buffer.alloc(0)) => ws.send(packet(kind, Buffer.from(payload)));
  state.hello = (profile = 'OpenLF2 Room 1 test', info = 'Name') => {
    state.send(KIND.hello, Buffer.concat([Buffer.from([profile.length]), Buffer.from(profile, 'latin1'), Buffer.from(info, 'latin1')]));
  };
  state.frames = () => state.messages.filter((message) => message.kind === KIND.frame).map((message) => ({ ...readFrame(message.payload), time: message.time }));
  return state;
}

// Players who said hello, with the host's START sent; resolves to each one's STARTED player list.
async function startedRoom(relay, count, { setup = 'setup' } = {}) {
  const code = room();
  const players = [];
  for (let index = 0; index < count; index += 1) {
    const one = player(relay, code, index === 0 ? 'host' : 'join');
    await one.next(KIND.welcome); // one after the other: the room lists them in the order they came
    players.push(one);
  }
  players.forEach((one, index) => one.hello(undefined, `P${index + 1}`));
  await players[0].until(() => players[0].messages.some((message) => message.kind === KIND.lobby && message.payload[0] === count));
  players[0].send(KIND.start, Buffer.from(setup));
  const started = await Promise.all(players.map((one) => one.next(KIND.started)));
  return { code, players, started };
}

test('four players meet, start together and get the same frames on the beat', async () => {
  const relay = await startRelay();
  try {
    const { players, started } = await startedRoom(relay, 4, { setup: 'random table' });
    for (const message of started) {
      const { players: list, at } = readPlayers(message.payload);
      assert.deepEqual(list.map((one) => one.info), ['P1', 'P2', 'P3', 'P4']);
      assert.equal(list[0].host, true);
      assert.equal(message.payload.readUInt16LE(at), 'random table'.length);
      assert.equal(message.payload.subarray(at + 2).toString(), 'random table');
    }
    assert.deepEqual(players[0].controls.at(-1), { t: 'room', players: 4, started: true });
    for (const one of players) one.send(KIND.ready);
    await Promise.all(players.map((one) => one.until(() => one.frames().length >= 30)));
    const reference = players[0].frames().slice(0, 30).map(({ time, ...frame }) => frame);
    reference.forEach((frame, index) => {
      assert.equal(frame.number, index);
      assert.equal(frame.count, 4);
      assert.equal(frame.present, 0b1111);
    });
    for (const one of players.slice(1)) {
      assert.deepEqual(one.frames().slice(0, 30).map(({ time, ...frame }) => frame), reference);
    }
    const times = players[0].frames().map((frame) => frame.time);
    const average = (times[29] - times[0]) / 29;
    assert.ok(average > 30 && average < 37, `average beat ${average} ms`);
    for (const one of players) one.ws.close();
  } finally { await relay.close(); }
});

test('inputs of one beat merge; without news the newest repeats, then releases', async () => {
  // A slow beat, so that the test's messages surely land between two beats.
  const relay = await startRelay({ tickMs: 150, repeatLimit: 2 });
  try {
    const { players } = await startedRoom(relay, 2);
    const [host, guest] = players;
    host.send(KIND.ready);
    guest.send(KIND.ready);
    await host.next(KIND.frame);
    await host.next(KIND.frame);
    host.read = host.messages.length; // from now on, only frames that come after what is sent below
    guest.send(KIND.input, [3, 0x10, 0, 0x40]);
    let frame = readFrame((await host.next(KIND.frame)).payload);
    assert.deepEqual(frame.inputs, [[], [3, 0x10, 0, 0x40]]);
    assert.equal(frame.fresh, 0b10);
    // No news: the keys stay, the events (byte 0) do not; after two beats the keys are released.
    frame = readFrame((await host.next(KIND.frame)).payload);
    assert.deepEqual(frame.inputs[1], [0, 0x10, 0, 0x40]);
    assert.equal(frame.fresh, 0);
    frame = readFrame((await host.next(KIND.frame)).payload);
    assert.deepEqual(frame.inputs[1], [0, 0x10, 0, 0x40]);
    frame = readFrame((await host.next(KIND.frame)).payload);
    assert.deepEqual(frame.inputs[1], []);
    // A tap (press then release) between two beats still counts on the next beat; the release
    // (the newest input) is what repeats after it.
    guest.send(KIND.input, [1, 0x08]);
    guest.send(KIND.input, [0, 0x00, 0, 0x40]);
    frame = readFrame((await host.next(KIND.frame)).payload);
    assert.deepEqual(frame.inputs[1], [1, 0x08, 0, 0x40]);
    assert.equal(frame.fresh, 0b10);
    frame = readFrame((await host.next(KIND.frame)).payload);
    assert.deepEqual(frame.inputs[1], [0, 0x00, 0, 0x40]);
    assert.equal(frame.fresh, 0);
    host.ws.close();
    guest.ws.close();
  } finally { await relay.close(); }
});

test('a player with a slow connection does not slow the others down', async () => {
  const relay = await startRelay();
  try {
    const { players } = await startedRoom(relay, 3);
    const [host, guest, distant] = players;
    for (const one of players) one.send(KIND.ready);
    // The distant player answers each frame 200 ms late, as if a quarter of a second away.
    let answered = 0;
    const answer = setInterval(() => {
      const frames = distant.messages.filter((message) => message.kind === KIND.frame && performance.now() - message.time >= 200);
      for (; answered < frames.length; answered += 1) distant.send(KIND.input, [0, 0x10]);
    }, 5);
    // The others answer at once.
    const quick = (one, bits) => setInterval(() => one.send(KIND.input, [0, bits]), 33);
    const timers = [quick(host, 0x20), quick(guest, 0x40)];
    await host.until(() => host.frames().length >= 60, 5000);
    clearInterval(answer);
    timers.forEach(clearInterval);
    const frames = host.frames();
    const average = (frames[59].time - frames[0].time) / 59;
    assert.ok(average > 30 && average < 37, `average beat ${average} ms`);
    // The distant player's keys arrive, about 200 ms (six frames) after the frames they answer.
    const first = frames.findIndex((frame) => frame.inputs[2][1] === 0x10);
    assert.ok(first >= 5 && first <= 12, `distant input first used in frame ${first}`);
    for (const one of players) one.ws.close();
  } finally { await relay.close(); }
});

test('a player who leaves is announced and the others play on', async () => {
  const relay = await startRelay();
  try {
    const { players } = await startedRoom(relay, 3);
    for (const one of players) one.send(KIND.ready);
    await players[0].until(() => players[0].frames().length >= 3);
    players[1].ws.close();
    const left = await players[0].next(KIND.left);
    assert.deepEqual([...left.payload], [1]);
    assert.deepEqual([...(await players[2].next(KIND.left)).payload], [1]);
    const seen = players[0].frames().length;
    await players[0].until(() => players[0].frames().length >= seen + 5);
    const last = players[0].frames().at(-1);
    assert.equal(last.present, 0b101);
    assert.deepEqual(last.inputs[1], []);
    assert.equal(players[0].closeInfo, undefined);
    assert.deepEqual(players[2].controls.at(-1), { t: 'room', players: 2, started: true });
    players[0].ws.close();
    players[2].ws.close();
    await relay.close();
    assert.equal(relay.groups.size, 0);
  } finally { await relay.close(); }
});

test('a player who stops reading is dropped, and only him', async () => {
  const relay = await startRelay({ maxBufferedBytes: 4000 });
  try {
    const { players } = await startedRoom(relay, 3);
    for (const one of players) one.send(KIND.ready);
    await players[2].next(KIND.frame);
    // As if the frames piled up unsent: the relay's side of the third player's connection.
    const stuck = [...relay.groups.values()][0].order[2].ws;
    Object.defineProperty(stuck, 'bufferedAmount', { get: () => 5000 });
    await players[0].next(KIND.left);
    const seen = players[0].frames().length;
    await players[0].until(() => players[0].frames().length >= seen + 3);
    assert.equal(players[0].closeInfo, undefined);
    assert.equal(players[1].closeInfo, undefined);
    assert.equal((await players[2].closed).code, CLOSE.slowClient[0]);
    players[0].ws.close();
    players[1].ws.close();
  } finally { await relay.close(); }
});

test('the beat waits for every game to be ready, but not for long', async () => {
  const relay = await startRelay({ startGraceMs: 300 });
  try {
    const { players } = await startedRoom(relay, 2);
    players[0].send(KIND.ready);
    await sleep(150);
    assert.equal(players[0].frames().length, 0);
    await players[0].until(() => players[0].frames().length > 0, 1000);
    for (const one of players) one.ws.close();
  } finally { await relay.close(); }
});

test('desync checks go to the other players', async () => {
  const relay = await startRelay();
  try {
    const { players } = await startedRoom(relay, 3);
    const check = Buffer.alloc(6);
    check.writeUInt32LE(48, 0);
    check.writeUInt16LE(1234, 4);
    players[2].send(KIND.check, check);
    for (const one of players.slice(0, 2)) {
      const message = await one.next(KIND.checked);
      assert.equal(message.payload[0], 2);
      assert.equal(message.payload.readUInt32LE(1), 48);
      assert.equal(message.payload.readUInt16LE(5), 1234);
    }
    await sleep(100);
    assert.ok(!players[2].messages.some((message) => message.kind === KIND.checked));
    for (const one of players) one.ws.close();
  } finally { await relay.close(); }
});

test('the lobby lists who said hello; the host starts once two are in, nobody else can', async () => {
  const relay = await startRelay();
  const code = room();
  try {
    const guest = player(relay, code);
    const welcome = await guest.next(KIND.welcome);
    assert.equal(welcome.payload[1], 2); // not the host (bit 0); the beat is 33 ms (byte 3) and 1/3 (bits 1-2)
    assert.equal(welcome.payload[2], 8);
    assert.equal(welcome.payload[3], 33);
    assert.equal(welcome.payload[4], code.length);
    assert.equal(welcome.payload.subarray(5).toString(), code);
    guest.hello(undefined, 'Guest');
    await guest.until(() => guest.messages.some((message) => message.kind === KIND.lobby && message.payload[0] === 1));
    const host = player(relay, code, 'host');
    assert.equal((await host.next(KIND.welcome)).payload[1], 3);
    assert.deepEqual(readPlayers((await host.next(KIND.lobby)).payload).players.map((one) => one.info), ['Guest']);
    host.hello(undefined, 'Host');
    await guest.until(() => guest.messages.some((message) => message.kind === KIND.lobby && message.payload[0] === 2));
    const list = readPlayers(guest.messages.filter((message) => message.kind === KIND.lobby).at(-1).payload).players;
    assert.deepEqual(list.map((one) => [one.info, one.host]), [['Host', true], ['Guest', false]]);
    guest.send(KIND.start, Buffer.from('mine'));
    assert.equal((await guest.closed).code, CLOSE.protocol[0]);
    host.ws.close();
  } finally { await relay.close(); }
});

test('a start before two said hello is answered with the list, not a start', async () => {
  const relay = await startRelay();
  const code = room();
  try {
    const host = player(relay, code, 'host');
    await host.next(KIND.welcome);
    host.hello();
    await host.next(KIND.lobby);
    host.send(KIND.start, Buffer.from('setup'));
    await host.next(KIND.lobby);
    await sleep(100);
    assert.ok(!host.messages.some((message) => message.kind === KIND.started));
    host.ws.close();
  } finally { await relay.close(); }
});

test('a game of another version is turned away', async () => {
  const relay = await startRelay();
  const code = room();
  try {
    const host = player(relay, code, 'host');
    await host.next(KIND.welcome);
    host.hello('version A');
    const guest = player(relay, code);
    await guest.next(KIND.welcome);
    guest.hello('version B');
    assert.deepEqual(await guest.closed, { code: CLOSE.mismatch[0], reason: CLOSE.mismatch[1] });
    assert.equal(host.closeInfo, undefined);
    host.ws.close();
  } finally { await relay.close(); }
});

test('rooms have a size limit, and nobody joins a started game', async () => {
  const relay = await startRelay({ roomPlayers: 3 });
  try {
    const { code, players } = await startedRoom(relay, 3);
    const late = player(relay, code);
    assert.equal((await late.closed).code, CLOSE.started[0]);
    for (const one of players) one.ws.close();
    const code2 = room();
    const full = [player(relay, code2, 'host'), player(relay, code2), player(relay, code2)];
    await Promise.all(full.map((one) => one.next(KIND.welcome)));
    const fourth = player(relay, code2);
    assert.equal((await fourth.closed).code, CLOSE.roomFull[0]);
    for (const one of full) one.ws.close();
  } finally { await relay.close(); }
});

test('the host leaving the lobby closes the room; a second host is refused', async () => {
  const relay = await startRelay();
  const code = room();
  try {
    const host = player(relay, code, 'host');
    const guest = player(relay, code);
    await Promise.all([host.next(KIND.welcome), guest.next(KIND.welcome)]);
    const second = player(relay, code, 'host');
    assert.equal((await second.closed).code, CLOSE.hostTaken[0]);
    host.ws.close();
    assert.equal((await guest.closed).code, CLOSE.hostLeft[0]);
    await sleep(50);
    assert.equal(relay.groups.size, 0);
  } finally { await relay.close(); }
});

test('malformed messages close only their sender', async () => {
  const relay = await startRelay();
  try {
    const { players } = await startedRoom(relay, 2);
    for (const one of players) one.send(KIND.ready);
    players[1].ws.send(Buffer.from([KIND.input, 40, 0, 1, 2])); // longer than what follows
    assert.equal((await players[1].closed).code, CLOSE.protocol[0]);
    const seen = players[0].frames().length;
    await players[0].until(() => players[0].frames().length >= seen + 3);
    assert.equal(players[0].closeInfo, undefined);
    players[0].ws.close();
    const { players: others } = await startedRoom(relay, 2);
    others[0].send(KIND.input, Buffer.alloc(17)); // too long
    assert.equal((await others[0].closed).code, CLOSE.protocol[0]);
    others[1].ws.close();
  } finally { await relay.close(); }
});

test('protocol 1 and protocol 2 rooms never share a code', async () => {
  const relay = await startRelay();
  try {
    const code = room();
    const old = new WebSocket(`${relay.url}?role=host&room=${code}`);
    await new Promise((resolve) => old.once('message', resolve));
    const fresh = player(relay, code, 'join');
    assert.equal((await fresh.closed).code, CLOSE.codeInUse[0]);
    old.close();
    const code2 = room();
    const host = player(relay, code2, 'host');
    await host.next(KIND.welcome);
    const stale = new WebSocket(`${relay.url}?role=join&room=${code2}`);
    const closed = await new Promise((resolve) => stale.on('close', (closeCode, reason) => resolve({ closeCode, reason: reason.toString() })));
    assert.deepEqual(closed, { closeCode: CLOSE.newerRoom[0], reason: CLOSE.newerRoom[1] });
    host.ws.close();
  } finally { await relay.close(); }
});

test('eight players fill a room and the frames carry all of them', async () => {
  const relay = await startRelay();
  try {
    const { players } = await startedRoom(relay, 8);
    players.forEach((one, index) => {
      one.send(KIND.ready);
      one.send(KIND.input, [0, 1 << (index % 8)]);
    });
    const everyone = (frame) => frame.inputs.every((input, index) => input[1] === 1 << index);
    await players[7].until(() => players[7].frames().some(everyone), 3000);
    assert.equal(players[7].frames().find(everyone).present, 0xff);
    for (const one of players) one.ws.close();
  } finally { await relay.close(); }
});

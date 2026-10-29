#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// OpenLF2 online relay.
//
// Browsers cannot open raw TCP sockets, so OpenLF2's web build plays over a WebSocket to this relay
// instead. Players meet in a room named by a numeric code. The relay speaks two protocols:
//
// Protocol 2, rooms of up to 8 players (the web build's own; see "Rooms" below):
//   ws(s)://<server>/relay?v=2&role=host&room=482913   Network Game > Host
//   ws(s)://<server>/relay?v=2&role=join&room=482913   Network Game > Connect, room code as the address
// The relay keeps the beat: every 33 1/3 ms (30 per second) it sends each player one frame holding the newest input of
// every player, so nobody waits for the slowest connection.
//
// Protocol 1, two players (older game pages): the relay pairs host and guest and copies binary frames
// from one to the other unchanged. The game's own lockstep protocol (handshake, random table, one
// 22-byte input packet per frame) runs on top; the relay never parses or stores it.
//   ws(s)://<server>/relay?role=host&room=482913
//   ws(s)://<server>/relay?role=join&room=482913
// Either side may arrive first. Server-to-client control messages are JSON text frames:
//   {"t":"waiting","room":"482913"}   registered, waiting for the other player
//   {"t":"paired"}                    both players are present; binary frames now flow
//
// Problems close the socket with a 4xxx code and a short ASCII reason, which the game shows.
//
// With INSTALLER_FILE set (install-vps.sh does), the relay also serves its copy of the original LF2
// v2.0a installer at /lf2-installer.data, which the game page downloads before trying archive.org:
// download managers such as IDM let that name through, while they take over the .exe from archive.org.
// With PACKS_DIR set, it also keeps game packs (mods played instead of the original game, see
// packs.js), which whoever holds ADMIN_KEY uploads at /admin.
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const { WebSocketServer, WebSocket } = require('ws');
const { createPacks } = require('./packs.js');

const INSTALLER_PATH = '/lf2-installer.data';

const ROOM_PATTERN = /^\d{4,12}$/;

// Close codes are part of the contract with online.js (it maps them to messages too).
const CLOSE = Object.freeze({
  badRequest: [4000, 'Relay: bad request'],
  originDenied: [4001, 'Relay: this website may not use the relay'],
  tooManyConnections: [4002, 'Relay: too many connections from your network'],
  serverFull: [4003, 'Relay: server is full'],
  hostTaken: [4004, 'Relay: room already has a host'],
  guestTaken: [4004, 'Relay: room already has a guest'],
  timeout: [4005, 'Relay: nobody joined in time'],
  peerLeft: [4006, 'Relay: the other player left'],
  rateLimited: [4007, 'Relay: too much traffic'],
  slowPeer: [4008, 'Relay: the other player stopped reading'],
  earlyData: [4009, 'Relay: data sent before pairing'],
  // Protocol 2 rooms.
  roomFull: [4010, 'Relay: the room is full'],
  started: [4011, 'Relay: the game in this room has already started'],
  mismatch: [4012, 'Relay: this room plays another game version or mod'],
  hostLeft: [4013, 'Relay: the host left the room'],
  notStarted: [4014, 'Relay: the host did not start the game in time'],
  protocol: [4015, 'Relay: unexpected message from the game'],
  slowClient: [4016, 'Relay: your connection is too slow for the game'],
  codeInUse: [4017, 'Relay: this room code is in use by an older game page'],
  newerRoom: [4017, 'Relay: this room is for a newer game page (reload the page)'],
  shutdown: [1001, 'Relay: server is restarting'],
});

// Protocol 2 message kinds (see "Rooms" below).
const KIND = Object.freeze({
  hello: 0x01, start: 0x02, input: 0x03, ready: 0x04, check: 0x05,
  welcome: 0x81, lobby: 0x82, started: 0x83, frame: 0x84, checked: 0x85, left: 0x86,
});
const ROOM_LIMITS = Object.freeze({ players: 8, profile: 200, info: 64, input: 16, setup: 8192, queue: 64 });

function readConfig(env = process.env) {
  const number = (name, fallback) => {
    const raw = env[name];
    const value = raw === undefined || raw === '' ? fallback : Number(raw);
    if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be a non-negative number`);
    return value;
  };
  return {
    port: number('PORT', 8787),
    host: env.HOST || '0.0.0.0',
    path: env.RELAY_PATH || '/relay',
    // Comma-separated page origins allowed to connect, e.g. "https://you.github.io". Empty allows any.
    allowedOrigins: (env.ALLOWED_ORIGINS || '').split(',').map(normalizeOrigin).filter(Boolean),
    // Behind a reverse proxy (Caddy, nginx, Cloudflare), take the client address from X-Forwarded-For.
    trustProxy: env.TRUST_PROXY === '1' || env.TRUST_PROXY === 'true',
    maxRooms: number('MAX_ROOMS', 500), // 0 = unlimited
    maxConnectionsPerIp: number('MAX_CONNECTIONS_PER_IP', 8), // 0 = unlimited
    roomWaitMs: number('ROOM_WAIT_MS', 120000),
    pingIntervalMs: number('PING_INTERVAL_MS', 15000),
    maxMessageBytes: number('MAX_MESSAGE_BYTES', 65536), // the game queues at most 64 KiB
    messagesPerSecond: number('MESSAGES_PER_SECOND', 240), // the game sends ~30 per second; 0 = unlimited
    bytesPerSecond: number('BYTES_PER_SECOND', 131072), // 0 = unlimited
    maxBufferedBytes: number('MAX_BUFFERED_BYTES', 1048576),
    // Testing aid: hold every forwarded frame this long, to feel how a distant relay would play.
    forwardDelayMs: number('FORWARD_DELAY_MS', 0),
    // Protocol 2 rooms: most players in a room (at most 8, the game's player slots), the beat, how
    // long a room may wait for its host to press start, how long the relay waits for every game to
    // be ready after the start, and after how many beats without news a player's keys count as released.
    roomPlayers: Math.min(ROOM_LIMITS.players, Math.max(2, number('ROOM_PLAYERS', ROOM_LIMITS.players))),
    // 33 1/3 ms: 30 beats per second, two refreshes of a 60 Hz display each (whole thirds of a ms only).
    tickMs: Math.max(1, Math.round(number('TICK_MS', 100 / 3) * 3) / 3),
    lobbyWaitMs: number('LOBBY_WAIT_MS', 1800000),
    startGraceMs: number('START_GRACE_MS', 5000),
    repeatLimit: number('REPEAT_LIMIT', 15),
    // The LF2 installer served at /lf2-installer.data (empty: not served), and how often one client
    // address may download it (about 30 MB each time; browsers keep it after the first time).
    installerFile: env.INSTALLER_FILE || '',
    installerDownloadsPerHour: number('INSTALLER_DOWNLOADS_PER_HOUR', 20), // 0 = unlimited
    // Game packs (packs.js): where they are kept (empty: none), the key for uploading them at /admin
    // (empty: no uploads), their largest size, and how often one client address may download one.
    packsDir: env.PACKS_DIR || '',
    adminKey: env.ADMIN_KEY || '',
    maxPackBytes: number('MAX_PACK_BYTES', 1024 * 1024 * 1024),
    packDownloadsPerHour: number('PACK_DOWNLOADS_PER_HOUR', 20), // 0 = unlimited
    quiet: env.QUIET === '1' || env.QUIET === 'true',
  };
}

function normalizeOrigin(value) {
  return String(value || '').trim().replace(/\/+$/, '').toLowerCase();
}

// Token bucket: `rate` units per second, bursts up to `capacity`. A rate of 0 disables the limit.
class Bucket {
  constructor(rate, capacity) {
    this.rate = rate;
    this.capacity = Math.max(capacity, rate);
    this.tokens = this.capacity;
    this.last = Date.now();
  }
  take(amount) {
    if (this.rate === 0) return true;
    const now = Date.now();
    this.tokens = Math.min(this.capacity, this.tokens + ((now - this.last) * this.rate) / 1000);
    this.last = now;
    if (this.tokens < amount) return false;
    this.tokens -= amount;
    return true;
  }
}

function createRelay(overrides = {}) {
  const config = { ...readConfig({}), ...overrides };
  const rooms = new Map(); // protocol 1: code -> { code, host, join, timer }
  const groups = new Map(); // protocol 2: code -> room (see "Rooms" below)
  const connectionsPerIp = new Map();
  const log = (...parts) => { if (!config.quiet) console.log(new Date().toISOString(), ...parts); };

  const installerDownloads = new Map(); // client address -> { count, until }
  const installerPaths = new Set([INSTALLER_PATH, config.path.replace(/[^/]*$/, INSTALLER_PATH.slice(1))]);
  // Beside the WebSocket path, as the installer copy: /x/relay -> /x/lf2-packs.json and /x/admin.
  const relayFolder = config.path.replace(/[^/]*$/, '');
  const packs = createPacks(config, { log, clientAddress: (req) => clientAddress(req), allowOrigin: (req) => allowOrigin(req) });

  const server = http.createServer((req, res) => {
    const { pathname } = new URL(req.url, 'http://relay.invalid');
    if (pathname === '/healthz') {
      // Readable from the game page (another origin) so its Online panel can show "relay OK".
      res.writeHead(200, {
        'content-type': 'application/json',
        'cache-control': 'no-store',
        'access-control-allow-origin': '*',
      });
      res.end(JSON.stringify({
        ok: true, rooms: rooms.size + groups.size, clients: wss.clients.size, installer: installerSize() > 0,
        protocols: [1, 2], players: config.roomPlayers, packs: Boolean(config.packsDir),
      }));
      return;
    }
    if (installerPaths.has(pathname)) {
      serveInstaller(req, res);
      return;
    }
    const local = relayFolder !== '/' && pathname.startsWith(relayFolder) ? pathname.slice(relayFolder.length - 1) : pathname;
    if (packs.handle(req, res, local)) return;
    if (pathname === '/' || pathname === config.path) {
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
      res.end(`OpenLF2 relay is running. Connect with a WebSocket to ${config.path}\n`);
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('Not found\n');
  });

  // Uploading a game pack from a slow line may take a while (Node's default gives up after 5 minutes).
  server.requestTimeout = 2 * 3600 * 1000;

  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: config.maxMessageBytes,
    perMessageDeflate: false, // 22-byte packets: compression only adds latency
  });

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://relay.invalid');
    if (url.pathname !== config.path && url.pathname !== '/') {
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      return;
    }
    // Requests are validated after the upgrade, so the browser receives a close code and reason
    // instead of an anonymous connection error.
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req, url));
  });

  wss.on('connection', (ws, req, url) => {
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('error', () => {}); // a 'close' event always follows

    if (config.allowedOrigins.length && !config.allowedOrigins.includes(normalizeOrigin(req.headers.origin))) {
      return closeWith(ws, CLOSE.originDenied);
    }
    const role = url.searchParams.get('role');
    const code = url.searchParams.get('room') || '';
    if ((role !== 'host' && role !== 'join') || !ROOM_PATTERN.test(code)) {
      return closeWith(ws, CLOSE.badRequest);
    }

    const address = clientAddress(req);
    const count = connectionsPerIp.get(address) || 0;
    if (config.maxConnectionsPerIp && count >= config.maxConnectionsPerIp) {
      return closeWith(ws, CLOSE.tooManyConnections);
    }
    connectionsPerIp.set(address, count + 1);
    ws.once('close', () => {
      const left = (connectionsPerIp.get(address) || 1) - 1;
      if (left > 0) connectionsPerIp.set(address, left);
      else connectionsPerIp.delete(address);
    });
    ws.messageBudget = new Bucket(config.messagesPerSecond, config.messagesPerSecond * 2);
    ws.byteBudget = new Bucket(config.bytesPerSecond, Math.max(config.bytesPerSecond, config.maxMessageBytes) * 2);

    const version = url.searchParams.get('v');
    if (version === '2') return joinGroup(ws, role, code);
    if (version !== null && version !== '1') return closeWith(ws, CLOSE.badRequest);
    if (groups.has(code)) return closeWith(ws, CLOSE.newerRoom);

    let room = rooms.get(code);
    if (!room) {
      if (config.maxRooms && rooms.size + groups.size >= config.maxRooms) return closeWith(ws, CLOSE.serverFull);
      room = { code, host: null, join: null, timer: null };
      rooms.set(code, room);
    }
    if (room[role]) return closeWith(ws, role === 'host' ? CLOSE.hostTaken : CLOSE.guestTaken);

    room[role] = ws;
    ws.room = room;
    ws.role = role;
    ws.peer = null;
    ws.on('message', (data, isBinary) => onMessage(ws, data, isBinary));
    ws.on('close', () => onClose(ws));

    const other = room[role === 'host' ? 'join' : 'host'];
    if (other) {
      clearTimeout(room.timer);
      room.timer = null;
      ws.peer = other;
      other.peer = ws;
      // Both peers are linked before either learns about it, so any data that follows has a destination.
      sendControl(other, { t: 'paired' });
      sendControl(ws, { t: 'paired' });
      log(`room ${code}: paired`);
    } else {
      sendControl(ws, { t: 'waiting', room: code });
      room.timer = setTimeout(() => {
        if (room[role] === ws && !ws.peer) closeWith(ws, CLOSE.timeout);
      }, config.roomWaitMs);
      log(`room ${code}: ${role} waiting`);
    }
  });

  function onMessage(ws, data, isBinary) {
    if (!isBinary) return; // only the relay speaks text; clients send game bytes as binary frames
    if (!ws.peer) return closeWith(ws, CLOSE.earlyData);
    if (!ws.messageBudget.take(1) || !ws.byteBudget.take(data.length)) {
      log(`room ${ws.room.code}: rate limit`);
      closeWith(ws.peer, CLOSE.rateLimited);
      return closeWith(ws, CLOSE.rateLimited);
    }
    const peer = ws.peer;
    if (peer.readyState !== WebSocket.OPEN) return;
    if (peer.bufferedAmount > config.maxBufferedBytes) {
      closeWith(ws, CLOSE.slowPeer);
      return closeWith(peer, CLOSE.slowPeer);
    }
    if (config.forwardDelayMs > 0) {
      // Timers with the same delay fire in the order they were set, so the stream stays in order.
      setTimeout(() => { if (peer.readyState === WebSocket.OPEN) peer.send(data, { binary: true }); }, config.forwardDelayMs);
      return;
    }
    peer.send(data, { binary: true });
  }

  function onClose(ws) {
    const room = ws.room;
    if (!room) return;
    if (room[ws.role] === ws) room[ws.role] = null;
    const peer = ws.peer;
    ws.peer = null;
    if (peer) {
      // A lockstep match cannot continue with one player, so the room ends with the pair and its
      // code is free again at once (the host can press Host again with the same code).
      peer.peer = null;
      room.host = room.join = null;
      closeWith(peer, CLOSE.peerLeft);
      log(`room ${room.code}: ended`);
    }
    if (!room.host && !room.join) {
      clearTimeout(room.timer);
      if (rooms.get(room.code) === room) rooms.delete(room.code);
    }
  }

  // ---- Rooms (protocol 2) -----------------------------------------------------------------------
  //
  // Up to config.roomPlayers games share a room. Each says HELLO with its profile (engine, scripts,
  // mods and game data: the first HELLO sets the room's, and a game with another one is turned away)
  // and its player names; LOBBY lists the players to everyone. The host sends START with the setup
  // every game needs (the random table); STARTED gives every game the final list of players, whose
  // position is the player's index, and once every game is READY (or after startGraceMs) the beat
  // begins: every tickMs, FRAME with the input of each player. The inputs a player sent since the
  // last beat are merged (OR: a key held in any of them is held, so a quick tap is never lost), and
  // the newest of them stays his input on the following beats while no news comes, without its
  // one-shot events (byte 0); after repeatLimit beats without news the player counts as having
  // released every key. Games send their input as soon as it changes. Every game runs exactly the
  // frames it receives, in order, so all stay in step whatever their own connection does: a distant
  // player's keys take effect a little later and he sees the game a little later, but nobody waits
  // for him. A game that cannot keep up with the frames is dropped, and the others go on.
  //
  // Binary messages, both ways: kind (1 byte), payload length (2 bytes, little endian), payload.
  // A WebSocket message may carry several. Game to relay:
  //   HELLO   0x01  profile length (1), profile, info (names; at most 64 bytes)
  //   START   0x02  setup (at most 8 KiB): the host, once two players or more said hello
  //   INPUT   0x03  input (at most 16 bytes; byte 0 holds one-shot events), after STARTED
  //   READY   0x04  empty: STARTED is applied
  //   CHECK   0x05  frame (4), hash (2): passed on to the others, which compare it with their own
  // Relay to game:
  //   WELCOME 0x81  id (1), flags (1; bit 0: host), most players (1), beat in ms (1),
  //                 room code length (1), room code
  //   LOBBY   0x82  count (1); per player: id (1), flags (1), info length (1), info
  //   STARTED 0x83  the players as in LOBBY, then setup length (2), setup
  //   FRAME   0x84  frame (4), count (1), fresh mask (1), present mask (1);
  //                 per player: input length (1), input
  //   CHECKED 0x85  index (1), frame (4), hash (2)
  //   LEFT    0x86  index (1): that player is gone; his input stays empty
  // Text (JSON) messages are for the page around the game: {"t":"welcome","v":2,"room":"…","host":true}
  // and {"t":"room","players":3,"started":false}.

  function joinGroup(ws, role, code) {
    if (rooms.has(code)) return closeWith(ws, CLOSE.codeInUse);
    let room = groups.get(code);
    if (!room) {
      if (config.maxRooms && rooms.size + groups.size >= config.maxRooms) return closeWith(ws, CLOSE.serverFull);
      room = {
        code, members: [], host: null, nextId: 1, profile: null, started: false, order: [], frame: 0,
        ticking: false, ticks: 0, tickStart: 0, lobbyTimer: null, graceTimer: null, tickTimer: null, ended: false,
      };
      groups.set(code, room);
      room.lobbyTimer = setTimeout(() => endGroup(room, CLOSE.notStarted), config.lobbyWaitMs);
      log(`room ${code}: opened`);
    }
    if (room.started) return closeWith(ws, CLOSE.started);
    if (role === 'host' && room.host) return closeWith(ws, CLOSE.hostTaken);
    if (room.members.length >= config.roomPlayers) return closeWith(ws, CLOSE.roomFull);
    while (room.members.some((other) => other.id === room.nextId)) room.nextId = (room.nextId % 255) + 1;
    const member = {
      ws, room, id: room.nextId, host: role === 'host', info: null, ready: false,
      queue: [], last: EMPTY, repeats: 0, present: true, index: -1,
    };
    room.nextId = (room.nextId % 255) + 1;
    room.members.push(member);
    if (member.host) room.host = member;
    ws.on('message', (data, isBinary) => onGroupMessage(member, data, isBinary));
    ws.on('close', () => leaveGroup(member));
    sendControl(ws, { t: 'welcome', v: 2, room: code, host: member.host });
    const welcome = Buffer.alloc(5 + code.length);
    welcome[0] = member.id;
    // Flags: bit 0 the host; bits 1-2 the beat's thirds of a millisecond beyond welcome[3].
    const thirds = Math.round(config.tickMs * 3);
    welcome[1] = (member.host ? 1 : 0) | ((thirds % 3) << 1);
    welcome[2] = config.roomPlayers;
    welcome[3] = Math.min(255, Math.floor(thirds / 3));
    welcome[4] = code.length;
    welcome.write(code, 5, 'latin1');
    sendBinary(ws, packet(KIND.welcome, welcome));
    sendLobby(room, member);
    log(`room ${code}: ${role} arrived (${room.members.length} in the room)`);
  }

  // The players who said hello, the host first, then in the order they came.
  function listed(room) {
    const known = room.members.filter((member) => member.info);
    return known.filter((member) => member.host).concat(known.filter((member) => !member.host));
  }

  function describePlayers(list) {
    const parts = [Buffer.from([list.length])];
    for (const member of list) parts.push(Buffer.from([member.id, member.host ? 1 : 0, member.info.length]), member.info);
    return Buffer.concat(parts);
  }

  function sendLobby(room, only) {
    const list = listed(room);
    const message = packet(KIND.lobby, describePlayers(list));
    for (const member of only ? [only] : room.members) {
      sendBinary(member.ws, message);
      sendControl(member.ws, { t: 'room', players: list.length, started: false });
    }
  }

  function onGroupMessage(member, data, isBinary) {
    const { ws, room } = member;
    if (!isBinary || room.ended || !room.members.includes(member)) return;
    if (!ws.messageBudget.take(1) || !ws.byteBudget.take(data.length)) {
      log(`room ${room.code}: rate limit`);
      return closeWith(ws, CLOSE.rateLimited);
    }
    let at = 0;
    while (at < data.length) {
      if (data.length - at < 3) return closeWith(ws, CLOSE.protocol);
      const kind = data[at];
      const length = data.readUInt16LE(at + 1);
      if (data.length - at - 3 < length) return closeWith(ws, CLOSE.protocol);
      const problem = handleGroupMessage(member, kind, data.subarray(at + 3, at + 3 + length));
      if (problem) return closeWith(ws, problem);
      if (room.ended || !room.members.includes(member)) return;
      at += 3 + length;
    }
  }

  // Returns the close code and reason for a message the game should not have sent.
  function handleGroupMessage(member, kind, payload) {
    const room = member.room;
    if (kind === KIND.hello) {
      if (member.info || room.started || payload.length < 1) return CLOSE.protocol;
      const length = payload[0];
      if (!length || length > ROOM_LIMITS.profile || payload.length < 1 + length) return CLOSE.protocol;
      const profile = Buffer.from(payload.subarray(1, 1 + length));
      const info = Buffer.from(payload.subarray(1 + length));
      if (info.length > ROOM_LIMITS.info) return CLOSE.protocol;
      if (room.profile && !room.profile.equals(profile)) return CLOSE.mismatch;
      room.profile = room.profile || profile;
      member.info = info;
      sendLobby(room);
      return null;
    }
    if (kind === KIND.start) {
      if (!member.host || !member.info || room.started || payload.length > ROOM_LIMITS.setup) return CLOSE.protocol;
      // Somebody left just before: the host sees the list again instead.
      if (listed(room).length < 2) sendLobby(room, member);
      else startGroup(room, Buffer.from(payload));
      return null;
    }
    if (kind === KIND.input) {
      if (!room.started || member.index < 0 || payload.length > ROOM_LIMITS.input) return CLOSE.protocol;
      member.queue.push(Buffer.from(payload));
      // Far more than a beat's worth (the rate limit allows bursts): fold them, keeping the newest last.
      if (member.queue.length > ROOM_LIMITS.queue) member.queue = [mergeInputs(member.queue.slice(0, -1)), member.queue.at(-1)];
      return null;
    }
    if (kind === KIND.ready) {
      if (!room.started || member.index < 0 || payload.length) return CLOSE.protocol;
      member.ready = true;
      if (room.order.every((other) => other.ready || !other.present)) startBeat(room);
      return null;
    }
    if (kind === KIND.check) {
      if (!room.started || member.index < 0 || payload.length !== 6) return CLOSE.protocol;
      const message = packet(KIND.checked, Buffer.concat([Buffer.from([member.index]), payload]));
      for (const other of room.order) if (other !== member && other.present) sendBinary(other.ws, message);
      return null;
    }
    return CLOSE.protocol;
  }

  function startGroup(room, setup) {
    clearTimeout(room.lobbyTimer);
    room.started = true;
    room.order = listed(room);
    room.order.forEach((member, index) => { member.index = index; });
    // A game still connecting has missed the start.
    for (const member of room.members) if (!member.info) closeWith(member.ws, CLOSE.started);
    const length = Buffer.alloc(2);
    length.writeUInt16LE(setup.length, 0);
    const message = packet(KIND.started, Buffer.concat([describePlayers(room.order), length, setup]));
    for (const member of room.order) {
      sendBinary(member.ws, message);
      sendControl(member.ws, { t: 'room', players: room.order.length, started: true });
    }
    room.graceTimer = setTimeout(() => startBeat(room), config.startGraceMs);
    log(`room ${room.code}: started with ${room.order.length} players`);
  }

  function startBeat(room) {
    if (room.ticking || room.ended) return;
    clearTimeout(room.graceTimer);
    room.ticking = true;
    room.tickStart = performance.now();
    room.ticks = 0;
    scheduleBeat(room);
  }

  function scheduleBeat(room) {
    const due = room.tickStart + (room.ticks + 1) * config.tickMs;
    room.tickTimer = setTimeout(() => runBeats(room), Math.max(0, due - performance.now()));
  }

  // Beats are counted from the start, so timer delays do not add up; after a stall of the whole
  // process a few missed beats are sent at once, and a longer one restarts the count.
  function runBeats(room) {
    if (room.ended) return;
    const now = performance.now();
    const due = Math.floor((now - room.tickStart) / config.tickMs) - room.ticks;
    for (let count = 0; count < Math.min(due, 4) && !room.ended; count += 1) {
      room.ticks += 1;
      beat(room);
    }
    if (room.ended) return;
    if (due > 4) room.tickStart = now - room.ticks * config.tickMs;
    scheduleBeat(room);
  }

  function beat(room) {
    let fresh = 0;
    let present = 0;
    const parts = [];
    for (const member of room.order) {
      let input = EMPTY;
      if (member.present) {
        present |= 1 << member.index;
        const waiting = member.queue.length;
        if (waiting) {
          fresh |= 1 << member.index;
          input = waiting === 1 ? member.queue[0] : mergeInputs(member.queue);
          member.last = member.queue[waiting - 1];
          member.queue = [];
          member.repeats = 0;
        } else {
          member.repeats += 1;
          input = member.repeats > config.repeatLimit ? EMPTY : withoutEvents(member.last);
        }
      }
      parts.push(Buffer.from([input.length]), input);
    }
    const header = Buffer.alloc(7);
    header.writeUInt32LE(room.frame % 4294967296, 0);
    header[4] = room.order.length;
    header[5] = fresh;
    header[6] = present;
    room.frame += 1;
    const message = packet(KIND.frame, Buffer.concat([header, ...parts]));
    for (const member of room.order) {
      if (!member.present) continue;
      if (member.ws.bufferedAmount > config.maxBufferedBytes) {
        closeWith(member.ws, CLOSE.slowClient);
        continue;
      }
      sendBinary(member.ws, message);
    }
  }

  function leaveGroup(member) {
    const room = member.room;
    const position = room.members.indexOf(member);
    if (position >= 0) room.members.splice(position, 1);
    if (room.ended) return;
    if (!room.started) {
      if (member.host) {
        room.host = null;
        endGroup(room, CLOSE.hostLeft);
      } else if (!room.members.length) {
        endGroup(room);
      } else if (member.info) {
        sendLobby(room);
      }
      return;
    }
    if (member.index >= 0 && member.present) {
      member.present = false;
      member.queue = [];
      const message = packet(KIND.left, Buffer.from([member.index]));
      const players = room.order.filter((other) => other.present).length;
      for (const other of room.order) {
        if (!other.present) continue;
        sendBinary(other.ws, message);
        sendControl(other.ws, { t: 'room', players, started: true });
      }
      log(`room ${room.code}: player ${member.index + 1} left`);
    }
    if (!room.order.some((other) => other.present)) endGroup(room);
    else if (room.order.every((other) => other.ready || !other.present)) startBeat(room);
  }

  function endGroup(room, reason) {
    if (room.ended) return;
    room.ended = true;
    clearTimeout(room.lobbyTimer);
    clearTimeout(room.graceTimer);
    clearTimeout(room.tickTimer);
    if (groups.get(room.code) === room) groups.delete(room.code);
    for (const member of room.members.slice()) closeWith(member.ws, reason || CLOSE.shutdown);
    log(`room ${room.code}: ended`);
  }

  // Size of the installer file, or 0 when none is configured or readable.
  function installerSize() {
    if (!config.installerFile) return 0;
    try {
      const stat = fs.statSync(config.installerFile);
      return stat.isFile() ? stat.size : 0;
    } catch {
      return 0;
    }
  }

  function serveInstaller(req, res) {
    const headers = { 'cache-control': 'public, max-age=86400', 'x-content-type-options': 'nosniff', ...allowOrigin(req) };
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { ...headers, allow: 'GET, HEAD' });
      res.end();
      return;
    }
    const size = installerSize();
    if (!size) {
      res.writeHead(404, headers);
      res.end();
      return;
    }
    if (req.method === 'GET' && config.installerDownloadsPerHour) {
      const address = clientAddress(req);
      const now = Date.now();
      let entry = installerDownloads.get(address);
      if (!entry || entry.until <= now) {
        entry = { count: 0, until: now + 3600000 };
        installerDownloads.set(address, entry);
      }
      if (entry.count >= config.installerDownloadsPerHour) {
        res.writeHead(429, { ...headers, 'retry-after': String(Math.ceil((entry.until - now) / 1000)) });
        res.end();
        return;
      }
      entry.count += 1;
    }
    res.writeHead(200, { ...headers, 'content-type': 'application/octet-stream', 'content-length': String(size) });
    if (req.method === 'HEAD') {
      res.end();
      return;
    }
    const stream = fs.createReadStream(config.installerFile);
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  }

  // Cross-origin: the game page lives elsewhere (GitHub Pages). With an allow-list, only its pages may read.
  function allowOrigin(req) {
    if (!config.allowedOrigins.length) return { 'access-control-allow-origin': '*' };
    const origin = normalizeOrigin(req.headers.origin);
    if (origin && config.allowedOrigins.includes(origin)) return { 'access-control-allow-origin': req.headers.origin, vary: 'Origin' };
    return {};
  }

  function clientAddress(req) {
    if (config.trustProxy) {
      // The last entry is the one our own proxy added (Apache appends, Caddy replaces); entries before
      // it come from the client and could be made up to slip past the per-address limits.
      const forwarded = String(req.headers['x-forwarded-for'] || '').split(',').map((part) => part.trim()).filter(Boolean);
      if (forwarded.length) return forwarded[forwarded.length - 1];
    }
    return req.socket.remoteAddress || 'unknown';
  }

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.isAlive) { ws.terminate(); continue; }
      ws.isAlive = false;
      try { ws.ping(); } catch { /* closing */ }
    }
    const now = Date.now();
    for (const [address, entry] of installerDownloads) if (entry.until <= now) installerDownloads.delete(address);
    packs.cleanup();
  }, config.pingIntervalMs);
  heartbeat.unref();

  return {
    config,
    server,
    wss,
    rooms,
    listen(port = config.port, host = config.host) {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => {
          server.off('error', reject);
          resolve(server.address());
        });
      });
    },
    groups,
    close() {
      clearInterval(heartbeat);
      for (const room of rooms.values()) clearTimeout(room.timer);
      for (const room of [...groups.values()]) endGroup(room, CLOSE.shutdown);
      for (const ws of wss.clients) closeWith(ws, CLOSE.shutdown);
      return new Promise((resolve) => {
        wss.close(() => server.close(() => resolve()));
        setTimeout(() => { for (const ws of wss.clients) ws.terminate(); }, 1000).unref();
      });
    },
  };
}

function sendControl(ws, message) {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
}

function sendBinary(ws, data) {
  if (ws.readyState === WebSocket.OPEN) ws.send(data, { binary: true });
}

const EMPTY = Buffer.alloc(0);

// A protocol 2 message: kind, payload length (2 bytes, little endian), payload.
function packet(kind, payload) {
  const message = Buffer.allocUnsafe(3 + payload.length);
  message[0] = kind;
  message.writeUInt16LE(payload.length, 1);
  payload.copy(message, 3);
  return message;
}

// Inputs are bit sets (keys held, events): merged, every bit set in any of them is set.
function mergeInputs(inputs) {
  const merged = Buffer.alloc(Math.max(0, ...inputs.map((input) => input.length)));
  for (const input of inputs) for (let index = 0; index < input.length; index += 1) merged[index] |= input[index];
  return merged;
}

// A repeated input keeps its held keys but not its one-shot events (byte 0).
function withoutEvents(input) {
  if (!input.length || input[0] === 0) return input;
  const copy = Buffer.from(input);
  copy[0] = 0;
  return copy;
}

function closeWith(ws, [code, reason]) {
  if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
    ws.close(code, reason);
    // Do not wait forever for a client that never answers the close handshake.
    setTimeout(() => { if (ws.readyState !== WebSocket.CLOSED) ws.terminate(); }, 3000).unref();
  }
}

module.exports = { createRelay, readConfig, CLOSE, ROOM_PATTERN, KIND, ROOM_LIMITS, packet, mergeInputs };

if (require.main === module) {
  const relay = createRelay(readConfig());
  relay.listen().then((address) => {
    const where = typeof address === 'string' ? address : `${address.address}:${address.port}`;
    console.log(`OpenLF2 relay listening on ${where}, WebSocket path ${relay.config.path}`);
    if (!relay.config.allowedOrigins.length) {
      console.log('ALLOWED_ORIGINS is empty: any website may use this relay. Set it to your game page origin.');
    }
  }).catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
  const stop = () => relay.close().then(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

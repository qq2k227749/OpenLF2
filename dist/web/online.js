// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors
//
// Network play in the browser.
//
// Browsers cannot open TCP sockets, so the web build's network transport
// (src/adapters/web/transport.cpp) hands the game's byte stream to this script, which carries it
// over a WebSocket to a relay server where up to 8 players meet in a room named by a numeric code
// (tools/relay, protocol 2: the relay keeps the beat, see scripts/base/game/room.lua).
//
// In the game, Network Game > Host opens this page's room. Network Game > Connect joins the room
// typed into the address field, or this page's room when the field is left empty (an invite link
// sets it). The host starts the game once everyone is in. All players need the same relay and the
// same OpenLF2 build.
//
// Messages returned to the game are short ASCII English: the game draws them with its bitmap font.
(function (root) {
  'use strict';

  const STATUS = Object.freeze({ idle: 0, listening: 1, connecting: 2, connected: 3 });
  const ROOM_PATTERN = /^\d{4,12}$/;
  const SEND_LIMIT = 65536; // the TCP transport's send queue limit
  const OPEN = 1; // WebSocket.OPEN
  const STORAGE = Object.freeze({ relay: 'openlf2-relay', room: 'openlf2-room' });
  // The relay's close codes (tools/relay/server.js), for proxies that drop the close reason.
  const CLOSE_REASONS = Object.freeze({
    4000: 'Relay: bad request',
    4001: 'Relay: this website may not use the relay',
    4002: 'Relay: too many connections from your network',
    4003: 'Relay: server is full',
    4004: 'Relay: room is taken',
    4005: 'Relay: nobody joined in time',
    4006: 'Relay: the other player left',
    4007: 'Relay: too much traffic',
    4008: 'Relay: the other player stopped reading',
    4009: 'Relay: data sent before pairing',
    4010: 'Relay: the room is full',
    4011: 'Relay: the game in this room has already started',
    4012: 'Relay: this room plays another game version or mod',
    4013: 'Relay: the host left the room',
    4014: 'Relay: the host did not start the game in time',
    4015: 'Relay: unexpected message from the game',
    4016: 'Relay: your connection is too slow for the game',
    4017: 'Relay: this room code is in use by another game page',
  });
  // A relay that only pairs two players (protocol 1) answers with these instead of a welcome.
  const OUTDATED_RELAY = 'Relay: this relay is too old for this game page; update it (install-vps.sh)';

  class OnlineTransport {
    constructor(options = {}) {
      this.WebSocket = options.WebSocket || root.WebSocket;
      this.pageProtocol = options.pageProtocol || (root.location && root.location.protocol) || '';
      this.relay = '';
      this.room = '';
      this.pack = ''; // the game pack (mod) this page plays, for invite links; set by the page
      this.setRelay(options.relay);
      this.setRoom(options.room);
      this.listeners = new Set();
      this.lastFailure = ''; // kept for the panel after the game has closed the failed connection
      this.reset();
    }

    reset() {
      this.socket = null;
      this.state = STATUS.idle;
      this.failure = ''; // why the connection ended; reported after the bytes received before it
      this.sendError = '';
      this.chunks = [];
      this.offset = 0; // read position inside chunks[0]
      this.buffered = 0;
      this.activeRoom = '';
      this.role = '';
      this.opened = false;
      this.players = 0; // in the room, from the relay's notes for this panel
      this.started = false;
    }

    // Accepts what people paste: wss://host/relay as printed by the installer, but also the
    // https:// address of the relay or a bare host name, which become wss://.
    setRelay(value) {
      let relay = String(value || '').trim();
      if (relay && !/^[a-z][a-z0-9+.-]*:\/\//i.test(relay)) relay = 'wss://' + relay;
      this.relay = relay.replace(/^https:\/\//i, 'wss://').replace(/^http:\/\//i, 'ws://');
    }
    setRoom(value) { this.room = String(value || '').replace(/\D/g, '').slice(0, 12); }

    // Where the relay keeps its copy of the LF2 installer (installer-store.js tries it before archive.org):
    // wss://host/relay -> https://host/lf2-installer.data. Empty without a relay.
    installerUrl() { return this.relayFile('lf2-installer.data'); }
    // The relay's game packs (mods, tools/relay/packs.js): the list, and one pack by id.
    packsUrl() { return this.relayFile('lf2-packs.json'); }
    packUrl(id) { return this.relayFile('lf2-packs/' + encodeURIComponent(id) + '.zip'); }

    // A file beside the relay's WebSocket path, over HTTP(S). Empty without a relay.
    relayFile(name) {
      let url;
      try { url = new URL(this.relay); } catch (error) { return ''; }
      if (url.protocol !== 'wss:' && url.protocol !== 'ws:') return '';
      url.protocol = url.protocol === 'ws:' ? 'http:' : 'https:';
      url.pathname = url.pathname.replace(/[^/]*$/, '') + name;
      url.search = '';
      url.hash = '';
      return url.href;
    }

    // ---- The game's side (src/adapters/web/transport.cpp) ---------------------------------------

    // Starts hosting (host = true) or joining. Returns false with error() set when it cannot start.
    start(host, address) {
      this.close();
      this.lastFailure = '';
      const typed = String(address || '').trim();
      if (!host && typed.includes('.')) return this.fail('Network: type the room code, not an IP address');
      const room = host ? this.room : typed || this.room;
      if (!ROOM_PATTERN.test(room)) {
        return this.fail(host ? 'Network: set a room code (4-12 digits) above the game'
          : 'Network: type the room code (4-12 digits)');
      }
      let url;
      try { url = new URL(this.relay); } catch (error) { return this.fail('Network: set the relay address above the game'); }
      if (url.protocol !== 'wss:' && url.protocol !== 'ws:') return this.fail('Network: the relay address must start with wss://');
      if (url.protocol === 'ws:' && this.pageProtocol === 'https:' && !isLoopback(url.hostname)) {
        return this.fail('Network: this https page needs a wss:// relay address');
      }
      if (typeof this.WebSocket !== 'function') return this.fail('Network: this browser has no WebSocket support');
      url.searchParams.set('v', '2');
      url.searchParams.set('role', host ? 'host' : 'join');
      url.searchParams.set('room', room);
      let socket;
      try {
        socket = new this.WebSocket(url.href);
      } catch (error) {
        return this.fail('Network: cannot open the relay address');
      }
      socket.binaryType = 'arraybuffer';
      this.socket = socket;
      this.state = host ? STATUS.listening : STATUS.connecting;
      this.activeRoom = room;
      this.role = host ? 'host' : 'join';
      socket.onopen = () => { if (socket === this.socket) this.opened = true; };
      socket.onmessage = (event) => this.onMessage(socket, event);
      socket.onclose = (event) => this.onClose(socket, event);
      // Browsers follow an error with a close event that carries the details. Some WebSocket
      // implementations (Node's) never send that close after a failed connection, so an error
      // that is not followed by a close soon counts as one.
      socket.onerror = () => {
        setTimeout(() => {
          if (socket !== this.socket) return;
          try { socket.close(); } catch (error) { /* not open */ }
          this.onClose(socket, { code: 1006, reason: '' });
        }, 250);
      };
      this.emit();
      return true;
    }

    // Queues bytes for the relay. Returns false with error() set when it cannot.
    send(bytes) {
      this.sendError = '';
      const socket = this.socket;
      if (!socket || this.state !== STATUS.connected || socket.readyState !== OPEN) {
        this.sendError = 'Network peer is not connected';
        return false;
      }
      if (socket.bufferedAmount + bytes.length > SEND_LIMIT) {
        this.sendError = 'Network send queue exceeds 64 KiB';
        return false;
      }
      socket.send(bytes);
      return true;
    }

    // Received bytes waiting to be taken; -1 once the connection has failed and nothing is left.
    available() {
      if (this.buffered > 0) return this.buffered;
      return this.failure ? -1 : 0;
    }

    // Moves up to `capacity` received bytes into `target` at `offset`; returns how many.
    takeInto(target, offset, capacity) {
      const size = Math.min(capacity, this.buffered);
      let written = 0;
      while (written < size) {
        const chunk = this.chunks[0];
        const count = Math.min(chunk.length - this.offset, size - written);
        target.set(chunk.subarray(this.offset, this.offset + count), offset + written);
        written += count;
        this.offset += count;
        if (this.offset === chunk.length) {
          this.chunks.shift();
          this.offset = 0;
        }
      }
      this.buffered -= size;
      return size;
    }

    take(capacity) {
      const bytes = new Uint8Array(Math.min(capacity, this.buffered));
      this.takeInto(bytes, 0, bytes.length);
      return bytes;
    }

    status() { return this.state; }
    error() { return this.failure || this.sendError; }

    close() {
      const socket = this.socket;
      if (socket) {
        socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
        try { socket.close(1000, 'closed'); } catch (error) { /* already closing */ }
      }
      const changed = this.state !== STATUS.idle || this.failure;
      this.reset();
      if (changed) this.emit();
    }

    // ---- Socket events ------------------------------------------------------------------------

    onMessage(socket, event) {
      if (socket !== this.socket) return;
      if (typeof event.data === 'string') {
        let message;
        try { message = JSON.parse(event.data); } catch (error) { return; }
        if (!message) return;
        if (message.t === 'welcome' && message.v === 2 && this.state !== STATUS.connected) {
          this.state = STATUS.connected;
          this.emit();
        } else if (message.t === 'room') {
          this.players = Number(message.players) || 0;
          this.started = message.started === true;
          this.emit();
        } else if (message.t === 'waiting' || message.t === 'paired') {
          this.fail(OUTDATED_RELAY);
        }
        return;
      }
      const bytes = new Uint8Array(event.data);
      if (!bytes.length) return;
      this.chunks.push(bytes);
      this.buffered += bytes.length;
    }

    onClose(socket, event) {
      if (socket !== this.socket) return;
      this.socket = null;
      this.state = STATUS.idle;
      this.failure = event.reason || CLOSE_REASONS[event.code]
        || (this.opened ? 'Network: lost the connection to the relay' : 'Network: cannot reach the relay');
      this.lastFailure = this.failure;
      this.emit();
    }

    fail(message) {
      const socket = this.socket;
      if (socket) {
        socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
        try { socket.close(1000, 'closed'); } catch (error) { /* already closing */ }
      }
      this.reset();
      this.failure = this.lastFailure = message;
      this.emit();
      return false;
    }

    // ---- Page side ----------------------------------------------------------------------------

    onChange(listener) {
      this.listeners.add(listener);
      return () => this.listeners.delete(listener);
    }

    emit() {
      for (const listener of this.listeners) {
        try { listener(this); } catch (error) { /* a broken panel must not break the game */ }
      }
    }
  }

  function isLoopback(hostname) {
    return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname.endsWith('.localhost');
  }

  function randomRoom() {
    const value = new Uint32Array(1);
    root.crypto.getRandomValues(value);
    return String(100000 + (value[0] % 900000));
  }

  function storageGet(key) {
    try { return root.localStorage.getItem(key); } catch (error) { return null; }
  }
  function storageSet(key, value) {
    try {
      if (value) root.localStorage.setItem(key, value);
      else root.localStorage.removeItem(key);
    } catch (error) { /* private mode: settings last for this visit only */ }
  }

  // The panel above the game: room code, invite link, relay address and connection status.
  function createPanel(online, document) {
    const stage = document.getElementById('stage') || document.getElementById('canvas');
    if (!stage || !stage.parentNode) return;
    const panel = document.createElement('section');
    panel.id = 'online';
    panel.setAttribute('aria-label', 'Online play');
    panel.innerHTML = `
      <style>
        #online { box-sizing: border-box; margin: .75rem 0; padding: .65rem .8rem;
          border: 1px solid rgba(127, 127, 127, .4); border-radius: 8px; font-size: .9rem; }
        #online .row { display: flex; flex-wrap: wrap; align-items: center; gap: .45rem .6rem; margin: .3rem 0; }
        #online label { display: flex; align-items: center; gap: .4rem; min-width: 0; }
        #online input { font: inherit; padding: .3rem .45rem; min-width: 0; box-sizing: border-box; }
        #online-room { width: 8.5rem; letter-spacing: .08em; }
        #online .relay { flex: 1 1 18rem; }
        #online-relay { flex: 1 1 auto; width: 100%; }
        #online button { padding: .35rem .7rem; cursor: pointer; }
        #online .help { margin: .35rem 0 0; opacity: .8; font-size: .85rem; }
        #online-status[data-state="connected"] { color: #5fd38d; }
        #online-status[data-state="failed"] { color: #ff8a80; }
      </style>
      <div class="row"><strong>Online play</strong><span id="online-status" role="status"></span></div>
      <div class="row">
        <label>Room <input id="online-room" inputmode="numeric" pattern="[0-9]*" maxlength="12" autocomplete="off"></label>
        <button type="button" id="online-new">New room</button>
        <button type="button" id="online-copy">Copy invite link</button>
      </div>
      <div class="row">
        <label class="relay">Relay <input id="online-relay" type="url" placeholder="wss://relay.example.com/relay" autocomplete="off" spellcheck="false"></label>
        <span id="online-relay-check"></span>
      </div>
      <p class="help">Host: <b>Network Game &rarr; Host</b>, then <b>START</b> once everyone is in (2 to 8 players).
        Friends: open your invite link, then <b>Network Game &rarr; Connect</b> with the address left empty (or type the room code).
        Everyone needs the same game version.</p>`;
    stage.parentNode.insertBefore(panel, stage);
    // As wide as the game: the bundle page caps the canvas width, the project site does not.
    const canvas = document.getElementById('canvas');
    const widest = canvas && root.getComputedStyle ? root.getComputedStyle(canvas).maxWidth : 'none';
    if (widest && widest !== 'none') panel.style.maxWidth = widest;

    // SDL listens for keys on the window; keep typing in these fields out of the game.
    for (const type of ['keydown', 'keyup', 'keypress']) panel.addEventListener(type, (event) => event.stopPropagation());

    const $ = (id) => panel.querySelector('#' + id);
    const status = $('online-status');
    const roomInput = $('online-room');
    const relayInput = $('online-relay');
    const relayCheck = $('online-relay-check');
    roomInput.value = online.room;
    relayInput.value = online.relay;

    const render = () => {
      const room = online.activeRoom || online.room;
      let text;
      let state = 'idle';
      const players = online.players === 1 ? '1 player' : `${online.players} players`;
      if (online.state === STATUS.connected && online.started) { text = `Playing in room ${room} (${players}).`; state = 'connected'; }
      else if (online.state === STATUS.connected && online.role === 'host') {
        text = `Hosting room ${room}: ${players} in. Press START in the game when everyone is here.`;
        state = 'connected';
      } else if (online.state === STATUS.connected) {
        text = `In room ${room} (${players}): waiting for the host to start.`;
        state = 'connected';
      } else if (online.state === STATUS.listening) text = `Opening room ${room}...`;
      else if (online.state === STATUS.connecting) text = `Joining room ${room}...`;
      else if (online.lastFailure) { text = online.lastFailure; state = 'failed'; }
      else text = online.relay ? `Not connected. Your room: ${online.room}` : 'Set a relay address to play online.';
      status.textContent = text;
      status.dataset.state = state;
    };
    online.onChange(render);

    roomInput.addEventListener('input', () => {
      online.setRoom(roomInput.value);
      if (roomInput.value !== online.room) roomInput.value = online.room;
      storageSet(STORAGE.room, online.room);
      render();
    });
    $('online-new').addEventListener('click', () => {
      online.setRoom(randomRoom());
      roomInput.value = online.room;
      storageSet(STORAGE.room, online.room);
      render();
    });
    $('online-copy').addEventListener('click', async () => {
      const link = new URL(root.location.href);
      link.searchParams.set('room', online.room);
      if (online.relay) link.searchParams.set('relay', online.relay);
      // Friends play the same game: the original, or the same mod.
      if (online.pack) link.searchParams.set('pack', online.pack);
      else link.searchParams.delete('pack');
      // The project site shows the game further down the page, in its "play" section.
      link.hash = document.getElementById('play') ? 'play' : '';
      const button = $('online-copy');
      try {
        await root.navigator.clipboard.writeText(link.href);
        button.textContent = 'Link copied';
      } catch (error) {
        root.prompt('Send this link to your friend:', link.href);
      }
      setTimeout(() => { button.textContent = 'Copy invite link'; }, 2000);
    });

    let checkTimer = 0;
    const checkRelay = async () => {
      relayCheck.textContent = '';
      if (!online.relay) return;
      let health;
      try {
        health = new URL(online.relay);
        health.protocol = health.protocol === 'ws:' ? 'http:' : 'https:';
        health.pathname = health.pathname.replace(/[^/]*$/, 'healthz'); // /relay -> /healthz
        health.search = '';
      } catch (error) {
        relayCheck.textContent = 'invalid address';
        return;
      }
      const checked = online.relay;
      const request = () => fetch(health.href, {
        cache: 'no-store',
        signal: typeof AbortSignal !== 'undefined' && AbortSignal.timeout ? AbortSignal.timeout(5000) : undefined,
      });
      try {
        const first = await request();
        if (!first.ok) throw new Error('status ' + first.status);
        let info = {};
        try { info = await first.json(); } catch (error) { /* an older relay: no details */ }
        // Later requests reuse the connection, so the quickest of them is close to the ping.
        let ping = Infinity;
        for (let attempt = 0; attempt < 3; attempt += 1) {
          const started = performance.now();
          await request();
          ping = Math.min(ping, Math.round(performance.now() - started));
        }
        if (checked === online.relay) {
          const current = info && Array.isArray(info.protocols) && info.protocols.includes(2);
          relayCheck.textContent = current ? `relay OK, ${ping} ms${info.installer ? ', game data ready' : ''}`
            : 'relay too old: update it (install-vps.sh)';
          relayCheck.title = 'Your own keys take effect about one ping (plus up to 33 ms) after you press them; '
            + 'a player far from the relay never slows the others down.';
        }
      } catch (error) {
        if (checked === online.relay) relayCheck.textContent = 'relay unreachable';
      }
    };
    relayInput.addEventListener('input', () => {
      online.setRelay(relayInput.value);
      storageSet(STORAGE.relay, online.relay);
      render();
      clearTimeout(checkTimer);
      checkTimer = setTimeout(checkRelay, 700);
    });
    render();
    checkRelay();
  }

  const api = { OnlineTransport, STATUS, ROOM_PATTERN, CLOSE_REASONS };
  if (typeof module === 'object' && module.exports) {
    module.exports = api; // tests
    return;
  }

  // Page start: an invite link's ?room= and ?relay= win, then this browser's saved choices,
  // then a relay the site sets with  <script>window.OPENLF2_RELAY = 'wss://...'</script>.
  let params;
  try { params = new URLSearchParams(root.location.search); } catch (error) { params = new URLSearchParams(); }
  const linkedRoom = (params.get('room') || '').replace(/\D/g, '').slice(0, 12);
  const linkedRelay = (params.get('relay') || '').trim();
  if (linkedRoom) storageSet(STORAGE.room, linkedRoom);
  if (linkedRelay) storageSet(STORAGE.relay, linkedRelay);
  const online = new OnlineTransport({
    room: linkedRoom || storageGet(STORAGE.room) || randomRoom(),
    relay: linkedRelay || storageGet(STORAGE.relay) || root.OPENLF2_RELAY || '',
  });
  if (!storageGet(STORAGE.room)) storageSet(STORAGE.room, online.room);
  root.OpenLF2Online = online;
  if (root.document) {
    const build = () => createPanel(online, root.document);
    if (root.document.readyState === 'loading') root.document.addEventListener('DOMContentLoaded', build);
    else build();
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);

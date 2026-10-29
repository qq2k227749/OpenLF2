// SPDX-License-Identifier: MIT
//
// The game page's side of the relay's installer copy: online.js computes where it is, and
// installer-store.js downloads it before archive.org, checking size and SHA-256 either way.
// installer-store.js is a browser script; here it runs in a context with a stand-in fetch.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const { OnlineTransport } = require('./helpers.js');

const repository = path.join(__dirname, '..', '..', '..');
const storeSource = fs.readFileSync(path.join(repository, 'dist', 'web', 'installer-store.js'), 'utf8');
const ARCHIVE = 'https://archive.org/download/little-fighter-2_202404/Little%20Fighter%202.rar/Little%20Fighter%202%2FLF2Setup.exe';

// Loads installer-store.js with `fetch` answering from `routes` (url -> Uint8Array | number status | Error).
function loadStore(routes, online) {
  const requested = [];
  const context = vm.createContext({
    URL, Blob, crypto: globalThis.crypto, Uint8Array, Array, Error, console,
    indexedDB: undefined,
    OpenLF2Online: online,
    fetch: async (url) => {
      requested.push(url);
      const answer = routes[url];
      if (answer instanceof Error) throw answer; // as when a download manager takes the request over
      if (typeof answer === 'number' || answer === undefined) return new Response(null, { status: answer || 404 });
      return new Response(answer, { status: 200 });
    },
  });
  vm.runInContext(`${storeSource}\nglobalThis.installerDownload = installerDownload;`, context);
  return { download: context.installerDownload, requested };
}

const file = new Uint8Array(crypto.randomBytes(150000));
const expected = { size: file.length, sha256: crypto.createHash('sha256').update(file).digest('hex') };

test('online.js puts the installer copy beside the relay', () => {
  const online = new OnlineTransport({});
  const cases = [
    ['wss://203-0-113-5.sslip.io/relay', 'https://203-0-113-5.sslip.io/lf2-installer.data'],
    ['wss://203-0-113-5.sslip.io', 'https://203-0-113-5.sslip.io/lf2-installer.data'],
    ['ws://localhost:8787/relay', 'http://localhost:8787/lf2-installer.data'],
    ['wss://example.com/games/relay?x=1', 'https://example.com/games/lf2-installer.data'],
    ['', ''],
  ];
  for (const [relay, url] of cases) {
    online.setRelay(relay);
    assert.equal(online.installerUrl(), url, relay);
  }
});

test('the relay copy is used first, and archive.org is not asked', async () => {
  const online = new OnlineTransport({ relay: 'wss://203-0-113-5.sslip.io/relay' });
  const copy = online.installerUrl();
  const { download, requested } = loadStore({ [copy]: file, [ARCHIVE]: new Error('should not be asked') }, online);
  const progress = [];
  const blob = await download((received, total, source) => progress.push([received, total, source]), expected);
  assert.equal(blob.size, file.length);
  assert.deepEqual(requested, [copy]);
  assert.equal(progress.at(-1)[0], file.length);
  assert.equal(progress.at(-1)[2], '203-0-113-5.sslip.io', 'the page names where the data comes from');
});

test('without a usable relay copy the page falls back to archive.org', async () => {
  const online = new OnlineTransport({ relay: 'wss://203-0-113-5.sslip.io/relay' });
  const copy = online.installerUrl();
  for (const answer of [404, new Error('Failed to fetch'), new Uint8Array(crypto.randomBytes(file.length))]) {
    const { download, requested } = loadStore({ [copy]: answer, [ARCHIVE]: file }, online);
    const blob = await download(() => {}, expected);
    assert.equal(blob.size, file.length);
    assert.deepEqual(requested, [copy, ARCHIVE]);
  }
  const noRelay = loadStore({ [ARCHIVE]: file }, new OnlineTransport({}));
  await noRelay.download(() => {}, expected);
  assert.deepEqual(noRelay.requested, [ARCHIVE]);
  const noOnline = loadStore({ [ARCHIVE]: file }, undefined);
  await noOnline.download(() => {}, expected);
  assert.deepEqual(noOnline.requested, [ARCHIVE]);
});

test('when every source fails, the error names each one', async () => {
  const online = new OnlineTransport({ relay: 'wss://203-0-113-5.sslip.io/relay' });
  const { download } = loadStore({ [online.installerUrl()]: 503, [ARCHIVE]: new Error('Failed to fetch') }, online);
  await assert.rejects(download(() => {}, expected), /203-0-113-5\.sslip\.io: HTTP 503; archive\.org: Failed to fetch/);
});

test('the page keeps the real installer\'s size and checksum by default', () => {
  assert.match(storeSource, /options\.size \|\| 29586263/);
  assert.match(storeSource, /options\.sha256 \|\| '540c485547e234b0d09595f54d067aafd7176092c308aca61868f3cbc03030e1'/);
  const installer = fs.readFileSync(path.join(__dirname, '..', 'install-vps.sh'), 'utf8');
  assert.match(installer, /LF2_DATA_SIZE:-29586263/, 'the relay keeps the file the page accepts');
  assert.match(installer, /LF2_DATA_SHA256:-540c485547e234b0d09595f54d067aafd7176092c308aca61868f3cbc03030e1/);
});

test('set-relay.py gives the built page a default relay address', () => {
  const os = require('node:os');
  const script = path.join(repository, 'dist', 'pages', 'set-relay.py');
  const page = path.join(repository, 'dist', 'pages', 'index.html');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-page-'));
  const run = (address) => {
    const copy = path.join(dir, 'index.html');
    fs.copyFileSync(page, copy);
    const output = execFileSync('python3', [script, copy, address], { encoding: 'utf8' });
    return { output, html: fs.readFileSync(copy, 'utf8') };
  };
  try {
    for (const [typed, address] of [
      ['wss://203-0-113-5.sslip.io/relay', 'wss://203-0-113-5.sslip.io/relay'],
      [' https://203-0-113-5.sslip.io/relay ', 'wss://203-0-113-5.sslip.io/relay'],
      ['203-0-113-5.sslip.io', 'wss://203-0-113-5.sslip.io/relay'],
    ]) {
      const { html } = run(typed);
      assert.ok(html.includes(`<script>window.OPENLF2_RELAY = '${address}';</script>\n<script src="online.js"></script>`), typed);
    }
    const unchanged = run('');
    assert.equal(unchanged.html, fs.readFileSync(page, 'utf8'));
    assert.throws(() => run("wss://x.example/relay';alert(1)//"), /must look like/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

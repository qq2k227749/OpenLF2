// SPDX-License-Identifier: MIT
//
// Game packs: what an upload keeps, the admin API, and serving packs to game pages.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { createRelay } = require('../server.js');
const { readZip, analyzeZip, writeZip } = require('../packs.js');

// A ZIP file from [name, content] pairs (Deflate, or stored when `stored` is set).
function makeZip(files, { stored = false } = {}) {
  const locals = [];
  const records = [];
  let offset = 0;
  for (const [name, content] of files) {
    const data = Buffer.from(content);
    const packed = stored ? data : zlib.deflateRawSync(data);
    const nameBytes = Buffer.from(name, 'latin1');
    const crc = zlib.crc32 ? zlib.crc32(data) : 0;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(stored ? 0 : 8, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(packed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    locals.push(local, nameBytes, packed);
    const record = Buffer.alloc(46);
    record.writeUInt32LE(0x02014b50, 0);
    record.writeUInt16LE(20, 4);
    record.writeUInt16LE(20, 6);
    record.writeUInt16LE(stored ? 0 : 8, 10);
    record.writeUInt32LE(crc, 16);
    record.writeUInt32LE(packed.length, 20);
    record.writeUInt32LE(data.length, 24);
    record.writeUInt16LE(nameBytes.length, 28);
    record.writeUInt32LE(offset, 42);
    records.push(record, nameBytes);
    offset += 30 + nameBytes.length + packed.length;
  }
  const directory = Buffer.concat(records);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

// A mod as people zip it: a folder with the game, notes, recordings and an older copy of the game inside.
const MOD = [
  ['My Mod/OPGW.exe', 'MZ big game program'.repeat(50)],
  ['My Mod/setup.exe', 'MZ'],
  ['My Mod/readme.txt', 'moves'],
  ['My Mod/movelist.swf', 'swf'],
  ['My Mod/data/data.txt', '<object> id: 1 type: 0 file: data\\a.dat'],
  ['My Mod/data/a.dat', 'x'.repeat(500)],
  ['My Mod/sprite/sys/a.bmp', 'BM'.repeat(300)],
  ['My Mod/bgm/main.wma', 'music'],
  ['My Mod/bg/sys/lf/bg.dat', 'bg'],
  ['My Mod/so/voice.wav', 'RIFF'],
  ['My Mod/recording/1.lfr', 'replay'],
  ['My Mod/Old/OPGW.exe', 'MZ old'],
  ['My Mod/Old/data/data.txt', 'old'],
  ['My Mod/Old/bgm/main.wma', 'old music'],
];
const KEPT = ['My Mod/OPGW.exe', 'My Mod/data/data.txt', 'My Mod/data/a.dat', 'My Mod/sprite/sys/a.bmp',
  'My Mod/bgm/main.wma', 'My Mod/bg/sys/lf/bg.dat', 'My Mod/so/voice.wav'];

function scratch() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-packs-'));
}

test('an upload keeps the game folder and its program, not notes, recordings or another copy', async () => {
  const dir = scratch();
  try {
    const source = path.join(dir, 'mod.zip');
    fs.writeFileSync(source, makeZip(MOD));
    const zip = await readZip(source);
    const analysis = analyzeZip(zip.entries);
    assert.equal(analysis.root, 'my mod/');
    assert.equal(analysis.executable, 'opgw.exe');
    assert.deepEqual(analysis.keep.map((entry) => entry.name), KEPT);
    const target = path.join(dir, 'pack.zip');
    const written = await writeZip(source, target, analysis.keep);
    assert.equal(written.files, KEPT.length);
    assert.equal(written.sha256, crypto.createHash('sha256').update(fs.readFileSync(target)).digest('hex'));
    // The new file is a valid ZIP whose entries still unpack to the same bytes.
    const again = await readZip(target);
    assert.deepEqual(again.entries.map((entry) => entry.name), KEPT);
    const bytes = fs.readFileSync(target);
    for (const entry of again.entries) {
      const nameLength = bytes.readUInt16LE(entry.localOffset + 26);
      const extraLength = bytes.readUInt16LE(entry.localOffset + 28);
      const start = entry.localOffset + 30 + nameLength + extraLength;
      const data = zlib.inflateRawSync(bytes.subarray(start, start + entry.compressedSize));
      assert.equal(data.toString(), MOD.find(([name]) => name === entry.name)[1]);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('files that are not a game are refused with a reason', async () => {
  const dir = scratch();
  try {
    const cases = [
      [Buffer.from('not a zip at all'), /not a ZIP/],
      [makeZip([['game/readme.txt', 'hi']]), /data\/data\.txt/],
      [makeZip([['game/data/data.txt', 'x']]), /\.exe/],
    ];
    for (const [bytes, reason] of cases) {
      const file = path.join(dir, 'x.zip');
      fs.writeFileSync(file, bytes);
      await assert.rejects(async () => analyzeZip((await readZip(file)).entries), reason);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

async function startRelay(overrides) {
  const relay = createRelay({ quiet: true, ...overrides });
  const address = await relay.listen(0, '127.0.0.1');
  relay.http = `http://127.0.0.1:${address.port}`;
  return relay;
}

test('the admin uploads, lists and removes packs; pages list and download them', async () => {
  const dir = scratch();
  const relay = await startRelay({ packsDir: dir, adminKey: 'secret-key', packDownloadsPerHour: 2, allowedOrigins: ['https://game.example'] });
  try {
    const page = await fetch(`${relay.http}/admin`);
    assert.equal(page.status, 200);
    assert.match(await page.text(), /Bản mod cho OpenLF2/);
    const body = makeZip(MOD);
    const put = (key, id = 'my-mod') => fetch(`${relay.http}/admin/api/packs/${id}?title=${encodeURIComponent('My Mod: One Piece')}`, {
      method: 'PUT', headers: { 'x-admin-key': key, 'content-type': 'application/zip' }, body,
    });
    assert.equal((await put('wrong')).status, 401);
    assert.equal((await put('secret-key', 'Bad_Id')).status, 400);
    const uploaded = await put('secret-key');
    assert.equal(uploaded.status, 200);
    const result = await uploaded.json();
    assert.equal(result.files, KEPT.length);
    assert.equal(result.dropped, MOD.length - KEPT.length);
    assert.equal(result.title, 'My Mod: One Piece');
    assert.deepEqual(fs.readdirSync(dir).sort(), ['my-mod.json', 'my-mod.zip']);

    const listed = await (await fetch(`${relay.http}/lf2-packs.json`)).json();
    assert.deepEqual(listed, { packs: [{ id: 'my-mod', title: 'My Mod: One Piece', size: result.size, sha256: result.sha256 }] });
    const download = await fetch(`${relay.http}/lf2-packs/my-mod.zip`, { headers: { origin: 'https://game.example' } });
    assert.equal(download.status, 200);
    assert.equal(download.headers.get('access-control-allow-origin'), 'https://game.example');
    const bytes = Buffer.from(await download.arrayBuffer());
    assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), result.sha256);
    assert.equal((await fetch(`${relay.http}/lf2-packs/my-mod.zip`)).status, 200);
    assert.equal((await fetch(`${relay.http}/lf2-packs/my-mod.zip`)).status, 429, 'downloads per hour are limited');
    assert.equal((await fetch(`${relay.http}/lf2-packs/other.zip`)).status, 404);

    const admin = await (await fetch(`${relay.http}/admin/api/packs`, { headers: { 'x-admin-key': 'secret-key' } })).json();
    assert.equal(admin.packs[0].original.files, MOD.length);
    const removed = await fetch(`${relay.http}/admin/api/packs/my-mod`, { method: 'DELETE', headers: { 'x-admin-key': 'secret-key' } });
    assert.equal(removed.status, 200);
    assert.deepEqual(await (await fetch(`${relay.http}/lf2-packs.json`)).json(), { packs: [] });
  } finally {
    await relay.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('uploads are refused without a key on the relay, beyond the size limit, and after many wrong keys', async () => {
  const dir = scratch();
  const noKey = await startRelay({ packsDir: dir });
  try {
    const response = await fetch(`${noKey.http}/admin/api/packs/x`, { method: 'PUT', headers: { 'x-admin-key': '' }, body: 'x' });
    assert.equal(response.status, 403);
  } finally { await noKey.close(); }
  const small = await startRelay({ packsDir: dir, adminKey: 'k', maxPackBytes: 100 });
  try {
    const response = await fetch(`${small.http}/admin/api/packs/x`, { method: 'PUT', headers: { 'x-admin-key': 'k' }, body: makeZip(MOD) });
    assert.equal(response.status, 413);
    for (let attempt = 0; attempt < 20; attempt += 1) {
      await fetch(`${small.http}/admin/api/packs`, { headers: { 'x-admin-key': 'guess' + attempt } });
    }
    assert.equal((await fetch(`${small.http}/admin/api/packs`, { headers: { 'x-admin-key': 'k' } })).status, 429);
    assert.deepEqual(fs.readdirSync(dir), [], 'nothing left behind');
  } finally {
    await small.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('behind a path prefix the packs and the admin page sit beside the relay path', async () => {
  const dir = scratch();
  const relay = await startRelay({ packsDir: dir, path: '/lf2-relay/relay' });
  try {
    assert.equal((await fetch(`${relay.http}/lf2-relay/lf2-packs.json`)).status, 200);
    assert.equal((await fetch(`${relay.http}/lf2-relay/admin`)).status, 200);
    assert.equal((await fetch(`${relay.http}/lf2-packs.json`)).status, 200);
  } finally {
    await relay.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

const MOD_ZIP = process.env.OPENLF2_MOD_ZIP || '/mnt/user-data/uploads/1793197712042_One_Piece_GrandWorld.zip';
test('a real mod: One Piece GrandWorld loses its old copy of the game', { skip: !fs.existsSync(MOD_ZIP) && 'no mod ZIP here' }, async () => {
  const zip = await readZip(MOD_ZIP);
  const analysis = analyzeZip(zip.entries);
  assert.equal(analysis.executable, 'opgw.exe');
  const kept = analysis.keep.reduce((sum, entry) => sum + entry.compressedSize, 0);
  assert.ok(kept < zip.size * 0.6, `kept ${kept} of ${zip.size} bytes`);
  assert.ok(analysis.keep.every((entry) => !/\/GrandWorld\//i.test(entry.name)));
  assert.ok(analysis.keep.some((entry) => /\/sprite\/sys\/luffy_0\.bmp$/i.test(entry.name)));
});

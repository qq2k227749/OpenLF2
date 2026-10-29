// SPDX-License-Identifier: MIT
//
// Game packs for the OpenLF2 relay: whole LF2 game folders as ZIP files (mods that come with their
// own lf2.exe, data, sprite, bgm and bg folders), which the web game plays instead of the original
// LF2 installer (the game's --pack option). The relay keeps them in PACKS_DIR and hands them to the
// game pages; whoever holds ADMIN_KEY adds and removes them on the page at /admin. An upload keeps
// only the game folder (the one holding data/data.txt nearest the top) without the copies of the
// game, recordings and notes that mods often carry, so that players download less.
//
//   GET  /lf2-packs.json             the packs: {"packs":[{"id","title","size","sha256"}]}
//   GET  /lf2-packs/<id>.zip         a pack
//   GET  /admin                      the page to manage them
//   GET  /admin/api/packs            the same list, with details (X-Admin-Key)
//   PUT  /admin/api/packs/<id>?title=<title>   upload a ZIP file as the body (X-Admin-Key)
//   DELETE /admin/api/packs/<id>     remove one (X-Admin-Key)
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { pipeline } = require('node:stream/promises');
const { Transform } = require('node:stream');

const PACK_ID = /^[a-z0-9][a-z0-9-]{0,39}$/;
const MIB = 1024 * 1024;
// Files beside the game that no game reads: notes, archives, videos, shortcuts.
const NOTES = /\.(txt|nfo|doc|docx|pdf|rtf|htm|html|url|lnk|swf|rar|zip|7z|lfr|mp4|avi|wmv|jpg|jpeg|gif)$/i;

class PackError extends Error {}

// The central directory of a ZIP file: its entries with their raw records.
async function readZip(file) {
  const handle = await fsp.open(file, 'r');
  try {
    const { size } = await handle.stat();
    if (size < 22) throw new PackError('this is not a ZIP file');
    if (size > 0xffffffff) throw new PackError('ZIP files over 4 GiB are not supported');
    const tailSize = Math.min(size, 22 + 65535);
    const tail = Buffer.alloc(tailSize);
    await handle.read(tail, 0, tailSize, size - tailSize);
    let end = -1;
    for (let at = tailSize - 22; at >= 0; at -= 1) {
      if (tail.readUInt32LE(at) === 0x06054b50 && at + 22 + tail.readUInt16LE(at + 20) === tailSize) {
        end = at;
        break;
      }
    }
    if (end < 0) throw new PackError('this is not a ZIP file');
    const count = tail.readUInt16LE(end + 10);
    const directorySize = tail.readUInt32LE(end + 12);
    const directoryOffset = tail.readUInt32LE(end + 16);
    if (tail.readUInt16LE(end + 4) !== 0 || tail.readUInt16LE(end + 8) !== count) throw new PackError('split ZIP files are not supported');
    if (count === 0xffff || directorySize === 0xffffffff || directoryOffset === 0xffffffff) {
      throw new PackError('ZIP64 files are not supported');
    }
    if (directoryOffset + directorySize > size) throw new PackError('the ZIP file is damaged');
    const directory = Buffer.alloc(directorySize);
    await handle.read(directory, 0, directorySize, directoryOffset);
    const entries = [];
    for (let at = 0, index = 0; index < count; index += 1) {
      if (at + 46 > directory.length || directory.readUInt32LE(at) !== 0x02014b50) throw new PackError('the ZIP file is damaged');
      const nameLength = directory.readUInt16LE(at + 28);
      const length = 46 + nameLength + directory.readUInt16LE(at + 30) + directory.readUInt16LE(at + 32);
      if (at + length > directory.length) throw new PackError('the ZIP file is damaged');
      const flags = directory.readUInt16LE(at + 8);
      const name = directory.toString(flags & 0x800 ? 'utf8' : 'latin1', at + 46, at + 46 + nameLength);
      entries.push({
        name, flags, method: directory.readUInt16LE(at + 10),
        compressedSize: directory.readUInt32LE(at + 20), size: directory.readUInt32LE(at + 24),
        localOffset: directory.readUInt32LE(at + 42), record: Buffer.from(directory.subarray(at, at + length)),
      });
      at += length;
    }
    return { entries, size };
  } finally {
    await handle.close();
  }
}

// What of a ZIP file the game needs: the game folder (the one holding data/data.txt nearest the
// top) without other copies of the game inside it, recordings, notes and other programs.
function analyzeZip(entries) {
  const lower = (name) => name.replace(/\\/g, '/').toLowerCase();
  let root = null;
  for (const entry of entries) {
    const name = lower(entry.name);
    if (name === 'data/data.txt' || name.endsWith('/data/data.txt')) {
      const folder = name.slice(0, name.length - 'data/data.txt'.length);
      if (root === null || folder.length < root.length) root = folder;
    }
  }
  if (root === null) throw new PackError('no data/data.txt inside: this is not an LF2 game folder');
  const inside = [];
  for (const entry of entries) {
    const name = lower(entry.name);
    if (!name.startsWith(root) || name.endsWith('/') || name.length === root.length) continue;
    inside.push({ entry, path: name.slice(root.length) });
  }
  // Another copy of a game inside this one (a subfolder with its own data/data.txt).
  const copies = inside.filter(({ path: name }) => name !== 'data/data.txt' && name.endsWith('/data/data.txt'))
    .map(({ path: name }) => name.slice(0, name.length - 'data/data.txt'.length));
  const executables = inside.filter(({ path: name }) => !name.includes('/') && name.endsWith('.exe'));
  if (!executables.length) throw new PackError('no game program (.exe) beside its data folder');
  const main = executables.find(({ path: name }) => name === 'lf2.exe')
    || executables.reduce((largest, item) => (item.entry.size > largest.entry.size ? item : largest));
  const keep = [];
  for (const item of inside) {
    const name = item.path;
    const topLevel = !name.includes('/');
    if (copies.some((copy) => name.startsWith(copy))) continue;
    if (name.startsWith('recording/')) continue;
    if (topLevel && name.endsWith('.exe') && item !== main) continue;
    if (topLevel && NOTES.test(name)) continue;
    if (item.entry.flags & 1) throw new PackError(`${item.entry.name} is encrypted`);
    if (item.entry.method !== 0 && item.entry.method !== 8) {
      throw new PackError(`${item.entry.name} uses a compression the game cannot read (zip it again with Deflate)`);
    }
    if (item.entry.size > 64 * MIB) throw new PackError(`${item.entry.name} is larger than 64 MB`);
    keep.push(item.entry);
  }
  return { root, executable: main.path, keep, dropped: entries.length - keep.length };
}

// Writes the kept entries of `source` as a new ZIP file, copying their compressed bytes as they are.
async function writeZip(source, target, keep) {
  const input = await fsp.open(source, 'r');
  const output = await fsp.open(target, 'w');
  const hash = crypto.createHash('sha256');
  let offset = 0;
  const write = async (buffer) => {
    let done = 0;
    while (done < buffer.length) {
      const { bytesWritten } = await output.write(buffer, done, buffer.length - done, offset + done);
      done += bytesWritten;
    }
    hash.update(buffer);
    offset += buffer.length;
  };
  try {
    const records = [];
    for (const entry of keep) {
      const header = Buffer.alloc(30);
      await input.read(header, 0, 30, entry.localOffset);
      if (header.readUInt32LE(0) !== 0x04034b50) throw new PackError('the ZIP file is damaged');
      let length = 30 + header.readUInt16LE(26) + header.readUInt16LE(28) + entry.compressedSize;
      if (entry.flags & 8) { // a data descriptor follows the data
        const probe = Buffer.alloc(4);
        await input.read(probe, 0, 4, entry.localOffset + length);
        length += probe.readUInt32LE(0) === 0x08074b50 ? 16 : 12;
      }
      const record = Buffer.from(entry.record);
      record.writeUInt32LE(offset, 42);
      records.push(record);
      for (let copied = 0; copied < length;) {
        const chunk = Buffer.alloc(Math.min(4 * MIB, length - copied));
        const { bytesRead } = await input.read(chunk, 0, chunk.length, entry.localOffset + copied);
        if (!bytesRead) throw new PackError('the ZIP file is damaged');
        await write(chunk.subarray(0, bytesRead));
        copied += bytesRead;
      }
    }
    const directoryOffset = offset;
    for (const record of records) await write(record);
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50, 0);
    end.writeUInt16LE(records.length, 8);
    end.writeUInt16LE(records.length, 10);
    end.writeUInt32LE(offset - directoryOffset, 12);
    end.writeUInt32LE(directoryOffset, 16);
    await write(end);
    return { size: offset, sha256: hash.digest('hex'), files: records.length };
  } finally {
    await input.close();
    await output.close();
  }
}

function sameKey(given, expected) {
  const a = crypto.createHash('sha256').update(String(given || '')).digest();
  const b = crypto.createHash('sha256').update(String(expected)).digest();
  return crypto.timingSafeEqual(a, b);
}

function createPacks(config, { log, clientAddress, allowOrigin }) {
  const directory = config.packsDir;
  const downloads = new Map(); // client address -> { count, until }
  const failures = new Map(); // client address -> { count, until }
  let uploading = false;

  const json = (res, status, body, headers = {}) => {
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers });
    res.end(JSON.stringify(body));
  };
  const counted = (map, address, limit) => {
    const now = Date.now();
    let entry = map.get(address);
    if (!entry || entry.until <= now) {
      entry = { count: 0, until: now + 3600000 };
      map.set(address, entry);
    }
    return { over: limit > 0 && entry.count >= limit, add: () => { entry.count += 1; }, retry: Math.ceil((entry.until - now) / 1000) };
  };

  async function list() {
    if (!directory) return [];
    let names;
    try { names = await fsp.readdir(directory); } catch { return []; }
    const packs = [];
    for (const name of names) {
      if (!name.endsWith('.json')) continue;
      const id = name.slice(0, -5);
      if (!PACK_ID.test(id)) continue;
      try {
        const info = JSON.parse(await fsp.readFile(path.join(directory, name), 'utf8'));
        const stat = await fsp.stat(path.join(directory, `${id}.zip`));
        packs.push({ id, title: String(info.title || id), size: stat.size, sha256: String(info.sha256 || ''),
          files: info.files, uploaded: info.uploaded, original: info.original });
      } catch { /* a half-written or removed pack */ }
    }
    return packs.sort((a, b) => a.title.localeCompare(b.title));
  }

  function authorized(req, res) {
    if (!config.adminKey) {
      json(res, 403, { error: 'Chưa đặt ADMIN_KEY cho relay (chạy lại install-vps.sh).' });
      return false;
    }
    const address = clientAddress(req);
    const tries = counted(failures, address, 20);
    if (tries.over) {
      json(res, 429, { error: 'Sai mã quá nhiều lần, thử lại sau một giờ.' }, { 'retry-after': String(tries.retry) });
      return false;
    }
    if (!sameKey(req.headers['x-admin-key'], config.adminKey)) {
      tries.add();
      json(res, 401, { error: 'Sai mã quản trị (ADMIN_KEY).' });
      return false;
    }
    return true;
  }

  async function upload(req, res, id, title) {
    if (!directory) return json(res, 503, { error: 'Relay này không giữ bản mod (chưa đặt PACKS_DIR).' });
    if (uploading) return json(res, 409, { error: 'Đang có một lần tải lên khác, chờ xong rồi thử lại.' });
    const declared = Number(req.headers['content-length'] || 0);
    if (declared > config.maxPackBytes) {
      return json(res, 413, { error: `File quá lớn (tối đa ${Math.round(config.maxPackBytes / MIB)} MB).` });
    }
    await fsp.mkdir(directory, { recursive: true });
    try {
      const space = await fsp.statfs(directory);
      const free = space.bavail * space.bsize;
      if (free < 2 * declared + 256 * MIB) {
        return json(res, 507, { error: `VPS không đủ chỗ trống (còn ${Math.round(free / MIB)} MB).` });
      }
    } catch { /* statfs unavailable: try anyway */ }
    uploading = true;
    const nonce = crypto.randomBytes(6).toString('hex');
    const received = path.join(directory, `.upload-${nonce}.zip`);
    const slim = path.join(directory, `.pack-${nonce}.zip`);
    try {
      let bytes = 0;
      const counter = new Transform({
        transform(chunk, encoding, done) {
          bytes += chunk.length;
          if (bytes > config.maxPackBytes) done(new PackError(`File quá lớn (tối đa ${Math.round(config.maxPackBytes / MIB)} MB).`));
          else done(null, chunk);
        },
      });
      await pipeline(req, counter, fs.createWriteStream(received));
      if (declared && bytes !== declared) throw new PackError('Tải lên bị ngắt giữa chừng.');
      const zip = await readZip(received);
      const analysis = analyzeZip(zip.entries);
      const written = await writeZip(received, slim, analysis.keep);
      await fsp.rename(slim, path.join(directory, `${id}.zip`));
      const info = { title, sha256: written.sha256, files: written.files, executable: analysis.executable,
        uploaded: new Date().toISOString(), original: { size: bytes, files: zip.entries.length } };
      await fsp.writeFile(path.join(directory, `${id}.json`), JSON.stringify(info, null, 2));
      await fsp.rm(received, { force: true });
      log(`pack ${id}: ${bytes} bytes uploaded, ${written.size} kept (${written.files} files)`);
      json(res, 200, { ok: true, id, title, size: written.size, sha256: written.sha256, files: written.files,
        dropped: analysis.dropped, executable: analysis.executable, original: info.original });
    } catch (error) {
      await fsp.rm(received, { force: true });
      await fsp.rm(slim, { force: true });
      const message = error instanceof PackError ? error.message : 'Không lưu được file: ' + (error.message || error);
      if (!res.headersSent) json(res, error instanceof PackError ? 400 : 500, { error: message });
    } finally {
      uploading = false;
    }
  }

  async function servePack(req, res, id) {
    const headers = { 'x-content-type-options': 'nosniff', ...allowOrigin(req) };
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { ...headers, allow: 'GET, HEAD' });
      res.end();
      return;
    }
    const file = path.join(directory || '/nonexistent', `${id}.zip`);
    let stat;
    try { stat = await fsp.stat(file); } catch { stat = null; }
    if (!directory || !stat || !stat.isFile()) {
      res.writeHead(404, headers);
      res.end();
      return;
    }
    if (req.method === 'GET') {
      const quota = counted(downloads, clientAddress(req), config.packDownloadsPerHour);
      if (quota.over) {
        res.writeHead(429, { ...headers, 'retry-after': String(quota.retry) });
        res.end();
        return;
      }
      quota.add();
    }
    res.writeHead(200, { ...headers, 'content-type': 'application/zip', 'content-length': String(stat.size),
      'cache-control': 'no-cache' });
    if (req.method === 'HEAD') {
      res.end();
      return;
    }
    const stream = fs.createReadStream(file);
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  }

  // Returns true when the request was one of the packs' and has been answered (or is being answered).
  function handle(req, res, pathname) {
    if (pathname === '/lf2-packs.json') {
      list().then((packs) => json(res, 200, { packs: packs.map(({ id, title, size, sha256 }) => ({ id, title, size, sha256 })) },
        { 'access-control-allow-origin': '*' }));
      return true;
    }
    const pack = pathname.match(/^\/lf2-packs\/([a-z0-9][a-z0-9-]{0,39})\.zip$/);
    if (pack) {
      servePack(req, res, pack[1]).catch(() => res.destroy());
      return true;
    }
    if (pathname === '/admin' || pathname === '/admin/') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store',
        'x-frame-options': 'DENY', 'referrer-policy': 'no-referrer' });
      res.end(ADMIN_PAGE);
      return true;
    }
    if (pathname === '/admin/api/packs' && req.method === 'GET') {
      if (authorized(req, res)) list().then((packs) => json(res, 200, { packs, maxBytes: config.maxPackBytes }));
      return true;
    }
    const managed = pathname.match(/^\/admin\/api\/packs\/([^/]*)$/);
    if (managed) {
      const id = managed[1];
      if (!PACK_ID.test(id)) {
        json(res, 400, { error: 'Mã ngắn chỉ gồm chữ thường a-z, số và dấu gạch ngang (tối đa 40 ký tự).' });
        return true;
      }
      if (req.method === 'PUT') {
        if (!authorized(req, res)) { req.resume(); return true; }
        const title = String(new URL(req.url, 'http://relay.invalid').searchParams.get('title') || id).trim().slice(0, 60) || id;
        upload(req, res, id, title).catch(() => res.destroy());
        return true;
      }
      if (req.method === 'DELETE') {
        if (!authorized(req, res)) return true;
        Promise.all([`${id}.zip`, `${id}.json`].map((name) => fsp.rm(path.join(directory || '/nonexistent', name), { force: true })))
          .then(() => { log(`pack ${id}: removed`); json(res, 200, { ok: true }); })
          .catch((error) => json(res, 500, { error: String(error.message || error) }));
        return true;
      }
      json(res, 405, { error: 'method not allowed' }, { allow: 'PUT, DELETE' });
      return true;
    }
    return false;
  }

  return { handle, list, cleanup: () => {
    const now = Date.now();
    for (const map of [downloads, failures]) for (const [key, entry] of map) if (entry.until <= now) map.delete(key);
  } };
}

// The page at /admin (Vietnamese: the relay's owner reads it).
const ADMIN_PAGE = `<!doctype html>
<html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenLF2 relay: bản mod</title>
<style>
  body { margin: 0; padding: 1.5rem; background: #111827; color: #f3f4f6; font: 16px/1.5 system-ui, sans-serif; }
  main { max-width: 760px; margin: auto; }
  h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
  .card { background: #1f2937; border: 1px solid #374151; border-radius: 12px; padding: 1rem 1.2rem; margin: 1rem 0; }
  label { display: block; margin: .6rem 0 .2rem; font-weight: 600; }
  input[type=text], input[type=password] { width: 100%; box-sizing: border-box; padding: .5rem .6rem; font: inherit;
    border-radius: 8px; border: 1px solid #4b5563; background: #0b1220; color: inherit; }
  button { padding: .55rem 1.1rem; font: inherit; border-radius: 8px; border: 0; cursor: pointer; background: #f59e0b; color: #1f1300; font-weight: 700; }
  button.secondary { background: #374151; color: #f3f4f6; font-weight: 500; }
  button:disabled { opacity: .5; cursor: default; }
  progress { width: 100%; height: .8rem; margin-top: .8rem; }
  .note { color: #9ca3af; font-size: .9rem; }
  .ok { color: #6ee7b7; } .bad { color: #fca5a5; }
  table { width: 100%; border-collapse: collapse; } td, th { text-align: left; padding: .4rem .3rem; border-bottom: 1px solid #374151; vertical-align: top; }
  code { background: #0b1220; padding: .05rem .3rem; border-radius: 4px; }
</style></head>
<body><main>
  <h1>Bản mod cho OpenLF2</h1>
  <p class="note">Tải lên một file .zip chứa cả thư mục game của bản mod (có file .exe và thư mục data, sprite, bgm, bg).
    Relay chỉ giữ lại phần game cần, rồi phát cho trình duyệt của người chơi. Ai cũng chọn cùng một bản mod mới vào chung phòng được.</p>
  <div class="card">
    <label for="key">Mã quản trị (ADMIN_KEY)</label>
    <input id="key" type="password" autocomplete="current-password" placeholder="in ra khi chạy install-vps.sh">
    <label for="file">File .zip của bản mod</label>
    <input id="file" type="file" accept=".zip,application/zip">
    <label for="title">Tên hiển thị trên trang game</label>
    <input id="title" type="text" maxlength="60" placeholder="ví dụ: One Piece GrandWorld">
    <label for="id">Mã ngắn (dùng trong link mời)</label>
    <input id="id" type="text" maxlength="40" placeholder="ví dụ: onepiece" pattern="[a-z0-9][a-z0-9-]*">
    <p><button id="upload">Tải lên</button></p>
    <progress id="progress" hidden></progress>
    <p id="status" role="status" class="note"></p>
  </div>
  <div class="card">
    <h2 style="font-size:1.15rem;margin:0 0 .5rem">Các bản mod trên relay</h2>
    <p><button id="refresh" class="secondary">Xem danh sách</button></p>
    <table><tbody id="list"></tbody></table>
  </div>
</main>
<script>
  const $ = (id) => document.getElementById(id);
  const api = location.pathname.replace(/\\/?$/, '/') + 'api/packs';
  try { $('key').value = localStorage.getItem('lf2-admin-key') || ''; } catch (error) {}
  const remember = () => { try { localStorage.setItem('lf2-admin-key', $('key').value); } catch (error) {} };
  const slug = (text) => text.toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').replace(/đ/g, 'd')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'mod';
  $('file').addEventListener('change', () => {
    const file = $('file').files[0];
    if (!file) return;
    const name = file.name.replace(/\\.zip$/i, '').replace(/[_]+/g, ' ').trim();
    if (!$('title').value) $('title').value = name;
    if (!$('id').value) $('id').value = slug(name);
  });
  $('title').addEventListener('input', () => { if (!$('id').dataset.touched) $('id').value = slug($('title').value); });
  $('id').addEventListener('input', () => { $('id').dataset.touched = '1'; });
  const mb = (bytes) => (bytes / 1e6).toFixed(1) + ' MB';
  function status(text, kind) { $('status').textContent = text; $('status').className = kind || 'note'; }
  $('upload').addEventListener('click', () => {
    const file = $('file').files[0];
    const id = $('id').value.trim();
    if (!$('key').value) return status('Nhập mã quản trị trước.', 'bad');
    if (!file) return status('Chọn file .zip trước.', 'bad');
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(id)) return status('Mã ngắn chỉ gồm chữ thường a-z, số và dấu gạch ngang.', 'bad');
    remember();
    const request = new XMLHttpRequest();
    request.open('PUT', api + '/' + id + '?title=' + encodeURIComponent($('title').value.trim() || id));
    request.setRequestHeader('x-admin-key', $('key').value);
    request.setRequestHeader('content-type', 'application/zip');
    $('progress').hidden = false;
    $('upload').disabled = true;
    request.upload.onprogress = (event) => {
      if (!event.lengthComputable) return;
      $('progress').max = event.total;
      $('progress').value = event.loaded;
      status('Đang tải lên: ' + mb(event.loaded) + ' / ' + mb(event.total) + (event.loaded === event.total ? ' (relay đang xử lý...)' : ''));
    };
    request.onload = () => {
      $('upload').disabled = false;
      $('progress').hidden = true;
      let body = {};
      try { body = JSON.parse(request.responseText); } catch (error) {}
      if (request.status === 200) {
        status('Xong: "' + body.title + '" (' + mb(body.size) + ', ' + body.files + ' file, bỏ bớt ' + body.dropped + ' file không cần). '
          + 'Trên trang game, chọn nó ở mục Game, hoặc gửi link mời có thêm &pack=' + body.id + '.', 'ok');
        refresh();
      } else status('Không được: ' + (body.error || ('lỗi ' + request.status)), 'bad');
    };
    request.onerror = () => { $('upload').disabled = false; $('progress').hidden = true; status('Mất kết nối khi tải lên.', 'bad'); };
    request.send(file);
  });
  async function refresh() {
    if (!$('key').value) return status('Nhập mã quản trị để xem danh sách.', 'bad');
    remember();
    const response = await fetch(api, { headers: { 'x-admin-key': $('key').value } });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) return status(body.error || ('lỗi ' + response.status), 'bad');
    const list = $('list');
    list.textContent = '';
    if (!body.packs.length) list.innerHTML = '<tr><td class="note">Chưa có bản mod nào.</td></tr>';
    for (const pack of body.packs) {
      const row = document.createElement('tr');
      const info = document.createElement('td');
      info.innerHTML = '<b></b><br><span class="note"></span>';
      info.querySelector('b').textContent = pack.title;
      info.querySelector('span').textContent = 'mã: ' + pack.id + ' · ' + mb(pack.size) + ' · tải lên ' + new Date(pack.uploaded).toLocaleString();
      const actions = document.createElement('td');
      const remove = document.createElement('button');
      remove.className = 'secondary';
      remove.textContent = 'Xóa';
      remove.onclick = async () => {
        if (!confirm('Xóa "' + pack.title + '" khỏi relay?')) return;
        const result = await fetch(api + '/' + pack.id, { method: 'DELETE', headers: { 'x-admin-key': $('key').value } });
        if (result.ok) refresh(); else status('Không xóa được (lỗi ' + result.status + ').', 'bad');
      };
      actions.appendChild(remove);
      row.append(info, actions);
      list.appendChild(row);
    }
  }
  $('refresh').addEventListener('click', refresh);
</script>
</body></html>
`;

module.exports = { createPacks, readZip, analyzeZip, writeZip, PackError, PACK_ID };

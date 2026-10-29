// Keep the user-selected installer in the browser for later visits to this origin.
const installerStore = (() => {
  const databaseName = 'openlf2-installer';
  const storeName = 'files';
  const key = 'LF2_v2.0a.exe';

  function open() {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(databaseName, 1);
      request.onupgradeneeded = () => request.result.createObjectStore(storeName);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  async function transact(mode, operation) {
    const database = await open();
    try {
      return await new Promise((resolve, reject) => {
        const transaction = database.transaction(storeName, mode);
        const request = operation(transaction.objectStore(storeName));
        transaction.oncomplete = () => resolve(request.result);
        request.onerror = () => reject(request.error);
        transaction.onerror = () => reject(transaction.error);
        transaction.onabort = () => reject(transaction.error);
      });
    } finally {
      database.close();
    }
  }

  return {
    load: () => transact('readonly', store => store.get(key)),
    save: file => transact('readwrite', store => store.put(file, key)),
    remove: () => transact('readwrite', store => store.delete(key))
  };
})();

// Downloads the LF2 v2.0a installer, reporting progress (received, total, source host) and checking size and
// SHA-256. Sources in order: the online relay's copy (online.js: OpenLF2Online.installerUrl(), when a relay is set
// and keeps one), then archive.org, the only public source that allows cross-origin requests. The relay's copy is
// named lf2-installer.data, which download managers such as IDM let through; they take over the .exe from archive.org.
const installerDownload = async (onProgress, options = {}) => {
  const size = options.size || 29586263;
  const sha256 = options.sha256 || '540c485547e234b0d09595f54d067aafd7176092c308aca61868f3cbc03030e1';
  const archive = 'https://archive.org/download/little-fighter-2_202404/Little%20Fighter%202.rar/Little%20Fighter%202%2FLF2Setup.exe';
  let relayCopy = '';
  try {
    if (globalThis.OpenLF2Online && typeof OpenLF2Online.installerUrl === 'function') relayCopy = OpenLF2Online.installerUrl();
  } catch (error) {
    // no relay copy: archive.org alone
  }
  const sources = options.sources || [relayCopy, archive].filter(Boolean);
  const download = async url => {
    const source = new URL(url).host;
    const response = await fetch(url);
    if (!response.ok) throw new Error('HTTP ' + response.status);
    const chunks = [];
    let received = 0;
    const reader = response.body.getReader();
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.length;
      if (received > size) throw new Error('more than ' + size + ' bytes');
      onProgress(received, size, source);
    }
    const blob = new Blob(chunks);
    if (blob.size !== size) throw new Error('received ' + blob.size + ' bytes, expected ' + size);
    if (crypto.subtle) {
      const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', await blob.arrayBuffer()));
      if (Array.from(digest, byte => byte.toString(16).padStart(2, '0')).join('') !== sha256) throw new Error('checksum mismatch');
    }
    return blob;
  };
  const failures = [];
  for (const url of sources) {
    try {
      return await download(url);
    } catch (error) {
      failures.push(new URL(url).host + ': ' + (error && error.message || error));
    }
  }
  throw new Error(failures.join('; '));
};

// Game packs: mods played instead of the original game (a ZIP file of the mod's game folder, see the game's
// --pack option and tools/relay/packs.js). Kept in the browser by id, with the SHA-256 they were checked against.
const packStore = (() => {
  const databaseName = 'openlf2-packs';
  const storeName = 'packs';

  function open() {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(databaseName, 1);
      request.onupgradeneeded = () => request.result.createObjectStore(storeName);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  async function transact(mode, operation) {
    const database = await open();
    try {
      return await new Promise((resolve, reject) => {
        const transaction = database.transaction(storeName, mode);
        const request = operation(transaction.objectStore(storeName));
        transaction.oncomplete = () => resolve(request.result);
        request.onerror = () => reject(request.error);
        transaction.onerror = () => reject(transaction.error);
        transaction.onabort = () => reject(transaction.error);
      });
    } finally {
      database.close();
    }
  }

  return {
    // { blob, title, sha256, saved } or undefined
    load: id => transact('readonly', store => store.get(id)),
    save: (id, record) => transact('readwrite', store => store.put(record, id)),
    remove: id => transact('readwrite', store => store.delete(id))
  };
})();

// The hex SHA-256 of a Blob, or '' where the browser cannot compute it (pages served over plain HTTP).
const blobSha256 = async blob => {
  if (!globalThis.crypto || !crypto.subtle) return '';
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', await blob.arrayBuffer()));
  return Array.from(digest, byte => byte.toString(16).padStart(2, '0')).join('');
};

// Downloads a game pack from the relay, reporting progress (received, total) and checking size and SHA-256.
const packDownload = async (url, expected, onProgress) => {
  const response = await fetch(url);
  if (!response.ok) throw new Error('HTTP ' + response.status);
  const total = expected.size || Number(response.headers.get('content-length')) || 0;
  const chunks = [];
  let received = 0;
  const reader = response.body.getReader();
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.length;
    if (total && received > total) throw new Error('more than ' + total + ' bytes');
    onProgress(received, total);
  }
  const blob = new Blob(chunks, {type: 'application/zip'});
  if (total && blob.size !== total) throw new Error('received ' + blob.size + ' bytes, expected ' + total);
  if (expected.sha256) {
    const digest = await blobSha256(blob);
    if (digest && digest !== expected.sha256) throw new Error('checksum mismatch');
  }
  return blob;
};

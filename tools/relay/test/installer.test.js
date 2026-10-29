// SPDX-License-Identifier: MIT
//
// install-vps.sh: its syntax, that the relay files embedded in it are current, and its helper
// functions (run in bash, sourced without running the installation).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync, execFile } = require('node:child_process');
const { render } = require('../update-installer.js');

const relayDir = path.join(__dirname, '..');
const installer = path.join(relayDir, 'install-vps.sh');

// Runs `script` in bash with the installer's functions loaded (LF2_INSTALLER_LIB=1 skips main).
function bash(script, env = {}) {
  return new Promise((resolve, reject) => {
    execFile('bash', ['-c', `set -euo pipefail; LF2_INSTALLER_LIB=1 source "${installer}"; ${script}`],
      { env: { ...process.env, ...env }, encoding: 'utf8' }, (error, stdout, stderr) => {
        if (error) reject(new Error(`${error.message}\n${stderr}`));
        else resolve(stdout);
      });
  });
}

test('the installer parses as bash', () => {
  execFileSync('bash', ['-n', installer]);
});

test('the relay files embedded in the installer are the current ones', async () => {
  const current = fs.readFileSync(installer, 'utf8');
  assert.equal(render(current), current, 'run: node update-installer.js');
  const decoded = await bash('dir=$(mktemp -d); write_server_js "$dir/s"; write_package_json "$dir/p"; cat "$dir/s"; echo "<<split>>"; cat "$dir/p"; rm -rf "$dir"');
  const [server, pkg] = decoded.split('<<split>>\n');
  assert.equal(server, fs.readFileSync(path.join(relayDir, 'server.js'), 'utf8'));
  assert.equal(pkg, fs.readFileSync(path.join(relayDir, 'package.json'), 'utf8'));
});

test('version comparison', async () => {
  const out = await bash(`for pair in "2.17 2.28" "2.28 2.28" "2.31 2.28" "2.9 2.28" "2.100 2.28"; do
    set -- $pair; if version_ge "$1" "$2"; then echo "$1 yes"; else echo "$1 no"; fi; done`);
  assert.equal(out, '2.17 no\n2.28 yes\n2.31 yes\n2.9 no\n2.100 yes\n');
});

test('the newest Node.js 22 build for glibc 2.17 is picked from the index', async () => {
  const index = [
    '[{"version":"v24.11.0","date":"2026-10-01","files":["headers","linux-x64-glibc-217","linux-x64-musl"],"npm":"11.6.1"},',
    '{"version":"v22.21.1","date":"2026-09-20","files":["headers","linux-x64-musl"],"npm":"10.9.4"},',
    '{"version":"v22.21.0","date":"2026-09-10","files":["headers","linux-x64-glibc-217","linux-x64-musl"],"npm":"10.9.4"},',
    '{"version":"v22.20.0","date":"2026-08-01","files":["linux-x64-glibc-217"],"npm":"10.9.3"},',
    '{"version":"v20.19.5","date":"2026-07-01","files":["linux-x64-glibc-217"],"npm":"10.8.2"}]',
  ].join('\n');
  fs.writeFileSync(path.join(__dirname, '.index.tmp.json'), index);
  try {
    const out = await bash(`latest_glibc217 22 < "${path.join(__dirname, '.index.tmp.json')}"`);
    assert.equal(out, 'v22.21.0\n');
    const none = await bash(`latest_glibc217 18 < "${path.join(__dirname, '.index.tmp.json')}"`);
    assert.equal(none, '');
  } finally {
    fs.rmSync(path.join(__dirname, '.index.tmp.json'), { force: true });
  }
});

test('which Node.js builds are tried on CentOS 7 and on newer systems', async () => {
  const index = '[{"version":"v22.21.0","files":["linux-x64-glibc-217"]}]';
  const server = http.createServer((req, res) => {
    if (req.url === '/index.json') { res.end(index); return; }
    res.writeHead(404); res.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const old = await bash('node_candidates 2.17 x64', { NODE_UNOFFICIAL: base, NODE_DIST: 'https://nodejs.org/dist' });
    assert.equal(old, `${base}/v22.21.0 node-v22.21.0-linux-x64-glibc-217\nhttps://nodejs.org/dist/v16.20.2 node-v16.20.2-linux-x64\n`);
    const unreachable = await bash('node_candidates 2.17 x64', { NODE_UNOFFICIAL: 'http://127.0.0.1:9', NODE_DIST: 'https://nodejs.org/dist' });
    assert.equal(unreachable, 'https://nodejs.org/dist/v16.20.2 node-v16.20.2-linux-x64\n', 'falls back when the index cannot be read');
    const modern = await bash('node_candidates 2.35 x64', { NODE_DIST: 'https://nodejs.org/dist' });
    assert.equal(modern, 'https://nodejs.org/dist/latest-v22.x LATEST\n');
  } finally {
    server.close();
  }
});

test('the sslip.io name for an address', async () => {
  assert.equal(await bash('sslip_name 203.0.113.5'), '203-0-113-5.sslip.io\n');
  assert.equal(await bash('is_ipv4 203.0.113.5 && echo yes; is_ipv4 "<html>" || echo no'), 'yes\nno\n');
});

// ss output (CentOS 7 format) with the given owners of ports 80 and 443; '' = free.
function ssOutput(owner80, owner443) {
  const lines = ['State      Recv-Q Send-Q Local Address:Port               Peer Address:Port',
    'LISTEN     0      128          *:22                       *:*                   users:(("sshd",pid=1012,fd=3))'];
  if (owner80) lines.push(`LISTEN     0      511       :::80                    :::*                   users:(("${owner80}",pid=3001,fd=4),("${owner80}",pid=3002,fd=4))`);
  if (owner443) lines.push(`LISTEN     0      511       :::443                   :::*                   users:(("${owner443}",pid=3001,fd=6))`);
  return lines.join('\n') + '\n';
}

// Runs check_ports against that ss output; `ours` = whether lf2-caddy is active.
async function portPlan(owner80, owner443, ours = false) {
  const file = path.join(__dirname, `.ss-plan-${process.pid}-${Math.random().toString(36).slice(2)}.txt`);
  fs.writeFileSync(file, ssOutput(owner80, owner443));
  try {
    return await bash(`ss() { cat "${file}"; }; check_ports; echo "mode=$CADDY_MODE"`,
      { LF2_SYSTEMCTL: ours ? 'true' : 'false' });
  } catch (error) {
    return `exit: ${error.message}`;
  } finally {
    fs.rmSync(file, { force: true });
  }
}

test('which ports Caddy takes, next to another web server', async () => {
  assert.equal(await portPlan('', ''), 'mode=full\n');
  const apache80 = await portPlan('httpd', '');
  assert.match(apache80, /Cong 80 dang do "httpd" dung/);
  assert.match(apache80, /mode=tls-only\n$/);
  assert.equal(await portPlan('caddy', 'caddy', true), 'mode=full\n', 'our own Caddy from an earlier run');
  assert.match(await portPlan('httpd', 'caddy', true), /mode=tls-only\n$/, 'rerun after a tls-only install');
  const both = await portPlan('httpd', 'httpd');
  assert.match(both, /^exit: /);
  assert.match(both, /Cong 443 \(HTTPS\) dang duoc chuong trinh "httpd" dung/);
  assert.match(both, /systemctl stop httpd\n\s+systemctl disable httpd/);
  assert.doesNotMatch(both, /--now/, 'CentOS 7 systemd has no --now');
  const other = await portPlan('', 'java');
  assert.match(other, /"java"/);
  assert.doesNotMatch(other, /systemctl stop/, 'no stop command for programs we do not know');
  assert.match(await portPlan('caddy', ''), /mode=tls-only/, 'someone else\'s Caddy on 80 is not ours');
});

test('the Caddy configuration for each mode', async () => {
  const caddyfile = (mode, extra = '') => bash(`CADDY_MODE=${mode}; DOMAIN=203-0-113-5.sslip.io; ${extra} f=$(mktemp); write_caddyfile "$f"; cat "$f"; rm -f "$f"`);
  assert.equal(await caddyfile('full'), [
    '# Written by install-vps.sh (full). HTTPS for the OpenLF2 relay; the certificate renews by itself.',
    '{', '\tadmin off', '}', '', '203-0-113-5.sslip.io {', '\ttls {', '\t\tissuer acme {', '\t\t}', '\t}',
    '\treverse_proxy 127.0.0.1:8787', '}', ''].join('\n'));
  assert.equal(await caddyfile('tls-only'), [
    '# Written by install-vps.sh (tls-only). HTTPS for the OpenLF2 relay; the certificate renews by itself.',
    '{', '\tadmin off', '\tauto_https disable_redirects', '}', '', '203-0-113-5.sslip.io {', '\ttls {', '\t\tissuer acme {',
    '\t\t\tdisable_http_challenge', '\t\t}', '\t}', '\treverse_proxy 127.0.0.1:8787', '}', ''].join('\n'));
  const withTestCa = await caddyfile('tls-only', 'LF2_ACME_DIR=https://localhost:14000/dir LF2_ACME_ROOT=/ca.pem');
  assert.match(withTestCa, /\t\t\tdir https:\/\/localhost:14000\/dir\n\t\t\ttrusted_roots \/ca.pem\n\t\t\tdisable_http_challenge\n/);
});

test('the game data is fetched once, checked, and never fatal', async () => {
  const os = require('node:os');
  const good = crypto.randomBytes(200000);
  const sha = crypto.createHash('sha256').update(good).digest('hex');
  let requests = 0;
  const server = http.createServer((req, res) => {
    requests += 1;
    if (req.url === '/good.exe') { res.end(good); return; }
    if (req.url === '/bad.exe') { res.end(crypto.randomBytes(200000)); return; }
    res.writeHead(404); res.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const prefix = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-data-'));
  const env = { LF2_PREFIX: prefix, LF2_DATA_SIZE: String(good.length), LF2_DATA_SHA256: sha, no_proxy: '127.0.0.1', NO_PROXY: '127.0.0.1' };
  try {
    // The first sources fail (missing, wrong bytes); the third is right.
    const first = await bash('install_game_data; echo "have=$HAVE_DATA"',
      { ...env, LF2_DATA_URLS: `${base}/missing.exe ${base}/bad.exe ${base}/good.exe` });
    assert.match(first, /have=1\n$/);
    assert.ok(fs.readFileSync(path.join(prefix, 'data', 'lf2-installer.data')).equals(good));
    const before = requests;
    const again = await bash('install_game_data; echo "have=$HAVE_DATA"', { ...env, LF2_DATA_URLS: `${base}/good.exe` });
    assert.match(again, /Du lieu game da co san/);
    assert.equal(requests, before, 'a good copy is not downloaded again');
    fs.rmSync(path.join(prefix, 'data'), { recursive: true });
    const none = await bash('install_game_data; echo "have=$HAVE_DATA"', { ...env, LF2_DATA_URLS: `${base}/bad.exe` });
    assert.match(none, /trang game se tai tu archive.org/);
    assert.match(none, /have=0\n$/);
    assert.ok(!fs.existsSync(path.join(prefix, 'data', 'lf2-installer.data')), 'wrong bytes are never kept');
  } finally {
    server.close();
    fs.rmSync(prefix, { recursive: true, force: true });
  }
});

test('who holds ports 80 and 443, from ss output', async () => {
  const ss = [
    'State      Recv-Q Send-Q Local Address:Port               Peer Address:Port',
    'LISTEN     0      128          *:22                       *:*                   users:(("sshd",pid=1012,fd=3))',
    'LISTEN     0      128          *:8080                     *:*                   users:(("java",pid=2001,fd=40))',
    'LISTEN     0      511       [::]:80                    [::]:*                   users:(("httpd",pid=3001,fd=4),("httpd",pid=3002,fd=4))',
    'LISTEN     0      100    127.0.0.1:25                     *:*                   users:(("master",pid=1200,fd=13))',
  ].join('\n');
  fs.writeFileSync(path.join(__dirname, '.ss.tmp.txt'), ss + '\n');
  try {
    const file = path.join(__dirname, '.ss.tmp.txt');
    assert.equal(await bash(`port_owner 80 < "${file}"`), 'httpd\n');
    assert.equal(await bash(`port_owner 443 < "${file}"`), '');
    assert.equal(await bash(`port_owner 22 < "${file}"`), 'sshd\n');
    assert.equal(await bash(`port_owner 8 < "${file}"`), '');
  } finally {
    fs.rmSync(path.join(__dirname, '.ss.tmp.txt'), { force: true });
  }
});

// --- Behind an existing Apache website (APACHE_SITE) ---------------------------------------------

// `httpd -S` on a CentOS 7 server like the one this mode was written for: the stock ssl.conf host
// named by the IP, a certbot site with its www alias, and a site served over plain HTTP only.
const httpdS = [
  'VirtualHost configuration:',
  '*:443                  is a NameVirtualHost',
  '         default server 116.118.45.198 (/etc/httpd/conf.d/ssl.conf:56)',
  '         port 443 namevhost 116.118.45.198 (/etc/httpd/conf.d/ssl.conf:56)',
  '         port 443 namevhost sybil.example (/etc/httpd/conf.d/sybil-le-ssl.conf:2)',
  '                 alias www.sybil.example',
  '*:80                   is a NameVirtualHost',
  '         default server sybil.example (/etc/httpd/conf.d/sybil.conf:1)',
  '         port 80 namevhost sybil.example (/etc/httpd/conf.d/sybil.conf:1)',
  '                 alias www.sybil.example',
  '         port 80 namevhost plain.example (/etc/httpd/conf.d/plain.conf:1)',
  'ServerRoot: "/etc/httpd"',
  'Main DocumentRoot: "/var/www/html"',
  'Main ErrorLog: "/etc/httpd/logs/error_log"',
].join('\n') + '\n';

// A temporary file with `content`, removed after `fn` ran with its path.
async function withFile(content, fn) {
  const file = path.join(__dirname, `.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`);
  fs.writeFileSync(file, content);
  try {
    return await fn(file);
  } finally {
    fs.rmSync(file, { force: true });
  }
}

test('which sites Apache serves over HTTPS, from httpd -S', async () => {
  await withFile(httpdS, async (file) => {
    const serves = (site) => bash(`apache_serves_https ${site} < "${file}" && echo yes || echo no`);
    assert.equal(await serves('sybil.example'), 'yes\n');
    assert.equal(await serves('www.sybil.example'), 'yes\n', 'an alias of an HTTPS site');
    assert.equal(await serves('116.118.45.198'), 'yes\n');
    assert.equal(await serves('plain.example'), 'no\n', 'served on port 80 only');
    assert.equal(await serves('other.example'), 'no\n');
    assert.equal(await bash(`apache_https_names < "${file}"`), '116.118.45.198\nsybil.example\nwww.sybil.example\n');
  });
  // One HTTPS site only: httpd -S puts it on the address line.
  await withFile('VirtualHost configuration:\n*:443                  one.example (/etc/httpd/conf.d/ssl.conf:56)\n*:80                   one.example (/etc/httpd/conf.d/one.conf:1)\n', async (file) => {
    assert.equal(await bash(`apache_serves_https one.example < "${file}" && echo yes`), 'yes\n');
    assert.equal(await bash(`apache_https_names < "${file}"`), 'one.example\n');
  });
});

test('Apache modules, from httpd -M', async () => {
  const modules = 'Loaded Modules:\n core_module (static)\n proxy_module (shared)\n proxy_http_module (shared)\n ssl_module (shared)\n';
  await withFile(modules, async (file) => {
    const has = (name) => bash(`apache_has_module ${name} < "${file}" && echo yes || echo no`);
    assert.equal(await has('proxy_module'), 'yes\n');
    assert.equal(await has('proxy_http_module'), 'yes\n');
    assert.equal(await has('proxy_wstunnel_module'), 'no\n');
    assert.equal(await has('http_module'), 'no\n', 'whole names only');
  });
});

test('where to reach Apache on this machine, from ss', async () => {
  const listen = (address) => ssOutput('', '').replace(/\n$/, '') +
    `\nLISTEN     0      511       ${address}                     *:*                   users:(("httpd",pid=3001,fd=6))\n`;
  for (const [address, expected] of [['*:443', '127.0.0.1'], [':::443', '127.0.0.1'], ['[::]:443', '127.0.0.1'],
    ['0.0.0.0:443', '127.0.0.1'], ['116.118.45.198:443', '116.118.45.198']]) {
    assert.equal(await bash(`apache_listen_address "$(cat <<'SS'\n${listen(address)}SS\n)"`), `${expected}\n`, address);
  }
});

test('a free local port for the relay, and SELinux', async () => {
  const taken = (ports) => ssOutput('httpd', 'httpd').replace(/\n$/, '') + ports.map((port) =>
    `\nLISTEN     0      128    127.0.0.1:${port}                     *:*                   users:(("java",pid=4001,fd=7))`).join('') + '\n';
  const pick = (ports, selinux) => withFile(taken(ports), (file) =>
    bash(`getenforce() { echo ${selinux}; }; pick_relay_port "$(cat "${file}")" && echo || echo none`));
  assert.equal(await pick([], 'Disabled'), '8787\n');
  assert.equal(await pick([8787], 'Permissive'), '8008\n');
  assert.equal(await pick([], 'Enforcing'), '8008\n', 'Apache may only connect to http_port_t ports');
  assert.equal(await pick([8008], 'Enforcing'), '8009\n');
  assert.equal(await pick([8008, 8009], 'Enforcing'), 'none\n');
});

test('the site name, however it was pasted', async () => {
  assert.equal(await bash('normalize_site "https://Sybil.Example/lf2"'), 'sybil.example');
  assert.equal(await bash('normalize_site "sybil.example:443"'), 'sybil.example');
  assert.equal(await bash('normalize_site sybil.example'), 'sybil.example');
});

test("the domain's addresses, from public DNS", async () => {
  const doh = '{"Status":0,"TC":false,"Question":[{"name":"www.sybil.example.","type":1}],"Answer":[' +
    '{"name":"www.sybil.example.","type":5,"TTL":300,"data":"sybil.example."},' +
    '{"name":"sybil.example.","type":1,"TTL":300,"data":"203.0.113.7"},{"name":"sybil.example.","type":1,"TTL":300,"data":"203.0.113.8"}]}';
  assert.equal(await bash(`curl() { printf '%s' '${doh}'; }; site_addresses www.sybil.example`), '203.0.113.7\n203.0.113.8\n');
  const nxdomain = '{"Status":3,"TC":false,"Question":[{"name":"nope.example.","type":1}]}';
  assert.equal(await bash(`curl() { printf '%s' '${nxdomain}'; }; site_addresses nope.example`), '');
  // No DNS over HTTPS from this machine: dig, else the system resolver.
  assert.equal(await bash('curl() { return 7; }; dig() { printf "sybil.example.\\n203.0.113.9\\n"; }; site_addresses sybil.example'), '203.0.113.9\n');
  // Without dig (a PATH of just the tools the function needs besides it).
  const os = require('node:os');
  const tools = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-tools-'));
  try {
    for (const tool of ['awk', 'sort', 'grep']) fs.symlinkSync(execFileSync('bash', ['-c', `command -v ${tool}`], { encoding: 'utf8' }).trim(), path.join(tools, tool));
    assert.equal(await bash(`curl() { return 7; }; getent() { echo "198.51.100.4    STREAM sybil.example"; echo "198.51.100.4    DGRAM"; }; PATH="${tools}"; site_addresses sybil.example`),
      '198.51.100.4\n');
  } finally {
    fs.rmSync(tools, { recursive: true, force: true });
  }
  assert.equal(await bash('site_addresses x', { LF2_SITE_ADDRESSES: '192.0.2.1 192.0.2.2' }), '192.0.2.1\n192.0.2.2\n');
});

test("Apache mode is chosen only next to Apache's HTTPS, with a domain name", async () => {
  const plan = (owner443, site) => withFile(ssOutput('httpd', owner443), (file) =>
    bash(`ss() { cat "${file}"; }; APACHE_SITE='${site}'; check_ports; echo "mode=$CADDY_MODE site=$APACHE_SITE"`, { LF2_SYSTEMCTL: 'false' })
      .catch((error) => `exit: ${error.message}`));
  assert.match(await plan('httpd', 'https://Sybil.example/'), /mode=apache site=sybil\.example\n$/);
  const nginx = await plan('nginx', 'sybil.example');
  assert.match(nginx, /^exit: /);
  assert.match(nginx, /APACHE_SITE chi dung khi Apache/);
  assert.match(await plan('httpd', '116.118.45.198'), /khong phai ten mien/);
  assert.match(await plan('httpd', 'bad name;rm'), /khong phai ten mien/);
});

test('with port 443 taken by Apache, the message names a site to share', async () => {
  await withFile(httpdS, async (sFile) => withFile(ssOutput('httpd', 'httpd'), async (ssFile) => {
    const out = await bash(`ss() { cat "${ssFile}"; }; fake_httpd() { cat "${sFile}"; }; HTTPD=fake_httpd; check_ports`, { LF2_SYSTEMCTL: 'false' })
      .catch((error) => error.message);
    assert.match(out, /\.\.\. \| APACHE_SITE=sybil\.example bash/, 'a domain name, not the IP');
    assert.match(out, /systemctl stop httpd/);
  }));
});

test("the Apache file: the relay's two paths, never pooled", async () => {
  const text = await bash('APACHE_SITE=sybil.example RELAY_PORT=8008; apache_conf_text');
  assert.match(text, /^# Written by install-vps\.sh/);
  assert.match(text, /\n\tProxyPass "\/lf2-relay\/relay" "ws:\/\/127\.0\.0\.1:8008\/relay" retry=0 disablereuse=On\n/);
  assert.match(text, /\n\tProxyPass "\/lf2-relay\/" "http:\/\/127\.0\.0\.1:8008\/" retry=0 disablereuse=On\n/);
  assert.ok(text.indexOf('/lf2-relay/relay"') < text.indexOf('"/lf2-relay/"'), 'the WebSocket path first (first match wins)');
  assert.doesNotMatch(text, /VirtualHost|Rewrite|Listen/, 'no new site, rule or port');
});

test('a rerun keeps the site, the port and the allowed game pages', async () => {
  const os = require('node:os');
  const prefix = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-state-'));
  const units = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-units-'));
  try {
    await bash('APACHE_SITE=sybil.example RELAY_PORT=8008; save_apache_state', { LF2_PREFIX: prefix });
    assert.equal(await bash('APACHE_SITE=""; load_apache_state; echo "$APACHE_SITE $SAVED_RELAY_PORT"', { LF2_PREFIX: prefix }), 'sybil.example 8008\n');
    assert.equal(await bash('APACHE_SITE=other.example; load_apache_state; echo "$APACHE_SITE"', { LF2_PREFIX: prefix }), 'other.example\n', 'the command line wins');
    fs.writeFileSync(path.join(units, 'lf2-relay.service'), '[Service]\nEnvironment="PORT=8008"\nEnvironment="ALLOWED_ORIGINS=https://you.github.io"\n');
    const env = { ...process.env, LF2_SYSTEMD_DIR: units };
    delete env.ALLOWED_ORIGINS;
    const kept = await new Promise((resolve, reject) => execFile('bash', ['-c',
      `set -euo pipefail; LF2_INSTALLER_LIB=1 source "${installer}"; keep_allowed_origins; echo "[$ALLOWED_ORIGINS]"`],
    { env, encoding: 'utf8' }, (error, stdout) => (error ? reject(error) : resolve(stdout))));
    assert.equal(kept, '[https://you.github.io]\n');
    assert.equal(await bash('keep_allowed_origins; echo "[$ALLOWED_ORIGINS]"', { LF2_SYSTEMD_DIR: units, ALLOWED_ORIGINS: '' }), '[]\n', 'ALLOWED_ORIGINS= clears');
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true });
    fs.rmSync(units, { recursive: true, force: true });
  }
});

test('the admin key for mods is made once, kept for root only, and kept by a rerun', async () => {
  const os = require('node:os');
  const prefix = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-key-'));
  const env = { ...process.env, LF2_PREFIX: prefix };
  delete env.ADMIN_KEY;
  const run = (script, extra = {}) => new Promise((resolve, reject) => execFile('bash', ['-c',
    `set -euo pipefail; LF2_INSTALLER_LIB=1 source "${installer}"; ${script}`],
  { env: { ...env, ...extra }, encoding: 'utf8' }, (error, stdout, stderr) => (error ? reject(new Error(stderr)) : resolve(stdout))));
  try {
    const first = (await run('keep_admin_key; (umask 077 && printf "ADMIN_KEY=%s\\n" "$ADMIN_KEY" >"$PREFIX/relay.env"); echo "$ADMIN_KEY"')).trim();
    assert.match(first, /^[0-9a-f]{24}$/);
    assert.equal(fs.statSync(path.join(prefix, 'relay.env')).mode & 0o777, 0o600);
    assert.equal((await run('keep_admin_key; echo "$ADMIN_KEY"')).trim(), first, 'a rerun keeps it');
    assert.equal((await run('keep_admin_key; echo "$ADMIN_KEY"', { ADMIN_KEY: 'my-own.key_1' })).trim(), 'my-own.key_1');
    await assert.rejects(run('keep_admin_key', { ADMIN_KEY: 'bad key!' }), /ADMIN_KEY/);
    await assert.rejects(run('keep_admin_key', { ADMIN_KEY: 'short' }), /ADMIN_KEY/);
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true });
  }
});

test('the relay service reads the packs folder and the admin key file', async () => {
  const os = require('node:os');
  const units = fs.mkdtempSync(path.join(os.tmpdir(), 'lf2-units-'));
  try {
    await bash('RELAY_PORT=8008; ALLOWED_ORIGINS=""; write_relay_unit', { LF2_SYSTEMD_DIR: units, LF2_PREFIX: '/opt/lf2-relay' });
    const unit = fs.readFileSync(path.join(units, 'lf2-relay.service'), 'utf8');
    assert.match(unit, /^Environment="PACKS_DIR=\/opt\/lf2-relay\/data\/packs"$/m);
    assert.match(unit, /^EnvironmentFile=-\/opt\/lf2-relay\/relay\.env$/m);
    assert.doesNotMatch(unit, /ADMIN_KEY/, 'the key stays out of the world-readable unit');
  } finally {
    fs.rmSync(units, { recursive: true, force: true });
  }
});

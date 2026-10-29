#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Embeds server.js, packs.js and package.json into install-vps.sh (base64, between the "generated" markers),
// so that the installer is the only file a server has to download. Run after changing either:
//
//   node update-installer.js          rewrite install-vps.sh
//   node update-installer.js --check  exit 1 when install-vps.sh is out of date
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const here = __dirname;
const installerPath = path.join(here, 'install-vps.sh');

function payload(file) {
  const encoded = fs.readFileSync(path.join(here, file)).toString('base64');
  return encoded.match(/.{1,76}/g).join('\n');
}

function render(installer) {
  const files = [['write_server_js', 'server.js'], ['write_packs_js', 'packs.js'], ['write_package_json', 'package.json']];
  let result = installer;
  for (const [fn, file] of files) {
    const pattern = new RegExp(`(${fn}\\(\\) \\{\\n\\tbase64 -d >"\\$1" <<'LF2_PAYLOAD'\\n)[\\s\\S]*?(LF2_PAYLOAD\\n\\})`);
    if (!pattern.test(result)) throw new Error(`install-vps.sh: no ${fn} block`);
    result = result.replace(pattern, (_, head, tail) => `${head}${payload(file)}\n${tail}`);
  }
  return result;
}

if (require.main === module) {
  const current = fs.readFileSync(installerPath, 'utf8');
  const next = render(current);
  if (process.argv.includes('--check')) {
    if (current !== next) {
      console.error('install-vps.sh is out of date: run node update-installer.js');
      process.exit(1);
    }
  } else if (current !== next) {
    fs.writeFileSync(installerPath, next);
    console.log('install-vps.sh updated');
  } else {
    console.log('install-vps.sh already up to date');
  }
}

module.exports = { render };

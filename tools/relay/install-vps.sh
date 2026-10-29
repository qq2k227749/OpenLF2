#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
#
# Installs the OpenLF2 online relay on a Linux server with systemd (CentOS 7 and newer, Rocky,
# Alma, Ubuntu, Debian): Node.js, the relay as a service, and Caddy in front of it for HTTPS with
# a free certificate for <your-ip>.sslip.io (or your own domain). Run it as root:
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/OpenLF2/main/tools/relay/install-vps.sh | bash
#
# Optional settings, put before "bash":   ... | DOMAIN=relay.example.com bash
#   DOMAIN            your own domain, already pointing at this server (default: <ip>.sslip.io)
#   ALLOWED_ORIGINS   only these game pages may use the relay, e.g. https://you.github.io
# Remove it again:   ... | bash -s -- --uninstall
#
# A web server that already runs on the machine is left alone: when another program (often
# Apache, "httpd") holds port 80, Caddy listens on port 443 only and gets its certificate through
# the TLS-ALPN challenge there. When port 443 is taken too, the script stops and explains.
#
# Sharing an existing Apache (httpd) website instead, when its owner agrees:
#   curl -fsSL .../install-vps.sh | APACHE_SITE=example.com bash
# puts the relay behind that site at https://example.com/lf2-relay/ (WebSocket: .../lf2-relay/relay).
# No Caddy then: one file, /etc/httpd/conf.d/lf2-relay.conf, with ProxyPass lines to 127.0.0.1; it is
# checked with "apachectl configtest", applied with a graceful reload, verified through Apache (HTTP,
# and two short games over the WebSocket) and at the address public DNS gives for the site, and
# removed again, with Apache reloaded as before and the relay stopped, if any step fails.
#
# It also keeps a copy of the original LF2 v2.0a installer (freeware, by Marti Wong and Starsky
# Wong; checked by SHA-256 as the game does), which the relay serves to the game page as
# /lf2-installer.data: players then need no download manager workaround, and the page falls back to
# archive.org when the copy is missing.
#
# Mods (game packs: a mod's whole game folder as a ZIP file) are uploaded on the relay's page
# /admin with the admin key this script makes (kept in /opt/lf2-relay/relay.env, shown at the end),
# and kept in /opt/lf2-relay/data/packs.
#
# Everything lives in /opt/lf2-relay plus two services, lf2-relay and lf2-caddy. The relay's own
# files are embedded below (update-installer.js writes them), so this file is all a server needs.
# Messages are Vietnamese without diacritics, so that every terminal shows them.
set -euo pipefail

INSTALLER_VERSION=6
CADDY_MODE=full # check_ports decides: full, tls-only, or apache (no Caddy)
HAVE_DATA=0     # install_game_data decides
PREFIX=${LF2_PREFIX:-/opt/lf2-relay}
APACHE_SITE=${APACHE_SITE:-}
APACHE_PATH=/lf2-relay
APACHE_CONF=${LF2_APACHE_CONF:-/etc/httpd/conf.d/lf2-relay.conf}
APACHE_SERVICE=${LF2_APACHE_SERVICE:-httpd}
HTTPD=${LF2_HTTPD:-httpd}
APACHECTL=${LF2_APACHECTL:-apachectl}
APACHE_ADDRESS=127.0.0.1 # apache_preflight decides, as the next three
SERVER_IP=""
SITE_ADDRESSES=""
SITE_HERE=0
SAVED_RELAY_PORT=""
SYSTEMD_DIR=${LF2_SYSTEMD_DIR:-/etc/systemd/system}
SYSTEMCTL=${LF2_SYSTEMCTL:-systemctl}
RELAY_PORT=${RELAY_PORT:-8787}
NODE_MAJOR=22
NODE_FALLBACK=v16.20.2 # the last official Node.js build that runs on glibc 2.17 (CentOS 7)
CADDY_VERSION=2.11.7
NODE_DIST=${NODE_DIST:-https://nodejs.org/dist}
NODE_UNOFFICIAL=${NODE_UNOFFICIAL:-https://unofficial-builds.nodejs.org/download/release}
CADDY_RELEASES=${CADDY_RELEASES:-https://github.com/caddyserver/caddy/releases/download}
# The LF2 v2.0a installer: the game's own checks (installer-store.js, the Flatpak manifest) use this size
# and SHA-256. Sources in order: lf2.net, its Internet Archive snapshot, the Internet Archive item.
LF2_DATA_SIZE=${LF2_DATA_SIZE:-29586263}
LF2_DATA_SHA256=${LF2_DATA_SHA256:-540c485547e234b0d09595f54d067aafd7176092c308aca61868f3cbc03030e1}
LF2_DATA_URLS=${LF2_DATA_URLS:-https://lf2.net/LF2_v2.0a.exe https://web.archive.org/web/20260921121026id_/https://lf2.net/LF2_v2.0a.exe https://archive.org/download/little-fighter-2_202404/Little%20Fighter%202.rar/Little%20Fighter%202%2FLF2Setup.exe}

say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() {
	printf '\n[LOI] %s\n' "$*" >&2
	exit 1
}

fetch() { # url file
	curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 -o "$2" "$1"
}

# True when version $1 >= version $2 (dotted numbers).
version_ge() {
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]
}

glibc_version() {
	if [ -n "${GLIBC_VERSION:-}" ]; then
		printf '%s\n' "$GLIBC_VERSION"
		return
	fi
	ldd --version 2>&1 | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | tail -n 1 || true
}

# Reads the unofficial builds' index.json on stdin; prints the newest vMAJOR.x.y with a
# linux-x64-glibc-217 build (the index lists newest first, one object per release).
latest_glibc217() {
	tr -d '\n' | grep -oE "\"version\":\"v$1\.[0-9]+\.[0-9]+\"[^}]*\"linux-x64-glibc-217\"" |
		head -n 1 | grep -oE "v$1\.[0-9]+\.[0-9]+" | head -n 1 || true
}

# 203.0.113.5 -> 203-0-113-5.sslip.io (a public DNS name for that address, with no sign-up).
sslip_name() {
	printf '%s.sslip.io\n' "$(printf '%s' "$1" | tr . -)"
}

is_ipv4() {
	[[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

public_ip() {
	if [ -n "${PUBLIC_IP:-}" ]; then
		printf '%s\n' "$PUBLIC_IP"
		return
	fi
	local url ip
	for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
		ip=$(curl -4 -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || continue
		if is_ipv4 "$ip"; then
			printf '%s\n' "$ip"
			return 0
		fi
	done
	return 0 # nothing printed: the caller explains
}

# Reads `ss -ltnp` on stdin; prints the process listening on TCP port $1 (empty when free).
port_owner() {
	awk -v port=":$1" '
		NR > 1 && substr($4, length($4) - length(port) + 1) == port {
			match($0, /users:\(\("[^"]*"/)
			owner = RSTART ? substr($0, RSTART + 9, RLENGTH - 10) : "unknown"
			print owner
			exit
		}'
}

# Picks "<base url> <file name>" of the Node.js build to install, newest first.
node_candidates() {
	local glibc=$1 arch=$2 version
	if [ "$arch" = x64 ] && [ -n "$glibc" ] && ! version_ge "$glibc" 2.28; then
		# Official Node.js 18+ needs glibc 2.28; CentOS 7 has 2.17. The Node.js project's
		# unofficial builds include ones made for glibc 2.17.
		version=$(curl -fsSL --max-time 60 "$NODE_UNOFFICIAL/index.json" 2>/dev/null | latest_glibc217 "$NODE_MAJOR" || true)
		if [ -n "$version" ]; then
			printf '%s %s\n' "$NODE_UNOFFICIAL/$version" "node-$version-linux-x64-glibc-217"
		fi
		printf '%s %s\n' "$NODE_DIST/$NODE_FALLBACK" "node-$NODE_FALLBACK-linux-x64"
	else
		printf '%s %s\n' "$NODE_DIST/latest-v$NODE_MAJOR.x" "LATEST"
	fi
}

# Downloads, checks (SHA-256) and unpacks one Node.js build into $PREFIX/node.
install_node_from() { # base name
	local base=$1 name=$2 work archive unpack
	work=$(mktemp -d)
	fetch "$base/SHASUMS256.txt" "$work/SHASUMS256.txt" || return 1
	if [ "$name" = LATEST ]; then
		name=$(grep -oE "node-v$NODE_MAJOR\.[0-9]+\.[0-9]+-linux-$NODE_ARCH\.tar\.gz" "$work/SHASUMS256.txt" | head -n 1 || true)
		name=${name%.tar.gz}
		[ -n "$name" ] || return 1
	fi
	# .tar.gz where there is one; .tar.xz needs the xz tool.
	if grep -q " $name.tar.gz\$" "$work/SHASUMS256.txt"; then
		archive="$name.tar.gz" unpack=-xzf
	elif grep -q " $name.tar.xz\$" "$work/SHASUMS256.txt" && command -v xz >/dev/null 2>&1; then
		archive="$name.tar.xz" unpack=-xJf
	else
		return 1
	fi
	info "Tai $archive"
	fetch "$base/$archive" "$work/$archive" || return 1
	(cd "$work" && grep " $archive\$" SHASUMS256.txt | sha256sum -c - >/dev/null) || return 1
	rm -rf "$PREFIX/node.new"
	mkdir -p "$PREFIX/node.new"
	tar "$unpack" "$work/$archive" -C "$PREFIX/node.new" --strip-components=1 || return 1
	rm -rf "$work"
	"$PREFIX/node.new/bin/node" --version >/dev/null 2>&1 || return 1
	rm -rf "$PREFIX/node"
	mv "$PREFIX/node.new" "$PREFIX/node"
}

install_node() {
	local glibc line
	glibc=$(glibc_version)
	info "glibc ${glibc:-(khong ro)}, kien truc $NODE_ARCH"
	while read -r line; do
		[ -n "$line" ] || continue
		# shellcheck disable=SC2086 # two words: base and name
		if install_node_from $line; then
			info "Node.js $("$PREFIX/node/bin/node" --version) da san sang"
			return 0
		fi
		info "Ban nay khong dung duoc, thu ban khac..."
	done < <(node_candidates "$glibc" "$NODE_ARCH")
	fail "Khong cai duoc Node.js. Gui thong bao nay cho nguoi huong dan ban."
}

install_app() {
	mkdir -p "$PREFIX/app"
	write_server_js "$PREFIX/app/server.js"
	write_packs_js "$PREFIX/app/packs.js"
	write_package_json "$PREFIX/app/package.json"
	if [ -n "${LF2_NODE_MODULES_FROM:-}" ]; then
		rm -rf "$PREFIX/app/node_modules"
		cp -r "$LF2_NODE_MODULES_FROM" "$PREFIX/app/node_modules"
	else
		(cd "$PREFIX/app" && PATH="$PREFIX/node/bin:$PATH" npm install --omit=dev --no-audit --no-fund --loglevel=error </dev/null) ||
			fail "npm install loi. Kiem tra VPS co vao duoc Internet khong."
	fi
	chmod -R a+rX "$PREFIX/app"
}

data_ok() { # file
	[ -f "$1" ] && [ "$(stat -c %s "$1")" = "$LF2_DATA_SIZE" ] &&
		[ "$(sha256sum "$1" | cut -d ' ' -f 1)" = "$LF2_DATA_SHA256" ]
}

# Keeps the LF2 installer in $PREFIX/data for the relay to serve; HAVE_DATA=1 when it is there.
# Never fatal: without it the game page downloads from archive.org as before.
install_game_data() {
	local target=$PREFIX/data/lf2-installer.data url work
	HAVE_DATA=0
	mkdir -p "$PREFIX/data"
	if data_ok "$target"; then
		HAVE_DATA=1
		info "Du lieu game da co san"
		return 0
	fi
	work=$(mktemp -d)
	for url in $LF2_DATA_URLS; do
		info "Tai tu $(printf '%s' "$url" | cut -d / -f 3) ..."
		if fetch "$url" "$work/lf2" 2>/dev/null && data_ok "$work/lf2"; then
			install -m 0644 "$work/lf2" "$target"
			HAVE_DATA=1
			break
		fi
		info "  khong duoc, thu nguon khac"
		rm -f "$work/lf2"
	done
	rm -rf "$work"
	if [ "$HAVE_DATA" = 1 ]; then
		info "Du lieu game da luu tren VPS"
	else
		info "Chua tai duoc du lieu game; trang game se tai tu archive.org nhu truoc."
	fi
	chmod a+rx "$PREFIX/data"
}

install_caddy() {
	local work archive
	work=$(mktemp -d)
	archive="caddy_${CADDY_VERSION}_linux_${CADDY_ARCH}.tar.gz"
	info "Tai $archive"
	fetch "$CADDY_RELEASES/v$CADDY_VERSION/$archive" "$work/$archive" || fail "Khong tai duoc Caddy."
	fetch "$CADDY_RELEASES/v$CADDY_VERSION/caddy_${CADDY_VERSION}_checksums.txt" "$work/checksums.txt" ||
		fail "Khong tai duoc checksum cua Caddy."
	(cd "$work" && grep " $archive\$" checksums.txt | sha512sum -c - >/dev/null) || fail "Caddy tai ve bi loi (checksum sai)."
	tar -xzf "$work/$archive" -C "$work" caddy
	mkdir -p "$PREFIX/bin"
	install -m 0755 "$work/caddy" "$PREFIX/bin/caddy"
	rm -rf "$work"
	CADDY_USER=lf2caddy
	if ! command -v setcap >/dev/null 2>&1 || ! setcap 'cap_net_bind_service=+ep' "$PREFIX/bin/caddy" 2>/dev/null; then
		CADDY_USER=root # without setcap, only root may listen on ports 80 and 443
	fi
	mkdir -p "$PREFIX/caddy-data" "$PREFIX/caddy-config"
	[ "$CADDY_USER" = root ] || chown -R lf2caddy: "$PREFIX/caddy-data" "$PREFIX/caddy-config"
	write_caddyfile "$PREFIX/Caddyfile"
	info "Caddy $CADDY_VERSION da san sang (chay bang tai khoan $CADDY_USER)"
}

# Caddy's configuration for $DOMAIN in $CADDY_MODE. "full": ports 80 (redirects, HTTP challenge)
# and 443. "tls-only": port 443 alone, the certificate through the TLS-ALPN challenge, so another
# web server keeps port 80. Certificates come from Let's Encrypt; the tests set LF2_ACME_DIR and
# LF2_ACME_ROOT to use a local test CA instead.
write_caddyfile() { # file
	{
		printf '# Written by install-vps.sh (%s). HTTPS for the OpenLF2 relay; the certificate renews by itself.\n' "$CADDY_MODE"
		printf '{\n\tadmin off\n'
		[ "$CADDY_MODE" != tls-only ] || printf '\tauto_https disable_redirects\n'
		printf '}\n\n%s {\n\ttls {\n\t\tissuer acme {\n' "$DOMAIN"
		[ -z "${LF2_ACME_DIR:-}" ] || printf '\t\t\tdir %s\n' "$LF2_ACME_DIR"
		[ -z "${LF2_ACME_ROOT:-}" ] || printf '\t\t\ttrusted_roots %s\n' "$LF2_ACME_ROOT"
		[ "$CADDY_MODE" != tls-only ] || printf '\t\t\tdisable_http_challenge\n'
		printf '\t\t}\n\t}\n\treverse_proxy 127.0.0.1:%s\n}\n' "$RELAY_PORT"
	} >"$1"
}

ensure_user() { # name home
	if ! id -u "$1" >/dev/null 2>&1; then
		useradd --system --no-create-home --home-dir "$2" --shell /sbin/nologin "$1"
	fi
}

write_units() {
	write_relay_unit
	[ "$CADDY_MODE" = apache ] || write_caddy_unit
}

# The key for uploading mods at /admin: the one an earlier run made (or ADMIN_KEY=...), else a new one.
# It lives in $PREFIX/relay.env, readable by root only (the service reads it before dropping to lf2relay).
keep_admin_key() {
	if [ -z "${ADMIN_KEY:-}" ] && [ -f "$PREFIX/relay.env" ]; then
		ADMIN_KEY=$(sed -n 's/^ADMIN_KEY=//p' "$PREFIX/relay.env" | head -n 1 || true)
	fi
	if [ -z "${ADMIN_KEY:-}" ]; then
		ADMIN_KEY=$(od -An -N 12 -tx1 /dev/urandom | tr -d ' \n')
	fi
	case "$ADMIN_KEY" in
	*[!A-Za-z0-9._-]* | ?????? | ????? | ???? | ??? | ?? | ?) fail "ADMIN_KEY chi gom chu, so, dau . _ - va dai it nhat 7 ky tu." ;;
	esac
}

write_relay_env() {
	(umask 077 && printf 'ADMIN_KEY=%s\n' "$ADMIN_KEY" >"$PREFIX/relay.env")
	install -d -m 755 "$PREFIX/data"
	install -d -m 755 -o lf2relay -g lf2relay "$PREFIX/data/packs" 2>/dev/null || install -d -m 755 "$PREFIX/data/packs"
	chown lf2relay "$PREFIX/data/packs" 2>/dev/null || true
}

# A rerun keeps the game pages an earlier run allowed, unless it says otherwise (ALLOWED_ORIGINS= clears).
keep_allowed_origins() {
	[ -z "${ALLOWED_ORIGINS+set}" ] || return 0
	ALLOWED_ORIGINS=$(sed -n 's/^Environment="ALLOWED_ORIGINS=\(.*\)"$/\1/p' "$SYSTEMD_DIR/lf2-relay.service" 2>/dev/null | head -n 1 || true)
}

write_relay_unit() {
	cat >"$SYSTEMD_DIR/lf2-relay.service" <<EOF
# Written by install-vps.sh
[Unit]
Description=OpenLF2 online relay
After=network-online.target
Wants=network-online.target

[Service]
User=lf2relay
WorkingDirectory=$PREFIX/app
Environment="PORT=$RELAY_PORT"
Environment="HOST=127.0.0.1"
Environment="TRUST_PROXY=1"
Environment="ALLOWED_ORIGINS=${ALLOWED_ORIGINS:-}"
Environment="INSTALLER_FILE=$PREFIX/data/lf2-installer.data"
Environment="PACKS_DIR=$PREFIX/data/packs"
EnvironmentFile=-$PREFIX/relay.env
ExecStart=$PREFIX/node/bin/node $PREFIX/app/server.js
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

write_caddy_unit() {
	cat >"$SYSTEMD_DIR/lf2-caddy.service" <<EOF
# Written by install-vps.sh
[Unit]
Description=HTTPS for the OpenLF2 relay (Caddy)
After=network-online.target lf2-relay.service
Wants=network-online.target

[Service]
User=$CADDY_USER
Environment="HOME=$PREFIX/caddy-data"
Environment="XDG_DATA_HOME=$PREFIX/caddy-data"
Environment="XDG_CONFIG_HOME=$PREFIX/caddy-config"
ExecStart=$PREFIX/bin/caddy run --config $PREFIX/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

# The ports Caddy needs in $CADDY_MODE, as words for messages.
caddy_ports() {
	if [ "$CADDY_MODE" = tls-only ]; then printf 'cong 443'; else printf 'cong 80 va 443'; fi
}

open_firewall() {
	if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		if [ "$CADDY_MODE" = tls-only ]; then
			firewall-cmd --quiet --permanent --add-service=https
		else
			firewall-cmd --quiet --permanent --add-service=http --add-service=https
		fi
		firewall-cmd --quiet --reload
		info "Da mo $(caddy_ports) tren firewalld"
	elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		[ "$CADDY_MODE" = tls-only ] || ufw allow 80/tcp >/dev/null
		ufw allow 443/tcp >/dev/null
		info "Da mo $(caddy_ports) tren ufw"
	else
		info "Khong thay firewalld/ufw dang chay, bo qua"
	fi
}

wait_for() { # url seconds [extra curl options]
	local url=$1 seconds=$2 waited=0
	shift 2
	while [ "$waited" -lt "$seconds" ]; do
		if curl -fsS --max-time 5 "$@" -o /dev/null "$url" 2>/dev/null; then
			return 0
		fi
		sleep 3
		waited=$((waited + 3))
	done
	return 1
}

# The program holding TCP port $2 in the `ss -ltnp` output $1, unless it is this relay's own Caddy
# from an earlier run. Empty when the port is free.
other_owner() { # ss-output port
	local owner
	owner=$(printf '%s\n' "$1" | port_owner "$2" || true)
	if [ "$owner" = caddy ] && "$SYSTEMCTL" is-active --quiet lf2-caddy.service 2>/dev/null; then
		owner=""
	fi
	printf '%s' "$owner"
}

# Sets CADDY_MODE: "apache" with APACHE_SITE (behind that Apache website, no Caddy); otherwise "full"
# when ports 80 and 443 are free, "tls-only" when another program keeps port 80 (it is left alone).
# Stops with an explanation when port 443 is taken.
check_ports() {
	local listening="" owner80="" owner443=""
	CADDY_MODE=full
	if command -v ss >/dev/null 2>&1; then
		listening=$(ss -ltnp 2>/dev/null || true)
		owner80=$(other_owner "$listening" 80)
		owner443=$(other_owner "$listening" 443)
	fi
	if [ -n "$APACHE_SITE" ]; then
		APACHE_SITE=$(normalize_site "$APACHE_SITE")
		if ! [[ $APACHE_SITE =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || is_ipv4 "$APACHE_SITE"; then
			fail "APACHE_SITE=\"$APACHE_SITE\" khong phai ten mien (vi du dung: APACHE_SITE=example.com). Chua co gi bi thay doi."
		fi
		if [ -n "$listening" ] && [ "$owner443" != httpd ]; then
			fail "APACHE_SITE chi dung khi Apache (httpd) dang chay website o cong 443; o day cong 443 ${owner443:-chua co ai dung}. Chua co gi bi thay doi."
		fi
		CADDY_MODE=apache
		info "Di chung website https://$APACHE_SITE cua Apache (httpd), khong dong toi cac file cua website"
		return 0
	fi
	[ -z "$owner443" ] || port_443_taken "$owner443"
	if [ -n "$owner80" ]; then
		CADDY_MODE=tls-only
		info "Cong 80 dang do \"$owner80\" dung: giu nguyen, khong dong cham toi."
		info "Relay se chi dung cong 443."
	fi
}

port_443_taken() { # owner
	local example=""
	{
		printf '\n[LOI] Cong 443 (HTTPS) dang duoc chuong trinh "%s" dung.\n' "$1"
		printf '      Relay can rieng cong 443, nen chua cai duoc. Chua co gi bi thay doi.\n'
		if [ "$1" = httpd ] && command -v "$HTTPD" >/dev/null 2>&1; then
			printf '      Website ma httpd dang chay:\n'
			"$HTTPD" -S 2>/dev/null | grep -oE '(namevhost|default server) [^ ]+' | awk '{print "         " $NF}' | sort -u || true
			example=$("$HTTPD" -S 2>/dev/null | apache_https_names | grep -vE '^[0-9.]+$' | head -n 1 || true)
			printf '      - Neu chu website dong y cho relay di chung website (qua Apache, khong sua\n'
			printf '        file nao cua website): chay lai lenh cai dat voi APACHE_SITE=<ten website>\n'
			printf '        dat truoc chu bash, vi du:  ... | APACHE_SITE=%s bash\n' "${example:-ten-website.com}"
		fi
		case "$1" in
		httpd | nginx | apache2)
			printf '      - Neu ban KHONG dung website nay, tat no bang 2 lenh:\n'
			printf '            systemctl stop %s\n' "$1"
			printf '            systemctl disable %s\n' "$1"
			printf '        roi chay lai lenh cai dat.\n'
			printf '      - Neu ban CO dung: gui toan bo thong bao nay cho nguoi huong dan ban.\n'
			;;
		*) printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n' ;;
		esac
	} >&2
	exit 1
}

# --- Behind an existing Apache website (CADDY_MODE=apache) -------------------------------------------

# True when Apache serves HTTPS for $1, reading `httpd -S` on stdin (names, aliases, default servers).
apache_serves_https() { # site
	awk -v site="$1" '
		$1 ~ /:443$/ { in443 = 1; if ($2 == site) found = 1; next }
		$1 ~ /:[0-9]+$/ { in443 = 0; next }
		in443 && $1 == "port" && $2 == "443" && $3 == "namevhost" && $4 == site { found = 1 }
		in443 && $1 == "default" && $2 == "server" && $3 == site { found = 1 }
		in443 && $1 == "alias" && $2 == site { found = 1 }
		END { exit found ? 0 : 1 }'
}

# The names Apache serves over HTTPS, from `httpd -S` on stdin.
apache_https_names() {
	awk '
		$1 ~ /:443$/ { in443 = 1; if ($2 != "is") print $2; next }
		$1 ~ /:[0-9]+$/ { in443 = 0; next }
		in443 && $1 == "port" && $3 == "namevhost" { print $4 }
		in443 && $1 == "alias" { print $2 }' | sort -u
}

# True when `httpd -M` on stdin lists module $1.
apache_has_module() { # module
	grep -qE "^[[:space:]]*$1[[:space:]]"
}

# Where to reach Apache's port 443 from this machine, from `ss -ltn(p)` output: 127.0.0.1 when it
# listens on every address (the usual "Listen 443"), else the first IPv4 address it listens on.
apache_listen_address() { # ss-output
	printf '%s\n' "$1" | awk '
		NR > 1 && $4 ~ /:443$/ {
			address = substr($4, 1, length($4) - 4)
			if (address == "*" || address == "0.0.0.0" || address == "::" || address == ":::" || address == "[::]") { wildcard = 1 }
			else if (first == "" && address ~ /^[0-9.]+$/) { first = address }
		}
		END { print (wildcard || first == "") ? "127.0.0.1" : first }'
}

# A free local port for the relay behind Apache, from `ss -ltnp` output. With SELinux enforcing,
# Apache may connect only to ports labelled http_port_t; 8008 and 8009 are, and are rarely used.
pick_relay_port() { # ss-output
	local candidates="8787 8008 8009 18787" port
	[ "$(getenforce 2>/dev/null || true)" != Enforcing ] || candidates="8008 8009"
	for port in $candidates; do
		if [ -z "$(printf '%s\n' "$1" | port_owner "$port" || true)" ]; then
			printf '%s' "$port"
			return 0
		fi
	done
	return 1
}

# "https://Example.com/x" -> "example.com": the site name as Apache knows it, however it was pasted.
normalize_site() { # site
	local site=${1#*://}
	site=${site%%/*}
	site=${site%%:*}
	printf '%s' "$site" | tr 'A-Z' 'a-z'
}

# The IPv4 addresses that players' browsers get for name $1, one per line (none when it has none):
# from public DNS over HTTPS (Google, then Cloudflare), else dig, else this machine's resolver.
site_addresses() { # name
	local answer address
	if [ -n "${LF2_SITE_ADDRESSES+set}" ]; then # tests
		for address in $LF2_SITE_ADDRESSES; do printf '%s\n' "$address"; done
		return 0
	fi
	answer=$(curl -fsS --max-time 10 "https://dns.google/resolve?name=$1&type=A" 2>/dev/null ||
		curl -fsS --max-time 10 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null ||
		true)
	case "$answer" in
	*'"Status"'*)
		printf '%s' "$answer" | grep -oE '"data": *"[0-9]+(\.[0-9]+){3}"' | grep -oE '[0-9]+(\.[0-9]+){3}' | sort -u || true
		return 0
		;;
	esac
	if command -v dig >/dev/null 2>&1; then
		dig +short A "$1" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u || true
		return 0
	fi
	getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u || true
}

# This machine's IPv4 addresses, one per line: its public one ($1) and its network interfaces'.
own_addresses() { # public-ip
	{
		[ -z "$1" ] || printf '%s\n' "$1"
		if command -v ip >/dev/null 2>&1; then
			ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d / -f 1
		else
			hostname -I 2>/dev/null | tr ' ' '\n'
		fi
	} | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u || true
}

# Reads the site and port a previous installation in Apache mode used, so a rerun keeps them.
load_apache_state() {
	local key value
	[ -f "$PREFIX/apache-site" ] || return 0
	while IFS='=' read -r key value; do
		case "$key" in
		APACHE_SITE) [ -n "$APACHE_SITE" ] || APACHE_SITE=$value ;;
		RELAY_PORT) SAVED_RELAY_PORT=$value ;;
		esac
	done <"$PREFIX/apache-site"
}

save_apache_state() {
	printf 'APACHE_SITE=%s\nRELAY_PORT=%s\n' "$APACHE_SITE" "$RELAY_PORT" >"$PREFIX/apache-site"
}

# Checks everything before anything is installed: the site, Apache's modules, our file, a port.
apache_preflight() {
	local vhosts modules module listening owner own address
	command -v "$HTTPD" >/dev/null 2>&1 || fail "Khong tim thay Apache (lenh $HTTPD) tren may nay. Chua co gi bi thay doi."
	[ -d "$(dirname "$APACHE_CONF")" ] || fail "Khong thay thu muc cau hinh $(dirname "$APACHE_CONF") cua Apache. Chua co gi bi thay doi."
	vhosts=$("$HTTPD" -S 2>/dev/null || true)
	if ! printf '%s\n' "$vhosts" | apache_serves_https "$APACHE_SITE"; then
		{
			printf '\n[LOI] Apache khong co website HTTPS ten "%s". Chua co gi bi thay doi.\n' "$APACHE_SITE"
			printf '      Cac website HTTPS cua Apache:\n'
			printf '%s\n' "$vhosts" | apache_https_names | sed 's/^/         /'
			printf '      Chay lai lenh voi APACHE_SITE= mot ten o tren (ten mien, khong phai so IP).\n'
		} >&2
		exit 1
	fi
	modules=$("$HTTPD" -M 2>/dev/null || true)
	for module in proxy_module proxy_http_module proxy_wstunnel_module; do
		printf '%s\n' "$modules" | apache_has_module "$module" ||
			fail "Apache chua bat module $module, ma relay can. Chua co gi bi thay doi. Gui thong bao nay cho nguoi huong dan ban."
	done
	if [ -f "$APACHE_CONF" ] && ! grep -q 'Written by install-vps.sh' "$APACHE_CONF"; then
		fail "Da co file $APACHE_CONF khong do trinh cai dat nay tao; khong ghi de. Chua co gi bi thay doi."
	fi
	listening=$(ss -ltnp 2>/dev/null || true)
	if [ -n "$SAVED_RELAY_PORT" ]; then
		owner=$(printf '%s\n' "$listening" | port_owner "$SAVED_RELAY_PORT" || true)
		case "$owner" in "" | node) RELAY_PORT=$SAVED_RELAY_PORT ;; *) SAVED_RELAY_PORT="" ;; esac
	fi
	if [ -z "$SAVED_RELAY_PORT" ]; then
		RELAY_PORT=$(pick_relay_port "$listening") ||
			fail "Khong con cong trong cho relay (8008, 8009...). Chua co gi bi thay doi. Gui thong bao nay cho nguoi huong dan ban."
	fi
	APACHE_ADDRESS=$(apache_listen_address "$listening")
	# Where players' browsers will go for the site: this server, or (through a CDN) maybe not.
	SERVER_IP=$(public_ip || true)
	SITE_ADDRESSES=$(site_addresses "$APACHE_SITE" | tr '\n' ' ' | sed 's/ *$//')
	[ -n "$SITE_ADDRESSES" ] ||
		fail "Ten mien $APACHE_SITE chua tro ve dia chi IP nao (khong tim thay ban ghi DNS). Chua co gi bi thay doi."
	own=$(own_addresses "$SERVER_IP")
	SITE_HERE=0
	for address in $SITE_ADDRESSES; do
		if printf '%s\n' "$own" | grep -qxF "$address"; then SITE_HERE=1; fi
	done
	if [ "$SITE_HERE" = 1 ]; then
		info "Ten mien $APACHE_SITE tro ve VPS nay ($SITE_ADDRESSES)"
	else
		info "Ten mien $APACHE_SITE tro toi $SITE_ADDRESSES, khong phai IP cua VPS nay (${SERVER_IP:-khong ro});"
		info "co the qua CDN (vi du Cloudflare): se kiem tra lai sau khi noi relay."
	fi
	info "Relay se o 127.0.0.1:$RELAY_PORT, Apache chuyen https://$APACHE_SITE$APACHE_PATH/ toi do"
}

apache_conf_text() {
	cat <<EOF
# Written by install-vps.sh for the OpenLF2 relay (service lf2-relay).
# https://$APACHE_SITE$APACHE_PATH/ (the same path on this server's other sites too) goes to the relay on
# 127.0.0.1:$RELAY_PORT; its WebSocket is $APACHE_PATH/relay. Nothing else of the sites changes.
# To undo: delete this file and run "systemctl reload $APACHE_SERVICE", or run the installer with --uninstall.
# disablereuse: Apache 2.4.6 (CentOS 7) would otherwise keep a finished WebSocket's connection open and
# send the next player's handshake down it.
<IfModule mod_proxy.c>
	ProxyPass "$APACHE_PATH/relay" "ws://127.0.0.1:$RELAY_PORT/relay" retry=0 disablereuse=On
	ProxyPass "$APACHE_PATH/" "http://127.0.0.1:$RELAY_PORT/" retry=0 disablereuse=On
	ProxyPassReverse "$APACHE_PATH/" "http://127.0.0.1:$RELAY_PORT/"
</IfModule>
EOF
}

# Plays two short rounds through the relay's WebSocket at $1 (wss://site/path/relay), reached at
# address $2 (the TLS name stays the URL's), as a page from origin $3 (may be empty), in rooms $4 and
# $4+1: a host and a guest pair, bytes pass both ways, the guest leaves and the host is told. Two rounds,
# because a web server that reuses a finished WebSocket's connection fails only the second. Prints what
# went wrong, if anything.
ws_check() { # url address origin room
	NODE_PATH="$PREFIX/app/node_modules" "$PREFIX/node/bin/node" -e '
		const WebSocket = require("ws");
		const [base, address, origin, firstRoom] = process.argv.slice(1);
		const family = address.includes(":") ? 6 : 4;
		const lookup = (host, options, callback) =>
			options && options.all ? callback(null, [{ address, family }]) : callback(null, address, family);
		const options = { lookup, rejectUnauthorized: false, handshakeTimeout: 10000 };
		if (origin) options.origin = origin;
		const fail = (problem) => { console.log(problem); process.exit(1); };
		setTimeout(() => fail("timeout"), 40000);
		function open(role, room) {
			const ws = new WebSocket(base + "?role=" + role + "&room=" + room, options);
			const got = { texts: [], bytes: 0, close: "" };
			ws.on("message", (data, binary) => {
				if (binary) { got.bytes += data.length; return; }
				let message = {};
				try { message = JSON.parse(String(data)); } catch (error) { message.t = "? " + String(data).slice(0, 60); }
				got.texts.push(message.t);
			});
			ws.on("unexpected-response", (request, response) => fail(role + ": HTTP " + response.statusCode));
			ws.on("close", (code, reason) => { got.close = code + " " + String(reason || ""); });
			ws.on("error", (error) => fail(role + ": " + error.message));
			return { ws, got };
		}
		const until = (problem, test) => new Promise((resolve) => {
			const started = Date.now();
			const tick = () => (test() ? resolve() : Date.now() - started > 8000 ? fail(problem) : setTimeout(tick, 20));
			tick();
		});
		async function round(room) {
			const host = open("host", room);
			await until("host: no answer", () => host.got.texts.length || host.got.close);
			if (host.got.texts[0] !== "waiting") fail("host: " + (host.got.close ? "closed " + host.got.close : host.got.texts[0]));
			const guest = open("join", room);
			await until("no pairing", () => host.got.texts.includes("paired") && guest.got.texts.includes("paired"));
			host.ws.send(Buffer.from([1, 2, 3, 4]));
			guest.ws.send(Buffer.from([5, 6, 7]));
			await until("bytes did not pass", () => guest.got.bytes === 4 && host.got.bytes === 3);
			guest.ws.close();
			await until("host not told that the guest left", () => host.got.close);
			if (host.got.close.indexOf("4006") !== 0) fail("host closed " + host.got.close);
		}
		(async () => {
			await round(firstRoom);
			await round(String(Number(firstRoom) + 1));
			process.exit(0);
		})();
	' "$1" "$2" "${3:-}" "$4"
}

# Checks the relay through Apache (HTTP, then WebSocket). Prints what went wrong, if anything.
apache_verify() {
	local base="https://$APACHE_SITE$APACHE_PATH" body="" waited=0 room reason origin
	# -k: the check is about the route through Apache; the site's own certificate is not our business,
	# and an old CA bundle on this machine may not know its issuer.
	while [ "$waited" -lt 20 ]; do
		body=$(curl -sS --max-time 5 -k --noproxy '*' --resolve "$APACHE_SITE:443:$APACHE_ADDRESS" "$base/healthz" 2>&1 || true)
		case "$body" in *'"ok":true'*) break ;; esac
		sleep 2
		waited=$((waited + 2))
	done
	case "$body" in
	*'"ok":true'*) ;;
	*)
		printf '%s/healthz tra ve: %s' "$base" "$(printf '%s' "$body" | head -c 200 | tr '\n' ' ')"
		return 1
		;;
	esac
	room=$(printf '9%011d' "$((RANDOM * 32768 + RANDOM))")
	# With ALLOWED_ORIGINS the relay only answers those pages, so the check comes as the first of them.
	origin=$(printf '%s' "${ALLOWED_ORIGINS:-}" | cut -d , -f 1 | tr -d '[:space:]')
	if ! reason=$(ws_check "wss://$APACHE_SITE$APACHE_PATH/relay" "$APACHE_ADDRESS" "$origin" "$room"); then
		printf 'WebSocket qua Apache khong chay (%s)' "$reason"
		return 1
	fi
}

# Checks the relay the way players reach it: $APACHE_SITE at each address public DNS gives for it.
# Prints what went wrong, if anything.
apache_public_check() {
	local address work status server port=${LF2_PUBLIC_PORT:-443}
	work=$(mktemp -d)
	for address in $SITE_ADDRESSES; do
		status=$(curl -sS --connect-timeout 5 --max-time 10 -k --noproxy '*' --resolve "$APACHE_SITE:$port:$address" \
			-D "$work/headers" -o "$work/body" -w '%{http_code}' "https://$APACHE_SITE:$port$APACHE_PATH/healthz" 2>"$work/error" || true)
		if grep -q '"ok":true' "$work/body" 2>/dev/null; then continue; fi
		server=$(grep -i '^server:' "$work/headers" 2>/dev/null | head -n 1 | cut -d : -f 2- | tr -d '\r' | sed 's/^ *//' || true)
		if [ "${status:-000}" = 000 ]; then
			printf '%s: %s' "$address" "$(head -c 160 "$work/error" | tr '\n' ' ')"
		else
			printf '%s tra ve HTTP %s%s' "$address" "$status" "${server:+, may chu: $server}"
		fi
		rm -rf "$work"
		return 1
	done
	rm -rf "$work"
}

apache_reload() {
	"$SYSTEMCTL" reload "$APACHE_SERVICE"
}

# Puts the relay behind Apache: writes $APACHE_CONF, checks Apache's whole configuration, reloads it
# gracefully, and checks the relay through it. On any failure the file is removed (or the previous one
# restored) and Apache reloaded as it was, so the websites keep running as before.
apache_apply() {
	local previous="" log problem=""
	log=$(mktemp)
	if [ -f "$APACHE_CONF" ]; then
		previous=$(mktemp)
		cp "$APACHE_CONF" "$previous"
	fi
	apache_conf_text >"$APACHE_CONF"
	chmod 0644 "$APACHE_CONF"
	if ! "$APACHECTL" configtest >"$log" 2>&1; then
		apache_undo "$previous" 0
		{
			printf '\n[LOI] Apache bao loi cau hinh; da go file vua them, website khong bi anh huong.\n'
			sed 's/^/      /' "$log"
			printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n'
		} >&2
		rm -f "$log"
		exit 1
	fi
	if ! apache_reload >"$log" 2>&1; then
		apache_undo "$previous" 1
		{
			printf '\n[LOI] Apache khong nap lai duoc; da go file vua them.\n'
			sed 's/^/      /' "$log"
			printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n'
		} >&2
		rm -f "$log"
		exit 1
	fi
	rm -f "$log"
	info "Apache da nap them file $APACHE_CONF (nap lai nhe, website van chay)"
	problem=$(apache_verify) || true
	if [ -n "$problem" ]; then
		apache_undo "$previous" 1
		{
			printf '\n[LOI] Relay chua di qua Apache duoc: %s\n' "$problem"
			printf '      Da go file vua them va nap lai cau hinh cu; website khong bi anh huong.\n'
			if [ "$(getenforce 2>/dev/null || true)" = Enforcing ]; then
				printf '      (SELinux dang bat.)\n'
			fi
			printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n'
		} >&2
		exit 1
	fi
	info "Da kiem tra: https://$APACHE_SITE$APACHE_PATH/ chuyen toi relay (ca HTTP va WebSocket)"
	if ! problem=$(apache_public_check); then
		if [ "$SITE_HERE" = 1 ]; then
			# The name leads here; this machine may just not reach itself by its public address.
			info "Ghi chu: tu VPS chua mo duoc relay qua dia chi cong khai ($problem);"
			info "hay mo https://$APACHE_SITE$APACHE_PATH/healthz tren trinh duyet cua ban de kiem tra."
		else
			apache_undo "$previous" 1
			{
				printf '\n[LOI] Ten mien %s dang tro toi may chu khac (%s), khong phai VPS nay (%s).\n' \
					"$APACHE_SITE" "$SITE_ADDRESSES" "${SERVER_IP:-khong ro IP}"
				printf '      Nguoi choi mo %s se vao may chu kia, khong toi duoc relay tren VPS nay.\n' "$APACHE_SITE"
				printf '      (%s)\n' "$problem"
				printf '      Da go file vua them va nap lai cau hinh cu; website khong bi anh huong.\n'
				printf '      Gui toan bo thong bao nay cho nguoi huong dan ban.\n'
			} >&2
			exit 1
		fi
	elif [ "$SITE_HERE" = 0 ]; then
		info "Da kiem tra qua dia chi cong khai cua $APACHE_SITE ($SITE_ADDRESSES): relay tra loi dung"
	fi
	rm -f "${previous:-/nonexistent}"
}

# Undoes apache_apply after a failure: the previous file back (or ours removed), Apache reloaded when it
# had loaded ours, and on a first installation the relay stopped again, so the server is as it was.
apache_undo() { # previous-copy reloaded(0/1)
	apache_restore "$1"
	[ "$2" = 0 ] || apache_reload >/dev/null 2>&1 || true
	if [ -z "$1" ]; then
		"$SYSTEMCTL" stop lf2-relay.service >/dev/null 2>&1 || true
		"$SYSTEMCTL" disable lf2-relay.service >/dev/null 2>&1 || true
	fi
}

apache_restore() { # copy of the previous file, or empty when there was none
	if [ -n "$1" ]; then
		cp "$1" "$APACHE_CONF"
		rm -f "$1"
	else
		rm -f "$APACHE_CONF"
	fi
}

# Removes the relay's Apache file, if this installer wrote one, and reloads Apache.
apache_unconfigure() {
	[ -f "$APACHE_CONF" ] && grep -q 'Written by install-vps.sh' "$APACHE_CONF" || return 0
	rm -f "$APACHE_CONF"
	if "$APACHECTL" configtest >/dev/null 2>&1 && apache_reload >/dev/null 2>&1; then
		info "Da go $APACHE_CONF khoi Apache va nap lai"
	else
		info "Da xoa $APACHE_CONF; hay chay: systemctl reload $APACHE_SERVICE"
	fi
}

uninstall() {
	say "Go relay"
	apache_unconfigure
	"$SYSTEMCTL" stop lf2-caddy.service lf2-relay.service 2>/dev/null || true
	"$SYSTEMCTL" disable lf2-caddy.service lf2-relay.service >/dev/null 2>&1 || true
	rm -f "$SYSTEMD_DIR/lf2-caddy.service" "$SYSTEMD_DIR/lf2-relay.service"
	"$SYSTEMCTL" daemon-reload || true
	rm -rf "$PREFIX"
	userdel lf2relay 2>/dev/null || true
	userdel lf2caddy 2>/dev/null || true
	info "Xong. (Cong 80 va 443 tren tuong lua van mo; dong lai neu ban muon.)"
}

main() {
	if [ "${1:-}" = --uninstall ]; then
		[ "$(id -u)" -eq 0 ] || fail "Hay chay bang tai khoan root."
		uninstall
		return
	fi

	say "Kiem tra may chu (trinh cai dat phien ban $INSTALLER_VERSION)"
	[ "$(id -u)" -eq 0 ] || fail "Hay chay bang tai khoan root (dang nhap root, hoac: ... | sudo bash)."
	[ -d /run/systemd/system ] || [ -n "${LF2_TEST_MODE:-}" ] || fail "May chu nay khong dung systemd."
	local os="Linux"
	if [ -r /etc/os-release ]; then
		os=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}")
	fi
	info "He dieu hanh: $os"
	case "$(uname -m)" in
	x86_64 | amd64) NODE_ARCH=x64 CADDY_ARCH=amd64 ;;
	aarch64 | arm64) NODE_ARCH=arm64 CADDY_ARCH=arm64 ;;
	*) fail "Kien truc $(uname -m) chua duoc ho tro." ;;
	esac
	load_apache_state
	check_ports
	keep_allowed_origins
	[ -z "$ALLOWED_ORIGINS" ] || info "Chi trang game o $ALLOWED_ORIGINS duoc dung relay"
	keep_admin_key

	if [ "$CADDY_MODE" = apache ]; then
		apache_preflight
	elif [ -z "${DOMAIN:-}" ]; then
		local ip
		ip=$(public_ip || true)
		[ -n "$ip" ] || fail "Khong tim duoc dia chi IP cong khai cua VPS. Thu lai, hoac chay voi DOMAIN=ten-mien-cua-ban."
		DOMAIN=$(sslip_name "$ip")
		info "IP cong khai: $ip  ->  ten mien: $DOMAIN"
	else
		info "Ten mien: $DOMAIN"
	fi

	say "Cai Node.js"
	mkdir -p "$PREFIX"
	install_node

	say "Cai relay"
	ensure_user lf2relay "$PREFIX/app"
	[ "$CADDY_MODE" = apache ] || ensure_user lf2caddy "$PREFIX/caddy-data"
	install_app
	write_relay_env
	info "Relay da cai vao $PREFIX/app"

	say "Luu du lieu game LF2 tren VPS (khoang 30 MB)"
	install_game_data

	if [ "$CADDY_MODE" != apache ]; then
		say "Cai Caddy (HTTPS)"
		install_caddy

		say "Mo $(caddy_ports)"
		open_firewall
	fi

	say "Khoi dong dich vu"
	write_units
	"$SYSTEMCTL" daemon-reload
	if [ "$CADDY_MODE" = apache ]; then
		"$SYSTEMCTL" enable lf2-relay.service >/dev/null 2>&1 ||
			fail "Khong bat duoc dich vu. Gui thong bao nay cho nguoi huong dan ban."
	else
		"$SYSTEMCTL" enable lf2-relay.service lf2-caddy.service >/dev/null 2>&1 ||
			fail "Khong bat duoc dich vu. Gui thong bao nay cho nguoi huong dan ban."
	fi
	"$SYSTEMCTL" restart lf2-relay.service
	wait_for "http://127.0.0.1:$RELAY_PORT/healthz" 30 --noproxy '*' ||
		fail "Relay khong chay. Xem loi bang lenh: journalctl -u lf2-relay -n 30 --no-pager"
	info "Relay dang chay"

	if [ "$CADDY_MODE" = apache ]; then
		say "Noi relay vao website $APACHE_SITE (Apache)"
		apache_apply
		save_apache_state
		finish_apache
		return 0
	fi
	"$SYSTEMCTL" restart lf2-caddy.service
	info "Dang lay chung chi HTTPS cho $DOMAIN (co the mat 1-2 phut)..."
	# (bash 4.2 on CentOS 7 treats an empty array as unset under set -u, so no array here)
	local strict=--fail
	[ -z "${LF2_TEST_MODE:-}" ] || strict=-k
	if ! wait_for "https://$DOMAIN/healthz" 150 "$strict"; then
		if wait_for "https://$DOMAIN/healthz" 6 -k; then
			info "HTTPS da chay, nhung may chu nay (he dieu hanh cu) chua tin chung chi moi."
			info "Hay mo https://$DOMAIN/healthz tren trinh duyet cua ban de kiem tra."
		else
			{
				printf '\n[LOI] Chua lay duoc chung chi HTTPS cho %s.\n' "$DOMAIN"
				printf '      Thuong la do tuong lua cua nha cung cap VPS chan %s:\n' "$(caddy_ports)"
				printf '      vao trang quan ly VPS, mo %s (TCP), roi chay lai lenh cai dat.\n' "$(caddy_ports)"
				printf '      Neu van loi, gui toan bo thong bao nay cho nguoi huong dan ban.\n'
				caddy_errors
			} >&2
			exit 1
		fi
	fi

	cat <<EOF

============================================================
  XONG! Dia chi relay cua ban:

      wss://$DOMAIN/relay

  Dan dia chi nay vao o "Relay" trong khung "Online play"
  tren trang game. Kiem tra nhanh: mo https://$DOMAIN/healthz
  tren trinh duyet, thay {"ok":true,...} la dung.

  Tai ban mod len relay:  https://$DOMAIN/admin
  Ma quan tri (ADMIN_KEY): $ADMIN_KEY
  (xem lai ma: cat $PREFIX/relay.env)
============================================================
EOF
	if [ "$CADDY_MODE" = tls-only ]; then
		info "Ghi chu: website dang chay o cong 80 van giu nguyen; relay chi dung cong 443."
	fi
	if [ "$HAVE_DATA" = 1 ]; then
		info "Du lieu game: trang game tai tu VPS nay, khong can IDM hay chon file."
	fi
}

finish_apache() {
	cat <<EOF

============================================================
  XONG! Dia chi relay cua ban:

      wss://$APACHE_SITE$APACHE_PATH/relay

  Dan dia chi nay vao o "Relay" trong khung "Online play"
  (hoac o "Relay address" khi build trang game).
  Kiem tra nhanh: mo https://$APACHE_SITE$APACHE_PATH/healthz
  tren trinh duyet, thay {"ok":true,...} la dung.

  Tai ban mod len relay:  https://$APACHE_SITE$APACHE_PATH/admin
  Ma quan tri (ADMIN_KEY): $ADMIN_KEY
  (xem lai ma: cat $PREFIX/relay.env)
============================================================
EOF
	info "Website $APACHE_SITE van chay nhu cu; relay chi dung duong dan $APACHE_PATH/."
	info "Da them file $APACHE_CONF (go bo: chay lai lenh voi --uninstall)."
	if [ "$HAVE_DATA" = 1 ]; then
		info "Du lieu game: trang game tai tu VPS nay, khong can IDM hay chon file."
	fi
}

# The last errors Caddy logged, to send along with a failure message.
caddy_errors() {
	command -v journalctl >/dev/null 2>&1 || return 0
	local lines
	lines=$(journalctl -u lf2-caddy.service -n 200 --no-pager 2>/dev/null | grep -E '"level":"error"' | tail -n 3 | cut -c 1-400 || true)
	[ -z "$lines" ] || printf '      Loi gan nhat cua Caddy:\n%s\n' "$lines"
}

# >>> generated by update-installer.js: the relay's files, base64 (do not edit by hand)
write_server_js() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
IyEvdXNyL2Jpbi9lbnYgbm9kZQovLyBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogTUlUCi8vCi8v
IE9wZW5MRjIgb25saW5lIHJlbGF5LgovLwovLyBCcm93c2VycyBjYW5ub3Qgb3BlbiByYXcgVENQ
IHNvY2tldHMsIHNvIE9wZW5MRjIncyB3ZWIgYnVpbGQgcGxheXMgb3ZlciBhIFdlYlNvY2tldCB0
byB0aGlzIHJlbGF5Ci8vIGluc3RlYWQuIFBsYXllcnMgbWVldCBpbiBhIHJvb20gbmFtZWQgYnkg
YSBudW1lcmljIGNvZGUuIFRoZSByZWxheSBzcGVha3MgdHdvIHByb3RvY29sczoKLy8KLy8gUHJv
dG9jb2wgMiwgcm9vbXMgb2YgdXAgdG8gOCBwbGF5ZXJzICh0aGUgd2ViIGJ1aWxkJ3Mgb3duOyBz
ZWUgIlJvb21zIiBiZWxvdyk6Ci8vICAgd3Mocyk6Ly88c2VydmVyPi9yZWxheT92PTImcm9sZT1o
b3N0JnJvb209NDgyOTEzICAgTmV0d29yayBHYW1lID4gSG9zdAovLyAgIHdzKHMpOi8vPHNlcnZl
cj4vcmVsYXk/dj0yJnJvbGU9am9pbiZyb29tPTQ4MjkxMyAgIE5ldHdvcmsgR2FtZSA+IENvbm5l
Y3QsIHJvb20gY29kZSBhcyB0aGUgYWRkcmVzcwovLyBUaGUgcmVsYXkga2VlcHMgdGhlIGJlYXQ6
IGV2ZXJ5IDMzIDEvMyBtcyAoMzAgcGVyIHNlY29uZCkgaXQgc2VuZHMgZWFjaCBwbGF5ZXIgb25l
IGZyYW1lIGhvbGRpbmcgdGhlIG5ld2VzdCBpbnB1dCBvZgovLyBldmVyeSBwbGF5ZXIsIHNvIG5v
Ym9keSB3YWl0cyBmb3IgdGhlIHNsb3dlc3QgY29ubmVjdGlvbi4KLy8KLy8gUHJvdG9jb2wgMSwg
dHdvIHBsYXllcnMgKG9sZGVyIGdhbWUgcGFnZXMpOiB0aGUgcmVsYXkgcGFpcnMgaG9zdCBhbmQg
Z3Vlc3QgYW5kIGNvcGllcyBiaW5hcnkgZnJhbWVzCi8vIGZyb20gb25lIHRvIHRoZSBvdGhlciB1
bmNoYW5nZWQuIFRoZSBnYW1lJ3Mgb3duIGxvY2tzdGVwIHByb3RvY29sIChoYW5kc2hha2UsIHJh
bmRvbSB0YWJsZSwgb25lCi8vIDIyLWJ5dGUgaW5wdXQgcGFja2V0IHBlciBmcmFtZSkgcnVucyBv
biB0b3A7IHRoZSByZWxheSBuZXZlciBwYXJzZXMgb3Igc3RvcmVzIGl0LgovLyAgIHdzKHMpOi8v
PHNlcnZlcj4vcmVsYXk/cm9sZT1ob3N0JnJvb209NDgyOTEzCi8vICAgd3Mocyk6Ly88c2VydmVy
Pi9yZWxheT9yb2xlPWpvaW4mcm9vbT00ODI5MTMKLy8gRWl0aGVyIHNpZGUgbWF5IGFycml2ZSBm
aXJzdC4gU2VydmVyLXRvLWNsaWVudCBjb250cm9sIG1lc3NhZ2VzIGFyZSBKU09OIHRleHQgZnJh
bWVzOgovLyAgIHsidCI6IndhaXRpbmciLCJyb29tIjoiNDgyOTEzIn0gICByZWdpc3RlcmVkLCB3
YWl0aW5nIGZvciB0aGUgb3RoZXIgcGxheWVyCi8vICAgeyJ0IjoicGFpcmVkIn0gICAgICAgICAg
ICAgICAgICAgIGJvdGggcGxheWVycyBhcmUgcHJlc2VudDsgYmluYXJ5IGZyYW1lcyBub3cgZmxv
dwovLwovLyBQcm9ibGVtcyBjbG9zZSB0aGUgc29ja2V0IHdpdGggYSA0eHh4IGNvZGUgYW5kIGEg
c2hvcnQgQVNDSUkgcmVhc29uLCB3aGljaCB0aGUgZ2FtZSBzaG93cy4KLy8KLy8gV2l0aCBJTlNU
QUxMRVJfRklMRSBzZXQgKGluc3RhbGwtdnBzLnNoIGRvZXMpLCB0aGUgcmVsYXkgYWxzbyBzZXJ2
ZXMgaXRzIGNvcHkgb2YgdGhlIG9yaWdpbmFsIExGMgovLyB2Mi4wYSBpbnN0YWxsZXIgYXQgL2xm
Mi1pbnN0YWxsZXIuZGF0YSwgd2hpY2ggdGhlIGdhbWUgcGFnZSBkb3dubG9hZHMgYmVmb3JlIHRy
eWluZyBhcmNoaXZlLm9yZzoKLy8gZG93bmxvYWQgbWFuYWdlcnMgc3VjaCBhcyBJRE0gbGV0IHRo
YXQgbmFtZSB0aHJvdWdoLCB3aGlsZSB0aGV5IHRha2Ugb3ZlciB0aGUgLmV4ZSBmcm9tIGFyY2hp
dmUub3JnLgovLyBXaXRoIFBBQ0tTX0RJUiBzZXQsIGl0IGFsc28ga2VlcHMgZ2FtZSBwYWNrcyAo
bW9kcyBwbGF5ZWQgaW5zdGVhZCBvZiB0aGUgb3JpZ2luYWwgZ2FtZSwgc2VlCi8vIHBhY2tzLmpz
KSwgd2hpY2ggd2hvZXZlciBob2xkcyBBRE1JTl9LRVkgdXBsb2FkcyBhdCAvYWRtaW4uCid1c2Ug
c3RyaWN0JzsKCmNvbnN0IGZzID0gcmVxdWlyZSgnbm9kZTpmcycpOwpjb25zdCBodHRwID0gcmVx
dWlyZSgnbm9kZTpodHRwJyk7CmNvbnN0IHsgV2ViU29ja2V0U2VydmVyLCBXZWJTb2NrZXQgfSA9
IHJlcXVpcmUoJ3dzJyk7CmNvbnN0IHsgY3JlYXRlUGFja3MgfSA9IHJlcXVpcmUoJy4vcGFja3Mu
anMnKTsKCmNvbnN0IElOU1RBTExFUl9QQVRIID0gJy9sZjItaW5zdGFsbGVyLmRhdGEnOwoKY29u
c3QgUk9PTV9QQVRURVJOID0gL15cZHs0LDEyfSQvOwoKLy8gQ2xvc2UgY29kZXMgYXJlIHBhcnQg
b2YgdGhlIGNvbnRyYWN0IHdpdGggb25saW5lLmpzIChpdCBtYXBzIHRoZW0gdG8gbWVzc2FnZXMg
dG9vKS4KY29uc3QgQ0xPU0UgPSBPYmplY3QuZnJlZXplKHsKICBiYWRSZXF1ZXN0OiBbNDAwMCwg
J1JlbGF5OiBiYWQgcmVxdWVzdCddLAogIG9yaWdpbkRlbmllZDogWzQwMDEsICdSZWxheTogdGhp
cyB3ZWJzaXRlIG1heSBub3QgdXNlIHRoZSByZWxheSddLAogIHRvb01hbnlDb25uZWN0aW9uczog
WzQwMDIsICdSZWxheTogdG9vIG1hbnkgY29ubmVjdGlvbnMgZnJvbSB5b3VyIG5ldHdvcmsnXSwK
ICBzZXJ2ZXJGdWxsOiBbNDAwMywgJ1JlbGF5OiBzZXJ2ZXIgaXMgZnVsbCddLAogIGhvc3RUYWtl
bjogWzQwMDQsICdSZWxheTogcm9vbSBhbHJlYWR5IGhhcyBhIGhvc3QnXSwKICBndWVzdFRha2Vu
OiBbNDAwNCwgJ1JlbGF5OiByb29tIGFscmVhZHkgaGFzIGEgZ3Vlc3QnXSwKICB0aW1lb3V0OiBb
NDAwNSwgJ1JlbGF5OiBub2JvZHkgam9pbmVkIGluIHRpbWUnXSwKICBwZWVyTGVmdDogWzQwMDYs
ICdSZWxheTogdGhlIG90aGVyIHBsYXllciBsZWZ0J10sCiAgcmF0ZUxpbWl0ZWQ6IFs0MDA3LCAn
UmVsYXk6IHRvbyBtdWNoIHRyYWZmaWMnXSwKICBzbG93UGVlcjogWzQwMDgsICdSZWxheTogdGhl
IG90aGVyIHBsYXllciBzdG9wcGVkIHJlYWRpbmcnXSwKICBlYXJseURhdGE6IFs0MDA5LCAnUmVs
YXk6IGRhdGEgc2VudCBiZWZvcmUgcGFpcmluZyddLAogIC8vIFByb3RvY29sIDIgcm9vbXMuCiAg
cm9vbUZ1bGw6IFs0MDEwLCAnUmVsYXk6IHRoZSByb29tIGlzIGZ1bGwnXSwKICBzdGFydGVkOiBb
NDAxMSwgJ1JlbGF5OiB0aGUgZ2FtZSBpbiB0aGlzIHJvb20gaGFzIGFscmVhZHkgc3RhcnRlZCdd
LAogIG1pc21hdGNoOiBbNDAxMiwgJ1JlbGF5OiB0aGlzIHJvb20gcGxheXMgYW5vdGhlciBnYW1l
IHZlcnNpb24gb3IgbW9kJ10sCiAgaG9zdExlZnQ6IFs0MDEzLCAnUmVsYXk6IHRoZSBob3N0IGxl
ZnQgdGhlIHJvb20nXSwKICBub3RTdGFydGVkOiBbNDAxNCwgJ1JlbGF5OiB0aGUgaG9zdCBkaWQg
bm90IHN0YXJ0IHRoZSBnYW1lIGluIHRpbWUnXSwKICBwcm90b2NvbDogWzQwMTUsICdSZWxheTog
dW5leHBlY3RlZCBtZXNzYWdlIGZyb20gdGhlIGdhbWUnXSwKICBzbG93Q2xpZW50OiBbNDAxNiwg
J1JlbGF5OiB5b3VyIGNvbm5lY3Rpb24gaXMgdG9vIHNsb3cgZm9yIHRoZSBnYW1lJ10sCiAgY29k
ZUluVXNlOiBbNDAxNywgJ1JlbGF5OiB0aGlzIHJvb20gY29kZSBpcyBpbiB1c2UgYnkgYW4gb2xk
ZXIgZ2FtZSBwYWdlJ10sCiAgbmV3ZXJSb29tOiBbNDAxNywgJ1JlbGF5OiB0aGlzIHJvb20gaXMg
Zm9yIGEgbmV3ZXIgZ2FtZSBwYWdlIChyZWxvYWQgdGhlIHBhZ2UpJ10sCiAgc2h1dGRvd246IFsx
MDAxLCAnUmVsYXk6IHNlcnZlciBpcyByZXN0YXJ0aW5nJ10sCn0pOwoKLy8gUHJvdG9jb2wgMiBt
ZXNzYWdlIGtpbmRzIChzZWUgIlJvb21zIiBiZWxvdykuCmNvbnN0IEtJTkQgPSBPYmplY3QuZnJl
ZXplKHsKICBoZWxsbzogMHgwMSwgc3RhcnQ6IDB4MDIsIGlucHV0OiAweDAzLCByZWFkeTogMHgw
NCwgY2hlY2s6IDB4MDUsCiAgd2VsY29tZTogMHg4MSwgbG9iYnk6IDB4ODIsIHN0YXJ0ZWQ6IDB4
ODMsIGZyYW1lOiAweDg0LCBjaGVja2VkOiAweDg1LCBsZWZ0OiAweDg2LAp9KTsKY29uc3QgUk9P
TV9MSU1JVFMgPSBPYmplY3QuZnJlZXplKHsgcGxheWVyczogOCwgcHJvZmlsZTogMjAwLCBpbmZv
OiA2NCwgaW5wdXQ6IDE2LCBzZXR1cDogODE5MiwgcXVldWU6IDY0IH0pOwoKZnVuY3Rpb24gcmVh
ZENvbmZpZyhlbnYgPSBwcm9jZXNzLmVudikgewogIGNvbnN0IG51bWJlciA9IChuYW1lLCBmYWxs
YmFjaykgPT4gewogICAgY29uc3QgcmF3ID0gZW52W25hbWVdOwogICAgY29uc3QgdmFsdWUgPSBy
YXcgPT09IHVuZGVmaW5lZCB8fCByYXcgPT09ICcnID8gZmFsbGJhY2sgOiBOdW1iZXIocmF3KTsK
ICAgIGlmICghTnVtYmVyLmlzRmluaXRlKHZhbHVlKSB8fCB2YWx1ZSA8IDApIHRocm93IG5ldyBF
cnJvcihgJHtuYW1lfSBtdXN0IGJlIGEgbm9uLW5lZ2F0aXZlIG51bWJlcmApOwogICAgcmV0dXJu
IHZhbHVlOwogIH07CiAgcmV0dXJuIHsKICAgIHBvcnQ6IG51bWJlcignUE9SVCcsIDg3ODcpLAog
ICAgaG9zdDogZW52LkhPU1QgfHwgJzAuMC4wLjAnLAogICAgcGF0aDogZW52LlJFTEFZX1BBVEgg
fHwgJy9yZWxheScsCiAgICAvLyBDb21tYS1zZXBhcmF0ZWQgcGFnZSBvcmlnaW5zIGFsbG93ZWQg
dG8gY29ubmVjdCwgZS5nLiAiaHR0cHM6Ly95b3UuZ2l0aHViLmlvIi4gRW1wdHkgYWxsb3dzIGFu
eS4KICAgIGFsbG93ZWRPcmlnaW5zOiAoZW52LkFMTE9XRURfT1JJR0lOUyB8fCAnJykuc3BsaXQo
JywnKS5tYXAobm9ybWFsaXplT3JpZ2luKS5maWx0ZXIoQm9vbGVhbiksCiAgICAvLyBCZWhpbmQg
YSByZXZlcnNlIHByb3h5IChDYWRkeSwgbmdpbngsIENsb3VkZmxhcmUpLCB0YWtlIHRoZSBjbGll
bnQgYWRkcmVzcyBmcm9tIFgtRm9yd2FyZGVkLUZvci4KICAgIHRydXN0UHJveHk6IGVudi5UUlVT
VF9QUk9YWSA9PT0gJzEnIHx8IGVudi5UUlVTVF9QUk9YWSA9PT0gJ3RydWUnLAogICAgbWF4Um9v
bXM6IG51bWJlcignTUFYX1JPT01TJywgNTAwKSwgLy8gMCA9IHVubGltaXRlZAogICAgbWF4Q29u
bmVjdGlvbnNQZXJJcDogbnVtYmVyKCdNQVhfQ09OTkVDVElPTlNfUEVSX0lQJywgOCksIC8vIDAg
PSB1bmxpbWl0ZWQKICAgIHJvb21XYWl0TXM6IG51bWJlcignUk9PTV9XQUlUX01TJywgMTIwMDAw
KSwKICAgIHBpbmdJbnRlcnZhbE1zOiBudW1iZXIoJ1BJTkdfSU5URVJWQUxfTVMnLCAxNTAwMCks
CiAgICBtYXhNZXNzYWdlQnl0ZXM6IG51bWJlcignTUFYX01FU1NBR0VfQllURVMnLCA2NTUzNiks
IC8vIHRoZSBnYW1lIHF1ZXVlcyBhdCBtb3N0IDY0IEtpQgogICAgbWVzc2FnZXNQZXJTZWNvbmQ6
IG51bWJlcignTUVTU0FHRVNfUEVSX1NFQ09ORCcsIDI0MCksIC8vIHRoZSBnYW1lIHNlbmRzIH4z
MCBwZXIgc2Vjb25kOyAwID0gdW5saW1pdGVkCiAgICBieXRlc1BlclNlY29uZDogbnVtYmVyKCdC
WVRFU19QRVJfU0VDT05EJywgMTMxMDcyKSwgLy8gMCA9IHVubGltaXRlZAogICAgbWF4QnVmZmVy
ZWRCeXRlczogbnVtYmVyKCdNQVhfQlVGRkVSRURfQllURVMnLCAxMDQ4NTc2KSwKICAgIC8vIFRl
c3RpbmcgYWlkOiBob2xkIGV2ZXJ5IGZvcndhcmRlZCBmcmFtZSB0aGlzIGxvbmcsIHRvIGZlZWwg
aG93IGEgZGlzdGFudCByZWxheSB3b3VsZCBwbGF5LgogICAgZm9yd2FyZERlbGF5TXM6IG51bWJl
cignRk9SV0FSRF9ERUxBWV9NUycsIDApLAogICAgLy8gUHJvdG9jb2wgMiByb29tczogbW9zdCBw
bGF5ZXJzIGluIGEgcm9vbSAoYXQgbW9zdCA4LCB0aGUgZ2FtZSdzIHBsYXllciBzbG90cyksIHRo
ZSBiZWF0LCBob3cKICAgIC8vIGxvbmcgYSByb29tIG1heSB3YWl0IGZvciBpdHMgaG9zdCB0byBw
cmVzcyBzdGFydCwgaG93IGxvbmcgdGhlIHJlbGF5IHdhaXRzIGZvciBldmVyeSBnYW1lIHRvCiAg
ICAvLyBiZSByZWFkeSBhZnRlciB0aGUgc3RhcnQsIGFuZCBhZnRlciBob3cgbWFueSBiZWF0cyB3
aXRob3V0IG5ld3MgYSBwbGF5ZXIncyBrZXlzIGNvdW50IGFzIHJlbGVhc2VkLgogICAgcm9vbVBs
YXllcnM6IE1hdGgubWluKFJPT01fTElNSVRTLnBsYXllcnMsIE1hdGgubWF4KDIsIG51bWJlcign
Uk9PTV9QTEFZRVJTJywgUk9PTV9MSU1JVFMucGxheWVycykpKSwKICAgIC8vIDMzIDEvMyBtczog
MzAgYmVhdHMgcGVyIHNlY29uZCwgdHdvIHJlZnJlc2hlcyBvZiBhIDYwIEh6IGRpc3BsYXkgZWFj
aCAod2hvbGUgdGhpcmRzIG9mIGEgbXMgb25seSkuCiAgICB0aWNrTXM6IE1hdGgubWF4KDEsIE1h
dGgucm91bmQobnVtYmVyKCdUSUNLX01TJywgMTAwIC8gMykgKiAzKSAvIDMpLAogICAgbG9iYnlX
YWl0TXM6IG51bWJlcignTE9CQllfV0FJVF9NUycsIDE4MDAwMDApLAogICAgc3RhcnRHcmFjZU1z
OiBudW1iZXIoJ1NUQVJUX0dSQUNFX01TJywgNTAwMCksCiAgICByZXBlYXRMaW1pdDogbnVtYmVy
KCdSRVBFQVRfTElNSVQnLCAxNSksCiAgICAvLyBUaGUgTEYyIGluc3RhbGxlciBzZXJ2ZWQgYXQg
L2xmMi1pbnN0YWxsZXIuZGF0YSAoZW1wdHk6IG5vdCBzZXJ2ZWQpLCBhbmQgaG93IG9mdGVuIG9u
ZSBjbGllbnQKICAgIC8vIGFkZHJlc3MgbWF5IGRvd25sb2FkIGl0IChhYm91dCAzMCBNQiBlYWNo
IHRpbWU7IGJyb3dzZXJzIGtlZXAgaXQgYWZ0ZXIgdGhlIGZpcnN0IHRpbWUpLgogICAgaW5zdGFs
bGVyRmlsZTogZW52LklOU1RBTExFUl9GSUxFIHx8ICcnLAogICAgaW5zdGFsbGVyRG93bmxvYWRz
UGVySG91cjogbnVtYmVyKCdJTlNUQUxMRVJfRE9XTkxPQURTX1BFUl9IT1VSJywgMjApLCAvLyAw
ID0gdW5saW1pdGVkCiAgICAvLyBHYW1lIHBhY2tzIChwYWNrcy5qcyk6IHdoZXJlIHRoZXkgYXJl
IGtlcHQgKGVtcHR5OiBub25lKSwgdGhlIGtleSBmb3IgdXBsb2FkaW5nIHRoZW0gYXQgL2FkbWlu
CiAgICAvLyAoZW1wdHk6IG5vIHVwbG9hZHMpLCB0aGVpciBsYXJnZXN0IHNpemUsIGFuZCBob3cg
b2Z0ZW4gb25lIGNsaWVudCBhZGRyZXNzIG1heSBkb3dubG9hZCBvbmUuCiAgICBwYWNrc0Rpcjog
ZW52LlBBQ0tTX0RJUiB8fCAnJywKICAgIGFkbWluS2V5OiBlbnYuQURNSU5fS0VZIHx8ICcnLAog
ICAgbWF4UGFja0J5dGVzOiBudW1iZXIoJ01BWF9QQUNLX0JZVEVTJywgMTAyNCAqIDEwMjQgKiAx
MDI0KSwKICAgIHBhY2tEb3dubG9hZHNQZXJIb3VyOiBudW1iZXIoJ1BBQ0tfRE9XTkxPQURTX1BF
Ul9IT1VSJywgMjApLCAvLyAwID0gdW5saW1pdGVkCiAgICBxdWlldDogZW52LlFVSUVUID09PSAn
MScgfHwgZW52LlFVSUVUID09PSAndHJ1ZScsCiAgfTsKfQoKZnVuY3Rpb24gbm9ybWFsaXplT3Jp
Z2luKHZhbHVlKSB7CiAgcmV0dXJuIFN0cmluZyh2YWx1ZSB8fCAnJykudHJpbSgpLnJlcGxhY2Uo
L1wvKyQvLCAnJykudG9Mb3dlckNhc2UoKTsKfQoKLy8gVG9rZW4gYnVja2V0OiBgcmF0ZWAgdW5p
dHMgcGVyIHNlY29uZCwgYnVyc3RzIHVwIHRvIGBjYXBhY2l0eWAuIEEgcmF0ZSBvZiAwIGRpc2Fi
bGVzIHRoZSBsaW1pdC4KY2xhc3MgQnVja2V0IHsKICBjb25zdHJ1Y3RvcihyYXRlLCBjYXBhY2l0
eSkgewogICAgdGhpcy5yYXRlID0gcmF0ZTsKICAgIHRoaXMuY2FwYWNpdHkgPSBNYXRoLm1heChj
YXBhY2l0eSwgcmF0ZSk7CiAgICB0aGlzLnRva2VucyA9IHRoaXMuY2FwYWNpdHk7CiAgICB0aGlz
Lmxhc3QgPSBEYXRlLm5vdygpOwogIH0KICB0YWtlKGFtb3VudCkgewogICAgaWYgKHRoaXMucmF0
ZSA9PT0gMCkgcmV0dXJuIHRydWU7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgdGhp
cy50b2tlbnMgPSBNYXRoLm1pbih0aGlzLmNhcGFjaXR5LCB0aGlzLnRva2VucyArICgobm93IC0g
dGhpcy5sYXN0KSAqIHRoaXMucmF0ZSkgLyAxMDAwKTsKICAgIHRoaXMubGFzdCA9IG5vdzsKICAg
IGlmICh0aGlzLnRva2VucyA8IGFtb3VudCkgcmV0dXJuIGZhbHNlOwogICAgdGhpcy50b2tlbnMg
LT0gYW1vdW50OwogICAgcmV0dXJuIHRydWU7CiAgfQp9CgpmdW5jdGlvbiBjcmVhdGVSZWxheShv
dmVycmlkZXMgPSB7fSkgewogIGNvbnN0IGNvbmZpZyA9IHsgLi4ucmVhZENvbmZpZyh7fSksIC4u
Lm92ZXJyaWRlcyB9OwogIGNvbnN0IHJvb21zID0gbmV3IE1hcCgpOyAvLyBwcm90b2NvbCAxOiBj
b2RlIC0+IHsgY29kZSwgaG9zdCwgam9pbiwgdGltZXIgfQogIGNvbnN0IGdyb3VwcyA9IG5ldyBN
YXAoKTsgLy8gcHJvdG9jb2wgMjogY29kZSAtPiByb29tIChzZWUgIlJvb21zIiBiZWxvdykKICBj
b25zdCBjb25uZWN0aW9uc1BlcklwID0gbmV3IE1hcCgpOwogIGNvbnN0IGxvZyA9ICguLi5wYXJ0
cykgPT4geyBpZiAoIWNvbmZpZy5xdWlldCkgY29uc29sZS5sb2cobmV3IERhdGUoKS50b0lTT1N0
cmluZygpLCAuLi5wYXJ0cyk7IH07CgogIGNvbnN0IGluc3RhbGxlckRvd25sb2FkcyA9IG5ldyBN
YXAoKTsgLy8gY2xpZW50IGFkZHJlc3MgLT4geyBjb3VudCwgdW50aWwgfQogIGNvbnN0IGluc3Rh
bGxlclBhdGhzID0gbmV3IFNldChbSU5TVEFMTEVSX1BBVEgsIGNvbmZpZy5wYXRoLnJlcGxhY2Uo
L1teL10qJC8sIElOU1RBTExFUl9QQVRILnNsaWNlKDEpKV0pOwogIC8vIEJlc2lkZSB0aGUgV2Vi
U29ja2V0IHBhdGgsIGFzIHRoZSBpbnN0YWxsZXIgY29weTogL3gvcmVsYXkgLT4gL3gvbGYyLXBh
Y2tzLmpzb24gYW5kIC94L2FkbWluLgogIGNvbnN0IHJlbGF5Rm9sZGVyID0gY29uZmlnLnBhdGgu
cmVwbGFjZSgvW14vXSokLywgJycpOwogIGNvbnN0IHBhY2tzID0gY3JlYXRlUGFja3MoY29uZmln
LCB7IGxvZywgY2xpZW50QWRkcmVzczogKHJlcSkgPT4gY2xpZW50QWRkcmVzcyhyZXEpLCBhbGxv
d09yaWdpbjogKHJlcSkgPT4gYWxsb3dPcmlnaW4ocmVxKSB9KTsKCiAgY29uc3Qgc2VydmVyID0g
aHR0cC5jcmVhdGVTZXJ2ZXIoKHJlcSwgcmVzKSA9PiB7CiAgICBjb25zdCB7IHBhdGhuYW1lIH0g
PSBuZXcgVVJMKHJlcS51cmwsICdodHRwOi8vcmVsYXkuaW52YWxpZCcpOwogICAgaWYgKHBhdGhu
YW1lID09PSAnL2hlYWx0aHonKSB7CiAgICAgIC8vIFJlYWRhYmxlIGZyb20gdGhlIGdhbWUgcGFn
ZSAoYW5vdGhlciBvcmlnaW4pIHNvIGl0cyBPbmxpbmUgcGFuZWwgY2FuIHNob3cgInJlbGF5IE9L
Ii4KICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsKICAgICAgICAnY29udGVudC10eXBlJzogJ2Fw
cGxpY2F0aW9uL2pzb24nLAogICAgICAgICdjYWNoZS1jb250cm9sJzogJ25vLXN0b3JlJywKICAg
ICAgICAnYWNjZXNzLWNvbnRyb2wtYWxsb3ctb3JpZ2luJzogJyonLAogICAgICB9KTsKICAgICAg
cmVzLmVuZChKU09OLnN0cmluZ2lmeSh7CiAgICAgICAgb2s6IHRydWUsIHJvb21zOiByb29tcy5z
aXplICsgZ3JvdXBzLnNpemUsIGNsaWVudHM6IHdzcy5jbGllbnRzLnNpemUsIGluc3RhbGxlcjog
aW5zdGFsbGVyU2l6ZSgpID4gMCwKICAgICAgICBwcm90b2NvbHM6IFsxLCAyXSwgcGxheWVyczog
Y29uZmlnLnJvb21QbGF5ZXJzLCBwYWNrczogQm9vbGVhbihjb25maWcucGFja3NEaXIpLAogICAg
ICB9KSk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGlmIChpbnN0YWxsZXJQYXRocy5oYXMocGF0
aG5hbWUpKSB7CiAgICAgIHNlcnZlSW5zdGFsbGVyKHJlcSwgcmVzKTsKICAgICAgcmV0dXJuOwog
ICAgfQogICAgY29uc3QgbG9jYWwgPSByZWxheUZvbGRlciAhPT0gJy8nICYmIHBhdGhuYW1lLnN0
YXJ0c1dpdGgocmVsYXlGb2xkZXIpID8gcGF0aG5hbWUuc2xpY2UocmVsYXlGb2xkZXIubGVuZ3Ro
IC0gMSkgOiBwYXRobmFtZTsKICAgIGlmIChwYWNrcy5oYW5kbGUocmVxLCByZXMsIGxvY2FsKSkg
cmV0dXJuOwogICAgaWYgKHBhdGhuYW1lID09PSAnLycgfHwgcGF0aG5hbWUgPT09IGNvbmZpZy5w
YXRoKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdjb250ZW50LXR5cGUnOiAndGV4dC9w
bGFpbjsgY2hhcnNldD11dGYtOCcgfSk7CiAgICAgIHJlcy5lbmQoYE9wZW5MRjIgcmVsYXkgaXMg
cnVubmluZy4gQ29ubmVjdCB3aXRoIGEgV2ViU29ja2V0IHRvICR7Y29uZmlnLnBhdGh9XG5gKTsK
ICAgICAgcmV0dXJuOwogICAgfQogICAgcmVzLndyaXRlSGVhZCg0MDQsIHsgJ2NvbnRlbnQtdHlw
ZSc6ICd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04JyB9KTsKICAgIHJlcy5lbmQoJ05vdCBmb3Vu
ZFxuJyk7CiAgfSk7CgogIC8vIFVwbG9hZGluZyBhIGdhbWUgcGFjayBmcm9tIGEgc2xvdyBsaW5l
IG1heSB0YWtlIGEgd2hpbGUgKE5vZGUncyBkZWZhdWx0IGdpdmVzIHVwIGFmdGVyIDUgbWludXRl
cykuCiAgc2VydmVyLnJlcXVlc3RUaW1lb3V0ID0gMiAqIDM2MDAgKiAxMDAwOwoKICBjb25zdCB3
c3MgPSBuZXcgV2ViU29ja2V0U2VydmVyKHsKICAgIG5vU2VydmVyOiB0cnVlLAogICAgbWF4UGF5
bG9hZDogY29uZmlnLm1heE1lc3NhZ2VCeXRlcywKICAgIHBlck1lc3NhZ2VEZWZsYXRlOiBmYWxz
ZSwgLy8gMjItYnl0ZSBwYWNrZXRzOiBjb21wcmVzc2lvbiBvbmx5IGFkZHMgbGF0ZW5jeQogIH0p
OwoKICBzZXJ2ZXIub24oJ3VwZ3JhZGUnLCAocmVxLCBzb2NrZXQsIGhlYWQpID0+IHsKICAgIGNv
bnN0IHVybCA9IG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6Ly9yZWxheS5pbnZhbGlkJyk7CiAgICBp
ZiAodXJsLnBhdGhuYW1lICE9PSBjb25maWcucGF0aCAmJiB1cmwucGF0aG5hbWUgIT09ICcvJykg
ewogICAgICBzb2NrZXQuZW5kKCdIVFRQLzEuMSA0MDQgTm90IEZvdW5kXHJcbkNvbm5lY3Rpb246
IGNsb3NlXHJcblxyXG4nKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgLy8gUmVxdWVzdHMgYXJl
IHZhbGlkYXRlZCBhZnRlciB0aGUgdXBncmFkZSwgc28gdGhlIGJyb3dzZXIgcmVjZWl2ZXMgYSBj
bG9zZSBjb2RlIGFuZCByZWFzb24KICAgIC8vIGluc3RlYWQgb2YgYW4gYW5vbnltb3VzIGNvbm5l
Y3Rpb24gZXJyb3IuCiAgICB3c3MuaGFuZGxlVXBncmFkZShyZXEsIHNvY2tldCwgaGVhZCwgKHdz
KSA9PiB3c3MuZW1pdCgnY29ubmVjdGlvbicsIHdzLCByZXEsIHVybCkpOwogIH0pOwoKICB3c3Mu
b24oJ2Nvbm5lY3Rpb24nLCAod3MsIHJlcSwgdXJsKSA9PiB7CiAgICB3cy5pc0FsaXZlID0gdHJ1
ZTsKICAgIHdzLm9uKCdwb25nJywgKCkgPT4geyB3cy5pc0FsaXZlID0gdHJ1ZTsgfSk7CiAgICB3
cy5vbignZXJyb3InLCAoKSA9PiB7fSk7IC8vIGEgJ2Nsb3NlJyBldmVudCBhbHdheXMgZm9sbG93
cwoKICAgIGlmIChjb25maWcuYWxsb3dlZE9yaWdpbnMubGVuZ3RoICYmICFjb25maWcuYWxsb3dl
ZE9yaWdpbnMuaW5jbHVkZXMobm9ybWFsaXplT3JpZ2luKHJlcS5oZWFkZXJzLm9yaWdpbikpKSB7
CiAgICAgIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLm9yaWdpbkRlbmllZCk7CiAgICB9CiAg
ICBjb25zdCByb2xlID0gdXJsLnNlYXJjaFBhcmFtcy5nZXQoJ3JvbGUnKTsKICAgIGNvbnN0IGNv
ZGUgPSB1cmwuc2VhcmNoUGFyYW1zLmdldCgncm9vbScpIHx8ICcnOwogICAgaWYgKChyb2xlICE9
PSAnaG9zdCcgJiYgcm9sZSAhPT0gJ2pvaW4nKSB8fCAhUk9PTV9QQVRURVJOLnRlc3QoY29kZSkp
IHsKICAgICAgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UuYmFkUmVxdWVzdCk7CiAgICB9Cgog
ICAgY29uc3QgYWRkcmVzcyA9IGNsaWVudEFkZHJlc3MocmVxKTsKICAgIGNvbnN0IGNvdW50ID0g
Y29ubmVjdGlvbnNQZXJJcC5nZXQoYWRkcmVzcykgfHwgMDsKICAgIGlmIChjb25maWcubWF4Q29u
bmVjdGlvbnNQZXJJcCAmJiBjb3VudCA+PSBjb25maWcubWF4Q29ubmVjdGlvbnNQZXJJcCkgewog
ICAgICByZXR1cm4gY2xvc2VXaXRoKHdzLCBDTE9TRS50b29NYW55Q29ubmVjdGlvbnMpOwogICAg
fQogICAgY29ubmVjdGlvbnNQZXJJcC5zZXQoYWRkcmVzcywgY291bnQgKyAxKTsKICAgIHdzLm9u
Y2UoJ2Nsb3NlJywgKCkgPT4gewogICAgICBjb25zdCBsZWZ0ID0gKGNvbm5lY3Rpb25zUGVySXAu
Z2V0KGFkZHJlc3MpIHx8IDEpIC0gMTsKICAgICAgaWYgKGxlZnQgPiAwKSBjb25uZWN0aW9uc1Bl
cklwLnNldChhZGRyZXNzLCBsZWZ0KTsKICAgICAgZWxzZSBjb25uZWN0aW9uc1BlcklwLmRlbGV0
ZShhZGRyZXNzKTsKICAgIH0pOwogICAgd3MubWVzc2FnZUJ1ZGdldCA9IG5ldyBCdWNrZXQoY29u
ZmlnLm1lc3NhZ2VzUGVyU2Vjb25kLCBjb25maWcubWVzc2FnZXNQZXJTZWNvbmQgKiAyKTsKICAg
IHdzLmJ5dGVCdWRnZXQgPSBuZXcgQnVja2V0KGNvbmZpZy5ieXRlc1BlclNlY29uZCwgTWF0aC5t
YXgoY29uZmlnLmJ5dGVzUGVyU2Vjb25kLCBjb25maWcubWF4TWVzc2FnZUJ5dGVzKSAqIDIpOwoK
ICAgIGNvbnN0IHZlcnNpb24gPSB1cmwuc2VhcmNoUGFyYW1zLmdldCgndicpOwogICAgaWYgKHZl
cnNpb24gPT09ICcyJykgcmV0dXJuIGpvaW5Hcm91cCh3cywgcm9sZSwgY29kZSk7CiAgICBpZiAo
dmVyc2lvbiAhPT0gbnVsbCAmJiB2ZXJzaW9uICE9PSAnMScpIHJldHVybiBjbG9zZVdpdGgod3Ms
IENMT1NFLmJhZFJlcXVlc3QpOwogICAgaWYgKGdyb3Vwcy5oYXMoY29kZSkpIHJldHVybiBjbG9z
ZVdpdGgod3MsIENMT1NFLm5ld2VyUm9vbSk7CgogICAgbGV0IHJvb20gPSByb29tcy5nZXQoY29k
ZSk7CiAgICBpZiAoIXJvb20pIHsKICAgICAgaWYgKGNvbmZpZy5tYXhSb29tcyAmJiByb29tcy5z
aXplICsgZ3JvdXBzLnNpemUgPj0gY29uZmlnLm1heFJvb21zKSByZXR1cm4gY2xvc2VXaXRoKHdz
LCBDTE9TRS5zZXJ2ZXJGdWxsKTsKICAgICAgcm9vbSA9IHsgY29kZSwgaG9zdDogbnVsbCwgam9p
bjogbnVsbCwgdGltZXI6IG51bGwgfTsKICAgICAgcm9vbXMuc2V0KGNvZGUsIHJvb20pOwogICAg
fQogICAgaWYgKHJvb21bcm9sZV0pIHJldHVybiBjbG9zZVdpdGgod3MsIHJvbGUgPT09ICdob3N0
JyA/IENMT1NFLmhvc3RUYWtlbiA6IENMT1NFLmd1ZXN0VGFrZW4pOwoKICAgIHJvb21bcm9sZV0g
PSB3czsKICAgIHdzLnJvb20gPSByb29tOwogICAgd3Mucm9sZSA9IHJvbGU7CiAgICB3cy5wZWVy
ID0gbnVsbDsKICAgIHdzLm9uKCdtZXNzYWdlJywgKGRhdGEsIGlzQmluYXJ5KSA9PiBvbk1lc3Nh
Z2Uod3MsIGRhdGEsIGlzQmluYXJ5KSk7CiAgICB3cy5vbignY2xvc2UnLCAoKSA9PiBvbkNsb3Nl
KHdzKSk7CgogICAgY29uc3Qgb3RoZXIgPSByb29tW3JvbGUgPT09ICdob3N0JyA/ICdqb2luJyA6
ICdob3N0J107CiAgICBpZiAob3RoZXIpIHsKICAgICAgY2xlYXJUaW1lb3V0KHJvb20udGltZXIp
OwogICAgICByb29tLnRpbWVyID0gbnVsbDsKICAgICAgd3MucGVlciA9IG90aGVyOwogICAgICBv
dGhlci5wZWVyID0gd3M7CiAgICAgIC8vIEJvdGggcGVlcnMgYXJlIGxpbmtlZCBiZWZvcmUgZWl0
aGVyIGxlYXJucyBhYm91dCBpdCwgc28gYW55IGRhdGEgdGhhdCBmb2xsb3dzIGhhcyBhIGRlc3Rp
bmF0aW9uLgogICAgICBzZW5kQ29udHJvbChvdGhlciwgeyB0OiAncGFpcmVkJyB9KTsKICAgICAg
c2VuZENvbnRyb2wod3MsIHsgdDogJ3BhaXJlZCcgfSk7CiAgICAgIGxvZyhgcm9vbSAke2NvZGV9
OiBwYWlyZWRgKTsKICAgIH0gZWxzZSB7CiAgICAgIHNlbmRDb250cm9sKHdzLCB7IHQ6ICd3YWl0
aW5nJywgcm9vbTogY29kZSB9KTsKICAgICAgcm9vbS50aW1lciA9IHNldFRpbWVvdXQoKCkgPT4g
ewogICAgICAgIGlmIChyb29tW3JvbGVdID09PSB3cyAmJiAhd3MucGVlcikgY2xvc2VXaXRoKHdz
LCBDTE9TRS50aW1lb3V0KTsKICAgICAgfSwgY29uZmlnLnJvb21XYWl0TXMpOwogICAgICBsb2co
YHJvb20gJHtjb2RlfTogJHtyb2xlfSB3YWl0aW5nYCk7CiAgICB9CiAgfSk7CgogIGZ1bmN0aW9u
IG9uTWVzc2FnZSh3cywgZGF0YSwgaXNCaW5hcnkpIHsKICAgIGlmICghaXNCaW5hcnkpIHJldHVy
bjsgLy8gb25seSB0aGUgcmVsYXkgc3BlYWtzIHRleHQ7IGNsaWVudHMgc2VuZCBnYW1lIGJ5dGVz
IGFzIGJpbmFyeSBmcmFtZXMKICAgIGlmICghd3MucGVlcikgcmV0dXJuIGNsb3NlV2l0aCh3cywg
Q0xPU0UuZWFybHlEYXRhKTsKICAgIGlmICghd3MubWVzc2FnZUJ1ZGdldC50YWtlKDEpIHx8ICF3
cy5ieXRlQnVkZ2V0LnRha2UoZGF0YS5sZW5ndGgpKSB7CiAgICAgIGxvZyhgcm9vbSAke3dzLnJv
b20uY29kZX06IHJhdGUgbGltaXRgKTsKICAgICAgY2xvc2VXaXRoKHdzLnBlZXIsIENMT1NFLnJh
dGVMaW1pdGVkKTsKICAgICAgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UucmF0ZUxpbWl0ZWQp
OwogICAgfQogICAgY29uc3QgcGVlciA9IHdzLnBlZXI7CiAgICBpZiAocGVlci5yZWFkeVN0YXRl
ICE9PSBXZWJTb2NrZXQuT1BFTikgcmV0dXJuOwogICAgaWYgKHBlZXIuYnVmZmVyZWRBbW91bnQg
PiBjb25maWcubWF4QnVmZmVyZWRCeXRlcykgewogICAgICBjbG9zZVdpdGgod3MsIENMT1NFLnNs
b3dQZWVyKTsKICAgICAgcmV0dXJuIGNsb3NlV2l0aChwZWVyLCBDTE9TRS5zbG93UGVlcik7CiAg
ICB9CiAgICBpZiAoY29uZmlnLmZvcndhcmREZWxheU1zID4gMCkgewogICAgICAvLyBUaW1lcnMg
d2l0aCB0aGUgc2FtZSBkZWxheSBmaXJlIGluIHRoZSBvcmRlciB0aGV5IHdlcmUgc2V0LCBzbyB0
aGUgc3RyZWFtIHN0YXlzIGluIG9yZGVyLgogICAgICBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKHBl
ZXIucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9QRU4pIHBlZXIuc2VuZChkYXRhLCB7IGJpbmFy
eTogdHJ1ZSB9KTsgfSwgY29uZmlnLmZvcndhcmREZWxheU1zKTsKICAgICAgcmV0dXJuOwogICAg
fQogICAgcGVlci5zZW5kKGRhdGEsIHsgYmluYXJ5OiB0cnVlIH0pOwogIH0KCiAgZnVuY3Rpb24g
b25DbG9zZSh3cykgewogICAgY29uc3Qgcm9vbSA9IHdzLnJvb207CiAgICBpZiAoIXJvb20pIHJl
dHVybjsKICAgIGlmIChyb29tW3dzLnJvbGVdID09PSB3cykgcm9vbVt3cy5yb2xlXSA9IG51bGw7
CiAgICBjb25zdCBwZWVyID0gd3MucGVlcjsKICAgIHdzLnBlZXIgPSBudWxsOwogICAgaWYgKHBl
ZXIpIHsKICAgICAgLy8gQSBsb2Nrc3RlcCBtYXRjaCBjYW5ub3QgY29udGludWUgd2l0aCBvbmUg
cGxheWVyLCBzbyB0aGUgcm9vbSBlbmRzIHdpdGggdGhlIHBhaXIgYW5kIGl0cwogICAgICAvLyBj
b2RlIGlzIGZyZWUgYWdhaW4gYXQgb25jZSAodGhlIGhvc3QgY2FuIHByZXNzIEhvc3QgYWdhaW4g
d2l0aCB0aGUgc2FtZSBjb2RlKS4KICAgICAgcGVlci5wZWVyID0gbnVsbDsKICAgICAgcm9vbS5o
b3N0ID0gcm9vbS5qb2luID0gbnVsbDsKICAgICAgY2xvc2VXaXRoKHBlZXIsIENMT1NFLnBlZXJM
ZWZ0KTsKICAgICAgbG9nKGByb29tICR7cm9vbS5jb2RlfTogZW5kZWRgKTsKICAgIH0KICAgIGlm
ICghcm9vbS5ob3N0ICYmICFyb29tLmpvaW4pIHsKICAgICAgY2xlYXJUaW1lb3V0KHJvb20udGlt
ZXIpOwogICAgICBpZiAocm9vbXMuZ2V0KHJvb20uY29kZSkgPT09IHJvb20pIHJvb21zLmRlbGV0
ZShyb29tLmNvZGUpOwogICAgfQogIH0KCiAgLy8gLS0tLSBSb29tcyAocHJvdG9jb2wgMikgLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0KICAvLwogIC8vIFVwIHRvIGNvbmZpZy5yb29tUGxheWVycyBnYW1lcyBzaGFy
ZSBhIHJvb20uIEVhY2ggc2F5cyBIRUxMTyB3aXRoIGl0cyBwcm9maWxlIChlbmdpbmUsIHNjcmlw
dHMsCiAgLy8gbW9kcyBhbmQgZ2FtZSBkYXRhOiB0aGUgZmlyc3QgSEVMTE8gc2V0cyB0aGUgcm9v
bSdzLCBhbmQgYSBnYW1lIHdpdGggYW5vdGhlciBvbmUgaXMgdHVybmVkIGF3YXkpCiAgLy8gYW5k
IGl0cyBwbGF5ZXIgbmFtZXM7IExPQkJZIGxpc3RzIHRoZSBwbGF5ZXJzIHRvIGV2ZXJ5b25lLiBU
aGUgaG9zdCBzZW5kcyBTVEFSVCB3aXRoIHRoZSBzZXR1cAogIC8vIGV2ZXJ5IGdhbWUgbmVlZHMg
KHRoZSByYW5kb20gdGFibGUpOyBTVEFSVEVEIGdpdmVzIGV2ZXJ5IGdhbWUgdGhlIGZpbmFsIGxp
c3Qgb2YgcGxheWVycywgd2hvc2UKICAvLyBwb3NpdGlvbiBpcyB0aGUgcGxheWVyJ3MgaW5kZXgs
IGFuZCBvbmNlIGV2ZXJ5IGdhbWUgaXMgUkVBRFkgKG9yIGFmdGVyIHN0YXJ0R3JhY2VNcykgdGhl
IGJlYXQKICAvLyBiZWdpbnM6IGV2ZXJ5IHRpY2tNcywgRlJBTUUgd2l0aCB0aGUgaW5wdXQgb2Yg
ZWFjaCBwbGF5ZXIuIFRoZSBpbnB1dHMgYSBwbGF5ZXIgc2VudCBzaW5jZSB0aGUKICAvLyBsYXN0
IGJlYXQgYXJlIG1lcmdlZCAoT1I6IGEga2V5IGhlbGQgaW4gYW55IG9mIHRoZW0gaXMgaGVsZCwg
c28gYSBxdWljayB0YXAgaXMgbmV2ZXIgbG9zdCksIGFuZAogIC8vIHRoZSBuZXdlc3Qgb2YgdGhl
bSBzdGF5cyBoaXMgaW5wdXQgb24gdGhlIGZvbGxvd2luZyBiZWF0cyB3aGlsZSBubyBuZXdzIGNv
bWVzLCB3aXRob3V0IGl0cwogIC8vIG9uZS1zaG90IGV2ZW50cyAoYnl0ZSAwKTsgYWZ0ZXIgcmVw
ZWF0TGltaXQgYmVhdHMgd2l0aG91dCBuZXdzIHRoZSBwbGF5ZXIgY291bnRzIGFzIGhhdmluZwog
IC8vIHJlbGVhc2VkIGV2ZXJ5IGtleS4gR2FtZXMgc2VuZCB0aGVpciBpbnB1dCBhcyBzb29uIGFz
IGl0IGNoYW5nZXMuIEV2ZXJ5IGdhbWUgcnVucyBleGFjdGx5IHRoZQogIC8vIGZyYW1lcyBpdCBy
ZWNlaXZlcywgaW4gb3JkZXIsIHNvIGFsbCBzdGF5IGluIHN0ZXAgd2hhdGV2ZXIgdGhlaXIgb3du
IGNvbm5lY3Rpb24gZG9lczogYSBkaXN0YW50CiAgLy8gcGxheWVyJ3Mga2V5cyB0YWtlIGVmZmVj
dCBhIGxpdHRsZSBsYXRlciBhbmQgaGUgc2VlcyB0aGUgZ2FtZSBhIGxpdHRsZSBsYXRlciwgYnV0
IG5vYm9keSB3YWl0cwogIC8vIGZvciBoaW0uIEEgZ2FtZSB0aGF0IGNhbm5vdCBrZWVwIHVwIHdp
dGggdGhlIGZyYW1lcyBpcyBkcm9wcGVkLCBhbmQgdGhlIG90aGVycyBnbyBvbi4KICAvLwogIC8v
IEJpbmFyeSBtZXNzYWdlcywgYm90aCB3YXlzOiBraW5kICgxIGJ5dGUpLCBwYXlsb2FkIGxlbmd0
aCAoMiBieXRlcywgbGl0dGxlIGVuZGlhbiksIHBheWxvYWQuCiAgLy8gQSBXZWJTb2NrZXQgbWVz
c2FnZSBtYXkgY2Fycnkgc2V2ZXJhbC4gR2FtZSB0byByZWxheToKICAvLyAgIEhFTExPICAgMHgw
MSAgcHJvZmlsZSBsZW5ndGggKDEpLCBwcm9maWxlLCBpbmZvIChuYW1lczsgYXQgbW9zdCA2NCBi
eXRlcykKICAvLyAgIFNUQVJUICAgMHgwMiAgc2V0dXAgKGF0IG1vc3QgOCBLaUIpOiB0aGUgaG9z
dCwgb25jZSB0d28gcGxheWVycyBvciBtb3JlIHNhaWQgaGVsbG8KICAvLyAgIElOUFVUICAgMHgw
MyAgaW5wdXQgKGF0IG1vc3QgMTYgYnl0ZXM7IGJ5dGUgMCBob2xkcyBvbmUtc2hvdCBldmVudHMp
LCBhZnRlciBTVEFSVEVECiAgLy8gICBSRUFEWSAgIDB4MDQgIGVtcHR5OiBTVEFSVEVEIGlzIGFw
cGxpZWQKICAvLyAgIENIRUNLICAgMHgwNSAgZnJhbWUgKDQpLCBoYXNoICgyKTogcGFzc2VkIG9u
IHRvIHRoZSBvdGhlcnMsIHdoaWNoIGNvbXBhcmUgaXQgd2l0aCB0aGVpciBvd24KICAvLyBSZWxh
eSB0byBnYW1lOgogIC8vICAgV0VMQ09NRSAweDgxICBpZCAoMSksIGZsYWdzICgxOyBiaXQgMDog
aG9zdCksIG1vc3QgcGxheWVycyAoMSksIGJlYXQgaW4gbXMgKDEpLAogIC8vICAgICAgICAgICAg
ICAgICByb29tIGNvZGUgbGVuZ3RoICgxKSwgcm9vbSBjb2RlCiAgLy8gICBMT0JCWSAgIDB4ODIg
IGNvdW50ICgxKTsgcGVyIHBsYXllcjogaWQgKDEpLCBmbGFncyAoMSksIGluZm8gbGVuZ3RoICgx
KSwgaW5mbwogIC8vICAgU1RBUlRFRCAweDgzICB0aGUgcGxheWVycyBhcyBpbiBMT0JCWSwgdGhl
biBzZXR1cCBsZW5ndGggKDIpLCBzZXR1cAogIC8vICAgRlJBTUUgICAweDg0ICBmcmFtZSAoNCks
IGNvdW50ICgxKSwgZnJlc2ggbWFzayAoMSksIHByZXNlbnQgbWFzayAoMSk7CiAgLy8gICAgICAg
ICAgICAgICAgIHBlciBwbGF5ZXI6IGlucHV0IGxlbmd0aCAoMSksIGlucHV0CiAgLy8gICBDSEVD
S0VEIDB4ODUgIGluZGV4ICgxKSwgZnJhbWUgKDQpLCBoYXNoICgyKQogIC8vICAgTEVGVCAgICAw
eDg2ICBpbmRleCAoMSk6IHRoYXQgcGxheWVyIGlzIGdvbmU7IGhpcyBpbnB1dCBzdGF5cyBlbXB0
eQogIC8vIFRleHQgKEpTT04pIG1lc3NhZ2VzIGFyZSBmb3IgdGhlIHBhZ2UgYXJvdW5kIHRoZSBn
YW1lOiB7InQiOiJ3ZWxjb21lIiwidiI6Miwicm9vbSI6IuKApiIsImhvc3QiOnRydWV9CiAgLy8g
YW5kIHsidCI6InJvb20iLCJwbGF5ZXJzIjozLCJzdGFydGVkIjpmYWxzZX0uCgogIGZ1bmN0aW9u
IGpvaW5Hcm91cCh3cywgcm9sZSwgY29kZSkgewogICAgaWYgKHJvb21zLmhhcyhjb2RlKSkgcmV0
dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UuY29kZUluVXNlKTsKICAgIGxldCByb29tID0gZ3JvdXBz
LmdldChjb2RlKTsKICAgIGlmICghcm9vbSkgewogICAgICBpZiAoY29uZmlnLm1heFJvb21zICYm
IHJvb21zLnNpemUgKyBncm91cHMuc2l6ZSA+PSBjb25maWcubWF4Um9vbXMpIHJldHVybiBjbG9z
ZVdpdGgod3MsIENMT1NFLnNlcnZlckZ1bGwpOwogICAgICByb29tID0gewogICAgICAgIGNvZGUs
IG1lbWJlcnM6IFtdLCBob3N0OiBudWxsLCBuZXh0SWQ6IDEsIHByb2ZpbGU6IG51bGwsIHN0YXJ0
ZWQ6IGZhbHNlLCBvcmRlcjogW10sIGZyYW1lOiAwLAogICAgICAgIHRpY2tpbmc6IGZhbHNlLCB0
aWNrczogMCwgdGlja1N0YXJ0OiAwLCBsb2JieVRpbWVyOiBudWxsLCBncmFjZVRpbWVyOiBudWxs
LCB0aWNrVGltZXI6IG51bGwsIGVuZGVkOiBmYWxzZSwKICAgICAgfTsKICAgICAgZ3JvdXBzLnNl
dChjb2RlLCByb29tKTsKICAgICAgcm9vbS5sb2JieVRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBl
bmRHcm91cChyb29tLCBDTE9TRS5ub3RTdGFydGVkKSwgY29uZmlnLmxvYmJ5V2FpdE1zKTsKICAg
ICAgbG9nKGByb29tICR7Y29kZX06IG9wZW5lZGApOwogICAgfQogICAgaWYgKHJvb20uc3RhcnRl
ZCkgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0Uuc3RhcnRlZCk7CiAgICBpZiAocm9sZSA9PT0g
J2hvc3QnICYmIHJvb20uaG9zdCkgcmV0dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0UuaG9zdFRha2Vu
KTsKICAgIGlmIChyb29tLm1lbWJlcnMubGVuZ3RoID49IGNvbmZpZy5yb29tUGxheWVycykgcmV0
dXJuIGNsb3NlV2l0aCh3cywgQ0xPU0Uucm9vbUZ1bGwpOwogICAgd2hpbGUgKHJvb20ubWVtYmVy
cy5zb21lKChvdGhlcikgPT4gb3RoZXIuaWQgPT09IHJvb20ubmV4dElkKSkgcm9vbS5uZXh0SWQg
PSAocm9vbS5uZXh0SWQgJSAyNTUpICsgMTsKICAgIGNvbnN0IG1lbWJlciA9IHsKICAgICAgd3Ms
IHJvb20sIGlkOiByb29tLm5leHRJZCwgaG9zdDogcm9sZSA9PT0gJ2hvc3QnLCBpbmZvOiBudWxs
LCByZWFkeTogZmFsc2UsCiAgICAgIHF1ZXVlOiBbXSwgbGFzdDogRU1QVFksIHJlcGVhdHM6IDAs
IHByZXNlbnQ6IHRydWUsIGluZGV4OiAtMSwKICAgIH07CiAgICByb29tLm5leHRJZCA9IChyb29t
Lm5leHRJZCAlIDI1NSkgKyAxOwogICAgcm9vbS5tZW1iZXJzLnB1c2gobWVtYmVyKTsKICAgIGlm
IChtZW1iZXIuaG9zdCkgcm9vbS5ob3N0ID0gbWVtYmVyOwogICAgd3Mub24oJ21lc3NhZ2UnLCAo
ZGF0YSwgaXNCaW5hcnkpID0+IG9uR3JvdXBNZXNzYWdlKG1lbWJlciwgZGF0YSwgaXNCaW5hcnkp
KTsKICAgIHdzLm9uKCdjbG9zZScsICgpID0+IGxlYXZlR3JvdXAobWVtYmVyKSk7CiAgICBzZW5k
Q29udHJvbCh3cywgeyB0OiAnd2VsY29tZScsIHY6IDIsIHJvb206IGNvZGUsIGhvc3Q6IG1lbWJl
ci5ob3N0IH0pOwogICAgY29uc3Qgd2VsY29tZSA9IEJ1ZmZlci5hbGxvYyg1ICsgY29kZS5sZW5n
dGgpOwogICAgd2VsY29tZVswXSA9IG1lbWJlci5pZDsKICAgIC8vIEZsYWdzOiBiaXQgMCB0aGUg
aG9zdDsgYml0cyAxLTIgdGhlIGJlYXQncyB0aGlyZHMgb2YgYSBtaWxsaXNlY29uZCBiZXlvbmQg
d2VsY29tZVszXS4KICAgIGNvbnN0IHRoaXJkcyA9IE1hdGgucm91bmQoY29uZmlnLnRpY2tNcyAq
IDMpOwogICAgd2VsY29tZVsxXSA9IChtZW1iZXIuaG9zdCA/IDEgOiAwKSB8ICgodGhpcmRzICUg
MykgPDwgMSk7CiAgICB3ZWxjb21lWzJdID0gY29uZmlnLnJvb21QbGF5ZXJzOwogICAgd2VsY29t
ZVszXSA9IE1hdGgubWluKDI1NSwgTWF0aC5mbG9vcih0aGlyZHMgLyAzKSk7CiAgICB3ZWxjb21l
WzRdID0gY29kZS5sZW5ndGg7CiAgICB3ZWxjb21lLndyaXRlKGNvZGUsIDUsICdsYXRpbjEnKTsK
ICAgIHNlbmRCaW5hcnkod3MsIHBhY2tldChLSU5ELndlbGNvbWUsIHdlbGNvbWUpKTsKICAgIHNl
bmRMb2JieShyb29tLCBtZW1iZXIpOwogICAgbG9nKGByb29tICR7Y29kZX06ICR7cm9sZX0gYXJy
aXZlZCAoJHtyb29tLm1lbWJlcnMubGVuZ3RofSBpbiB0aGUgcm9vbSlgKTsKICB9CgogIC8vIFRo
ZSBwbGF5ZXJzIHdobyBzYWlkIGhlbGxvLCB0aGUgaG9zdCBmaXJzdCwgdGhlbiBpbiB0aGUgb3Jk
ZXIgdGhleSBjYW1lLgogIGZ1bmN0aW9uIGxpc3RlZChyb29tKSB7CiAgICBjb25zdCBrbm93biA9
IHJvb20ubWVtYmVycy5maWx0ZXIoKG1lbWJlcikgPT4gbWVtYmVyLmluZm8pOwogICAgcmV0dXJu
IGtub3duLmZpbHRlcigobWVtYmVyKSA9PiBtZW1iZXIuaG9zdCkuY29uY2F0KGtub3duLmZpbHRl
cigobWVtYmVyKSA9PiAhbWVtYmVyLmhvc3QpKTsKICB9CgogIGZ1bmN0aW9uIGRlc2NyaWJlUGxh
eWVycyhsaXN0KSB7CiAgICBjb25zdCBwYXJ0cyA9IFtCdWZmZXIuZnJvbShbbGlzdC5sZW5ndGhd
KV07CiAgICBmb3IgKGNvbnN0IG1lbWJlciBvZiBsaXN0KSBwYXJ0cy5wdXNoKEJ1ZmZlci5mcm9t
KFttZW1iZXIuaWQsIG1lbWJlci5ob3N0ID8gMSA6IDAsIG1lbWJlci5pbmZvLmxlbmd0aF0pLCBt
ZW1iZXIuaW5mbyk7CiAgICByZXR1cm4gQnVmZmVyLmNvbmNhdChwYXJ0cyk7CiAgfQoKICBmdW5j
dGlvbiBzZW5kTG9iYnkocm9vbSwgb25seSkgewogICAgY29uc3QgbGlzdCA9IGxpc3RlZChyb29t
KTsKICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQoS0lORC5sb2JieSwgZGVzY3JpYmVQbGF5ZXJz
KGxpc3QpKTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIG9ubHkgPyBbb25seV0gOiByb29tLm1l
bWJlcnMpIHsKICAgICAgc2VuZEJpbmFyeShtZW1iZXIud3MsIG1lc3NhZ2UpOwogICAgICBzZW5k
Q29udHJvbChtZW1iZXIud3MsIHsgdDogJ3Jvb20nLCBwbGF5ZXJzOiBsaXN0Lmxlbmd0aCwgc3Rh
cnRlZDogZmFsc2UgfSk7CiAgICB9CiAgfQoKICBmdW5jdGlvbiBvbkdyb3VwTWVzc2FnZShtZW1i
ZXIsIGRhdGEsIGlzQmluYXJ5KSB7CiAgICBjb25zdCB7IHdzLCByb29tIH0gPSBtZW1iZXI7CiAg
ICBpZiAoIWlzQmluYXJ5IHx8IHJvb20uZW5kZWQgfHwgIXJvb20ubWVtYmVycy5pbmNsdWRlcyht
ZW1iZXIpKSByZXR1cm47CiAgICBpZiAoIXdzLm1lc3NhZ2VCdWRnZXQudGFrZSgxKSB8fCAhd3Mu
Ynl0ZUJ1ZGdldC50YWtlKGRhdGEubGVuZ3RoKSkgewogICAgICBsb2coYHJvb20gJHtyb29tLmNv
ZGV9OiByYXRlIGxpbWl0YCk7CiAgICAgIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnJhdGVM
aW1pdGVkKTsKICAgIH0KICAgIGxldCBhdCA9IDA7CiAgICB3aGlsZSAoYXQgPCBkYXRhLmxlbmd0
aCkgewogICAgICBpZiAoZGF0YS5sZW5ndGggLSBhdCA8IDMpIHJldHVybiBjbG9zZVdpdGgod3Ms
IENMT1NFLnByb3RvY29sKTsKICAgICAgY29uc3Qga2luZCA9IGRhdGFbYXRdOwogICAgICBjb25z
dCBsZW5ndGggPSBkYXRhLnJlYWRVSW50MTZMRShhdCArIDEpOwogICAgICBpZiAoZGF0YS5sZW5n
dGggLSBhdCAtIDMgPCBsZW5ndGgpIHJldHVybiBjbG9zZVdpdGgod3MsIENMT1NFLnByb3RvY29s
KTsKICAgICAgY29uc3QgcHJvYmxlbSA9IGhhbmRsZUdyb3VwTWVzc2FnZShtZW1iZXIsIGtpbmQs
IGRhdGEuc3ViYXJyYXkoYXQgKyAzLCBhdCArIDMgKyBsZW5ndGgpKTsKICAgICAgaWYgKHByb2Js
ZW0pIHJldHVybiBjbG9zZVdpdGgod3MsIHByb2JsZW0pOwogICAgICBpZiAocm9vbS5lbmRlZCB8
fCAhcm9vbS5tZW1iZXJzLmluY2x1ZGVzKG1lbWJlcikpIHJldHVybjsKICAgICAgYXQgKz0gMyAr
IGxlbmd0aDsKICAgIH0KICB9CgogIC8vIFJldHVybnMgdGhlIGNsb3NlIGNvZGUgYW5kIHJlYXNv
biBmb3IgYSBtZXNzYWdlIHRoZSBnYW1lIHNob3VsZCBub3QgaGF2ZSBzZW50LgogIGZ1bmN0aW9u
IGhhbmRsZUdyb3VwTWVzc2FnZShtZW1iZXIsIGtpbmQsIHBheWxvYWQpIHsKICAgIGNvbnN0IHJv
b20gPSBtZW1iZXIucm9vbTsKICAgIGlmIChraW5kID09PSBLSU5ELmhlbGxvKSB7CiAgICAgIGlm
IChtZW1iZXIuaW5mbyB8fCByb29tLnN0YXJ0ZWQgfHwgcGF5bG9hZC5sZW5ndGggPCAxKSByZXR1
cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIGNvbnN0IGxlbmd0aCA9IHBheWxvYWRbMF07CiAgICAg
IGlmICghbGVuZ3RoIHx8IGxlbmd0aCA+IFJPT01fTElNSVRTLnByb2ZpbGUgfHwgcGF5bG9hZC5s
ZW5ndGggPCAxICsgbGVuZ3RoKSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIGNvbnN0IHBy
b2ZpbGUgPSBCdWZmZXIuZnJvbShwYXlsb2FkLnN1YmFycmF5KDEsIDEgKyBsZW5ndGgpKTsKICAg
ICAgY29uc3QgaW5mbyA9IEJ1ZmZlci5mcm9tKHBheWxvYWQuc3ViYXJyYXkoMSArIGxlbmd0aCkp
OwogICAgICBpZiAoaW5mby5sZW5ndGggPiBST09NX0xJTUlUUy5pbmZvKSByZXR1cm4gQ0xPU0Uu
cHJvdG9jb2w7CiAgICAgIGlmIChyb29tLnByb2ZpbGUgJiYgIXJvb20ucHJvZmlsZS5lcXVhbHMo
cHJvZmlsZSkpIHJldHVybiBDTE9TRS5taXNtYXRjaDsKICAgICAgcm9vbS5wcm9maWxlID0gcm9v
bS5wcm9maWxlIHx8IHByb2ZpbGU7CiAgICAgIG1lbWJlci5pbmZvID0gaW5mbzsKICAgICAgc2Vu
ZExvYmJ5KHJvb20pOwogICAgICByZXR1cm4gbnVsbDsKICAgIH0KICAgIGlmIChraW5kID09PSBL
SU5ELnN0YXJ0KSB7CiAgICAgIGlmICghbWVtYmVyLmhvc3QgfHwgIW1lbWJlci5pbmZvIHx8IHJv
b20uc3RhcnRlZCB8fCBwYXlsb2FkLmxlbmd0aCA+IFJPT01fTElNSVRTLnNldHVwKSByZXR1cm4g
Q0xPU0UucHJvdG9jb2w7CiAgICAgIC8vIFNvbWVib2R5IGxlZnQganVzdCBiZWZvcmU6IHRoZSBo
b3N0IHNlZXMgdGhlIGxpc3QgYWdhaW4gaW5zdGVhZC4KICAgICAgaWYgKGxpc3RlZChyb29tKS5s
ZW5ndGggPCAyKSBzZW5kTG9iYnkocm9vbSwgbWVtYmVyKTsKICAgICAgZWxzZSBzdGFydEdyb3Vw
KHJvb20sIEJ1ZmZlci5mcm9tKHBheWxvYWQpKTsKICAgICAgcmV0dXJuIG51bGw7CiAgICB9CiAg
ICBpZiAoa2luZCA9PT0gS0lORC5pbnB1dCkgewogICAgICBpZiAoIXJvb20uc3RhcnRlZCB8fCBt
ZW1iZXIuaW5kZXggPCAwIHx8IHBheWxvYWQubGVuZ3RoID4gUk9PTV9MSU1JVFMuaW5wdXQpIHJl
dHVybiBDTE9TRS5wcm90b2NvbDsKICAgICAgbWVtYmVyLnF1ZXVlLnB1c2goQnVmZmVyLmZyb20o
cGF5bG9hZCkpOwogICAgICAvLyBGYXIgbW9yZSB0aGFuIGEgYmVhdCdzIHdvcnRoICh0aGUgcmF0
ZSBsaW1pdCBhbGxvd3MgYnVyc3RzKTogZm9sZCB0aGVtLCBrZWVwaW5nIHRoZSBuZXdlc3QgbGFz
dC4KICAgICAgaWYgKG1lbWJlci5xdWV1ZS5sZW5ndGggPiBST09NX0xJTUlUUy5xdWV1ZSkgbWVt
YmVyLnF1ZXVlID0gW21lcmdlSW5wdXRzKG1lbWJlci5xdWV1ZS5zbGljZSgwLCAtMSkpLCBtZW1i
ZXIucXVldWUuYXQoLTEpXTsKICAgICAgcmV0dXJuIG51bGw7CiAgICB9CiAgICBpZiAoa2luZCA9
PT0gS0lORC5yZWFkeSkgewogICAgICBpZiAoIXJvb20uc3RhcnRlZCB8fCBtZW1iZXIuaW5kZXgg
PCAwIHx8IHBheWxvYWQubGVuZ3RoKSByZXR1cm4gQ0xPU0UucHJvdG9jb2w7CiAgICAgIG1lbWJl
ci5yZWFkeSA9IHRydWU7CiAgICAgIGlmIChyb29tLm9yZGVyLmV2ZXJ5KChvdGhlcikgPT4gb3Ro
ZXIucmVhZHkgfHwgIW90aGVyLnByZXNlbnQpKSBzdGFydEJlYXQocm9vbSk7CiAgICAgIHJldHVy
biBudWxsOwogICAgfQogICAgaWYgKGtpbmQgPT09IEtJTkQuY2hlY2spIHsKICAgICAgaWYgKCFy
b29tLnN0YXJ0ZWQgfHwgbWVtYmVyLmluZGV4IDwgMCB8fCBwYXlsb2FkLmxlbmd0aCAhPT0gNikg
cmV0dXJuIENMT1NFLnByb3RvY29sOwogICAgICBjb25zdCBtZXNzYWdlID0gcGFja2V0KEtJTkQu
Y2hlY2tlZCwgQnVmZmVyLmNvbmNhdChbQnVmZmVyLmZyb20oW21lbWJlci5pbmRleF0pLCBwYXls
b2FkXSkpOwogICAgICBmb3IgKGNvbnN0IG90aGVyIG9mIHJvb20ub3JkZXIpIGlmIChvdGhlciAh
PT0gbWVtYmVyICYmIG90aGVyLnByZXNlbnQpIHNlbmRCaW5hcnkob3RoZXIud3MsIG1lc3NhZ2Up
OwogICAgICByZXR1cm4gbnVsbDsKICAgIH0KICAgIHJldHVybiBDTE9TRS5wcm90b2NvbDsKICB9
CgogIGZ1bmN0aW9uIHN0YXJ0R3JvdXAocm9vbSwgc2V0dXApIHsKICAgIGNsZWFyVGltZW91dChy
b29tLmxvYmJ5VGltZXIpOwogICAgcm9vbS5zdGFydGVkID0gdHJ1ZTsKICAgIHJvb20ub3JkZXIg
PSBsaXN0ZWQocm9vbSk7CiAgICByb29tLm9yZGVyLmZvckVhY2goKG1lbWJlciwgaW5kZXgpID0+
IHsgbWVtYmVyLmluZGV4ID0gaW5kZXg7IH0pOwogICAgLy8gQSBnYW1lIHN0aWxsIGNvbm5lY3Rp
bmcgaGFzIG1pc3NlZCB0aGUgc3RhcnQuCiAgICBmb3IgKGNvbnN0IG1lbWJlciBvZiByb29tLm1l
bWJlcnMpIGlmICghbWVtYmVyLmluZm8pIGNsb3NlV2l0aChtZW1iZXIud3MsIENMT1NFLnN0YXJ0
ZWQpOwogICAgY29uc3QgbGVuZ3RoID0gQnVmZmVyLmFsbG9jKDIpOwogICAgbGVuZ3RoLndyaXRl
VUludDE2TEUoc2V0dXAubGVuZ3RoLCAwKTsKICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQoS0lO
RC5zdGFydGVkLCBCdWZmZXIuY29uY2F0KFtkZXNjcmliZVBsYXllcnMocm9vbS5vcmRlciksIGxl
bmd0aCwgc2V0dXBdKSk7CiAgICBmb3IgKGNvbnN0IG1lbWJlciBvZiByb29tLm9yZGVyKSB7CiAg
ICAgIHNlbmRCaW5hcnkobWVtYmVyLndzLCBtZXNzYWdlKTsKICAgICAgc2VuZENvbnRyb2wobWVt
YmVyLndzLCB7IHQ6ICdyb29tJywgcGxheWVyczogcm9vbS5vcmRlci5sZW5ndGgsIHN0YXJ0ZWQ6
IHRydWUgfSk7CiAgICB9CiAgICByb29tLmdyYWNlVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHN0
YXJ0QmVhdChyb29tKSwgY29uZmlnLnN0YXJ0R3JhY2VNcyk7CiAgICBsb2coYHJvb20gJHtyb29t
LmNvZGV9OiBzdGFydGVkIHdpdGggJHtyb29tLm9yZGVyLmxlbmd0aH0gcGxheWVyc2ApOwogIH0K
CiAgZnVuY3Rpb24gc3RhcnRCZWF0KHJvb20pIHsKICAgIGlmIChyb29tLnRpY2tpbmcgfHwgcm9v
bS5lbmRlZCkgcmV0dXJuOwogICAgY2xlYXJUaW1lb3V0KHJvb20uZ3JhY2VUaW1lcik7CiAgICBy
b29tLnRpY2tpbmcgPSB0cnVlOwogICAgcm9vbS50aWNrU3RhcnQgPSBwZXJmb3JtYW5jZS5ub3co
KTsKICAgIHJvb20udGlja3MgPSAwOwogICAgc2NoZWR1bGVCZWF0KHJvb20pOwogIH0KCiAgZnVu
Y3Rpb24gc2NoZWR1bGVCZWF0KHJvb20pIHsKICAgIGNvbnN0IGR1ZSA9IHJvb20udGlja1N0YXJ0
ICsgKHJvb20udGlja3MgKyAxKSAqIGNvbmZpZy50aWNrTXM7CiAgICByb29tLnRpY2tUaW1lciA9
IHNldFRpbWVvdXQoKCkgPT4gcnVuQmVhdHMocm9vbSksIE1hdGgubWF4KDAsIGR1ZSAtIHBlcmZv
cm1hbmNlLm5vdygpKSk7CiAgfQoKICAvLyBCZWF0cyBhcmUgY291bnRlZCBmcm9tIHRoZSBzdGFy
dCwgc28gdGltZXIgZGVsYXlzIGRvIG5vdCBhZGQgdXA7IGFmdGVyIGEgc3RhbGwgb2YgdGhlIHdo
b2xlCiAgLy8gcHJvY2VzcyBhIGZldyBtaXNzZWQgYmVhdHMgYXJlIHNlbnQgYXQgb25jZSwgYW5k
IGEgbG9uZ2VyIG9uZSByZXN0YXJ0cyB0aGUgY291bnQuCiAgZnVuY3Rpb24gcnVuQmVhdHMocm9v
bSkgewogICAgaWYgKHJvb20uZW5kZWQpIHJldHVybjsKICAgIGNvbnN0IG5vdyA9IHBlcmZvcm1h
bmNlLm5vdygpOwogICAgY29uc3QgZHVlID0gTWF0aC5mbG9vcigobm93IC0gcm9vbS50aWNrU3Rh
cnQpIC8gY29uZmlnLnRpY2tNcykgLSByb29tLnRpY2tzOwogICAgZm9yIChsZXQgY291bnQgPSAw
OyBjb3VudCA8IE1hdGgubWluKGR1ZSwgNCkgJiYgIXJvb20uZW5kZWQ7IGNvdW50ICs9IDEpIHsK
ICAgICAgcm9vbS50aWNrcyArPSAxOwogICAgICBiZWF0KHJvb20pOwogICAgfQogICAgaWYgKHJv
b20uZW5kZWQpIHJldHVybjsKICAgIGlmIChkdWUgPiA0KSByb29tLnRpY2tTdGFydCA9IG5vdyAt
IHJvb20udGlja3MgKiBjb25maWcudGlja01zOwogICAgc2NoZWR1bGVCZWF0KHJvb20pOwogIH0K
CiAgZnVuY3Rpb24gYmVhdChyb29tKSB7CiAgICBsZXQgZnJlc2ggPSAwOwogICAgbGV0IHByZXNl
bnQgPSAwOwogICAgY29uc3QgcGFydHMgPSBbXTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJv
b20ub3JkZXIpIHsKICAgICAgbGV0IGlucHV0ID0gRU1QVFk7CiAgICAgIGlmIChtZW1iZXIucHJl
c2VudCkgewogICAgICAgIHByZXNlbnQgfD0gMSA8PCBtZW1iZXIuaW5kZXg7CiAgICAgICAgY29u
c3Qgd2FpdGluZyA9IG1lbWJlci5xdWV1ZS5sZW5ndGg7CiAgICAgICAgaWYgKHdhaXRpbmcpIHsK
ICAgICAgICAgIGZyZXNoIHw9IDEgPDwgbWVtYmVyLmluZGV4OwogICAgICAgICAgaW5wdXQgPSB3
YWl0aW5nID09PSAxID8gbWVtYmVyLnF1ZXVlWzBdIDogbWVyZ2VJbnB1dHMobWVtYmVyLnF1ZXVl
KTsKICAgICAgICAgIG1lbWJlci5sYXN0ID0gbWVtYmVyLnF1ZXVlW3dhaXRpbmcgLSAxXTsKICAg
ICAgICAgIG1lbWJlci5xdWV1ZSA9IFtdOwogICAgICAgICAgbWVtYmVyLnJlcGVhdHMgPSAwOwog
ICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBtZW1iZXIucmVwZWF0cyArPSAxOwogICAgICAgICAg
aW5wdXQgPSBtZW1iZXIucmVwZWF0cyA+IGNvbmZpZy5yZXBlYXRMaW1pdCA/IEVNUFRZIDogd2l0
aG91dEV2ZW50cyhtZW1iZXIubGFzdCk7CiAgICAgICAgfQogICAgICB9CiAgICAgIHBhcnRzLnB1
c2goQnVmZmVyLmZyb20oW2lucHV0Lmxlbmd0aF0pLCBpbnB1dCk7CiAgICB9CiAgICBjb25zdCBo
ZWFkZXIgPSBCdWZmZXIuYWxsb2MoNyk7CiAgICBoZWFkZXIud3JpdGVVSW50MzJMRShyb29tLmZy
YW1lICUgNDI5NDk2NzI5NiwgMCk7CiAgICBoZWFkZXJbNF0gPSByb29tLm9yZGVyLmxlbmd0aDsK
ICAgIGhlYWRlcls1XSA9IGZyZXNoOwogICAgaGVhZGVyWzZdID0gcHJlc2VudDsKICAgIHJvb20u
ZnJhbWUgKz0gMTsKICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQoS0lORC5mcmFtZSwgQnVmZmVy
LmNvbmNhdChbaGVhZGVyLCAuLi5wYXJ0c10pKTsKICAgIGZvciAoY29uc3QgbWVtYmVyIG9mIHJv
b20ub3JkZXIpIHsKICAgICAgaWYgKCFtZW1iZXIucHJlc2VudCkgY29udGludWU7CiAgICAgIGlm
IChtZW1iZXIud3MuYnVmZmVyZWRBbW91bnQgPiBjb25maWcubWF4QnVmZmVyZWRCeXRlcykgewog
ICAgICAgIGNsb3NlV2l0aChtZW1iZXIud3MsIENMT1NFLnNsb3dDbGllbnQpOwogICAgICAgIGNv
bnRpbnVlOwogICAgICB9CiAgICAgIHNlbmRCaW5hcnkobWVtYmVyLndzLCBtZXNzYWdlKTsKICAg
IH0KICB9CgogIGZ1bmN0aW9uIGxlYXZlR3JvdXAobWVtYmVyKSB7CiAgICBjb25zdCByb29tID0g
bWVtYmVyLnJvb207CiAgICBjb25zdCBwb3NpdGlvbiA9IHJvb20ubWVtYmVycy5pbmRleE9mKG1l
bWJlcik7CiAgICBpZiAocG9zaXRpb24gPj0gMCkgcm9vbS5tZW1iZXJzLnNwbGljZShwb3NpdGlv
biwgMSk7CiAgICBpZiAocm9vbS5lbmRlZCkgcmV0dXJuOwogICAgaWYgKCFyb29tLnN0YXJ0ZWQp
IHsKICAgICAgaWYgKG1lbWJlci5ob3N0KSB7CiAgICAgICAgcm9vbS5ob3N0ID0gbnVsbDsKICAg
ICAgICBlbmRHcm91cChyb29tLCBDTE9TRS5ob3N0TGVmdCk7CiAgICAgIH0gZWxzZSBpZiAoIXJv
b20ubWVtYmVycy5sZW5ndGgpIHsKICAgICAgICBlbmRHcm91cChyb29tKTsKICAgICAgfSBlbHNl
IGlmIChtZW1iZXIuaW5mbykgewogICAgICAgIHNlbmRMb2JieShyb29tKTsKICAgICAgfQogICAg
ICByZXR1cm47CiAgICB9CiAgICBpZiAobWVtYmVyLmluZGV4ID49IDAgJiYgbWVtYmVyLnByZXNl
bnQpIHsKICAgICAgbWVtYmVyLnByZXNlbnQgPSBmYWxzZTsKICAgICAgbWVtYmVyLnF1ZXVlID0g
W107CiAgICAgIGNvbnN0IG1lc3NhZ2UgPSBwYWNrZXQoS0lORC5sZWZ0LCBCdWZmZXIuZnJvbShb
bWVtYmVyLmluZGV4XSkpOwogICAgICBjb25zdCBwbGF5ZXJzID0gcm9vbS5vcmRlci5maWx0ZXIo
KG90aGVyKSA9PiBvdGhlci5wcmVzZW50KS5sZW5ndGg7CiAgICAgIGZvciAoY29uc3Qgb3RoZXIg
b2Ygcm9vbS5vcmRlcikgewogICAgICAgIGlmICghb3RoZXIucHJlc2VudCkgY29udGludWU7CiAg
ICAgICAgc2VuZEJpbmFyeShvdGhlci53cywgbWVzc2FnZSk7CiAgICAgICAgc2VuZENvbnRyb2wo
b3RoZXIud3MsIHsgdDogJ3Jvb20nLCBwbGF5ZXJzLCBzdGFydGVkOiB0cnVlIH0pOwogICAgICB9
CiAgICAgIGxvZyhgcm9vbSAke3Jvb20uY29kZX06IHBsYXllciAke21lbWJlci5pbmRleCArIDF9
IGxlZnRgKTsKICAgIH0KICAgIGlmICghcm9vbS5vcmRlci5zb21lKChvdGhlcikgPT4gb3RoZXIu
cHJlc2VudCkpIGVuZEdyb3VwKHJvb20pOwogICAgZWxzZSBpZiAocm9vbS5vcmRlci5ldmVyeSgo
b3RoZXIpID0+IG90aGVyLnJlYWR5IHx8ICFvdGhlci5wcmVzZW50KSkgc3RhcnRCZWF0KHJvb20p
OwogIH0KCiAgZnVuY3Rpb24gZW5kR3JvdXAocm9vbSwgcmVhc29uKSB7CiAgICBpZiAocm9vbS5l
bmRlZCkgcmV0dXJuOwogICAgcm9vbS5lbmRlZCA9IHRydWU7CiAgICBjbGVhclRpbWVvdXQocm9v
bS5sb2JieVRpbWVyKTsKICAgIGNsZWFyVGltZW91dChyb29tLmdyYWNlVGltZXIpOwogICAgY2xl
YXJUaW1lb3V0KHJvb20udGlja1RpbWVyKTsKICAgIGlmIChncm91cHMuZ2V0KHJvb20uY29kZSkg
PT09IHJvb20pIGdyb3Vwcy5kZWxldGUocm9vbS5jb2RlKTsKICAgIGZvciAoY29uc3QgbWVtYmVy
IG9mIHJvb20ubWVtYmVycy5zbGljZSgpKSBjbG9zZVdpdGgobWVtYmVyLndzLCByZWFzb24gfHwg
Q0xPU0Uuc2h1dGRvd24pOwogICAgbG9nKGByb29tICR7cm9vbS5jb2RlfTogZW5kZWRgKTsKICB9
CgogIC8vIFNpemUgb2YgdGhlIGluc3RhbGxlciBmaWxlLCBvciAwIHdoZW4gbm9uZSBpcyBjb25m
aWd1cmVkIG9yIHJlYWRhYmxlLgogIGZ1bmN0aW9uIGluc3RhbGxlclNpemUoKSB7CiAgICBpZiAo
IWNvbmZpZy5pbnN0YWxsZXJGaWxlKSByZXR1cm4gMDsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHN0
YXQgPSBmcy5zdGF0U3luYyhjb25maWcuaW5zdGFsbGVyRmlsZSk7CiAgICAgIHJldHVybiBzdGF0
LmlzRmlsZSgpID8gc3RhdC5zaXplIDogMDsKICAgIH0gY2F0Y2ggewogICAgICByZXR1cm4gMDsK
ICAgIH0KICB9CgogIGZ1bmN0aW9uIHNlcnZlSW5zdGFsbGVyKHJlcSwgcmVzKSB7CiAgICBjb25z
dCBoZWFkZXJzID0geyAnY2FjaGUtY29udHJvbCc6ICdwdWJsaWMsIG1heC1hZ2U9ODY0MDAnLCAn
eC1jb250ZW50LXR5cGUtb3B0aW9ucyc6ICdub3NuaWZmJywgLi4uYWxsb3dPcmlnaW4ocmVxKSB9
OwogICAgaWYgKHJlcS5tZXRob2QgIT09ICdHRVQnICYmIHJlcS5tZXRob2QgIT09ICdIRUFEJykg
ewogICAgICByZXMud3JpdGVIZWFkKDQwNSwgeyAuLi5oZWFkZXJzLCBhbGxvdzogJ0dFVCwgSEVB
RCcgfSk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3Qgc2l6
ZSA9IGluc3RhbGxlclNpemUoKTsKICAgIGlmICghc2l6ZSkgewogICAgICByZXMud3JpdGVIZWFk
KDQwNCwgaGVhZGVycyk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAg
aWYgKHJlcS5tZXRob2QgPT09ICdHRVQnICYmIGNvbmZpZy5pbnN0YWxsZXJEb3dubG9hZHNQZXJI
b3VyKSB7CiAgICAgIGNvbnN0IGFkZHJlc3MgPSBjbGllbnRBZGRyZXNzKHJlcSk7CiAgICAgIGNv
bnN0IG5vdyA9IERhdGUubm93KCk7CiAgICAgIGxldCBlbnRyeSA9IGluc3RhbGxlckRvd25sb2Fk
cy5nZXQoYWRkcmVzcyk7CiAgICAgIGlmICghZW50cnkgfHwgZW50cnkudW50aWwgPD0gbm93KSB7
CiAgICAgICAgZW50cnkgPSB7IGNvdW50OiAwLCB1bnRpbDogbm93ICsgMzYwMDAwMCB9OwogICAg
ICAgIGluc3RhbGxlckRvd25sb2Fkcy5zZXQoYWRkcmVzcywgZW50cnkpOwogICAgICB9CiAgICAg
IGlmIChlbnRyeS5jb3VudCA+PSBjb25maWcuaW5zdGFsbGVyRG93bmxvYWRzUGVySG91cikgewog
ICAgICAgIHJlcy53cml0ZUhlYWQoNDI5LCB7IC4uLmhlYWRlcnMsICdyZXRyeS1hZnRlcic6IFN0
cmluZyhNYXRoLmNlaWwoKGVudHJ5LnVudGlsIC0gbm93KSAvIDEwMDApKSB9KTsKICAgICAgICBy
ZXMuZW5kKCk7CiAgICAgICAgcmV0dXJuOwogICAgICB9CiAgICAgIGVudHJ5LmNvdW50ICs9IDE7
CiAgICB9CiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAuLi5oZWFkZXJzLCAnY29udGVudC10eXBl
JzogJ2FwcGxpY2F0aW9uL29jdGV0LXN0cmVhbScsICdjb250ZW50LWxlbmd0aCc6IFN0cmluZyhz
aXplKSB9KTsKICAgIGlmIChyZXEubWV0aG9kID09PSAnSEVBRCcpIHsKICAgICAgcmVzLmVuZCgp
OwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzdHJlYW0gPSBmcy5jcmVhdGVSZWFkU3Ry
ZWFtKGNvbmZpZy5pbnN0YWxsZXJGaWxlKTsKICAgIHN0cmVhbS5vbignZXJyb3InLCAoKSA9PiBy
ZXMuZGVzdHJveSgpKTsKICAgIHN0cmVhbS5waXBlKHJlcyk7CiAgfQoKICAvLyBDcm9zcy1vcmln
aW46IHRoZSBnYW1lIHBhZ2UgbGl2ZXMgZWxzZXdoZXJlIChHaXRIdWIgUGFnZXMpLiBXaXRoIGFu
IGFsbG93LWxpc3QsIG9ubHkgaXRzIHBhZ2VzIG1heSByZWFkLgogIGZ1bmN0aW9uIGFsbG93T3Jp
Z2luKHJlcSkgewogICAgaWYgKCFjb25maWcuYWxsb3dlZE9yaWdpbnMubGVuZ3RoKSByZXR1cm4g
eyAnYWNjZXNzLWNvbnRyb2wtYWxsb3ctb3JpZ2luJzogJyonIH07CiAgICBjb25zdCBvcmlnaW4g
PSBub3JtYWxpemVPcmlnaW4ocmVxLmhlYWRlcnMub3JpZ2luKTsKICAgIGlmIChvcmlnaW4gJiYg
Y29uZmlnLmFsbG93ZWRPcmlnaW5zLmluY2x1ZGVzKG9yaWdpbikpIHJldHVybiB7ICdhY2Nlc3Mt
Y29udHJvbC1hbGxvdy1vcmlnaW4nOiByZXEuaGVhZGVycy5vcmlnaW4sIHZhcnk6ICdPcmlnaW4n
IH07CiAgICByZXR1cm4ge307CiAgfQoKICBmdW5jdGlvbiBjbGllbnRBZGRyZXNzKHJlcSkgewog
ICAgaWYgKGNvbmZpZy50cnVzdFByb3h5KSB7CiAgICAgIC8vIFRoZSBsYXN0IGVudHJ5IGlzIHRo
ZSBvbmUgb3VyIG93biBwcm94eSBhZGRlZCAoQXBhY2hlIGFwcGVuZHMsIENhZGR5IHJlcGxhY2Vz
KTsgZW50cmllcyBiZWZvcmUKICAgICAgLy8gaXQgY29tZSBmcm9tIHRoZSBjbGllbnQgYW5kIGNv
dWxkIGJlIG1hZGUgdXAgdG8gc2xpcCBwYXN0IHRoZSBwZXItYWRkcmVzcyBsaW1pdHMuCiAgICAg
IGNvbnN0IGZvcndhcmRlZCA9IFN0cmluZyhyZXEuaGVhZGVyc1sneC1mb3J3YXJkZWQtZm9yJ10g
fHwgJycpLnNwbGl0KCcsJykubWFwKChwYXJ0KSA9PiBwYXJ0LnRyaW0oKSkuZmlsdGVyKEJvb2xl
YW4pOwogICAgICBpZiAoZm9yd2FyZGVkLmxlbmd0aCkgcmV0dXJuIGZvcndhcmRlZFtmb3J3YXJk
ZWQubGVuZ3RoIC0gMV07CiAgICB9CiAgICByZXR1cm4gcmVxLnNvY2tldC5yZW1vdGVBZGRyZXNz
IHx8ICd1bmtub3duJzsKICB9CgogIGNvbnN0IGhlYXJ0YmVhdCA9IHNldEludGVydmFsKCgpID0+
IHsKICAgIGZvciAoY29uc3Qgd3Mgb2Ygd3NzLmNsaWVudHMpIHsKICAgICAgaWYgKCF3cy5pc0Fs
aXZlKSB7IHdzLnRlcm1pbmF0ZSgpOyBjb250aW51ZTsgfQogICAgICB3cy5pc0FsaXZlID0gZmFs
c2U7CiAgICAgIHRyeSB7IHdzLnBpbmcoKTsgfSBjYXRjaCB7IC8qIGNsb3NpbmcgKi8gfQogICAg
fQogICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICAgIGZvciAoY29uc3QgW2FkZHJlc3MsIGVu
dHJ5XSBvZiBpbnN0YWxsZXJEb3dubG9hZHMpIGlmIChlbnRyeS51bnRpbCA8PSBub3cpIGluc3Rh
bGxlckRvd25sb2Fkcy5kZWxldGUoYWRkcmVzcyk7CiAgICBwYWNrcy5jbGVhbnVwKCk7CiAgfSwg
Y29uZmlnLnBpbmdJbnRlcnZhbE1zKTsKICBoZWFydGJlYXQudW5yZWYoKTsKCiAgcmV0dXJuIHsK
ICAgIGNvbmZpZywKICAgIHNlcnZlciwKICAgIHdzcywKICAgIHJvb21zLAogICAgbGlzdGVuKHBv
cnQgPSBjb25maWcucG9ydCwgaG9zdCA9IGNvbmZpZy5ob3N0KSB7CiAgICAgIHJldHVybiBuZXcg
UHJvbWlzZSgocmVzb2x2ZSwgcmVqZWN0KSA9PiB7CiAgICAgICAgc2VydmVyLm9uY2UoJ2Vycm9y
JywgcmVqZWN0KTsKICAgICAgICBzZXJ2ZXIubGlzdGVuKHBvcnQsIGhvc3QsICgpID0+IHsKICAg
ICAgICAgIHNlcnZlci5vZmYoJ2Vycm9yJywgcmVqZWN0KTsKICAgICAgICAgIHJlc29sdmUoc2Vy
dmVyLmFkZHJlc3MoKSk7CiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfSwKICAgIGdyb3VwcywK
ICAgIGNsb3NlKCkgewogICAgICBjbGVhckludGVydmFsKGhlYXJ0YmVhdCk7CiAgICAgIGZvciAo
Y29uc3Qgcm9vbSBvZiByb29tcy52YWx1ZXMoKSkgY2xlYXJUaW1lb3V0KHJvb20udGltZXIpOwog
ICAgICBmb3IgKGNvbnN0IHJvb20gb2YgWy4uLmdyb3Vwcy52YWx1ZXMoKV0pIGVuZEdyb3VwKHJv
b20sIENMT1NFLnNodXRkb3duKTsKICAgICAgZm9yIChjb25zdCB3cyBvZiB3c3MuY2xpZW50cykg
Y2xvc2VXaXRoKHdzLCBDTE9TRS5zaHV0ZG93bik7CiAgICAgIHJldHVybiBuZXcgUHJvbWlzZSgo
cmVzb2x2ZSkgPT4gewogICAgICAgIHdzcy5jbG9zZSgoKSA9PiBzZXJ2ZXIuY2xvc2UoKCkgPT4g
cmVzb2x2ZSgpKSk7CiAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7IGZvciAoY29uc3Qgd3Mgb2Yg
d3NzLmNsaWVudHMpIHdzLnRlcm1pbmF0ZSgpOyB9LCAxMDAwKS51bnJlZigpOwogICAgICB9KTsK
ICAgIH0sCiAgfTsKfQoKZnVuY3Rpb24gc2VuZENvbnRyb2wod3MsIG1lc3NhZ2UpIHsKICBpZiAo
d3MucmVhZHlTdGF0ZSA9PT0gV2ViU29ja2V0Lk9QRU4pIHdzLnNlbmQoSlNPTi5zdHJpbmdpZnko
bWVzc2FnZSkpOwp9CgpmdW5jdGlvbiBzZW5kQmluYXJ5KHdzLCBkYXRhKSB7CiAgaWYgKHdzLnJl
YWR5U3RhdGUgPT09IFdlYlNvY2tldC5PUEVOKSB3cy5zZW5kKGRhdGEsIHsgYmluYXJ5OiB0cnVl
IH0pOwp9Cgpjb25zdCBFTVBUWSA9IEJ1ZmZlci5hbGxvYygwKTsKCi8vIEEgcHJvdG9jb2wgMiBt
ZXNzYWdlOiBraW5kLCBwYXlsb2FkIGxlbmd0aCAoMiBieXRlcywgbGl0dGxlIGVuZGlhbiksIHBh
eWxvYWQuCmZ1bmN0aW9uIHBhY2tldChraW5kLCBwYXlsb2FkKSB7CiAgY29uc3QgbWVzc2FnZSA9
IEJ1ZmZlci5hbGxvY1Vuc2FmZSgzICsgcGF5bG9hZC5sZW5ndGgpOwogIG1lc3NhZ2VbMF0gPSBr
aW5kOwogIG1lc3NhZ2Uud3JpdGVVSW50MTZMRShwYXlsb2FkLmxlbmd0aCwgMSk7CiAgcGF5bG9h
ZC5jb3B5KG1lc3NhZ2UsIDMpOwogIHJldHVybiBtZXNzYWdlOwp9CgovLyBJbnB1dHMgYXJlIGJp
dCBzZXRzIChrZXlzIGhlbGQsIGV2ZW50cyk6IG1lcmdlZCwgZXZlcnkgYml0IHNldCBpbiBhbnkg
b2YgdGhlbSBpcyBzZXQuCmZ1bmN0aW9uIG1lcmdlSW5wdXRzKGlucHV0cykgewogIGNvbnN0IG1l
cmdlZCA9IEJ1ZmZlci5hbGxvYyhNYXRoLm1heCgwLCAuLi5pbnB1dHMubWFwKChpbnB1dCkgPT4g
aW5wdXQubGVuZ3RoKSkpOwogIGZvciAoY29uc3QgaW5wdXQgb2YgaW5wdXRzKSBmb3IgKGxldCBp
bmRleCA9IDA7IGluZGV4IDwgaW5wdXQubGVuZ3RoOyBpbmRleCArPSAxKSBtZXJnZWRbaW5kZXhd
IHw9IGlucHV0W2luZGV4XTsKICByZXR1cm4gbWVyZ2VkOwp9CgovLyBBIHJlcGVhdGVkIGlucHV0
IGtlZXBzIGl0cyBoZWxkIGtleXMgYnV0IG5vdCBpdHMgb25lLXNob3QgZXZlbnRzIChieXRlIDAp
LgpmdW5jdGlvbiB3aXRob3V0RXZlbnRzKGlucHV0KSB7CiAgaWYgKCFpbnB1dC5sZW5ndGggfHwg
aW5wdXRbMF0gPT09IDApIHJldHVybiBpbnB1dDsKICBjb25zdCBjb3B5ID0gQnVmZmVyLmZyb20o
aW5wdXQpOwogIGNvcHlbMF0gPSAwOwogIHJldHVybiBjb3B5Owp9CgpmdW5jdGlvbiBjbG9zZVdp
dGgod3MsIFtjb2RlLCByZWFzb25dKSB7CiAgaWYgKHdzLnJlYWR5U3RhdGUgPT09IFdlYlNvY2tl
dC5PUEVOIHx8IHdzLnJlYWR5U3RhdGUgPT09IFdlYlNvY2tldC5DT05ORUNUSU5HKSB7CiAgICB3
cy5jbG9zZShjb2RlLCByZWFzb24pOwogICAgLy8gRG8gbm90IHdhaXQgZm9yZXZlciBmb3IgYSBj
bGllbnQgdGhhdCBuZXZlciBhbnN3ZXJzIHRoZSBjbG9zZSBoYW5kc2hha2UuCiAgICBzZXRUaW1l
b3V0KCgpID0+IHsgaWYgKHdzLnJlYWR5U3RhdGUgIT09IFdlYlNvY2tldC5DTE9TRUQpIHdzLnRl
cm1pbmF0ZSgpOyB9LCAzMDAwKS51bnJlZigpOwogIH0KfQoKbW9kdWxlLmV4cG9ydHMgPSB7IGNy
ZWF0ZVJlbGF5LCByZWFkQ29uZmlnLCBDTE9TRSwgUk9PTV9QQVRURVJOLCBLSU5ELCBST09NX0xJ
TUlUUywgcGFja2V0LCBtZXJnZUlucHV0cyB9OwoKaWYgKHJlcXVpcmUubWFpbiA9PT0gbW9kdWxl
KSB7CiAgY29uc3QgcmVsYXkgPSBjcmVhdGVSZWxheShyZWFkQ29uZmlnKCkpOwogIHJlbGF5Lmxp
c3RlbigpLnRoZW4oKGFkZHJlc3MpID0+IHsKICAgIGNvbnN0IHdoZXJlID0gdHlwZW9mIGFkZHJl
c3MgPT09ICdzdHJpbmcnID8gYWRkcmVzcyA6IGAke2FkZHJlc3MuYWRkcmVzc306JHthZGRyZXNz
LnBvcnR9YDsKICAgIGNvbnNvbGUubG9nKGBPcGVuTEYyIHJlbGF5IGxpc3RlbmluZyBvbiAke3do
ZXJlfSwgV2ViU29ja2V0IHBhdGggJHtyZWxheS5jb25maWcucGF0aH1gKTsKICAgIGlmICghcmVs
YXkuY29uZmlnLmFsbG93ZWRPcmlnaW5zLmxlbmd0aCkgewogICAgICBjb25zb2xlLmxvZygnQUxM
T1dFRF9PUklHSU5TIGlzIGVtcHR5OiBhbnkgd2Vic2l0ZSBtYXkgdXNlIHRoaXMgcmVsYXkuIFNl
dCBpdCB0byB5b3VyIGdhbWUgcGFnZSBvcmlnaW4uJyk7CiAgICB9CiAgfSkuY2F0Y2goKGVycm9y
KSA9PiB7CiAgICBjb25zb2xlLmVycm9yKGVycm9yLm1lc3NhZ2UpOwogICAgcHJvY2Vzcy5leGl0
KDEpOwogIH0pOwogIGNvbnN0IHN0b3AgPSAoKSA9PiByZWxheS5jbG9zZSgpLnRoZW4oKCkgPT4g
cHJvY2Vzcy5leGl0KDApKTsKICBwcm9jZXNzLm9uKCdTSUdJTlQnLCBzdG9wKTsKICBwcm9jZXNz
Lm9uKCdTSUdURVJNJywgc3RvcCk7Cn0K
LF2_PAYLOAD
}
write_packs_js() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IE1JVAovLwovLyBHYW1lIHBhY2tzIGZvciB0aGUg
T3BlbkxGMiByZWxheTogd2hvbGUgTEYyIGdhbWUgZm9sZGVycyBhcyBaSVAgZmlsZXMgKG1vZHMg
dGhhdCBjb21lIHdpdGggdGhlaXIKLy8gb3duIGxmMi5leGUsIGRhdGEsIHNwcml0ZSwgYmdtIGFu
ZCBiZyBmb2xkZXJzKSwgd2hpY2ggdGhlIHdlYiBnYW1lIHBsYXlzIGluc3RlYWQgb2YgdGhlIG9y
aWdpbmFsCi8vIExGMiBpbnN0YWxsZXIgKHRoZSBnYW1lJ3MgLS1wYWNrIG9wdGlvbikuIFRoZSBy
ZWxheSBrZWVwcyB0aGVtIGluIFBBQ0tTX0RJUiBhbmQgaGFuZHMgdGhlbSB0byB0aGUKLy8gZ2Ft
ZSBwYWdlczsgd2hvZXZlciBob2xkcyBBRE1JTl9LRVkgYWRkcyBhbmQgcmVtb3ZlcyB0aGVtIG9u
IHRoZSBwYWdlIGF0IC9hZG1pbi4gQW4gdXBsb2FkIGtlZXBzCi8vIG9ubHkgdGhlIGdhbWUgZm9s
ZGVyICh0aGUgb25lIGhvbGRpbmcgZGF0YS9kYXRhLnR4dCBuZWFyZXN0IHRoZSB0b3ApIHdpdGhv
dXQgdGhlIGNvcGllcyBvZiB0aGUKLy8gZ2FtZSwgcmVjb3JkaW5ncyBhbmQgbm90ZXMgdGhhdCBt
b2RzIG9mdGVuIGNhcnJ5LCBzbyB0aGF0IHBsYXllcnMgZG93bmxvYWQgbGVzcy4KLy8KLy8gICBH
RVQgIC9sZjItcGFja3MuanNvbiAgICAgICAgICAgICB0aGUgcGFja3M6IHsicGFja3MiOlt7Imlk
IiwidGl0bGUiLCJzaXplIiwic2hhMjU2In1dfQovLyAgIEdFVCAgL2xmMi1wYWNrcy88aWQ+Lnpp
cCAgICAgICAgIGEgcGFjawovLyAgIEdFVCAgL2FkbWluICAgICAgICAgICAgICAgICAgICAgIHRo
ZSBwYWdlIHRvIG1hbmFnZSB0aGVtCi8vICAgR0VUICAvYWRtaW4vYXBpL3BhY2tzICAgICAgICAg
ICAgdGhlIHNhbWUgbGlzdCwgd2l0aCBkZXRhaWxzIChYLUFkbWluLUtleSkKLy8gICBQVVQgIC9h
ZG1pbi9hcGkvcGFja3MvPGlkPj90aXRsZT08dGl0bGU+ICAgdXBsb2FkIGEgWklQIGZpbGUgYXMg
dGhlIGJvZHkgKFgtQWRtaW4tS2V5KQovLyAgIERFTEVURSAvYWRtaW4vYXBpL3BhY2tzLzxpZD4g
ICAgIHJlbW92ZSBvbmUgKFgtQWRtaW4tS2V5KQondXNlIHN0cmljdCc7Cgpjb25zdCBjcnlwdG8g
PSByZXF1aXJlKCdub2RlOmNyeXB0bycpOwpjb25zdCBmcyA9IHJlcXVpcmUoJ25vZGU6ZnMnKTsK
Y29uc3QgZnNwID0gcmVxdWlyZSgnbm9kZTpmcy9wcm9taXNlcycpOwpjb25zdCBwYXRoID0gcmVx
dWlyZSgnbm9kZTpwYXRoJyk7CmNvbnN0IHsgcGlwZWxpbmUgfSA9IHJlcXVpcmUoJ25vZGU6c3Ry
ZWFtL3Byb21pc2VzJyk7CmNvbnN0IHsgVHJhbnNmb3JtIH0gPSByZXF1aXJlKCdub2RlOnN0cmVh
bScpOwoKY29uc3QgUEFDS19JRCA9IC9eW2EtejAtOV1bYS16MC05LV17MCwzOX0kLzsKY29uc3Qg
TUlCID0gMTAyNCAqIDEwMjQ7Ci8vIEZpbGVzIGJlc2lkZSB0aGUgZ2FtZSB0aGF0IG5vIGdhbWUg
cmVhZHM6IG5vdGVzLCBhcmNoaXZlcywgdmlkZW9zLCBzaG9ydGN1dHMuCmNvbnN0IE5PVEVTID0g
L1wuKHR4dHxuZm98ZG9jfGRvY3h8cGRmfHJ0ZnxodG18aHRtbHx1cmx8bG5rfHN3ZnxyYXJ8emlw
fDd6fGxmcnxtcDR8YXZpfHdtdnxqcGd8anBlZ3xnaWYpJC9pOwoKY2xhc3MgUGFja0Vycm9yIGV4
dGVuZHMgRXJyb3Ige30KCi8vIFRoZSBjZW50cmFsIGRpcmVjdG9yeSBvZiBhIFpJUCBmaWxlOiBp
dHMgZW50cmllcyB3aXRoIHRoZWlyIHJhdyByZWNvcmRzLgphc3luYyBmdW5jdGlvbiByZWFkWmlw
KGZpbGUpIHsKICBjb25zdCBoYW5kbGUgPSBhd2FpdCBmc3Aub3BlbihmaWxlLCAncicpOwogIHRy
eSB7CiAgICBjb25zdCB7IHNpemUgfSA9IGF3YWl0IGhhbmRsZS5zdGF0KCk7CiAgICBpZiAoc2l6
ZSA8IDIyKSB0aHJvdyBuZXcgUGFja0Vycm9yKCd0aGlzIGlzIG5vdCBhIFpJUCBmaWxlJyk7CiAg
ICBpZiAoc2l6ZSA+IDB4ZmZmZmZmZmYpIHRocm93IG5ldyBQYWNrRXJyb3IoJ1pJUCBmaWxlcyBv
dmVyIDQgR2lCIGFyZSBub3Qgc3VwcG9ydGVkJyk7CiAgICBjb25zdCB0YWlsU2l6ZSA9IE1hdGgu
bWluKHNpemUsIDIyICsgNjU1MzUpOwogICAgY29uc3QgdGFpbCA9IEJ1ZmZlci5hbGxvYyh0YWls
U2l6ZSk7CiAgICBhd2FpdCBoYW5kbGUucmVhZCh0YWlsLCAwLCB0YWlsU2l6ZSwgc2l6ZSAtIHRh
aWxTaXplKTsKICAgIGxldCBlbmQgPSAtMTsKICAgIGZvciAobGV0IGF0ID0gdGFpbFNpemUgLSAy
MjsgYXQgPj0gMDsgYXQgLT0gMSkgewogICAgICBpZiAodGFpbC5yZWFkVUludDMyTEUoYXQpID09
PSAweDA2MDU0YjUwICYmIGF0ICsgMjIgKyB0YWlsLnJlYWRVSW50MTZMRShhdCArIDIwKSA9PT0g
dGFpbFNpemUpIHsKICAgICAgICBlbmQgPSBhdDsKICAgICAgICBicmVhazsKICAgICAgfQogICAg
fQogICAgaWYgKGVuZCA8IDApIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoaXMgaXMgbm90IGEgWklQ
IGZpbGUnKTsKICAgIGNvbnN0IGNvdW50ID0gdGFpbC5yZWFkVUludDE2TEUoZW5kICsgMTApOwog
ICAgY29uc3QgZGlyZWN0b3J5U2l6ZSA9IHRhaWwucmVhZFVJbnQzMkxFKGVuZCArIDEyKTsKICAg
IGNvbnN0IGRpcmVjdG9yeU9mZnNldCA9IHRhaWwucmVhZFVJbnQzMkxFKGVuZCArIDE2KTsKICAg
IGlmICh0YWlsLnJlYWRVSW50MTZMRShlbmQgKyA0KSAhPT0gMCB8fCB0YWlsLnJlYWRVSW50MTZM
RShlbmQgKyA4KSAhPT0gY291bnQpIHRocm93IG5ldyBQYWNrRXJyb3IoJ3NwbGl0IFpJUCBmaWxl
cyBhcmUgbm90IHN1cHBvcnRlZCcpOwogICAgaWYgKGNvdW50ID09PSAweGZmZmYgfHwgZGlyZWN0
b3J5U2l6ZSA9PT0gMHhmZmZmZmZmZiB8fCBkaXJlY3RvcnlPZmZzZXQgPT09IDB4ZmZmZmZmZmYp
IHsKICAgICAgdGhyb3cgbmV3IFBhY2tFcnJvcignWklQNjQgZmlsZXMgYXJlIG5vdCBzdXBwb3J0
ZWQnKTsKICAgIH0KICAgIGlmIChkaXJlY3RvcnlPZmZzZXQgKyBkaXJlY3RvcnlTaXplID4gc2l6
ZSkgdGhyb3cgbmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAgIGNv
bnN0IGRpcmVjdG9yeSA9IEJ1ZmZlci5hbGxvYyhkaXJlY3RvcnlTaXplKTsKICAgIGF3YWl0IGhh
bmRsZS5yZWFkKGRpcmVjdG9yeSwgMCwgZGlyZWN0b3J5U2l6ZSwgZGlyZWN0b3J5T2Zmc2V0KTsK
ICAgIGNvbnN0IGVudHJpZXMgPSBbXTsKICAgIGZvciAobGV0IGF0ID0gMCwgaW5kZXggPSAwOyBp
bmRleCA8IGNvdW50OyBpbmRleCArPSAxKSB7CiAgICAgIGlmIChhdCArIDQ2ID4gZGlyZWN0b3J5
Lmxlbmd0aCB8fCBkaXJlY3RvcnkucmVhZFVJbnQzMkxFKGF0KSAhPT0gMHgwMjAxNGI1MCkgdGhy
b3cgbmV3IFBhY2tFcnJvcigndGhlIFpJUCBmaWxlIGlzIGRhbWFnZWQnKTsKICAgICAgY29uc3Qg
bmFtZUxlbmd0aCA9IGRpcmVjdG9yeS5yZWFkVUludDE2TEUoYXQgKyAyOCk7CiAgICAgIGNvbnN0
IGxlbmd0aCA9IDQ2ICsgbmFtZUxlbmd0aCArIGRpcmVjdG9yeS5yZWFkVUludDE2TEUoYXQgKyAz
MCkgKyBkaXJlY3RvcnkucmVhZFVJbnQxNkxFKGF0ICsgMzIpOwogICAgICBpZiAoYXQgKyBsZW5n
dGggPiBkaXJlY3RvcnkubGVuZ3RoKSB0aHJvdyBuZXcgUGFja0Vycm9yKCd0aGUgWklQIGZpbGUg
aXMgZGFtYWdlZCcpOwogICAgICBjb25zdCBmbGFncyA9IGRpcmVjdG9yeS5yZWFkVUludDE2TEUo
YXQgKyA4KTsKICAgICAgY29uc3QgbmFtZSA9IGRpcmVjdG9yeS50b1N0cmluZyhmbGFncyAmIDB4
ODAwID8gJ3V0ZjgnIDogJ2xhdGluMScsIGF0ICsgNDYsIGF0ICsgNDYgKyBuYW1lTGVuZ3RoKTsK
ICAgICAgZW50cmllcy5wdXNoKHsKICAgICAgICBuYW1lLCBmbGFncywgbWV0aG9kOiBkaXJlY3Rv
cnkucmVhZFVJbnQxNkxFKGF0ICsgMTApLAogICAgICAgIGNvbXByZXNzZWRTaXplOiBkaXJlY3Rv
cnkucmVhZFVJbnQzMkxFKGF0ICsgMjApLCBzaXplOiBkaXJlY3RvcnkucmVhZFVJbnQzMkxFKGF0
ICsgMjQpLAogICAgICAgIGxvY2FsT2Zmc2V0OiBkaXJlY3RvcnkucmVhZFVJbnQzMkxFKGF0ICsg
NDIpLCByZWNvcmQ6IEJ1ZmZlci5mcm9tKGRpcmVjdG9yeS5zdWJhcnJheShhdCwgYXQgKyBsZW5n
dGgpKSwKICAgICAgfSk7CiAgICAgIGF0ICs9IGxlbmd0aDsKICAgIH0KICAgIHJldHVybiB7IGVu
dHJpZXMsIHNpemUgfTsKICB9IGZpbmFsbHkgewogICAgYXdhaXQgaGFuZGxlLmNsb3NlKCk7CiAg
fQp9CgovLyBXaGF0IG9mIGEgWklQIGZpbGUgdGhlIGdhbWUgbmVlZHM6IHRoZSBnYW1lIGZvbGRl
ciAodGhlIG9uZSBob2xkaW5nIGRhdGEvZGF0YS50eHQgbmVhcmVzdCB0aGUKLy8gdG9wKSB3aXRo
b3V0IG90aGVyIGNvcGllcyBvZiB0aGUgZ2FtZSBpbnNpZGUgaXQsIHJlY29yZGluZ3MsIG5vdGVz
IGFuZCBvdGhlciBwcm9ncmFtcy4KZnVuY3Rpb24gYW5hbHl6ZVppcChlbnRyaWVzKSB7CiAgY29u
c3QgbG93ZXIgPSAobmFtZSkgPT4gbmFtZS5yZXBsYWNlKC9cXC9nLCAnLycpLnRvTG93ZXJDYXNl
KCk7CiAgbGV0IHJvb3QgPSBudWxsOwogIGZvciAoY29uc3QgZW50cnkgb2YgZW50cmllcykgewog
ICAgY29uc3QgbmFtZSA9IGxvd2VyKGVudHJ5Lm5hbWUpOwogICAgaWYgKG5hbWUgPT09ICdkYXRh
L2RhdGEudHh0JyB8fCBuYW1lLmVuZHNXaXRoKCcvZGF0YS9kYXRhLnR4dCcpKSB7CiAgICAgIGNv
bnN0IGZvbGRlciA9IG5hbWUuc2xpY2UoMCwgbmFtZS5sZW5ndGggLSAnZGF0YS9kYXRhLnR4dCcu
bGVuZ3RoKTsKICAgICAgaWYgKHJvb3QgPT09IG51bGwgfHwgZm9sZGVyLmxlbmd0aCA8IHJvb3Qu
bGVuZ3RoKSByb290ID0gZm9sZGVyOwogICAgfQogIH0KICBpZiAocm9vdCA9PT0gbnVsbCkgdGhy
b3cgbmV3IFBhY2tFcnJvcignbm8gZGF0YS9kYXRhLnR4dCBpbnNpZGU6IHRoaXMgaXMgbm90IGFu
IExGMiBnYW1lIGZvbGRlcicpOwogIGNvbnN0IGluc2lkZSA9IFtdOwogIGZvciAoY29uc3QgZW50
cnkgb2YgZW50cmllcykgewogICAgY29uc3QgbmFtZSA9IGxvd2VyKGVudHJ5Lm5hbWUpOwogICAg
aWYgKCFuYW1lLnN0YXJ0c1dpdGgocm9vdCkgfHwgbmFtZS5lbmRzV2l0aCgnLycpIHx8IG5hbWUu
bGVuZ3RoID09PSByb290Lmxlbmd0aCkgY29udGludWU7CiAgICBpbnNpZGUucHVzaCh7IGVudHJ5
LCBwYXRoOiBuYW1lLnNsaWNlKHJvb3QubGVuZ3RoKSB9KTsKICB9CiAgLy8gQW5vdGhlciBjb3B5
IG9mIGEgZ2FtZSBpbnNpZGUgdGhpcyBvbmUgKGEgc3ViZm9sZGVyIHdpdGggaXRzIG93biBkYXRh
L2RhdGEudHh0KS4KICBjb25zdCBjb3BpZXMgPSBpbnNpZGUuZmlsdGVyKCh7IHBhdGg6IG5hbWUg
fSkgPT4gbmFtZSAhPT0gJ2RhdGEvZGF0YS50eHQnICYmIG5hbWUuZW5kc1dpdGgoJy9kYXRhL2Rh
dGEudHh0JykpCiAgICAubWFwKCh7IHBhdGg6IG5hbWUgfSkgPT4gbmFtZS5zbGljZSgwLCBuYW1l
Lmxlbmd0aCAtICdkYXRhL2RhdGEudHh0Jy5sZW5ndGgpKTsKICBjb25zdCBleGVjdXRhYmxlcyA9
IGluc2lkZS5maWx0ZXIoKHsgcGF0aDogbmFtZSB9KSA9PiAhbmFtZS5pbmNsdWRlcygnLycpICYm
IG5hbWUuZW5kc1dpdGgoJy5leGUnKSk7CiAgaWYgKCFleGVjdXRhYmxlcy5sZW5ndGgpIHRocm93
IG5ldyBQYWNrRXJyb3IoJ25vIGdhbWUgcHJvZ3JhbSAoLmV4ZSkgYmVzaWRlIGl0cyBkYXRhIGZv
bGRlcicpOwogIGNvbnN0IG1haW4gPSBleGVjdXRhYmxlcy5maW5kKCh7IHBhdGg6IG5hbWUgfSkg
PT4gbmFtZSA9PT0gJ2xmMi5leGUnKQogICAgfHwgZXhlY3V0YWJsZXMucmVkdWNlKChsYXJnZXN0
LCBpdGVtKSA9PiAoaXRlbS5lbnRyeS5zaXplID4gbGFyZ2VzdC5lbnRyeS5zaXplID8gaXRlbSA6
IGxhcmdlc3QpKTsKICBjb25zdCBrZWVwID0gW107CiAgZm9yIChjb25zdCBpdGVtIG9mIGluc2lk
ZSkgewogICAgY29uc3QgbmFtZSA9IGl0ZW0ucGF0aDsKICAgIGNvbnN0IHRvcExldmVsID0gIW5h
bWUuaW5jbHVkZXMoJy8nKTsKICAgIGlmIChjb3BpZXMuc29tZSgoY29weSkgPT4gbmFtZS5zdGFy
dHNXaXRoKGNvcHkpKSkgY29udGludWU7CiAgICBpZiAobmFtZS5zdGFydHNXaXRoKCdyZWNvcmRp
bmcvJykpIGNvbnRpbnVlOwogICAgaWYgKHRvcExldmVsICYmIG5hbWUuZW5kc1dpdGgoJy5leGUn
KSAmJiBpdGVtICE9PSBtYWluKSBjb250aW51ZTsKICAgIGlmICh0b3BMZXZlbCAmJiBOT1RFUy50
ZXN0KG5hbWUpKSBjb250aW51ZTsKICAgIGlmIChpdGVtLmVudHJ5LmZsYWdzICYgMSkgdGhyb3cg
bmV3IFBhY2tFcnJvcihgJHtpdGVtLmVudHJ5Lm5hbWV9IGlzIGVuY3J5cHRlZGApOwogICAgaWYg
KGl0ZW0uZW50cnkubWV0aG9kICE9PSAwICYmIGl0ZW0uZW50cnkubWV0aG9kICE9PSA4KSB7CiAg
ICAgIHRocm93IG5ldyBQYWNrRXJyb3IoYCR7aXRlbS5lbnRyeS5uYW1lfSB1c2VzIGEgY29tcHJl
c3Npb24gdGhlIGdhbWUgY2Fubm90IHJlYWQgKHppcCBpdCBhZ2FpbiB3aXRoIERlZmxhdGUpYCk7
CiAgICB9CiAgICBpZiAoaXRlbS5lbnRyeS5zaXplID4gNjQgKiBNSUIpIHRocm93IG5ldyBQYWNr
RXJyb3IoYCR7aXRlbS5lbnRyeS5uYW1lfSBpcyBsYXJnZXIgdGhhbiA2NCBNQmApOwogICAga2Vl
cC5wdXNoKGl0ZW0uZW50cnkpOwogIH0KICByZXR1cm4geyByb290LCBleGVjdXRhYmxlOiBtYWlu
LnBhdGgsIGtlZXAsIGRyb3BwZWQ6IGVudHJpZXMubGVuZ3RoIC0ga2VlcC5sZW5ndGggfTsKfQoK
Ly8gV3JpdGVzIHRoZSBrZXB0IGVudHJpZXMgb2YgYHNvdXJjZWAgYXMgYSBuZXcgWklQIGZpbGUs
IGNvcHlpbmcgdGhlaXIgY29tcHJlc3NlZCBieXRlcyBhcyB0aGV5IGFyZS4KYXN5bmMgZnVuY3Rp
b24gd3JpdGVaaXAoc291cmNlLCB0YXJnZXQsIGtlZXApIHsKICBjb25zdCBpbnB1dCA9IGF3YWl0
IGZzcC5vcGVuKHNvdXJjZSwgJ3InKTsKICBjb25zdCBvdXRwdXQgPSBhd2FpdCBmc3Aub3Blbih0
YXJnZXQsICd3Jyk7CiAgY29uc3QgaGFzaCA9IGNyeXB0by5jcmVhdGVIYXNoKCdzaGEyNTYnKTsK
ICBsZXQgb2Zmc2V0ID0gMDsKICBjb25zdCB3cml0ZSA9IGFzeW5jIChidWZmZXIpID0+IHsKICAg
IGxldCBkb25lID0gMDsKICAgIHdoaWxlIChkb25lIDwgYnVmZmVyLmxlbmd0aCkgewogICAgICBj
b25zdCB7IGJ5dGVzV3JpdHRlbiB9ID0gYXdhaXQgb3V0cHV0LndyaXRlKGJ1ZmZlciwgZG9uZSwg
YnVmZmVyLmxlbmd0aCAtIGRvbmUsIG9mZnNldCArIGRvbmUpOwogICAgICBkb25lICs9IGJ5dGVz
V3JpdHRlbjsKICAgIH0KICAgIGhhc2gudXBkYXRlKGJ1ZmZlcik7CiAgICBvZmZzZXQgKz0gYnVm
ZmVyLmxlbmd0aDsKICB9OwogIHRyeSB7CiAgICBjb25zdCByZWNvcmRzID0gW107CiAgICBmb3Ig
KGNvbnN0IGVudHJ5IG9mIGtlZXApIHsKICAgICAgY29uc3QgaGVhZGVyID0gQnVmZmVyLmFsbG9j
KDMwKTsKICAgICAgYXdhaXQgaW5wdXQucmVhZChoZWFkZXIsIDAsIDMwLCBlbnRyeS5sb2NhbE9m
ZnNldCk7CiAgICAgIGlmIChoZWFkZXIucmVhZFVJbnQzMkxFKDApICE9PSAweDA0MDM0YjUwKSB0
aHJvdyBuZXcgUGFja0Vycm9yKCd0aGUgWklQIGZpbGUgaXMgZGFtYWdlZCcpOwogICAgICBsZXQg
bGVuZ3RoID0gMzAgKyBoZWFkZXIucmVhZFVJbnQxNkxFKDI2KSArIGhlYWRlci5yZWFkVUludDE2
TEUoMjgpICsgZW50cnkuY29tcHJlc3NlZFNpemU7CiAgICAgIGlmIChlbnRyeS5mbGFncyAmIDgp
IHsgLy8gYSBkYXRhIGRlc2NyaXB0b3IgZm9sbG93cyB0aGUgZGF0YQogICAgICAgIGNvbnN0IHBy
b2JlID0gQnVmZmVyLmFsbG9jKDQpOwogICAgICAgIGF3YWl0IGlucHV0LnJlYWQocHJvYmUsIDAs
IDQsIGVudHJ5LmxvY2FsT2Zmc2V0ICsgbGVuZ3RoKTsKICAgICAgICBsZW5ndGggKz0gcHJvYmUu
cmVhZFVJbnQzMkxFKDApID09PSAweDA4MDc0YjUwID8gMTYgOiAxMjsKICAgICAgfQogICAgICBj
b25zdCByZWNvcmQgPSBCdWZmZXIuZnJvbShlbnRyeS5yZWNvcmQpOwogICAgICByZWNvcmQud3Jp
dGVVSW50MzJMRShvZmZzZXQsIDQyKTsKICAgICAgcmVjb3Jkcy5wdXNoKHJlY29yZCk7CiAgICAg
IGZvciAobGV0IGNvcGllZCA9IDA7IGNvcGllZCA8IGxlbmd0aDspIHsKICAgICAgICBjb25zdCBj
aHVuayA9IEJ1ZmZlci5hbGxvYyhNYXRoLm1pbig0ICogTUlCLCBsZW5ndGggLSBjb3BpZWQpKTsK
ICAgICAgICBjb25zdCB7IGJ5dGVzUmVhZCB9ID0gYXdhaXQgaW5wdXQucmVhZChjaHVuaywgMCwg
Y2h1bmsubGVuZ3RoLCBlbnRyeS5sb2NhbE9mZnNldCArIGNvcGllZCk7CiAgICAgICAgaWYgKCFi
eXRlc1JlYWQpIHRocm93IG5ldyBQYWNrRXJyb3IoJ3RoZSBaSVAgZmlsZSBpcyBkYW1hZ2VkJyk7
CiAgICAgICAgYXdhaXQgd3JpdGUoY2h1bmsuc3ViYXJyYXkoMCwgYnl0ZXNSZWFkKSk7CiAgICAg
ICAgY29waWVkICs9IGJ5dGVzUmVhZDsKICAgICAgfQogICAgfQogICAgY29uc3QgZGlyZWN0b3J5
T2Zmc2V0ID0gb2Zmc2V0OwogICAgZm9yIChjb25zdCByZWNvcmQgb2YgcmVjb3JkcykgYXdhaXQg
d3JpdGUocmVjb3JkKTsKICAgIGNvbnN0IGVuZCA9IEJ1ZmZlci5hbGxvYygyMik7CiAgICBlbmQu
d3JpdGVVSW50MzJMRSgweDA2MDU0YjUwLCAwKTsKICAgIGVuZC53cml0ZVVJbnQxNkxFKHJlY29y
ZHMubGVuZ3RoLCA4KTsKICAgIGVuZC53cml0ZVVJbnQxNkxFKHJlY29yZHMubGVuZ3RoLCAxMCk7
CiAgICBlbmQud3JpdGVVSW50MzJMRShvZmZzZXQgLSBkaXJlY3RvcnlPZmZzZXQsIDEyKTsKICAg
IGVuZC53cml0ZVVJbnQzMkxFKGRpcmVjdG9yeU9mZnNldCwgMTYpOwogICAgYXdhaXQgd3JpdGUo
ZW5kKTsKICAgIHJldHVybiB7IHNpemU6IG9mZnNldCwgc2hhMjU2OiBoYXNoLmRpZ2VzdCgnaGV4
JyksIGZpbGVzOiByZWNvcmRzLmxlbmd0aCB9OwogIH0gZmluYWxseSB7CiAgICBhd2FpdCBpbnB1
dC5jbG9zZSgpOwogICAgYXdhaXQgb3V0cHV0LmNsb3NlKCk7CiAgfQp9CgpmdW5jdGlvbiBzYW1l
S2V5KGdpdmVuLCBleHBlY3RlZCkgewogIGNvbnN0IGEgPSBjcnlwdG8uY3JlYXRlSGFzaCgnc2hh
MjU2JykudXBkYXRlKFN0cmluZyhnaXZlbiB8fCAnJykpLmRpZ2VzdCgpOwogIGNvbnN0IGIgPSBj
cnlwdG8uY3JlYXRlSGFzaCgnc2hhMjU2JykudXBkYXRlKFN0cmluZyhleHBlY3RlZCkpLmRpZ2Vz
dCgpOwogIHJldHVybiBjcnlwdG8udGltaW5nU2FmZUVxdWFsKGEsIGIpOwp9CgpmdW5jdGlvbiBj
cmVhdGVQYWNrcyhjb25maWcsIHsgbG9nLCBjbGllbnRBZGRyZXNzLCBhbGxvd09yaWdpbiB9KSB7
CiAgY29uc3QgZGlyZWN0b3J5ID0gY29uZmlnLnBhY2tzRGlyOwogIGNvbnN0IGRvd25sb2FkcyA9
IG5ldyBNYXAoKTsgLy8gY2xpZW50IGFkZHJlc3MgLT4geyBjb3VudCwgdW50aWwgfQogIGNvbnN0
IGZhaWx1cmVzID0gbmV3IE1hcCgpOyAvLyBjbGllbnQgYWRkcmVzcyAtPiB7IGNvdW50LCB1bnRp
bCB9CiAgbGV0IHVwbG9hZGluZyA9IGZhbHNlOwoKICBjb25zdCBqc29uID0gKHJlcywgc3RhdHVz
LCBib2R5LCBoZWFkZXJzID0ge30pID0+IHsKICAgIHJlcy53cml0ZUhlYWQoc3RhdHVzLCB7ICdj
b250ZW50LXR5cGUnOiAnYXBwbGljYXRpb24vanNvbjsgY2hhcnNldD11dGYtOCcsICdjYWNoZS1j
b250cm9sJzogJ25vLXN0b3JlJywgLi4uaGVhZGVycyB9KTsKICAgIHJlcy5lbmQoSlNPTi5zdHJp
bmdpZnkoYm9keSkpOwogIH07CiAgY29uc3QgY291bnRlZCA9IChtYXAsIGFkZHJlc3MsIGxpbWl0
KSA9PiB7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgbGV0IGVudHJ5ID0gbWFwLmdl
dChhZGRyZXNzKTsKICAgIGlmICghZW50cnkgfHwgZW50cnkudW50aWwgPD0gbm93KSB7CiAgICAg
IGVudHJ5ID0geyBjb3VudDogMCwgdW50aWw6IG5vdyArIDM2MDAwMDAgfTsKICAgICAgbWFwLnNl
dChhZGRyZXNzLCBlbnRyeSk7CiAgICB9CiAgICByZXR1cm4geyBvdmVyOiBsaW1pdCA+IDAgJiYg
ZW50cnkuY291bnQgPj0gbGltaXQsIGFkZDogKCkgPT4geyBlbnRyeS5jb3VudCArPSAxOyB9LCBy
ZXRyeTogTWF0aC5jZWlsKChlbnRyeS51bnRpbCAtIG5vdykgLyAxMDAwKSB9OwogIH07CgogIGFz
eW5jIGZ1bmN0aW9uIGxpc3QoKSB7CiAgICBpZiAoIWRpcmVjdG9yeSkgcmV0dXJuIFtdOwogICAg
bGV0IG5hbWVzOwogICAgdHJ5IHsgbmFtZXMgPSBhd2FpdCBmc3AucmVhZGRpcihkaXJlY3Rvcnkp
OyB9IGNhdGNoIHsgcmV0dXJuIFtdOyB9CiAgICBjb25zdCBwYWNrcyA9IFtdOwogICAgZm9yIChj
b25zdCBuYW1lIG9mIG5hbWVzKSB7CiAgICAgIGlmICghbmFtZS5lbmRzV2l0aCgnLmpzb24nKSkg
Y29udGludWU7CiAgICAgIGNvbnN0IGlkID0gbmFtZS5zbGljZSgwLCAtNSk7CiAgICAgIGlmICgh
UEFDS19JRC50ZXN0KGlkKSkgY29udGludWU7CiAgICAgIHRyeSB7CiAgICAgICAgY29uc3QgaW5m
byA9IEpTT04ucGFyc2UoYXdhaXQgZnNwLnJlYWRGaWxlKHBhdGguam9pbihkaXJlY3RvcnksIG5h
bWUpLCAndXRmOCcpKTsKICAgICAgICBjb25zdCBzdGF0ID0gYXdhaXQgZnNwLnN0YXQocGF0aC5q
b2luKGRpcmVjdG9yeSwgYCR7aWR9LnppcGApKTsKICAgICAgICBwYWNrcy5wdXNoKHsgaWQsIHRp
dGxlOiBTdHJpbmcoaW5mby50aXRsZSB8fCBpZCksIHNpemU6IHN0YXQuc2l6ZSwgc2hhMjU2OiBT
dHJpbmcoaW5mby5zaGEyNTYgfHwgJycpLAogICAgICAgICAgZmlsZXM6IGluZm8uZmlsZXMsIHVw
bG9hZGVkOiBpbmZvLnVwbG9hZGVkLCBvcmlnaW5hbDogaW5mby5vcmlnaW5hbCB9KTsKICAgICAg
fSBjYXRjaCB7IC8qIGEgaGFsZi13cml0dGVuIG9yIHJlbW92ZWQgcGFjayAqLyB9CiAgICB9CiAg
ICByZXR1cm4gcGFja3Muc29ydCgoYSwgYikgPT4gYS50aXRsZS5sb2NhbGVDb21wYXJlKGIudGl0
bGUpKTsKICB9CgogIGZ1bmN0aW9uIGF1dGhvcml6ZWQocmVxLCByZXMpIHsKICAgIGlmICghY29u
ZmlnLmFkbWluS2V5KSB7CiAgICAgIGpzb24ocmVzLCA0MDMsIHsgZXJyb3I6ICdDaMawYSDEkeG6
t3QgQURNSU5fS0VZIGNobyByZWxheSAoY2jhuqF5IGzhuqFpIGluc3RhbGwtdnBzLnNoKS4nIH0p
OwogICAgICByZXR1cm4gZmFsc2U7CiAgICB9CiAgICBjb25zdCBhZGRyZXNzID0gY2xpZW50QWRk
cmVzcyhyZXEpOwogICAgY29uc3QgdHJpZXMgPSBjb3VudGVkKGZhaWx1cmVzLCBhZGRyZXNzLCAy
MCk7CiAgICBpZiAodHJpZXMub3ZlcikgewogICAgICBqc29uKHJlcywgNDI5LCB7IGVycm9yOiAn
U2FpIG3DoyBxdcOhIG5oaeG7gXUgbOG6p24sIHRo4butIGzhuqFpIHNhdSBt4buZdCBnaeG7nS4n
IH0sIHsgJ3JldHJ5LWFmdGVyJzogU3RyaW5nKHRyaWVzLnJldHJ5KSB9KTsKICAgICAgcmV0dXJu
IGZhbHNlOwogICAgfQogICAgaWYgKCFzYW1lS2V5KHJlcS5oZWFkZXJzWyd4LWFkbWluLWtleSdd
LCBjb25maWcuYWRtaW5LZXkpKSB7CiAgICAgIHRyaWVzLmFkZCgpOwogICAgICBqc29uKHJlcywg
NDAxLCB7IGVycm9yOiAnU2FpIG3DoyBxdeG6o24gdHLhu4sgKEFETUlOX0tFWSkuJyB9KTsKICAg
ICAgcmV0dXJuIGZhbHNlOwogICAgfQogICAgcmV0dXJuIHRydWU7CiAgfQoKICBhc3luYyBmdW5j
dGlvbiB1cGxvYWQocmVxLCByZXMsIGlkLCB0aXRsZSkgewogICAgaWYgKCFkaXJlY3RvcnkpIHJl
dHVybiBqc29uKHJlcywgNTAzLCB7IGVycm9yOiAnUmVsYXkgbsOgeSBraMO0bmcgZ2nhu68gYuG6
o24gbW9kIChjaMawYSDEkeG6t3QgUEFDS1NfRElSKS4nIH0pOwogICAgaWYgKHVwbG9hZGluZykg
cmV0dXJuIGpzb24ocmVzLCA0MDksIHsgZXJyb3I6ICfEkGFuZyBjw7MgbeG7mXQgbOG6p24gdOG6
o2kgbMOqbiBraMOhYywgY2jhu50geG9uZyBy4buTaSB0aOG7rSBs4bqhaS4nIH0pOwogICAgY29u
c3QgZGVjbGFyZWQgPSBOdW1iZXIocmVxLmhlYWRlcnNbJ2NvbnRlbnQtbGVuZ3RoJ10gfHwgMCk7
CiAgICBpZiAoZGVjbGFyZWQgPiBjb25maWcubWF4UGFja0J5dGVzKSB7CiAgICAgIHJldHVybiBq
c29uKHJlcywgNDEzLCB7IGVycm9yOiBgRmlsZSBxdcOhIGzhu5tuICh04buRaSDEkWEgJHtNYXRo
LnJvdW5kKGNvbmZpZy5tYXhQYWNrQnl0ZXMgLyBNSUIpfSBNQikuYCB9KTsKICAgIH0KICAgIGF3
YWl0IGZzcC5ta2RpcihkaXJlY3RvcnksIHsgcmVjdXJzaXZlOiB0cnVlIH0pOwogICAgdHJ5IHsK
ICAgICAgY29uc3Qgc3BhY2UgPSBhd2FpdCBmc3Auc3RhdGZzKGRpcmVjdG9yeSk7CiAgICAgIGNv
bnN0IGZyZWUgPSBzcGFjZS5iYXZhaWwgKiBzcGFjZS5ic2l6ZTsKICAgICAgaWYgKGZyZWUgPCAy
ICogZGVjbGFyZWQgKyAyNTYgKiBNSUIpIHsKICAgICAgICByZXR1cm4ganNvbihyZXMsIDUwNywg
eyBlcnJvcjogYFZQUyBraMO0bmcgxJHhu6cgY2jhu5cgdHLhu5FuZyAoY8OybiAke01hdGgucm91
bmQoZnJlZSAvIE1JQil9IE1CKS5gIH0pOwogICAgICB9CiAgICB9IGNhdGNoIHsgLyogc3RhdGZz
IHVuYXZhaWxhYmxlOiB0cnkgYW55d2F5ICovIH0KICAgIHVwbG9hZGluZyA9IHRydWU7CiAgICBj
b25zdCBub25jZSA9IGNyeXB0by5yYW5kb21CeXRlcyg2KS50b1N0cmluZygnaGV4Jyk7CiAgICBj
b25zdCByZWNlaXZlZCA9IHBhdGguam9pbihkaXJlY3RvcnksIGAudXBsb2FkLSR7bm9uY2V9Lnpp
cGApOwogICAgY29uc3Qgc2xpbSA9IHBhdGguam9pbihkaXJlY3RvcnksIGAucGFjay0ke25vbmNl
fS56aXBgKTsKICAgIHRyeSB7CiAgICAgIGxldCBieXRlcyA9IDA7CiAgICAgIGNvbnN0IGNvdW50
ZXIgPSBuZXcgVHJhbnNmb3JtKHsKICAgICAgICB0cmFuc2Zvcm0oY2h1bmssIGVuY29kaW5nLCBk
b25lKSB7CiAgICAgICAgICBieXRlcyArPSBjaHVuay5sZW5ndGg7CiAgICAgICAgICBpZiAoYnl0
ZXMgPiBjb25maWcubWF4UGFja0J5dGVzKSBkb25lKG5ldyBQYWNrRXJyb3IoYEZpbGUgcXXDoSBs
4bubbiAodOG7kWkgxJFhICR7TWF0aC5yb3VuZChjb25maWcubWF4UGFja0J5dGVzIC8gTUlCKX0g
TUIpLmApKTsKICAgICAgICAgIGVsc2UgZG9uZShudWxsLCBjaHVuayk7CiAgICAgICAgfSwKICAg
ICAgfSk7CiAgICAgIGF3YWl0IHBpcGVsaW5lKHJlcSwgY291bnRlciwgZnMuY3JlYXRlV3JpdGVT
dHJlYW0ocmVjZWl2ZWQpKTsKICAgICAgaWYgKGRlY2xhcmVkICYmIGJ5dGVzICE9PSBkZWNsYXJl
ZCkgdGhyb3cgbmV3IFBhY2tFcnJvcignVOG6o2kgbMOqbiBi4buLIG5n4bqvdCBnaeG7r2EgY2jh
u6tuZy4nKTsKICAgICAgY29uc3QgemlwID0gYXdhaXQgcmVhZFppcChyZWNlaXZlZCk7CiAgICAg
IGNvbnN0IGFuYWx5c2lzID0gYW5hbHl6ZVppcCh6aXAuZW50cmllcyk7CiAgICAgIGNvbnN0IHdy
aXR0ZW4gPSBhd2FpdCB3cml0ZVppcChyZWNlaXZlZCwgc2xpbSwgYW5hbHlzaXMua2VlcCk7CiAg
ICAgIGF3YWl0IGZzcC5yZW5hbWUoc2xpbSwgcGF0aC5qb2luKGRpcmVjdG9yeSwgYCR7aWR9Lnpp
cGApKTsKICAgICAgY29uc3QgaW5mbyA9IHsgdGl0bGUsIHNoYTI1Njogd3JpdHRlbi5zaGEyNTYs
IGZpbGVzOiB3cml0dGVuLmZpbGVzLCBleGVjdXRhYmxlOiBhbmFseXNpcy5leGVjdXRhYmxlLAog
ICAgICAgIHVwbG9hZGVkOiBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCksIG9yaWdpbmFsOiB7IHNp
emU6IGJ5dGVzLCBmaWxlczogemlwLmVudHJpZXMubGVuZ3RoIH0gfTsKICAgICAgYXdhaXQgZnNw
LndyaXRlRmlsZShwYXRoLmpvaW4oZGlyZWN0b3J5LCBgJHtpZH0uanNvbmApLCBKU09OLnN0cmlu
Z2lmeShpbmZvLCBudWxsLCAyKSk7CiAgICAgIGF3YWl0IGZzcC5ybShyZWNlaXZlZCwgeyBmb3Jj
ZTogdHJ1ZSB9KTsKICAgICAgbG9nKGBwYWNrICR7aWR9OiAke2J5dGVzfSBieXRlcyB1cGxvYWRl
ZCwgJHt3cml0dGVuLnNpemV9IGtlcHQgKCR7d3JpdHRlbi5maWxlc30gZmlsZXMpYCk7CiAgICAg
IGpzb24ocmVzLCAyMDAsIHsgb2s6IHRydWUsIGlkLCB0aXRsZSwgc2l6ZTogd3JpdHRlbi5zaXpl
LCBzaGEyNTY6IHdyaXR0ZW4uc2hhMjU2LCBmaWxlczogd3JpdHRlbi5maWxlcywKICAgICAgICBk
cm9wcGVkOiBhbmFseXNpcy5kcm9wcGVkLCBleGVjdXRhYmxlOiBhbmFseXNpcy5leGVjdXRhYmxl
LCBvcmlnaW5hbDogaW5mby5vcmlnaW5hbCB9KTsKICAgIH0gY2F0Y2ggKGVycm9yKSB7CiAgICAg
IGF3YWl0IGZzcC5ybShyZWNlaXZlZCwgeyBmb3JjZTogdHJ1ZSB9KTsKICAgICAgYXdhaXQgZnNw
LnJtKHNsaW0sIHsgZm9yY2U6IHRydWUgfSk7CiAgICAgIGNvbnN0IG1lc3NhZ2UgPSBlcnJvciBp
bnN0YW5jZW9mIFBhY2tFcnJvciA/IGVycm9yLm1lc3NhZ2UgOiAnS2jDtG5nIGzGsHUgxJHGsOG7
o2MgZmlsZTogJyArIChlcnJvci5tZXNzYWdlIHx8IGVycm9yKTsKICAgICAgaWYgKCFyZXMuaGVh
ZGVyc1NlbnQpIGpzb24ocmVzLCBlcnJvciBpbnN0YW5jZW9mIFBhY2tFcnJvciA/IDQwMCA6IDUw
MCwgeyBlcnJvcjogbWVzc2FnZSB9KTsKICAgIH0gZmluYWxseSB7CiAgICAgIHVwbG9hZGluZyA9
IGZhbHNlOwogICAgfQogIH0KCiAgYXN5bmMgZnVuY3Rpb24gc2VydmVQYWNrKHJlcSwgcmVzLCBp
ZCkgewogICAgY29uc3QgaGVhZGVycyA9IHsgJ3gtY29udGVudC10eXBlLW9wdGlvbnMnOiAnbm9z
bmlmZicsIC4uLmFsbG93T3JpZ2luKHJlcSkgfTsKICAgIGlmIChyZXEubWV0aG9kICE9PSAnR0VU
JyAmJiByZXEubWV0aG9kICE9PSAnSEVBRCcpIHsKICAgICAgcmVzLndyaXRlSGVhZCg0MDUsIHsg
Li4uaGVhZGVycywgYWxsb3c6ICdHRVQsIEhFQUQnIH0pOwogICAgICByZXMuZW5kKCk7CiAgICAg
IHJldHVybjsKICAgIH0KICAgIGNvbnN0IGZpbGUgPSBwYXRoLmpvaW4oZGlyZWN0b3J5IHx8ICcv
bm9uZXhpc3RlbnQnLCBgJHtpZH0uemlwYCk7CiAgICBsZXQgc3RhdDsKICAgIHRyeSB7IHN0YXQg
PSBhd2FpdCBmc3Auc3RhdChmaWxlKTsgfSBjYXRjaCB7IHN0YXQgPSBudWxsOyB9CiAgICBpZiAo
IWRpcmVjdG9yeSB8fCAhc3RhdCB8fCAhc3RhdC5pc0ZpbGUoKSkgewogICAgICByZXMud3JpdGVI
ZWFkKDQwNCwgaGVhZGVycyk7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuOwogICAgfQog
ICAgaWYgKHJlcS5tZXRob2QgPT09ICdHRVQnKSB7CiAgICAgIGNvbnN0IHF1b3RhID0gY291bnRl
ZChkb3dubG9hZHMsIGNsaWVudEFkZHJlc3MocmVxKSwgY29uZmlnLnBhY2tEb3dubG9hZHNQZXJI
b3VyKTsKICAgICAgaWYgKHF1b3RhLm92ZXIpIHsKICAgICAgICByZXMud3JpdGVIZWFkKDQyOSwg
eyAuLi5oZWFkZXJzLCAncmV0cnktYWZ0ZXInOiBTdHJpbmcocXVvdGEucmV0cnkpIH0pOwogICAg
ICAgIHJlcy5lbmQoKTsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgcXVvdGEuYWRkKCk7
CiAgICB9CiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAuLi5oZWFkZXJzLCAnY29udGVudC10eXBl
JzogJ2FwcGxpY2F0aW9uL3ppcCcsICdjb250ZW50LWxlbmd0aCc6IFN0cmluZyhzdGF0LnNpemUp
LAogICAgICAnY2FjaGUtY29udHJvbCc6ICduby1jYWNoZScgfSk7CiAgICBpZiAocmVxLm1ldGhv
ZCA9PT0gJ0hFQUQnKSB7CiAgICAgIHJlcy5lbmQoKTsKICAgICAgcmV0dXJuOwogICAgfQogICAg
Y29uc3Qgc3RyZWFtID0gZnMuY3JlYXRlUmVhZFN0cmVhbShmaWxlKTsKICAgIHN0cmVhbS5vbign
ZXJyb3InLCAoKSA9PiByZXMuZGVzdHJveSgpKTsKICAgIHN0cmVhbS5waXBlKHJlcyk7CiAgfQoK
ICAvLyBSZXR1cm5zIHRydWUgd2hlbiB0aGUgcmVxdWVzdCB3YXMgb25lIG9mIHRoZSBwYWNrcycg
YW5kIGhhcyBiZWVuIGFuc3dlcmVkIChvciBpcyBiZWluZyBhbnN3ZXJlZCkuCiAgZnVuY3Rpb24g
aGFuZGxlKHJlcSwgcmVzLCBwYXRobmFtZSkgewogICAgaWYgKHBhdGhuYW1lID09PSAnL2xmMi1w
YWNrcy5qc29uJykgewogICAgICBsaXN0KCkudGhlbigocGFja3MpID0+IGpzb24ocmVzLCAyMDAs
IHsgcGFja3M6IHBhY2tzLm1hcCgoeyBpZCwgdGl0bGUsIHNpemUsIHNoYTI1NiB9KSA9PiAoeyBp
ZCwgdGl0bGUsIHNpemUsIHNoYTI1NiB9KSkgfSwKICAgICAgICB7ICdhY2Nlc3MtY29udHJvbC1h
bGxvdy1vcmlnaW4nOiAnKicgfSkpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGNvbnN0
IHBhY2sgPSBwYXRobmFtZS5tYXRjaCgvXlwvbGYyLXBhY2tzXC8oW2EtejAtOV1bYS16MC05LV17
MCwzOX0pXC56aXAkLyk7CiAgICBpZiAocGFjaykgewogICAgICBzZXJ2ZVBhY2socmVxLCByZXMs
IHBhY2tbMV0pLmNhdGNoKCgpID0+IHJlcy5kZXN0cm95KCkpOwogICAgICByZXR1cm4gdHJ1ZTsK
ICAgIH0KICAgIGlmIChwYXRobmFtZSA9PT0gJy9hZG1pbicgfHwgcGF0aG5hbWUgPT09ICcvYWRt
aW4vJykgewogICAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAnY29udGVudC10eXBlJzogJ3RleHQv
aHRtbDsgY2hhcnNldD11dGYtOCcsICdjYWNoZS1jb250cm9sJzogJ25vLXN0b3JlJywKICAgICAg
ICAneC1mcmFtZS1vcHRpb25zJzogJ0RFTlknLCAncmVmZXJyZXItcG9saWN5JzogJ25vLXJlZmVy
cmVyJyB9KTsKICAgICAgcmVzLmVuZChBRE1JTl9QQUdFKTsKICAgICAgcmV0dXJuIHRydWU7CiAg
ICB9CiAgICBpZiAocGF0aG5hbWUgPT09ICcvYWRtaW4vYXBpL3BhY2tzJyAmJiByZXEubWV0aG9k
ID09PSAnR0VUJykgewogICAgICBpZiAoYXV0aG9yaXplZChyZXEsIHJlcykpIGxpc3QoKS50aGVu
KChwYWNrcykgPT4ganNvbihyZXMsIDIwMCwgeyBwYWNrcywgbWF4Qnl0ZXM6IGNvbmZpZy5tYXhQ
YWNrQnl0ZXMgfSkpOwogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGNvbnN0IG1hbmFnZWQg
PSBwYXRobmFtZS5tYXRjaCgvXlwvYWRtaW5cL2FwaVwvcGFja3NcLyhbXi9dKikkLyk7CiAgICBp
ZiAobWFuYWdlZCkgewogICAgICBjb25zdCBpZCA9IG1hbmFnZWRbMV07CiAgICAgIGlmICghUEFD
S19JRC50ZXN0KGlkKSkgewogICAgICAgIGpzb24ocmVzLCA0MDAsIHsgZXJyb3I6ICdNw6Mgbmfh
uq9uIGNo4buJIGfhu5NtIGNo4buvIHRoxrDhu51uZyBhLXosIHPhu5EgdsOgIGThuqV1IGfhuqFj
aCBuZ2FuZyAodOG7kWkgxJFhIDQwIGvDvSB04buxKS4nIH0pOwogICAgICAgIHJldHVybiB0cnVl
OwogICAgICB9CiAgICAgIGlmIChyZXEubWV0aG9kID09PSAnUFVUJykgewogICAgICAgIGlmICgh
YXV0aG9yaXplZChyZXEsIHJlcykpIHsgcmVxLnJlc3VtZSgpOyByZXR1cm4gdHJ1ZTsgfQogICAg
ICAgIGNvbnN0IHRpdGxlID0gU3RyaW5nKG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6Ly9yZWxheS5p
bnZhbGlkJykuc2VhcmNoUGFyYW1zLmdldCgndGl0bGUnKSB8fCBpZCkudHJpbSgpLnNsaWNlKDAs
IDYwKSB8fCBpZDsKICAgICAgICB1cGxvYWQocmVxLCByZXMsIGlkLCB0aXRsZSkuY2F0Y2goKCkg
PT4gcmVzLmRlc3Ryb3koKSk7CiAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgIH0KICAgICAgaWYg
KHJlcS5tZXRob2QgPT09ICdERUxFVEUnKSB7CiAgICAgICAgaWYgKCFhdXRob3JpemVkKHJlcSwg
cmVzKSkgcmV0dXJuIHRydWU7CiAgICAgICAgUHJvbWlzZS5hbGwoW2Ake2lkfS56aXBgLCBgJHtp
ZH0uanNvbmBdLm1hcCgobmFtZSkgPT4gZnNwLnJtKHBhdGguam9pbihkaXJlY3RvcnkgfHwgJy9u
b25leGlzdGVudCcsIG5hbWUpLCB7IGZvcmNlOiB0cnVlIH0pKSkKICAgICAgICAgIC50aGVuKCgp
ID0+IHsgbG9nKGBwYWNrICR7aWR9OiByZW1vdmVkYCk7IGpzb24ocmVzLCAyMDAsIHsgb2s6IHRy
dWUgfSk7IH0pCiAgICAgICAgICAuY2F0Y2goKGVycm9yKSA9PiBqc29uKHJlcywgNTAwLCB7IGVy
cm9yOiBTdHJpbmcoZXJyb3IubWVzc2FnZSB8fCBlcnJvcikgfSkpOwogICAgICAgIHJldHVybiB0
cnVlOwogICAgICB9CiAgICAgIGpzb24ocmVzLCA0MDUsIHsgZXJyb3I6ICdtZXRob2Qgbm90IGFs
bG93ZWQnIH0sIHsgYWxsb3c6ICdQVVQsIERFTEVURScgfSk7CiAgICAgIHJldHVybiB0cnVlOwog
ICAgfQogICAgcmV0dXJuIGZhbHNlOwogIH0KCiAgcmV0dXJuIHsgaGFuZGxlLCBsaXN0LCBjbGVh
bnVwOiAoKSA9PiB7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgZm9yIChjb25zdCBt
YXAgb2YgW2Rvd25sb2FkcywgZmFpbHVyZXNdKSBmb3IgKGNvbnN0IFtrZXksIGVudHJ5XSBvZiBt
YXApIGlmIChlbnRyeS51bnRpbCA8PSBub3cpIG1hcC5kZWxldGUoa2V5KTsKICB9IH07Cn0KCi8v
IFRoZSBwYWdlIGF0IC9hZG1pbiAoVmlldG5hbWVzZTogdGhlIHJlbGF5J3Mgb3duZXIgcmVhZHMg
aXQpLgpjb25zdCBBRE1JTl9QQUdFID0gYDwhZG9jdHlwZSBodG1sPgo8aHRtbCBsYW5nPSJ2aSI+
PGhlYWQ+PG1ldGEgY2hhcnNldD0idXRmLTgiPjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50
PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+Cjx0aXRsZT5PcGVuTEYyIHJl
bGF5OiBi4bqjbiBtb2Q8L3RpdGxlPgo8c3R5bGU+CiAgYm9keSB7IG1hcmdpbjogMDsgcGFkZGlu
ZzogMS41cmVtOyBiYWNrZ3JvdW5kOiAjMTExODI3OyBjb2xvcjogI2YzZjRmNjsgZm9udDogMTZw
eC8xLjUgc3lzdGVtLXVpLCBzYW5zLXNlcmlmOyB9CiAgbWFpbiB7IG1heC13aWR0aDogNzYwcHg7
IG1hcmdpbjogYXV0bzsgfQogIGgxIHsgZm9udC1zaXplOiAxLjVyZW07IG1hcmdpbjogMCAwIC4y
NXJlbTsgfQogIC5jYXJkIHsgYmFja2dyb3VuZDogIzFmMjkzNzsgYm9yZGVyOiAxcHggc29saWQg
IzM3NDE1MTsgYm9yZGVyLXJhZGl1czogMTJweDsgcGFkZGluZzogMXJlbSAxLjJyZW07IG1hcmdp
bjogMXJlbSAwOyB9CiAgbGFiZWwgeyBkaXNwbGF5OiBibG9jazsgbWFyZ2luOiAuNnJlbSAwIC4y
cmVtOyBmb250LXdlaWdodDogNjAwOyB9CiAgaW5wdXRbdHlwZT10ZXh0XSwgaW5wdXRbdHlwZT1w
YXNzd29yZF0geyB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgcGFkZGluZzog
LjVyZW0gLjZyZW07IGZvbnQ6IGluaGVyaXQ7CiAgICBib3JkZXItcmFkaXVzOiA4cHg7IGJvcmRl
cjogMXB4IHNvbGlkICM0YjU1NjM7IGJhY2tncm91bmQ6ICMwYjEyMjA7IGNvbG9yOiBpbmhlcml0
OyB9CiAgYnV0dG9uIHsgcGFkZGluZzogLjU1cmVtIDEuMXJlbTsgZm9udDogaW5oZXJpdDsgYm9y
ZGVyLXJhZGl1czogOHB4OyBib3JkZXI6IDA7IGN1cnNvcjogcG9pbnRlcjsgYmFja2dyb3VuZDog
I2Y1OWUwYjsgY29sb3I6ICMxZjEzMDA7IGZvbnQtd2VpZ2h0OiA3MDA7IH0KICBidXR0b24uc2Vj
b25kYXJ5IHsgYmFja2dyb3VuZDogIzM3NDE1MTsgY29sb3I6ICNmM2Y0ZjY7IGZvbnQtd2VpZ2h0
OiA1MDA7IH0KICBidXR0b246ZGlzYWJsZWQgeyBvcGFjaXR5OiAuNTsgY3Vyc29yOiBkZWZhdWx0
OyB9CiAgcHJvZ3Jlc3MgeyB3aWR0aDogMTAwJTsgaGVpZ2h0OiAuOHJlbTsgbWFyZ2luLXRvcDog
LjhyZW07IH0KICAubm90ZSB7IGNvbG9yOiAjOWNhM2FmOyBmb250LXNpemU6IC45cmVtOyB9CiAg
Lm9rIHsgY29sb3I6ICM2ZWU3Yjc7IH0gLmJhZCB7IGNvbG9yOiAjZmNhNWE1OyB9CiAgdGFibGUg
eyB3aWR0aDogMTAwJTsgYm9yZGVyLWNvbGxhcHNlOiBjb2xsYXBzZTsgfSB0ZCwgdGggeyB0ZXh0
LWFsaWduOiBsZWZ0OyBwYWRkaW5nOiAuNHJlbSAuM3JlbTsgYm9yZGVyLWJvdHRvbTogMXB4IHNv
bGlkICMzNzQxNTE7IHZlcnRpY2FsLWFsaWduOiB0b3A7IH0KICBjb2RlIHsgYmFja2dyb3VuZDog
IzBiMTIyMDsgcGFkZGluZzogLjA1cmVtIC4zcmVtOyBib3JkZXItcmFkaXVzOiA0cHg7IH0KPC9z
dHlsZT48L2hlYWQ+Cjxib2R5PjxtYWluPgogIDxoMT5C4bqjbiBtb2QgY2hvIE9wZW5MRjI8L2gx
PgogIDxwIGNsYXNzPSJub3RlIj5U4bqjaSBsw6puIG3hu5l0IGZpbGUgLnppcCBjaOG7qWEgY+G6
oyB0aMawIG3hu6VjIGdhbWUgY+G7p2EgYuG6o24gbW9kIChjw7MgZmlsZSAuZXhlIHbDoCB0aMaw
IG3hu6VjIGRhdGEsIHNwcml0ZSwgYmdtLCBiZykuCiAgICBSZWxheSBjaOG7iSBnaeG7ryBs4bqh
aSBwaOG6p24gZ2FtZSBj4bqnbiwgcuG7k2kgcGjDoXQgY2hvIHRyw6xuaCBkdXnhu4d0IGPhu6dh
IG5nxrDhu51pIGNoxqFpLiBBaSBjxaluZyBjaOG7jW4gY8O5bmcgbeG7mXQgYuG6o24gbW9kIG3h
u5tpIHbDoG8gY2h1bmcgcGjDsm5nIMSRxrDhu6NjLjwvcD4KICA8ZGl2IGNsYXNzPSJjYXJkIj4K
ICAgIDxsYWJlbCBmb3I9ImtleSI+TcOjIHF14bqjbiB0cuG7iyAoQURNSU5fS0VZKTwvbGFiZWw+
CiAgICA8aW5wdXQgaWQ9ImtleSIgdHlwZT0icGFzc3dvcmQiIGF1dG9jb21wbGV0ZT0iY3VycmVu
dC1wYXNzd29yZCIgcGxhY2Vob2xkZXI9ImluIHJhIGtoaSBjaOG6oXkgaW5zdGFsbC12cHMuc2gi
PgogICAgPGxhYmVsIGZvcj0iZmlsZSI+RmlsZSAuemlwIGPhu6dhIGLhuqNuIG1vZDwvbGFiZWw+
CiAgICA8aW5wdXQgaWQ9ImZpbGUiIHR5cGU9ImZpbGUiIGFjY2VwdD0iLnppcCxhcHBsaWNhdGlv
bi96aXAiPgogICAgPGxhYmVsIGZvcj0idGl0bGUiPlTDqm4gaGnhu4NuIHRo4buLIHRyw6puIHRy
YW5nIGdhbWU8L2xhYmVsPgogICAgPGlucHV0IGlkPSJ0aXRsZSIgdHlwZT0idGV4dCIgbWF4bGVu
Z3RoPSI2MCIgcGxhY2Vob2xkZXI9InbDrSBk4bulOiBPbmUgUGllY2UgR3JhbmRXb3JsZCI+CiAg
ICA8bGFiZWwgZm9yPSJpZCI+TcOjIG5n4bqvbiAoZMO5bmcgdHJvbmcgbGluayBt4budaSk8L2xh
YmVsPgogICAgPGlucHV0IGlkPSJpZCIgdHlwZT0idGV4dCIgbWF4bGVuZ3RoPSI0MCIgcGxhY2Vo
b2xkZXI9InbDrSBk4bulOiBvbmVwaWVjZSIgcGF0dGVybj0iW2EtejAtOV1bYS16MC05LV0qIj4K
ICAgIDxwPjxidXR0b24gaWQ9InVwbG9hZCI+VOG6o2kgbMOqbjwvYnV0dG9uPjwvcD4KICAgIDxw
cm9ncmVzcyBpZD0icHJvZ3Jlc3MiIGhpZGRlbj48L3Byb2dyZXNzPgogICAgPHAgaWQ9InN0YXR1
cyIgcm9sZT0ic3RhdHVzIiBjbGFzcz0ibm90ZSI+PC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9
ImNhcmQiPgogICAgPGgyIHN0eWxlPSJmb250LXNpemU6MS4xNXJlbTttYXJnaW46MCAwIC41cmVt
Ij5Dw6FjIGLhuqNuIG1vZCB0csOqbiByZWxheTwvaDI+CiAgICA8cD48YnV0dG9uIGlkPSJyZWZy
ZXNoIiBjbGFzcz0ic2Vjb25kYXJ5Ij5YZW0gZGFuaCBzw6FjaDwvYnV0dG9uPjwvcD4KICAgIDx0
YWJsZT48dGJvZHkgaWQ9Imxpc3QiPjwvdGJvZHk+PC90YWJsZT4KICA8L2Rpdj4KPC9tYWluPgo8
c2NyaXB0PgogIGNvbnN0ICQgPSAoaWQpID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsK
ICBjb25zdCBhcGkgPSBsb2NhdGlvbi5wYXRobmFtZS5yZXBsYWNlKC9cXC8/JC8sICcvJykgKyAn
YXBpL3BhY2tzJzsKICB0cnkgeyAkKCdrZXknKS52YWx1ZSA9IGxvY2FsU3RvcmFnZS5nZXRJdGVt
KCdsZjItYWRtaW4ta2V5JykgfHwgJyc7IH0gY2F0Y2ggKGVycm9yKSB7fQogIGNvbnN0IHJlbWVt
YmVyID0gKCkgPT4geyB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnbGYyLWFkbWluLWtleScs
ICQoJ2tleScpLnZhbHVlKTsgfSBjYXRjaCAoZXJyb3IpIHt9IH07CiAgY29uc3Qgc2x1ZyA9ICh0
ZXh0KSA9PiB0ZXh0LnRvTG93ZXJDYXNlKCkubm9ybWFsaXplKCdORkQnKS5yZXBsYWNlKC9bXFx1
MDMwMC1cXHUwMzZmXS9nLCAnJykucmVwbGFjZSgvxJEvZywgJ2QnKQogICAgLnJlcGxhY2UoL1te
YS16MC05XSsvZywgJy0nKS5yZXBsYWNlKC9eLSt8LSskL2csICcnKS5zbGljZSgwLCA0MCkgfHwg
J21vZCc7CiAgJCgnZmlsZScpLmFkZEV2ZW50TGlzdGVuZXIoJ2NoYW5nZScsICgpID0+IHsKICAg
IGNvbnN0IGZpbGUgPSAkKCdmaWxlJykuZmlsZXNbMF07CiAgICBpZiAoIWZpbGUpIHJldHVybjsK
ICAgIGNvbnN0IG5hbWUgPSBmaWxlLm5hbWUucmVwbGFjZSgvXFwuemlwJC9pLCAnJykucmVwbGFj
ZSgvW19dKy9nLCAnICcpLnRyaW0oKTsKICAgIGlmICghJCgndGl0bGUnKS52YWx1ZSkgJCgndGl0
bGUnKS52YWx1ZSA9IG5hbWU7CiAgICBpZiAoISQoJ2lkJykudmFsdWUpICQoJ2lkJykudmFsdWUg
PSBzbHVnKG5hbWUpOwogIH0pOwogICQoJ3RpdGxlJykuYWRkRXZlbnRMaXN0ZW5lcignaW5wdXQn
LCAoKSA9PiB7IGlmICghJCgnaWQnKS5kYXRhc2V0LnRvdWNoZWQpICQoJ2lkJykudmFsdWUgPSBz
bHVnKCQoJ3RpdGxlJykudmFsdWUpOyB9KTsKICAkKCdpZCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2lu
cHV0JywgKCkgPT4geyAkKCdpZCcpLmRhdGFzZXQudG91Y2hlZCA9ICcxJzsgfSk7CiAgY29uc3Qg
bWIgPSAoYnl0ZXMpID0+IChieXRlcyAvIDFlNikudG9GaXhlZCgxKSArICcgTUInOwogIGZ1bmN0
aW9uIHN0YXR1cyh0ZXh0LCBraW5kKSB7ICQoJ3N0YXR1cycpLnRleHRDb250ZW50ID0gdGV4dDsg
JCgnc3RhdHVzJykuY2xhc3NOYW1lID0ga2luZCB8fCAnbm90ZSc7IH0KICAkKCd1cGxvYWQnKS5h
ZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IHsKICAgIGNvbnN0IGZpbGUgPSAkKCdmaWxl
JykuZmlsZXNbMF07CiAgICBjb25zdCBpZCA9ICQoJ2lkJykudmFsdWUudHJpbSgpOwogICAgaWYg
KCEkKCdrZXknKS52YWx1ZSkgcmV0dXJuIHN0YXR1cygnTmjhuq1wIG3DoyBxdeG6o24gdHLhu4sg
dHLGsOG7m2MuJywgJ2JhZCcpOwogICAgaWYgKCFmaWxlKSByZXR1cm4gc3RhdHVzKCdDaOG7jW4g
ZmlsZSAuemlwIHRyxrDhu5tjLicsICdiYWQnKTsKICAgIGlmICghL15bYS16MC05XVthLXowLTkt
XXswLDM5fSQvLnRlc3QoaWQpKSByZXR1cm4gc3RhdHVzKCdNw6Mgbmfhuq9uIGNo4buJIGfhu5Nt
IGNo4buvIHRoxrDhu51uZyBhLXosIHPhu5EgdsOgIGThuqV1IGfhuqFjaCBuZ2FuZy4nLCAnYmFk
Jyk7CiAgICByZW1lbWJlcigpOwogICAgY29uc3QgcmVxdWVzdCA9IG5ldyBYTUxIdHRwUmVxdWVz
dCgpOwogICAgcmVxdWVzdC5vcGVuKCdQVVQnLCBhcGkgKyAnLycgKyBpZCArICc/dGl0bGU9JyAr
IGVuY29kZVVSSUNvbXBvbmVudCgkKCd0aXRsZScpLnZhbHVlLnRyaW0oKSB8fCBpZCkpOwogICAg
cmVxdWVzdC5zZXRSZXF1ZXN0SGVhZGVyKCd4LWFkbWluLWtleScsICQoJ2tleScpLnZhbHVlKTsK
ICAgIHJlcXVlc3Quc2V0UmVxdWVzdEhlYWRlcignY29udGVudC10eXBlJywgJ2FwcGxpY2F0aW9u
L3ppcCcpOwogICAgJCgncHJvZ3Jlc3MnKS5oaWRkZW4gPSBmYWxzZTsKICAgICQoJ3VwbG9hZCcp
LmRpc2FibGVkID0gdHJ1ZTsKICAgIHJlcXVlc3QudXBsb2FkLm9ucHJvZ3Jlc3MgPSAoZXZlbnQp
ID0+IHsKICAgICAgaWYgKCFldmVudC5sZW5ndGhDb21wdXRhYmxlKSByZXR1cm47CiAgICAgICQo
J3Byb2dyZXNzJykubWF4ID0gZXZlbnQudG90YWw7CiAgICAgICQoJ3Byb2dyZXNzJykudmFsdWUg
PSBldmVudC5sb2FkZWQ7CiAgICAgIHN0YXR1cygnxJBhbmcgdOG6o2kgbMOqbjogJyArIG1iKGV2
ZW50LmxvYWRlZCkgKyAnIC8gJyArIG1iKGV2ZW50LnRvdGFsKSArIChldmVudC5sb2FkZWQgPT09
IGV2ZW50LnRvdGFsID8gJyAocmVsYXkgxJFhbmcgeOG7rSBsw70uLi4pJyA6ICcnKSk7CiAgICB9
OwogICAgcmVxdWVzdC5vbmxvYWQgPSAoKSA9PiB7CiAgICAgICQoJ3VwbG9hZCcpLmRpc2FibGVk
ID0gZmFsc2U7CiAgICAgICQoJ3Byb2dyZXNzJykuaGlkZGVuID0gdHJ1ZTsKICAgICAgbGV0IGJv
ZHkgPSB7fTsKICAgICAgdHJ5IHsgYm9keSA9IEpTT04ucGFyc2UocmVxdWVzdC5yZXNwb25zZVRl
eHQpOyB9IGNhdGNoIChlcnJvcikge30KICAgICAgaWYgKHJlcXVlc3Quc3RhdHVzID09PSAyMDAp
IHsKICAgICAgICBzdGF0dXMoJ1hvbmc6ICInICsgYm9keS50aXRsZSArICciICgnICsgbWIoYm9k
eS5zaXplKSArICcsICcgKyBib2R5LmZpbGVzICsgJyBmaWxlLCBi4buPIGLhu5t0ICcgKyBib2R5
LmRyb3BwZWQgKyAnIGZpbGUga2jDtG5nIGPhuqduKS4gJwogICAgICAgICAgKyAnVHLDqm4gdHJh
bmcgZ2FtZSwgY2jhu41uIG7DsyDhu58gbeG7pWMgR2FtZSwgaG/hurdjIGfhu61pIGxpbmsgbeG7
nWkgY8OzIHRow6ptICZwYWNrPScgKyBib2R5LmlkICsgJy4nLCAnb2snKTsKICAgICAgICByZWZy
ZXNoKCk7CiAgICAgIH0gZWxzZSBzdGF0dXMoJ0tow7RuZyDEkcaw4bujYzogJyArIChib2R5LmVy
cm9yIHx8ICgnbOG7l2kgJyArIHJlcXVlc3Quc3RhdHVzKSksICdiYWQnKTsKICAgIH07CiAgICBy
ZXF1ZXN0Lm9uZXJyb3IgPSAoKSA9PiB7ICQoJ3VwbG9hZCcpLmRpc2FibGVkID0gZmFsc2U7ICQo
J3Byb2dyZXNzJykuaGlkZGVuID0gdHJ1ZTsgc3RhdHVzKCdN4bqldCBr4bq/dCBu4buRaSBraGkg
dOG6o2kgbMOqbi4nLCAnYmFkJyk7IH07CiAgICByZXF1ZXN0LnNlbmQoZmlsZSk7CiAgfSk7CiAg
YXN5bmMgZnVuY3Rpb24gcmVmcmVzaCgpIHsKICAgIGlmICghJCgna2V5JykudmFsdWUpIHJldHVy
biBzdGF0dXMoJ05o4bqtcCBtw6MgcXXhuqNuIHRy4buLIMSR4buDIHhlbSBkYW5oIHPDoWNoLics
ICdiYWQnKTsKICAgIHJlbWVtYmVyKCk7CiAgICBjb25zdCByZXNwb25zZSA9IGF3YWl0IGZldGNo
KGFwaSwgeyBoZWFkZXJzOiB7ICd4LWFkbWluLWtleSc6ICQoJ2tleScpLnZhbHVlIH0gfSk7CiAg
ICBjb25zdCBib2R5ID0gYXdhaXQgcmVzcG9uc2UuanNvbigpLmNhdGNoKCgpID0+ICh7fSkpOwog
ICAgaWYgKCFyZXNwb25zZS5vaykgcmV0dXJuIHN0YXR1cyhib2R5LmVycm9yIHx8ICgnbOG7l2kg
JyArIHJlc3BvbnNlLnN0YXR1cyksICdiYWQnKTsKICAgIGNvbnN0IGxpc3QgPSAkKCdsaXN0Jyk7
CiAgICBsaXN0LnRleHRDb250ZW50ID0gJyc7CiAgICBpZiAoIWJvZHkucGFja3MubGVuZ3RoKSBs
aXN0LmlubmVySFRNTCA9ICc8dHI+PHRkIGNsYXNzPSJub3RlIj5DaMawYSBjw7MgYuG6o24gbW9k
IG7DoG8uPC90ZD48L3RyPic7CiAgICBmb3IgKGNvbnN0IHBhY2sgb2YgYm9keS5wYWNrcykgewog
ICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd0cicpOwogICAgICBjb25z
dCBpbmZvID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgndGQnKTsKICAgICAgaW5mby5pbm5lckhU
TUwgPSAnPGI+PC9iPjxicj48c3BhbiBjbGFzcz0ibm90ZSI+PC9zcGFuPic7CiAgICAgIGluZm8u
cXVlcnlTZWxlY3RvcignYicpLnRleHRDb250ZW50ID0gcGFjay50aXRsZTsKICAgICAgaW5mby5x
dWVyeVNlbGVjdG9yKCdzcGFuJykudGV4dENvbnRlbnQgPSAnbcOjOiAnICsgcGFjay5pZCArICcg
wrcgJyArIG1iKHBhY2suc2l6ZSkgKyAnIMK3IHThuqNpIGzDqm4gJyArIG5ldyBEYXRlKHBhY2su
dXBsb2FkZWQpLnRvTG9jYWxlU3RyaW5nKCk7CiAgICAgIGNvbnN0IGFjdGlvbnMgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCd0ZCcpOwogICAgICBjb25zdCByZW1vdmUgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgcmVtb3ZlLmNsYXNzTmFtZSA9ICdzZWNvbmRhcnkn
OwogICAgICByZW1vdmUudGV4dENvbnRlbnQgPSAnWMOzYSc7CiAgICAgIHJlbW92ZS5vbmNsaWNr
ID0gYXN5bmMgKCkgPT4gewogICAgICAgIGlmICghY29uZmlybSgnWMOzYSAiJyArIHBhY2sudGl0
bGUgKyAnIiBraOG7j2kgcmVsYXk/JykpIHJldHVybjsKICAgICAgICBjb25zdCByZXN1bHQgPSBh
d2FpdCBmZXRjaChhcGkgKyAnLycgKyBwYWNrLmlkLCB7IG1ldGhvZDogJ0RFTEVURScsIGhlYWRl
cnM6IHsgJ3gtYWRtaW4ta2V5JzogJCgna2V5JykudmFsdWUgfSB9KTsKICAgICAgICBpZiAocmVz
dWx0Lm9rKSByZWZyZXNoKCk7IGVsc2Ugc3RhdHVzKCdLaMO0bmcgeMOzYSDEkcaw4bujYyAobOG7
l2kgJyArIHJlc3VsdC5zdGF0dXMgKyAnKS4nLCAnYmFkJyk7CiAgICAgIH07CiAgICAgIGFjdGlv
bnMuYXBwZW5kQ2hpbGQocmVtb3ZlKTsKICAgICAgcm93LmFwcGVuZChpbmZvLCBhY3Rpb25zKTsK
ICAgICAgbGlzdC5hcHBlbmRDaGlsZChyb3cpOwogICAgfQogIH0KICAkKCdyZWZyZXNoJykuYWRk
RXZlbnRMaXN0ZW5lcignY2xpY2snLCByZWZyZXNoKTsKPC9zY3JpcHQ+CjwvYm9keT48L2h0bWw+
CmA7Cgptb2R1bGUuZXhwb3J0cyA9IHsgY3JlYXRlUGFja3MsIHJlYWRaaXAsIGFuYWx5emVaaXAs
IHdyaXRlWmlwLCBQYWNrRXJyb3IsIFBBQ0tfSUQgfTsK
LF2_PAYLOAD
}
write_package_json() {
	base64 -d >"$1" <<'LF2_PAYLOAD'
ewogICJuYW1lIjogIm9wZW5sZjItb25saW5lLXJlbGF5IiwKICAidmVyc2lvbiI6ICIxLjAuMCIs
CiAgInByaXZhdGUiOiB0cnVlLAogICJkZXNjcmlwdGlvbiI6ICJXZWJTb2NrZXQgcmVsYXkgZm9y
IE9wZW5MRjIgd2ViIHBsYXllcnM6IHJvb21zIG9mIHVwIHRvIDggcGxheWVycyBieSByb29tIGNv
ZGUsIGtlcHQgaW4gc3RlcCBieSB0aGUgcmVsYXksIGFuZCB0aGUgZ2FtZSBmaWxlcyBpdCBzZXJ2
ZXMiLAogICJsaWNlbnNlIjogIk1JVCIsCiAgIm1haW4iOiAic2VydmVyLmpzIiwKICAiYmluIjog
ewogICAgIm9wZW5sZjItcmVsYXkiOiAic2VydmVyLmpzIgogIH0sCiAgInNjcmlwdHMiOiB7CiAg
ICAic3RhcnQiOiAibm9kZSBzZXJ2ZXIuanMiLAogICAgInRlc3QiOiAibm9kZSAtLXRlc3QgXCJ0
ZXN0LyoudGVzdC5qc1wiIgogIH0sCiAgImVuZ2luZXMiOiB7CiAgICAibm9kZSI6ICI+PTIwIgog
IH0sCiAgImRlcGVuZGVuY2llcyI6IHsKICAgICJ3cyI6ICJeOC4xOC4wIgogIH0KfQo=
LF2_PAYLOAD
}
# <<< generated

# Last line on purpose: bash reads the whole script before running anything, so a cut-off
# download does nothing, and commands cannot swallow the script through stdin.
[ "${LF2_INSTALLER_LIB:-}" = 1 ] || main "$@"

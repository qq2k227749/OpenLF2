#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Gives a built game page a default relay address for online play (window.OPENLF2_RELAY, read by
online.js), so that players who open the site need not type one. The page then also downloads the
game data from that relay's copy. Used by the WebAssembly workflow with its "relay" input.

    set-relay.py PAGE ADDRESS

An empty ADDRESS leaves the page as it is. The address may be pasted the way the relay installer
prints it (wss://203-0-113-5.sslip.io/relay), or as https://… or a bare host name.
"""
import re
import sys

PATTERN = re.compile(r"wss?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?")
TAG = '<script src="online.js"></script>'


def normalize(address):
    address = address.strip()
    if not address:
        return ""
    if not re.match(r"^[a-z][a-z0-9+.-]*://", address, re.IGNORECASE):
        address = "wss://" + address
    address = re.sub(r"^https://", "wss://", address, flags=re.IGNORECASE)
    address = re.sub(r"^http://", "ws://", address, flags=re.IGNORECASE)
    scheme, rest = address.split("://", 1)
    if "/" not in rest:
        address = f"{scheme}://{rest}/relay"
    return address


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    page, address = argv[1], normalize(argv[2])
    if not address:
        print("No relay address given; the page keeps asking players for one.")
        return
    if not PATTERN.fullmatch(address):
        sys.exit(f"The relay address must look like wss://203-0-113-5.sslip.io/relay, not {argv[2]!r}")
    with open(page, encoding="utf-8") as file:
        html = file.read()
    if html.count(TAG) != 1:
        sys.exit(f"{page}: expected exactly one {TAG}")
    html = html.replace(TAG, f"<script>window.OPENLF2_RELAY = '{address}';</script>\n{TAG}")
    with open(page, "w", encoding="utf-8") as file:
        file.write(html)
    print(f"Default relay address: {address}")


if __name__ == "__main__":
    main(sys.argv)

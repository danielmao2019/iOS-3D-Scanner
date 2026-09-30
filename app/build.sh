#!/usr/bin/env bash
# Builds the app from Linux with xtool. Usage: ./build.sh (build only) or ./build.sh run (build, install and launch on the iPhone reached through USBMUXD_SOCKET_ADDRESS).
set -euo pipefail
cd "$(dirname "$0")"
. ~/.local/share/swiftly/env.sh
export USBMUXD_SOCKET_ADDRESS="${USBMUXD_SOCKET_ADDRESS:-UNIX:$HOME/.usbmuxd.sock}"

# The repo is public, so the receiver's address and upload token stay out of git: server/url holds the address the app uploads to by default (http://host:port), and server/token the token shared with server/receive.py.
url_file=../server/url
token_file=../server/token
[ -s "$url_file" ] || { echo "server/url is missing: write the receiver's address (http://host:port) into it" >&2; exit 1; }
[ -s "$token_file" ] || python3 -c "import secrets; print(secrets.token_hex(16))" > "$token_file"
printf 'enum Secrets {\n    static let server = "%s"\n    static let uploadToken = "%s"\n}\n' "$(tr -d '\n' < "$url_file")" "$(tr -d '\n' < "$token_file")" > Sources/RGBDScanner/Secrets.swift

xtool dev "${1:-build}"

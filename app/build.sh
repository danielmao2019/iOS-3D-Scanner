#!/usr/bin/env bash
# Builds the app from Linux with xtool. Usage: ./build.sh (build only) or ./build.sh run (build, install and launch on the iPhone reached through USBMUXD_SOCKET_ADDRESS).
set -euo pipefail
cd "$(dirname "$0")"
. ~/.local/share/swiftly/env.sh
export USBMUXD_SOCKET_ADDRESS="${USBMUXD_SOCKET_ADDRESS:-UNIX:$HOME/.usbmuxd.sock}"

# The repo is public, so the receivers' addresses and the upload token stay out of git: server/users.json holds each receiver's server by name with its address and the users the app offers at launch, each with its configs, {"servers": {"<name>": "http://host:port", ...}, "users": [{"name", "configs": [{"server": "<name>", "data_root": "/path/on/that/machine"}, ...]}, ...]}, the app showing and saving only the names, and server/token the token shared with every server/receive.py.
users_file=../server/users.json
token_file=../server/token
[ -s "$users_file" ] || { echo "server/users.json is missing: write the users and their configs into it" >&2; exit 1; }
[ -s "$token_file" ] || python3 -c "import secrets; print(secrets.token_hex(16))" > "$token_file"
printf 'enum Secrets {\n    static let uploadToken = "%s"\n    static let users = #"%s"#\n}\n' "$(tr -d '\n' < "$token_file")" "$(tr -d '\n' < "$users_file")" > Sources/RGBDScanner/Secrets.swift

# Release: the app runs its per-frame work (encoding, depth copies, the depth view) optimized.
xtool dev "${1:-build}" --configuration release

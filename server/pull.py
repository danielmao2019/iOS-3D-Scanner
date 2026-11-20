"""Takes the recordings of the RGBD Scanner app's Wired transfer config from an iPhone plugged into this computer by USB cable, and stores each as <folder>/<scan_id>.tar, the same file server/receive.py writes, <folder> being the folder the recording's config names on this computer or, when it names none, this computer's Downloads folder.

The app (from 6.0) serves its Wired transfer recordings while it is on screen, on port 8765 of the phone's loopback, which a computer reaches only through usbmux, Apple's USB multiplexer, once the phone trusts that computer: on Windows the Apple Mobile Device Service, which the Apple Devices app installs, at 127.0.0.1:27015; on macOS and Linux (the usbmuxd package) the socket /var/run/usbmuxd; the environment variable USBMUXD_SOCKET_ADDRESS, UNIX:<path> or <host>:<port>, names another. Over each usbmux connection the app answers one HTTP/1.1 request: GET /recordings answers {"recordings": [{"scan_id", "path", "members"}, ...]}, path being the folder or null, members as receive.py's manifest lists them; GET /recordings/<scan_id>/<file> answers the bytes of one of its files, a JSON file or a frames file's segment; POST /stored/<scan_id> tells the phone that this computer has stored the recording, and the phone deletes it.

Each file streams into <folder>/.<scan_id>.staging/ while it is hashed and is kept, beside <name>.sha256, only when its size and SHA-256 are those listed, so a pull cut short resumes with the files still missing. Once every file is there, receive.py's store writes <folder>/<scan_id>.tar from them, the staging directory is removed, and only then is the phone told the recording is stored. A recording whose <folder>/<scan_id>.tar already exists, holding the members it lists at their sizes, is only reported to the phone as stored; one whose tar differs, or whose folder does not exist, stays on the phone. The folder holds a recording twice while its tar is written.
"""

import argparse
import hashlib
import http.client
import json
import os
import plistlib
import re
import socket
import struct
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from receive import CHUNK, FRAMES_FILES, KEY, MANIFEST, staged_recording, store

PHONE_PORT = 8765
# usbmux's plist protocol: each message a 16-byte little-endian header (total length, version 1, message type 8 for a plist, tag), then an XML plist.
USBMUX_HEADER = struct.Struct("<IIII")
USBMUX_PLIST_VERSION = 1
USBMUX_PLIST_MESSAGE = 8
# Connect's result when nothing listens on the phone's port.
USBMUX_CONNECTION_REFUSED = 3


def usbmux_socket() -> socket.socket:
    """A connection to this computer's usbmux service, at USBMUXD_SOCKET_ADDRESS or the platform's own address."""
    address = os.environ.get("USBMUXD_SOCKET_ADDRESS") or ("127.0.0.1:27015" if sys.platform == "win32" else "UNIX:/var/run/usbmuxd")
    if address.startswith("UNIX:"):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(address[len("UNIX:"):])
        return sock
    host, port = address.rsplit(":", 1)
    return socket.create_connection((host, int(port)))


def usbmux_exchange(sock: socket.socket, message: Dict[str, Any]) -> Dict[str, Any]:
    """Sends a plist message to usbmux and returns its reply."""
    body = plistlib.dumps({**message, "ClientVersionString": "pull.py", "ProgName": "pull.py", "kLibUSBMuxVersion": 3})
    sock.sendall(USBMUX_HEADER.pack(USBMUX_HEADER.size + len(body), USBMUX_PLIST_VERSION, USBMUX_PLIST_MESSAGE, 1) + body)
    length = USBMUX_HEADER.unpack(receive_exactly(sock, USBMUX_HEADER.size))[0]
    return plistlib.loads(receive_exactly(sock, length - USBMUX_HEADER.size))


def receive_exactly(sock: socket.socket, n: int) -> bytes:
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        assert chunk, "usbmux closed the connection"
        data += chunk
    return bytes(data)


def phone_device_id(udid: Optional[str]) -> int:
    """usbmux's DeviceID of the iPhone plugged in by USB, the one with that UDID when given; exits when there is not exactly one."""
    with usbmux_socket() as sock:
        devices = [d for d in usbmux_exchange(sock, {"MessageType": "ListDevices"})["DeviceList"] if d["Properties"].get("ConnectionType") == "USB"]
    if udid is not None:
        devices = [d for d in devices if d["Properties"].get("SerialNumber") == udid]
    if len(devices) != 1:
        sys.exit(f"pull.py: {len(devices)} iPhones plugged in by USB{' with UDID ' + udid if udid else ''}: {[d['Properties'].get('SerialNumber') for d in devices]}; plug in one, unlock it and tap Trust, or pick one with --udid")
    return devices[0]["DeviceID"]


def phone_request(device_id: int, method: str, path: str) -> http.client.HTTPResponse:
    """Sends one HTTP request to the app over a new usbmux connection and returns the response, whose body closes the connection once read."""
    sock = usbmux_socket()
    result = usbmux_exchange(sock, {"MessageType": "Connect", "DeviceID": device_id, "PortNumber": socket.htons(PHONE_PORT)})
    if result.get("Number") != 0:
        sock.close()
        if result.get("Number") == USBMUX_CONNECTION_REFUSED:
            sys.exit("pull.py: RGBD Scanner does not answer on the phone: open it, from version 6.0, and keep it on screen")
        sys.exit(f"pull.py: usbmux cannot reach the phone: {result}")
    connection = http.client.HTTPConnection("phone")
    connection.sock = sock
    connection.request(method, path)
    return connection.getresponse()


def phone_json(device_id: int, method: str, path: str) -> Dict[str, Any]:
    response = phone_request(device_id, method, path)
    body = response.read()
    assert response.status == 200, f"{method} {path}: the phone replied {response.status}: {body.decode(errors='replace')}"
    return json.loads(body)


def downloads_folder() -> Path:
    """This computer's Downloads folder, where the user's system keeps it."""
    if sys.platform == "win32":
        return windows_downloads_folder()
    if sys.platform == "darwin":
        return Path.home() / "Downloads"
    # Linux and other XDG desktops: XDG_DOWNLOAD_DIR in user-dirs.dirs, "$HOME/..." or absolute, else ~/Downloads.
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "user-dirs.dirs"
    if config.is_file():
        match = re.search(r'^XDG_DOWNLOAD_DIR="([^"]*)"', config.read_text(), re.MULTILINE)
        if match is not None:
            return Path(match.group(1).replace("$HOME", str(Path.home())))
    return Path.home() / "Downloads"


def windows_downloads_folder() -> Path:
    """The Downloads known folder (FOLDERID_Downloads), wherever the user has moved it."""
    # Lazy: ctypes.windll and ctypes.wintypes exist only on Windows.
    import ctypes
    from ctypes import wintypes

    class GUID(ctypes.Structure):
        _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD), ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]

    folder_id = GUID(0x374DE290, 0x123F, 0x4565, (ctypes.c_ubyte * 8)(0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B))
    path = ctypes.c_wchar_p()
    result = ctypes.windll.shell32.SHGetKnownFolderPath(ctypes.byref(folder_id), 0, None, ctypes.byref(path))
    try:
        assert result == 0, f"SHGetKnownFolderPath(FOLDERID_Downloads) failed: {result:#x}"
        return Path(path.value)
    finally:
        ctypes.windll.ole32.CoTaskMemFree(path)


def member_size(member: Dict[str, Any]) -> int:
    """A member's size in the tar: a JSON file's own, a frames file's segments' joined."""
    return sum(s["size"] for s in member["segments"]) if member["name"] in FRAMES_FILES else member["size"]


def stored_matches(archive: Path, scan_id: str, members: List[Dict[str, Any]]) -> bool:
    """Whether an existing tar holds exactly the recording's members, in order, at their sizes."""
    with tarfile.open(archive, "r:") as tar:
        held = [(m.name, m.size) for m in tar.getmembers()]
    return held == [(f"{scan_id}/{m['name']}", member_size(m)) for m in members]


def fetch(device_id: int, scan_id: str, file: Dict[str, Any], staging: Path, progress: "Progress") -> None:
    """Streams one of the recording's files into the staging directory while hashing it, keeping it beside <name>.sha256 only when its size and SHA-256 are those listed; a file already kept is not fetched again."""
    name, size, sha256 = file["name"], file["size"], file["sha256"]
    kept, hash_file = staging / name, staging / f"{name}.sha256"
    if kept.is_file() and kept.stat().st_size == size and hash_file.is_file() and hash_file.read_text() == sha256:
        progress.add(size)
        return
    response = phone_request(device_id, "GET", f"/recordings/{scan_id}/{name}")
    if response.status != 200:
        raise RuntimeError(f"{name}: the phone replied {response.status}: {response.read().decode(errors='replace')}")
    fd, part_name = tempfile.mkstemp(dir=staging, prefix=f".{name}.", suffix=".part")
    part = Path(part_name)
    try:
        digest = hashlib.sha256()
        received = 0
        with os.fdopen(fd, "wb") as f:
            while chunk := response.read(CHUNK):
                f.write(chunk)
                digest.update(chunk)
                received += len(chunk)
                progress.add(len(chunk))
        response.close()
        if received != size or digest.hexdigest() != sha256:
            raise RuntimeError(f"{name}: received {received} bytes with SHA-256 {digest.hexdigest()}, listed {size} bytes with {sha256}")
        hash_file.write_text(sha256)
        os.replace(part, kept)
    finally:
        part.unlink(missing_ok=True)


class Progress:
    """Prints, on one line, the bytes of a recording fetched or found already fetched, and the rate of those fetched."""

    def __init__(self, scan_id: str, total: int) -> None:
        self.scan_id, self.total, self.done, self.start = scan_id, total, 0, time.monotonic()

    def add(self, n: int) -> None:
        self.done += n
        elapsed = max(time.monotonic() - self.start, 1e-9)
        print(f"\r{self.scan_id}: {self.done / 1e9:.2f} / {self.total / 1e9:.2f} GB, {self.done / elapsed / 1e6:.0f} MB/s ", end="", file=sys.stderr, flush=True)


def pull(device_id: int, recording: Dict[str, Any]) -> bool:
    """Stores one recording as <folder>/<scan_id>.tar and tells the phone it is stored; whether it is."""
    scan_id, members = recording["scan_id"], recording["members"]
    assert re.fullmatch(KEY, scan_id), scan_id
    folder = downloads_folder() if recording["path"] is None else Path(recording["path"])
    if not folder.is_absolute() or not folder.is_dir():
        print(f"{scan_id}: not taken: its folder {folder} is not an existing folder on this computer; create it, or change the Wired transfer folder on the phone for later recordings", file=sys.stderr)
        return False
    archive = folder / f"{scan_id}.tar"
    if archive.exists():
        if not stored_matches(archive, scan_id, members):
            print(f"{scan_id}: not taken: {archive} exists and holds another recording", file=sys.stderr)
            return False
        print(f"{scan_id}: already stored as {archive}", file=sys.stderr)
    else:
        staging = folder / f".{scan_id}.staging"
        staging.mkdir(exist_ok=True)
        files = [f for m in members for f in (m["segments"] if m["name"] in FRAMES_FILES else [m])]
        progress = Progress(scan_id, sum(f["size"] for f in files))
        try:
            for file in files:
                fetch(device_id, scan_id, file, staging, progress)
        except (RuntimeError, OSError, http.client.HTTPException) as error:
            print(f"\n{scan_id}: not taken: {error}; run pull.py again to resume", file=sys.stderr)
            return False
        print(file=sys.stderr)
        (staging / MANIFEST).write_text(json.dumps({"scan_id": scan_id, "members": members}))
        staged = staged_recording(staging)
        assert staged == (scan_id, [(m["name"], [f["name"] for f in (m["segments"] if m["name"] in FRAMES_FILES else [m])]) for m in members]), staged
        print(f"{scan_id}: stored as {store(folder, staging, *staged)}", file=sys.stderr)
    phone_json(device_id, "POST", f"/stored/{scan_id}")
    print(f"{scan_id}: deleted from the phone", file=sys.stderr)
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description="Takes the Wired transfer recordings from the iPhone plugged into this computer.")
    parser.add_argument("--udid", help="the iPhone's UDID, when more than one is plugged in")
    args = parser.parse_args()
    device_id = phone_device_id(args.udid)
    recordings = phone_json(device_id, "GET", "/recordings")["recordings"]
    print(f"{len(recordings)} Wired transfer recordings on the phone", file=sys.stderr)
    taken = [pull(device_id, r) for r in recordings]
    sys.exit(0 if all(taken) else 1)


if __name__ == "__main__":
    main()

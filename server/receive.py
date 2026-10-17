"""Receives recordings uploaded by the RGBD Scanner app and stores each as the single file <data root>/<scan_id>.tar.

The app (from 5.2) uploads a recording (format_version "5.2", as tools/rgbd_recording.py documents) one file at a time under an upload key, each a PUT with headers X-Upload-Token (must match server/token), X-Content-SHA256 (the file's SHA-256 as 64 lowercase hex characters) and X-Data-Root (from app 5.2, whose users each upload to a config of their own: the absolute path of an existing directory on this machine, without "." or ".." parts, to store the recording in; a request without one, or naming another, is refused with 400): PUT /upload/<key>/<file> for each of the recording's files (scan_metadata.json, color_frames_metadata.json, depth_frames_metadata.json, color_intrinsics.json, depth_intrinsics.json, extrinsics.json) and each segment <frames file>.<index, 6 digits> of the three frames files (color_frames.bin, depth_frames.bin, depth_frames_confidence.bin for the rear), which the app uploads while recording, then PUT /upload/<key>/manifest.json, {"scan_id", "members": [...]}, each member {"name", "size", "sha256"} or, for a frames file, {"name", "segments": [{"name", "size", "sha256"}, ...]}; any other file name is refused with 404. The key is the phone's own for the recording, fixed when recording starts, before the scan_id, which takes the name given at Stop, is known. Each request streams its body into its own temporary file in <data root>/.staging/<key>/ while hashing it and, when the hash matches, renames it to the file's name beside <name>.sha256, the hash it was checked against, and only then replies 200, which the app takes as the file's safe arrival, deleting a segment's frames from the phone; concurrent uploads of one file cannot interfere and a stored file is always complete; a body whose hash does not match is refused with 400. After each stored file, once the manifest and every file it lists are stored with its size and SHA-256, the listed members are written as <data root>/<scan_id>.tar, an uncompressed GNU tar (a member can exceed 8 GiB) holding exactly them under <scan_id>/ in the manifest's order, a frames file its segments' bytes joined in order, through a temporary file in the data root renamed into place, so the archive appears whole, and <data root>/.staging/<key>, with the manifest and the hashes, is removed. A recording whose <data root>/<scan_id>.tar already exists is not stored over it: that is logged and its staging directory kept. GET /stored/<scan_id>, with the same X-Upload-Token and X-Data-Root, answers {"stored": true} once <data root>/<scan_id>.tar exists, and {"stored": false} before: the app deletes a recording from the phone only once it is stored. GET /recordings, with the same headers, answers {"recordings": [...]}, each <scan_id>.tar in the data root, newest first, with its scan_id, size in bytes and, from its scan_metadata.json, name, start_time_utc, duration_s, camera and author (null when it has none): the app lists a config's recordings from it. GET /ping answers {"ok": true}.
"""

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Type

KEY = r"[A-Za-z0-9_][A-Za-z0-9_.-]*"
PATH = re.compile(rf"^/upload/({KEY})/([a-z_]+\.[a-z]+(?:\.[0-9]{{6}})?)$")
STORED = re.compile(rf"^/stored/({KEY})$")
JSON_FILES = {"scan_metadata.json", "color_frames_metadata.json", "depth_frames_metadata.json", "color_intrinsics.json", "depth_intrinsics.json", "extrinsics.json"}
FRAMES_FILES = {"color_frames.bin", "depth_frames.bin", "depth_frames_confidence.bin"}
# A frames file's segment, as the app uploads it while recording: the frames file's name and the segment's index.
SEGMENT = re.compile(r"(color_frames\.bin|depth_frames\.bin|depth_frames_confidence\.bin)\.[0-9]{6}")
MANIFEST = "manifest.json"
CHUNK = 8 << 20


def data_root(header: Optional[str]) -> Optional[Path]:
    """The directory a request's X-Data-Root names, when it is the absolute path of an existing directory without "." or ".." parts; None otherwise."""
    if header is None or not header.startswith("/") or any(part in (".", "..") for part in header.split("/")):
        return None
    root = Path(header)
    return root if root.is_dir() else None


def stored_recordings(root: Path) -> List[Dict[str, Any]]:
    """Each <scan_id>.tar in the data root, newest first, with its scan_id, size and, read from its scan_metadata.json, name, start_time_utc, duration_s, camera and author, each None for a tar without one."""
    recordings = []
    for path in root.glob("*.tar"):
        # The temporary file an archive is written through starts with a dot.
        if path.name.startswith("."):
            continue
        entry: Dict[str, Any] = {"scan_id": path.stem, "size": path.stat().st_size, "name": None, "start_time_utc": None, "duration_s": None, "camera": None, "author": None}
        try:
            with tarfile.open(path, "r:") as tar:
                meta = json.load(tar.extractfile(tar.getmember(f"{path.stem}/scan_metadata.json")))
            entry |= {key: meta.get(key) for key in ("name", "start_time_utc", "duration_s", "camera", "author")}
        except (KeyError, OSError, tarfile.TarError, ValueError):
            pass
        recordings.append(entry)
    return sorted(recordings, key=lambda e: (e["start_time_utc"] or "", e["scan_id"]), reverse=True)


def staged_recording(staging: Path) -> Optional[Tuple[str, List[Tuple[str, List[str]]]]]:
    """The scan_id the manifest in a staging directory names and each tar member it lists with the staged files that make it, in order, once the manifest and every file it lists are stored there with their sizes and SHA-256s; None while a file is missing."""
    if not (staging / MANIFEST).is_file():
        return None
    manifest = json.loads((staging / MANIFEST).read_text())
    scan_id = manifest["scan_id"]
    assert re.fullmatch(KEY, scan_id), scan_id
    members = []
    for m in manifest["members"]:
        # A JSON file is a member of its own, a frames file its segments joined.
        files = m["segments"] if m["name"] in FRAMES_FILES else [m]
        assert (m["name"] in JSON_FILES and files[0]["name"] == m["name"]) or (m["name"] in FRAMES_FILES and all(SEGMENT.fullmatch(f["name"]) is not None and f["name"].rsplit(".", 1)[0] == m["name"] for f in files)), m
        for f in files:
            path = staging / f["name"]
            if not path.is_file() or path.stat().st_size != f["size"] or (staging / f"{f['name']}.sha256").read_text() != f["sha256"]:
                return None
        members.append((m["name"], [f["name"] for f in files]))
    return scan_id, members


class Joined(io.RawIOBase):
    """Files read one after another as one stream."""

    def __init__(self, paths: List[Path]) -> None:
        self._paths = list(paths)
        self._file: Optional[io.BufferedReader] = None

    def readable(self) -> bool:
        return True

    def readinto(self, buffer: Any) -> int:
        while True:
            if self._file is None:
                if not self._paths:
                    return 0
                self._file = open(self._paths.pop(0), "rb")
            n = self._file.readinto(buffer)
            if n:
                return n
            self._file.close()
            self._file = None

    def close(self) -> None:
        if self._file is not None:
            self._file.close()
        super().close()


def store(root: Path, staging: Path, scan_id: str, members: List[Tuple[str, List[str]]]) -> Path:
    """Writes a recording's staged members as <data root>/<scan_id>.tar, an uncompressed GNU tar holding them under <scan_id>/ in that order, each the bytes of its staged files joined in order, through a temporary file in the data root renamed into place, then removes its staging directory; returns the archive's path."""
    archive = root / f"{scan_id}.tar"
    fd, part_name = tempfile.mkstemp(dir=root, prefix=f".{archive.name}.", suffix=".part")
    part = Path(part_name)
    try:
        with os.fdopen(fd, "wb") as f, tarfile.open(fileobj=f, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for name, files in members:
                paths = [staging / file for file in files]
                info = tar.gettarinfo(paths[0], arcname=f"{scan_id}/{name}")
                info.size = sum(p.stat().st_size for p in paths)
                # A buffered reader fills each block the tar copies, across the files' boundaries.
                with io.BufferedReader(Joined(paths), CHUNK) as data:
                    tar.addfile(info, data)
        part.chmod(0o664)
        os.replace(part, archive)
    finally:
        part.unlink(missing_ok=True)
    shutil.rmtree(staging)
    return archive


def make_handler(token: str) -> Type[BaseHTTPRequestHandler]:
    # One recording is stored at a time, so two files completing it together cannot both write its archive.
    storing = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def reply(self, code: int, body: Dict[str, Any]) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def reject(self, code: int, body: Dict[str, Any], length: int) -> None:
            """Replies with an error after reading and discarding the request body, so a client still sending it receives the reply instead of a connection reset."""
            while length > 0:
                chunk = self.rfile.read(min(length, CHUNK))
                if not chunk:
                    break
                length -= len(chunk)
            self.reply(code, body)

        def do_GET(self) -> None:
            if self.path == "/ping":
                return self.reply(200, {"ok": True})
            match = STORED.match(self.path)
            if match is None and self.path != "/recordings":
                return self.reply(404, {"error": "not found"})
            if self.headers.get("X-Upload-Token") != token:
                return self.reply(403, {"error": "bad token"})
            root = data_root(self.headers.get("X-Data-Root"))
            if root is None:
                return self.reply(400, {"error": "bad data root", "data_root": self.headers.get("X-Data-Root")})
            if match is None:
                return self.reply(200, {"recordings": stored_recordings(root)})
            self.reply(200, {"stored": (root / f"{match.group(1)}.tar").is_file()})

        def do_PUT(self) -> None:
            length = int(self.headers.get("Content-Length", "-1"))
            if length < 0:
                # A body of unknown length cannot be read past, so the connection closes after the reply.
                self.close_connection = True
                return self.reply(411, {"error": "length required"})
            match = PATH.match(self.path)
            if match is None or (match.group(2) not in JSON_FILES | {MANIFEST} and SEGMENT.fullmatch(match.group(2)) is None):
                return self.reject(404, {"error": "bad path"}, length)
            if self.headers.get("X-Upload-Token") != token:
                return self.reject(403, {"error": "bad token"}, length)
            root = data_root(self.headers.get("X-Data-Root"))
            if root is None:
                return self.reject(400, {"error": "bad data root", "data_root": self.headers.get("X-Data-Root")}, length)
            key, name = match.group(1), match.group(2)
            expected = self.headers.get("X-Content-SHA256", "")

            staging = root / ".staging" / key
            staging.mkdir(parents=True, exist_ok=True)
            stored = staging / name
            fd, part_name = tempfile.mkstemp(dir=staging, prefix=f".{name}.", suffix=".part")
            part = Path(part_name)
            try:
                digest = hashlib.sha256()
                remaining = length
                with os.fdopen(fd, "wb") as f:
                    while remaining > 0:
                        chunk = self.rfile.read(min(remaining, CHUNK))
                        if not chunk:
                            break
                        f.write(chunk)
                        digest.update(chunk)
                        remaining -= len(chunk)
                if remaining != 0:
                    return self.reply(400, {"error": f"connection closed with {remaining} bytes missing"})
                if digest.hexdigest() != expected:
                    return self.reply(400, {"error": "sha256 mismatch", "got": digest.hexdigest(), "expected": expected})
                (staging / f"{name}.sha256").write_text(expected)
                part.chmod(0o664)
                os.replace(part, stored)
            finally:
                part.unlink(missing_ok=True)
            self.log_message("stored %s (%d bytes)", stored, length)
            self.reply(200, {"stored": str(stored), "size": length, "sha256": expected})
            # After the reply, so the phone is not kept waiting while a long recording's files are copied into its archive.
            with storing:
                recording = staged_recording(staging)
                if recording is None:
                    return
                scan_id, members = recording
                archive = root / f"{scan_id}.tar"
                if archive.exists():
                    self.log_message("not stored: %s exists, %s kept", archive, staging)
                else:
                    self.log_message("stored recording %s", store(root, staging, scan_id, members))

    return Handler


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    token = (here / "token").read_text().strip()
    assert token, "server/token is empty"
    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(token))
    print(f"receiving on port {args.port}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

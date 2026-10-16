"""Receives recordings uploaded by the RGBD Scanner app and stores each as the single file <out>/<scan_id>.tar.

The app uploads a recording (format_version "4.8" to "5.1", as tools/rgbd_recording.py documents) one file at a time under an upload key, each a PUT with headers X-Upload-Token (must match server/token) and X-Content-SHA256 (the file's SHA-256 as 64 lowercase hex characters): PUT /upload/<key>/<file> for each of the recording's files (scan_metadata.json, color_frames.bin, color_frames_metadata.json, depth_frames.bin, depth_frames_metadata.json, depth_frames_confidence.bin for the rear, color_intrinsics.json, depth_intrinsics.json, extrinsics.json) or, from app 5.0.3, which uploads its frames while recording, for each segment <frames file>.<index, 6 digits> of the three frames files, then PUT /upload/<key>/manifest.json, {"scan_id" (from 5.0.3), "members": [...]}, each member {"name", "size", "sha256"} or, for a frames file sent in segments, {"name", "segments": [{"name", "size", "sha256"}, ...]}; any other file name is refused with 404. Before 5.0.3 the key is the scan_id; from 5.0.3 it is the phone's own key for the recording, fixed when recording starts, before the scan_id, which takes the name given at Stop, is known. Each request streams its body into its own temporary file in <out>/.staging/<key>/ while hashing it and, when the hash matches, renames it to the file's name beside <name>.sha256, the hash it was checked against, and only then replies 200, which the app takes as the file's safe arrival, deleting a segment's frames from the phone; concurrent uploads of one file cannot interfere and a stored file is always complete; a body whose hash does not match is refused with 400. After each stored file, once the manifest and every file it lists are stored with its size and SHA-256, the listed members are written as <out>/<scan_id>.tar, an uncompressed GNU tar (a member can exceed 8 GiB) holding exactly them under <scan_id>/ in the manifest's order, a member sent in segments their bytes joined in order, through a temporary file in <out> renamed into place, so the archive appears whole, and <out>/.staging/<key>, with the manifest and the hashes, is removed. A recording whose <out>/<scan_id>.tar already exists is not stored over it: that is logged and its staging directory kept. GET /stored/<scan_id>, with the same X-Upload-Token, answers {"stored": true} once <out>/<scan_id>.tar exists, and {"stored": false} before: from 5.0.3 the app deletes a recording from the phone only once it is stored. GET /recordings, with the same header, answers {"recordings": [...]}, each <scan_id>.tar in <out>, newest first, with its scan_id, size in bytes and, from its scan_metadata.json, name, start_time_utc, duration_s and camera (null when it has none): the app lists the recordings it uploaded from it. GET /ping answers {"ok": true}.
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
FILES = {"scan_metadata.json", "color_frames.bin", "color_frames_metadata.json", "depth_frames.bin", "depth_frames_metadata.json", "depth_frames_confidence.bin", "color_intrinsics.json", "depth_intrinsics.json", "extrinsics.json"}
# A frames file's segment, as app 5.0.3 uploads it while recording: the frames file's name and the segment's index.
SEGMENT = re.compile(r"(color_frames\.bin|depth_frames\.bin|depth_frames_confidence\.bin)\.[0-9]{6}")
MANIFEST = "manifest.json"
CHUNK = 8 << 20


def stored_recordings(root: Path) -> List[Dict[str, Any]]:
    """Each <scan_id>.tar in the folder, newest first, with its scan_id, size and, read from its scan_metadata.json, name, start_time_utc, duration_s and camera, each None for a tar without one."""
    recordings = []
    for path in root.glob("*.tar"):
        # The temporary file an archive is written through starts with a dot.
        if path.name.startswith("."):
            continue
        entry: Dict[str, Any] = {"scan_id": path.stem, "size": path.stat().st_size, "name": None, "start_time_utc": None, "duration_s": None, "camera": None}
        try:
            with tarfile.open(path, "r:") as tar:
                meta = json.load(tar.extractfile(tar.getmember(f"{path.stem}/scan_metadata.json")))
            entry |= {key: meta.get(key) for key in ("name", "start_time_utc", "duration_s", "camera")}
        except (KeyError, OSError, tarfile.TarError, ValueError):
            pass
        recordings.append(entry)
    return sorted(recordings, key=lambda e: (e["start_time_utc"] or "", e["scan_id"]), reverse=True)


def staged_recording(staging: Path) -> Optional[Tuple[str, List[Tuple[str, List[str]]]]]:
    """The scan_id the manifest in a staging directory names (the directory's own name when it names none) and each tar member it lists with the staged files that make it, in order, once the manifest and every file it lists are stored there with their sizes and SHA-256s; None while a file is missing."""
    if not (staging / MANIFEST).is_file():
        return None
    manifest = json.loads((staging / MANIFEST).read_text())
    scan_id = manifest.get("scan_id", staging.name)
    assert re.fullmatch(KEY, scan_id), scan_id
    members = []
    for m in manifest["members"]:
        files = m["segments"] if "segments" in m else [m]
        assert m["name"] in FILES and all(f["name"] == m["name"] if "segments" not in m else (SEGMENT.fullmatch(f["name"]) is not None and f["name"].rsplit(".", 1)[0] == m["name"]) for f in files), m
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


def store(out_dir: Path, staging: Path, scan_id: str, members: List[Tuple[str, List[str]]]) -> Path:
    """Writes a recording's staged members as <out>/<scan_id>.tar, an uncompressed GNU tar holding them under <scan_id>/ in that order, each the bytes of its staged files joined in order, through a temporary file in <out> renamed into place, then removes its staging directory; returns the archive's path."""
    archive = out_dir / f"{scan_id}.tar"
    fd, part_name = tempfile.mkstemp(dir=out_dir, prefix=f".{archive.name}.", suffix=".part")
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


def make_handler(out_dir: Path, token: str) -> Type[BaseHTTPRequestHandler]:
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
            if match is None:
                return self.reply(200, {"recordings": stored_recordings(out_dir)})
            self.reply(200, {"stored": (out_dir / f"{match.group(1)}.tar").is_file()})

        def do_PUT(self) -> None:
            length = int(self.headers.get("Content-Length", "-1"))
            if length < 0:
                # A body of unknown length cannot be read past, so the connection closes after the reply.
                self.close_connection = True
                return self.reply(411, {"error": "length required"})
            match = PATH.match(self.path)
            if match is None or (match.group(2) not in FILES | {MANIFEST} and SEGMENT.fullmatch(match.group(2)) is None):
                return self.reject(404, {"error": "bad path"}, length)
            if self.headers.get("X-Upload-Token") != token:
                return self.reject(403, {"error": "bad token"}, length)
            key, name = match.group(1), match.group(2)
            expected = self.headers.get("X-Content-SHA256", "")

            staging = out_dir / ".staging" / key
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
                archive = out_dir / f"{scan_id}.tar"
                if archive.exists():
                    self.log_message("not stored: %s exists, %s kept", archive, staging)
                else:
                    self.log_message("stored recording %s", store(out_dir, staging, scan_id, members))

    return Handler


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    # One folder per app version, e.g. tasks/20260930_ios_3d_scanner_mvp/outputs/v3 for scans made with v3.
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    token = (here / "token").read_text().strip()
    assert token, "server/token is empty"
    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(args.out, token))
    print(f"receiving into {args.out} on port {args.port}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

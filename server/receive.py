"""Receives recordings uploaded by the RGBD Scanner app and stores each as <out>/<id>.tar.

The app uploads a recording one file at a time, each a PUT with headers X-Upload-Token (must match server/token) and X-Content-SHA256 (the file's SHA-256 as 64 lowercase hex characters): PUT /upload/<id>/<member> for each archive member (metadata.json, color.bin, color.csv, depth.bin, depth.csv, and confidence.bin or calibration.jsonl), then PUT /upload/<id>/manifest.json, {"members": [{"name", "size", "sha256"}, ...]}, the members in the archive's order. Each request streams its body into its own temporary file in <out>/.staging/<id>/ while hashing it and, when the hash matches, renames it to the file's name beside <name>.sha256, the hash it was checked against, so concurrent uploads of one file cannot interfere and a stored file is always complete. After each stored file, once the manifest and every member it lists are stored with its size and SHA-256, the members are written as <out>/<id>.tar, an uncompressed GNU tar (members can exceed 8 GiB) with the members under <id>/ in the manifest's order, through a temporary file renamed into place, and <out>/.staging/<id> is removed. GET /ping answers {"ok": true}.
"""

import argparse
import hashlib
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
from typing import Any, Dict, Optional, Type

PATH = re.compile(r"^/upload/([A-Za-z0-9_][A-Za-z0-9_.-]*)/([a-z]+\.[a-z]+)$")
MEMBERS = {"metadata.json", "color.bin", "color.csv", "depth.bin", "depth.csv", "confidence.bin", "calibration.jsonl"}
MANIFEST = "manifest.json"
CHUNK = 8 << 20


def assemble(out_dir: Path, rec_id: str) -> Optional[Path]:
    """Writes <out>/<id>.tar once the manifest and every member it lists are staged with their sizes and SHA-256s, then removes the staging directory; returns the archive's path, or None while a file is missing."""
    staging = out_dir / ".staging" / rec_id
    if not (staging / MANIFEST).is_file():
        return None
    members = json.loads((staging / MANIFEST).read_text())["members"]
    assert all(m["name"] in MEMBERS for m in members), members
    for m in members:
        path = staging / m["name"]
        if not path.is_file() or path.stat().st_size != m["size"] or (staging / f"{m['name']}.sha256").read_text() != m["sha256"]:
            return None
    archive = out_dir / f"{rec_id}.tar"
    fd, part_name = tempfile.mkstemp(dir=out_dir, prefix=f".{archive.name}.", suffix=".part")
    part = Path(part_name)
    try:
        with os.fdopen(fd, "wb") as f, tarfile.open(fileobj=f, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for m in members:
                tar.add(staging / m["name"], arcname=f"{rec_id}/{m['name']}", recursive=False)
        part.chmod(0o664)
        os.replace(part, archive)
    finally:
        part.unlink(missing_ok=True)
    shutil.rmtree(staging)
    return archive


def make_handler(out_dir: Path, token: str) -> Type[BaseHTTPRequestHandler]:
    # One recording is assembled at a time, so two files completing it together cannot both write its archive.
    assembling = threading.Lock()

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
                self.reply(200, {"ok": True})
            else:
                self.reply(404, {"error": "not found"})

        def do_PUT(self) -> None:
            length = int(self.headers.get("Content-Length", "-1"))
            if length < 0:
                # A body of unknown length cannot be read past, so the connection closes after the reply.
                self.close_connection = True
                return self.reply(411, {"error": "length required"})
            match = PATH.match(self.path)
            if match is None or match.group(2) not in MEMBERS | {MANIFEST}:
                return self.reject(404, {"error": "bad path"}, length)
            if self.headers.get("X-Upload-Token") != token:
                return self.reject(403, {"error": "bad token"}, length)
            rec_id, name = match.group(1), match.group(2)
            expected = self.headers.get("X-Content-SHA256", "")

            staging = out_dir / ".staging" / rec_id
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
            # After the reply, so the phone is not kept waiting while a long recording's members are copied into its archive.
            with assembling:
                archive = assemble(out_dir, rec_id)
            if archive is not None:
                self.log_message("assembled %s", archive)

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

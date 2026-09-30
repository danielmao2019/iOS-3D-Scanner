"""Receives recordings uploaded by the RGBD Scanner app and stores them in the --out folder.

PUT /upload/<name>.tar with headers X-Upload-Token (must match server/token) and X-Content-SHA256. Each request streams its body into its own temporary file in the output directory, checks the SHA-256, then renames it to <name>.tar, so concurrent uploads of the same recording cannot interfere and a stored file is always complete. GET /ping answers {"ok": true}.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Type

NAME = re.compile(r"^/upload/([A-Za-z0-9_.-]+\.tar)$")
CHUNK = 8 << 20


def make_handler(out_dir: Path, token: str) -> Type[BaseHTTPRequestHandler]:
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
            match = NAME.match(self.path)
            if match is None:
                return self.reject(404, {"error": "bad path"}, length)
            if self.headers.get("X-Upload-Token") != token:
                return self.reject(403, {"error": "bad token"}, length)
            expected = self.headers.get("X-Content-SHA256", "")

            out_dir.mkdir(parents=True, exist_ok=True)
            final = out_dir / match.group(1)
            fd, part_name = tempfile.mkstemp(dir=out_dir, prefix=f".{final.name}.", suffix=".part")
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
                    return self.reply(400, {"error": "sha256 mismatch", "got": digest.hexdigest()})
                part.chmod(0o664)
                os.replace(part, final)
            finally:
                part.unlink(missing_ok=True)
            self.log_message("stored %s (%d bytes)", final, length)
            self.reply(200, {"stored": str(final), "size": length, "sha256": expected})

    return Handler


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=here.parent / "tasks" / "20260930_ios_3d_scanner_mvp" / "outputs" / "recordings")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    token = (here / "token").read_text().strip()
    assert token, "server/token is empty"
    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(args.out, token))
    print(f"receiving into {args.out} on port {args.port}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

"""Tests pull.py against a fake usbmux service and a fake phone serving one Wired transfer recording as the app does: the tar it stores, the phone told only once it is stored, a corrupt file refused and resumed, an existing tar confirmed without fetching, the Downloads folder by default, and a missing folder refused."""

import hashlib
import json
import plistlib
import socket
import struct
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

import pytest

from pull import PHONE_PORT, downloads_folder, phone_device_id, phone_json, pull

SCAN_ID = "rgbd_20261120_120000_front_test"
DEVICE_ID = 7
HEADER = struct.Struct("<IIII")


class FakePhone:
    """The app's cable server over one recording: its JSON files and two segments of each frames file, the requests it answered, and the recordings it was told are stored."""

    def __init__(self, path: Optional[str]) -> None:
        self.files = {"scan_metadata.json": b'{"format_version": "1.6.0"}', "color_frames.bin.000000": b"c" * 1000, "color_frames.bin.000001": b"C" * 10, "depth_frames.bin.000000": b"d" * 500, "color_frames_metadata.json": b"{}", "depth_frames_metadata.json": b"{}"}
        self.order = [("scan_metadata.json", None), ("color_frames.bin", ["color_frames.bin.000000", "color_frames.bin.000001"]), ("color_frames_metadata.json", None), ("depth_frames.bin", ["depth_frames.bin.000000"]), ("depth_frames_metadata.json", None)]
        self.path = path
        # The bytes served for a file, when they differ from those listed.
        self.served: Dict[str, bytes] = {}
        self.requests: List[str] = []
        self.stored: List[str] = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self.handler())
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def entry(self, name: str) -> Dict[str, Any]:
        return {"name": name, "size": len(self.files[name]), "sha256": hashlib.sha256(self.files[name]).hexdigest()}

    def listing(self) -> Dict[str, Any]:
        members = [self.entry(name) if segments is None else {"name": name, "segments": [self.entry(s) for s in segments]} for name, segments in self.order]
        return {"recordings": [] if SCAN_ID in self.stored else [{"scan_id": SCAN_ID, "path": self.path, "members": members}]}

    def handler(self) -> type:
        phone = self

        class Handler(BaseHTTPRequestHandler):
            def send(self, status: int, body: bytes, kind: str) -> None:
                self.send_response(status)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                phone.requests.append(f"GET {self.path}")
                if self.path == "/recordings":
                    return self.send(200, json.dumps(phone.listing()).encode(), "application/json")
                name = self.path.rsplit("/", 1)[1]
                self.send(200, phone.served.get(name, phone.files[name]), "application/octet-stream")

            def do_POST(self) -> None:
                phone.requests.append(f"POST {self.path}")
                phone.stored.append(self.path.rsplit("/", 1)[1])
                self.send(200, b'{"deleted": true}', "application/json")

            def log_message(self, *args: Any) -> None:
                pass

        return Handler


class FakeUsbmux:
    """A usbmux service listing one iPhone by USB and relaying a Connect to its port to the fake phone."""

    def __init__(self, phone: FakePhone) -> None:
        self.phone = phone
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.address = f"127.0.0.1:{self.listener.getsockname()[1]}"
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self) -> None:
        while True:
            client, _ = self.listener.accept()
            threading.Thread(target=self.serve, args=(client,), daemon=True).start()

    def serve(self, client: socket.socket) -> None:
        length = HEADER.unpack(client.recv(HEADER.size, socket.MSG_WAITALL))[0]
        message = plistlib.loads(client.recv(length - HEADER.size, socket.MSG_WAITALL))
        if message["MessageType"] == "ListDevices":
            self.reply(client, {"DeviceList": [{"DeviceID": DEVICE_ID, "MessageType": "Attached", "Properties": {"ConnectionType": "USB", "SerialNumber": "phone-udid"}}]})
            return client.close()
        assert message["MessageType"] == "Connect" and message["DeviceID"] == DEVICE_ID and message["PortNumber"] == socket.htons(PHONE_PORT), message
        self.reply(client, {"MessageType": "Result", "Number": 0})
        phone = socket.create_connection(self.phone.server.server_address)
        threading.Thread(target=self.relay, args=(client, phone), daemon=True).start()
        self.relay(phone, client)

    @staticmethod
    def reply(client: socket.socket, message: Dict[str, Any]) -> None:
        body = plistlib.dumps(message)
        client.sendall(HEADER.pack(HEADER.size + len(body), 1, 8, 1) + body)

    @staticmethod
    def relay(source: socket.socket, sink: socket.socket) -> None:
        while data := source.recv(1 << 16):
            sink.sendall(data)
        try:
            sink.shutdown(socket.SHUT_WR)
        except OSError:
            pass


@pytest.fixture
def phone(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[FakePhone]:
    phone = FakePhone(str(tmp_path / "scans"))
    (tmp_path / "scans").mkdir()
    monkeypatch.setenv("USBMUXD_SOCKET_ADDRESS", FakeUsbmux(phone).address)
    yield phone
    phone.server.shutdown()


def take(phone: FakePhone) -> bool:
    """One pull.py pass over the recordings the phone lists: whether every one was stored."""
    device_id = phone_device_id(None)
    return all(pull(device_id, r) for r in phone_json(device_id, "GET", "/recordings")["recordings"])


def test_pull_stores_the_receivers_tar_then_tells_the_phone(phone: FakePhone) -> None:
    assert take(phone)

    folder = Path(phone.path)
    with tarfile.open(folder / f"{SCAN_ID}.tar") as tar:
        held = [(m.name, tar.extractfile(m).read()) for m in tar.getmembers()]
    assert held == [(f"{SCAN_ID}/{name}", b"".join(phone.files[s] for s in segments) if segments else phone.files[name]) for name, segments in phone.order]
    assert phone.stored == [SCAN_ID] and phone.requests[-1] == f"POST /stored/{SCAN_ID}"
    assert sorted(p.name for p in folder.iterdir()) == [f"{SCAN_ID}.tar"]


def test_a_corrupt_file_is_refused_and_the_pull_resumes(phone: FakePhone) -> None:
    phone.served["color_frames.bin.000001"] = b"X" * 10

    assert not take(phone)
    assert phone.stored == [] and not (Path(phone.path) / f"{SCAN_ID}.tar").exists()

    del phone.served["color_frames.bin.000001"]
    phone.requests.clear()
    assert take(phone)
    # Only the refused file and those after it are fetched again.
    assert [r for r in phone.requests if r.startswith("GET /recordings/")] == [f"GET /recordings/{SCAN_ID}/{name}" for name in ["color_frames.bin.000001", "color_frames_metadata.json", "depth_frames.bin.000000", "depth_frames_metadata.json"]]
    assert phone.stored == [SCAN_ID]


def test_an_existing_tar_of_the_recording_is_only_confirmed(phone: FakePhone) -> None:
    assert take(phone)
    # The phone did not hear the confirmation and lists the recording again.
    phone.stored.clear()
    phone.requests.clear()

    assert take(phone)
    assert phone.requests == ["GET /recordings", f"POST /stored/{SCAN_ID}"]


def test_the_default_folder_is_the_downloads_folder(phone: FakePhone, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    downloads = tmp_path / "Herunterladen"
    downloads.mkdir()
    (tmp_path / "config").mkdir()
    (tmp_path / "config" / "user-dirs.dirs").write_text(f'XDG_DESKTOP_DIR="$HOME/Desktop"\nXDG_DOWNLOAD_DIR="{downloads}"\n')
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    phone.path = None

    assert downloads_folder() == downloads
    assert take(phone)
    assert (downloads / f"{SCAN_ID}.tar").is_file()


def test_a_missing_folder_keeps_the_recording_on_the_phone(phone: FakePhone, tmp_path: Path) -> None:
    phone.path = str(tmp_path / "missing")

    assert not take(phone)
    assert phone.stored == [] and phone.requests == ["GET /recordings"]

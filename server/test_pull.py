"""Tests server/pull.ps1, run in PowerShell 7 as a user runs it, its text piped into Invoke-Expression, against a fake iPhone: a usbmux server on a unix socket whose one USB device runs a fake RGBD Scanner app answering the requests of app/Sources/RGBDScanner/WiredServer.swift for a small rear recording laid out as app v1.6.0 lays it out, its frames files in segments of 16 KiB: a finished recording taken whole, each file fetched once and each segment acknowledged, its tar, but for when and by whom its files were written, byte for byte the one server/receive.py stores for it; a recording taken while it records, each segment fetched and acknowledged once the recording closes it, the rest once it is finished; the script killed while its tar flushes the first file, a segment inside a member, a member's first segment and the archive's end, then run again, each file fetched once over all runs and the tar right; a tar cut short with garbage past the point it resumes at, inside a member, at a member's start and at the archive's end, cut back and finished without fetching anything; a tar shorter than the files already moved into it, and a staged file missing after the point it resumes at, each printed as one wait while the script polls on; the app off screen when the phone is to be told the recording is stored, printed as one wait for the recording and one for the phone, then told once it is back, the tar not written again; a recording whose tar is already stored only told so; the staging folder holding at most the recording plus one segment while the tar is written; requests reaching the phone at least every 10 s, the time after which it locks its screen, while a slow disk makes the tar take longer; the call keeping Windows awake compiling and made only on Windows; and the script parsing without PowerShell 7's syntax, as Windows PowerShell must run it. PowerShell 7 must be on PATH as pwsh, and strace, which makes a disk slow by holding each fsync, for the tests that write a slow tar.

Usage, from the repository's root: python -m pytest server/test_pull.py
"""

import contextlib
import dataclasses
import hashlib
import io
import itertools
import json
import os
import plistlib
import random
import re
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import tarfile
import tempfile
import threading
import time
from collections import Counter
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, NamedTuple, Optional, Set, Tuple, Union

import pytest

from server.receive import store

PULL = Path(__file__).resolve().parent / "pull.ps1"
PWSH = shutil.which("pwsh")
assert PWSH is not None, "server/pull.ps1 runs in PowerShell 7, which must be on PATH as pwsh"
# The app's port on the phone, which usbmux's Connect takes in network byte order.
PHONE_PORT = 8765
PORT_NUMBER = int.from_bytes(PHONE_PORT.to_bytes(2, "big"), "little")
DEVICE_ID = 7
# usbmux's message type for a plist, and Connect's result when nothing listens on the port.
USBMUX_PLIST = 8
USBMUX_REFUSED = 3
REASONS = {200: "OK", 404: "Not Found", 409: "Conflict"}
# The phone's key for the recording, fixed before its id is, and its id.
KEY = "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E"
SCAN_ID = "rgbd_20261120_120000_rear"
SEGMENT = 16 << 10
# The rear recording's members in recording.json's order, as app v1.6.0 writes them, with their sizes in bytes, each frames file several segments, its last short.
LAYOUT = [
    ("scan_metadata.json", 700),
    ("color_frames.bin", 6 * SEGMENT + 5000),
    ("color_frames_metadata.json", 1900),
    ("depth_frames.bin", 3 * SEGMENT + 300),
    ("depth_frames_metadata.json", 1500),
    ("depth_frames_confidence.bin", SEGMENT + 77),
    ("color_intrinsics.json", 450),
    ("depth_intrinsics.json", 460),
    ("extrinsics.json", 1800),
]
STAGING = f".{KEY}.staging"
PART = f"{SCAN_ID}.tar.part"
ARCHIVE = f"{SCAN_ID}.tar"
NOT_ANSWERING = "Waiting: RGBD Scanner does not answer: open it on the phone, from version 1.6.0, and keep it on screen"


def recording() -> List[Tuple[str, List[Tuple[str, bytes]]]]:
    """Each member of the recording in recording.json's order with the files the phone holds it as, a JSON file itself and a frames file its segments <name>.<index, 6 digits> of SEGMENT bytes, the last shorter; each member is random bytes, which pull.ps1 copies without reading them."""
    members = []
    for member, size in LAYOUT:
        data = random.Random(member).randbytes(size)
        if member.endswith(".bin"):
            members.append((member, [(f"{member}.{start // SEGMENT:06d}", data[start:start + SEGMENT]) for start in range(0, size, SEGMENT)]))
        else:
            members.append((member, [(member, data)]))
    return members


RECORDING = recording()
NAMES = [name for _, files in RECORDING for name, _ in files]
DATA = {name: data for _, files in RECORDING for name, data in files}
SHA256 = {name: hashlib.sha256(data).hexdigest() for name, data in DATA.items()}
SEGMENTS = [name for member, files in RECORDING if member.endswith(".bin") for name, _ in files]
# The segments the recording closes while it records: each frames file's but its last, which closes when it is finished.
LIVE = [name for member, files in RECORDING if member.endswith(".bin") for name, _ in files[:-1]]


def described(name: str) -> Dict[str, Any]:
    """One of the recording's files as the app lists it."""
    return {"name": name, "size": len(DATA[name]), "sha256": SHA256[name]}


# The recording's members as the upload manifest lists them, each frames file's segments grouped under it.
MANIFEST = [{"name": member, "segments": [described(name) for name, _ in files]} if member.endswith(".bin") else described(member) for member, files in RECORDING]


class Request(NamedTuple):
    """A request the fake app answered: when it finished answering, its method and path, and its status."""

    time: float
    method: str
    path: str
    status: int


@dataclasses.dataclass
class Recording:
    """The Wired transfer recording on the fake phone, whose files are those of RECORDING: the folder on the computer it goes to, None for the Downloads folder; whether it is finished; the files the phone has deleted; and the segments it has closed while recording, in order."""

    path: Optional[Path]
    finished: bool
    deleted: Set[str]
    closed: List[str] = dataclasses.field(default_factory=list)

    def held(self) -> List[str]:
        """The files the phone holds of it: while it records, the segments it has closed, and once it is finished, all of them, but those it has deleted."""
        return [name for name in (NAMES if self.finished else self.closed) if name not in self.deleted]

    def listing(self) -> Dict[str, Any]:
        """Its entry in GET /recordings."""
        return {"key": KEY, "scan_id": SCAN_ID if self.finished else None, "path": None if self.path is None else str(self.path), "files": [described(name) for name in self.held()], "members": MANIFEST if self.finished else None}


class Phone:
    """The fake iPhone plugged in by USB: the unix socket of its usbmux, whether its app is on screen, the file the app is sending when the user leaves it, None for none, how many connections to the app were refused while it was off screen, its one Wired transfer recording, None once the computer has stored it, and each request the app answered, in order."""

    def __init__(self, usbmux: Path) -> None:
        self.usbmux = usbmux
        self.lock = threading.Lock()
        self.on_screen = True
        self.leaves_after: Optional[str] = None
        self.refused = 0
        self.recording: Optional[Recording] = None
        self.requests: List[Request] = []

    def answer(self, method: str, path: str, sha256: Optional[str]) -> Tuple[int, Union[Dict[str, Any], bytes]]:
        """The app's status and body for a request with the X-Content-SHA256 it sends, None for none, as WiredServer.swift answers it."""
        parts = path.split("/")[1:]
        with self.lock:
            recording = self.recording
            held = [] if recording is None else recording.held()
            if method == "GET" and parts == ["recordings"]:
                return 200, {"recordings": [] if recording is None else [recording.listing()]}
            if method == "GET" and len(parts) == 3 and parts[:2] == ["files", KEY] and parts[2] in held:
                if parts[2] == self.leaves_after:
                    self.on_screen = False
                return 200, DATA[parts[2]]
            if method == "POST" and len(parts) == 3 and parts[:2] == ["acknowledged", KEY] and parts[2] in held and parts[2] in SEGMENTS:
                if sha256 != SHA256[parts[2]]:
                    return 409, {"error": f"the segment's SHA-256 is {SHA256[parts[2]]}"}
                recording.deleted.add(parts[2])
                return 200, {"deleted": parts[2]}
            if method == "POST" and parts == ["stored", SCAN_ID] and recording is not None and recording.finished:
                self.recording = None
                return 200, {"deleted": SCAN_ID}
            return 404, {"error": "not found"}

    def close(self, names: List[str]) -> float:
        """Closes segments of the recording while it records, offering them to the computer; returns when."""
        with self.lock:
            self.recording.closed += names
            return time.monotonic()

    def finish(self) -> float:
        """Finishes the recording; returns when."""
        with self.lock:
            self.recording.finished = True
            return time.monotonic()


def receive_exactly(connection: socket.socket, count: int) -> bytes:
    data = b""
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        assert chunk, f"the connection closed {count - len(data)} bytes short"
        data += chunk
    return data


def receive_plist(connection: socket.socket) -> Tuple[int, Dict[str, Any]]:
    """A usbmux message's tag and plist: a 16-byte little-endian header (total length, version 1, type 8 for a plist, tag), then an XML plist."""
    length, version, kind, tag = struct.unpack("<IIII", receive_exactly(connection, 16))
    assert (version, kind) == (1, USBMUX_PLIST), (version, kind)
    return tag, plistlib.loads(receive_exactly(connection, length - 16))


def send_plist(connection: socket.socket, tag: int, message: Dict[str, Any]) -> None:
    body = plistlib.dumps(message)
    connection.sendall(struct.pack("<IIII", 16 + len(body), 1, USBMUX_PLIST, tag) + body)


def receive_request(connection: socket.socket) -> Tuple[str, str, Optional[str]]:
    """The method, path and X-Content-SHA256, None for none, of the HTTP request, without a body, the connection sends."""
    head = b""
    while not head.endswith(b"\r\n\r\n"):
        chunk = connection.recv(4096)
        assert chunk, head
        head += chunk
    lines = head.decode().split("\r\n")[:-2]
    method, path, version = lines[0].split(" ")
    assert version == "HTTP/1.1", lines[0]
    headers = dict(line.split(": ", 1) for line in lines[1:])
    return method, path, headers.get("X-Content-SHA256")


def send_reply(connection: socket.socket, status: int, body: Union[Dict[str, Any], bytes]) -> None:
    """Sends a file's bytes, or a JSON body as the app sends it, its keys sorted."""
    data, kind = (body, "application/octet-stream") if isinstance(body, bytes) else (json.dumps(body, sort_keys=True).encode(), "application/json")
    connection.sendall(f"HTTP/1.1 {status} {REASONS[status]}\r\nContent-Type: {kind}\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)


class Usbmux(socketserver.BaseRequestHandler):
    """One connection to the fake phone's usbmux, which pull.ps1 opens for each message: ListDevices, or Connect to the app's port followed, while the app is on screen, by one HTTP request to it."""

    server: "PhoneServer"

    def handle(self) -> None:
        phone = self.server.phone
        tag, message = receive_plist(self.request)
        if message["MessageType"] == "ListDevices":
            send_plist(self.request, tag, {"DeviceList": [{"DeviceID": DEVICE_ID, "MessageType": "Attached", "Properties": {"ConnectionType": "USB", "DeviceID": DEVICE_ID}}]})
            return
        assert (message["MessageType"], message["DeviceID"], message["PortNumber"]) == ("Connect", DEVICE_ID, PORT_NUMBER), message
        if not phone.on_screen:
            phone.refused += 1
            send_plist(self.request, tag, {"MessageType": "Result", "Number": USBMUX_REFUSED})
            return
        send_plist(self.request, tag, {"MessageType": "Result", "Number": 0})
        method, path, sha256 = receive_request(self.request)
        status, body = phone.answer(method, path, sha256)
        send_reply(self.request, status, body)
        phone.requests.append(Request(time.monotonic(), method, path, status))


class PhoneServer(socketserver.ThreadingUnixStreamServer):
    """The fake phone's usbmux, each connection answered on a thread of its own."""

    daemon_threads = True

    def __init__(self, phone: Phone) -> None:
        self.phone = phone
        super().__init__(str(phone.usbmux), Usbmux)


@pytest.fixture
def phone() -> Iterator[Phone]:
    """The fake iPhone, its app on screen, its usbmux listening until the test ends."""
    # A unix socket's path holds at most 107 bytes, which one in a test's tmp_path can pass.
    with tempfile.TemporaryDirectory() as folder:
        phone = Phone(Path(folder) / "usbmuxd")
        with PhoneServer(phone) as server:
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            yield phone
            server.shutdown()
            thread.join()


@pytest.fixture
def downloads(tmp_path: Path) -> Path:
    """The Downloads folder in the home pull.ps1 runs with, where a recording naming no folder goes."""
    folder = tmp_path / "home" / "Downloads"
    folder.mkdir(parents=True)
    return folder


@pytest.fixture(scope="module")
def received(tmp_path_factory: pytest.TempPathFactory) -> bytes:
    """The tar server/receive.py stores for the recording from its files staged as the receiver stages them."""
    root = tmp_path_factory.mktemp("receive")
    staging = root / ".staging" / KEY
    staging.mkdir(parents=True)
    for name, data in DATA.items():
        (staging / name).write_bytes(data)
        # The receiver makes each file it stages group-writable.
        (staging / name).chmod(0o664)
    return store(root, staging, SCAN_ID, [(member, [name for name, _ in files]) for member, files in RECORDING]).read_bytes()


@pytest.fixture(scope="module")
def ends(received: bytes) -> Dict[str, int]:
    """Where each of the recording's files ends in its tar."""
    with tarfile.open(fileobj=io.BytesIO(received)) as tar:
        starts = {member.name: member.offset_data for member in tar.getmembers()}
    ends = {}
    for member, files in RECORDING:
        end = starts[f"{SCAN_ID}/{member}"]
        for name, data in files:
            end += len(data)
            ends[name] = end
    return ends


def undated(archive: bytes) -> bytes:
    """The tar with each header's mtime, uid, gid, uname and gname cleared and its checksum recomputed: when and by whom a file was written, which receive.py takes from the file it staged and pull.ps1 writes as the time it writes the tar and root."""
    data = bytearray(archive)
    # tarfile checks each header's checksum as it reads it.
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        headers = [member.offset for member in tar.getmembers()]
    for at in headers:
        for start, end in ((108, 124), (136, 148), (265, 329)):
            data[at + start:at + end] = bytes(end - start)
        data[at + 148:at + 156] = b" " * 8
        data[at + 148:at + 156] = b"%06o\x00 " % sum(data[at:at + 512])
    return bytes(data)


@contextlib.contextmanager
def pulling(tmp_path: Path, phone: Phone, fsync_delay_s: Optional[float]) -> Iterator[None]:
    """Runs server/pull.ps1 as a user runs it, its text piped into Invoke-Expression, with tmp_path/home as its home and the fake phone's usbmux, what it prints appended to tmp_path/pull.out, until the block ends, when it is killed as a crash or a closed window ends it; with fsync_delay_s, strace holds each fsync it makes that much longer, a slow disk under its tar, which flushes each file it writes into the tar."""
    command = [PWSH, "-NoProfile", "-NonInteractive", "-Command", f"Get-Content -Raw -LiteralPath '{PULL}' | Invoke-Expression"]
    if fsync_delay_s is not None:
        strace = shutil.which("strace")
        assert strace is not None, "a slow disk is made with strace, which must be on PATH"
        command = [strace, "-f", "-qq", "--seccomp-bpf", "-o", "/dev/null", "-e", "trace=fsync", "-e", f"inject=fsync:delay_exit={round(fsync_delay_s * 1e6)}"] + command
    # POWERSHELL_TELEMETRY_OPTOUT keeps PowerShell from reporting its start over the network.
    env = os.environ | {"HOME": str(tmp_path / "home"), "USBMUXD_SOCKET_ADDRESS": f"UNIX:{phone.usbmux}", "POWERSHELL_TELEMETRY_OPTOUT": "1"}
    with open(tmp_path / "pull.out", "ab") as out:
        # A process group of its own, so one kill ends strace and PowerShell together.
        pull = subprocess.Popen(command, stdout=out, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    try:
        yield
    finally:
        os.killpg(pull.pid, signal.SIGKILL)
        pull.wait()


def wait_for(condition: Callable[[], Any], what: str) -> None:
    deadline = time.monotonic() + 60
    while not condition():
        assert time.monotonic() < deadline, f"a minute passed without {what}"
        time.sleep(0.01)


def taken(phone: Phone, folder: Path) -> bool:
    """Whether the phone has been told the recording is stored, deleting it, and the recording's staging folder in the folder is gone."""
    return phone.recording is None and not (folder / STAGING).exists()


def waits(tmp_path: Path) -> List[str]:
    """The waits pull.ps1 has printed."""
    return [line for line in (tmp_path / "pull.out").read_text().replace("\r", "\n").splitlines() if line.startswith("Waiting:")]


def fetched(phone: Phone) -> Counter:
    return Counter(r.path.rsplit("/", 1)[1] for r in phone.requests if r.method == "GET" and r.path.startswith("/files/"))


def acknowledged(phone: Phone) -> Counter:
    return Counter(r.path.rsplit("/", 1)[1] for r in phone.requests if r.path.startswith("/acknowledged/") and r.status == 200)


def listings(phone: Phone) -> int:
    return sum(1 for r in phone.requests if r.path == "/recordings")


def stage(staging: Path, resume: int, part: bytes) -> Path:
    """Leaves the staging folder as a tar cut short leaves it, holding the files from the resume-th on, each beside its SHA-256, and the tar's part; returns the part's path."""
    staging.mkdir()
    for name in NAMES[resume:]:
        (staging / name).write_bytes(DATA[name])
        (staging / f"{name}.sha256").write_text(SHA256[name])
    (staging / PART).write_bytes(part)
    return staging / PART


def test_finished_recording_taken_whole(tmp_path: Path, downloads: Path, phone: Phone, received: bytes) -> None:
    phone.recording = Recording(None, True, set())
    with pulling(tmp_path, phone, None):
        wait_for(lambda: taken(phone, downloads), "the recording taken")
    assert fetched(phone) == Counter(NAMES) and acknowledged(phone) == Counter(SEGMENTS)
    assert {r.status for r in phone.requests} == {200}
    assert sorted(p.name for p in downloads.iterdir()) == [ARCHIVE]
    assert undated((downloads / ARCHIVE).read_bytes()) == undated(received)


def test_live_recording_taken_while_it_records(tmp_path: Path, downloads: Path, phone: Phone, received: bytes) -> None:
    phone.recording = Recording(None, False, set())
    closed_at: Dict[str, float] = {}
    with pulling(tmp_path, phone, None):
        for batch in (LIVE[:5], LIVE[5:]):
            closed_at |= dict.fromkeys(batch, phone.close(batch))
            wait_for(lambda: set(batch) <= acknowledged(phone).keys(), f"{batch} acknowledged")
        finished_at = phone.finish()
        wait_for(lambda: taken(phone, downloads), "the recording taken")
    # Each segment fetched once the recording closed it and acknowledged, so the phone deleted it, before the recording finished.
    for name in LIVE:
        fetch, ack = (r.time for r in phone.requests if r.path in (f"/files/{KEY}/{name}", f"/acknowledged/{KEY}/{name}"))
        assert closed_at[name] <= fetch < ack < finished_at, name
    assert all(r.time > finished_at for r in phone.requests if r.path.startswith("/files/") and r.path.rsplit("/", 1)[1] not in LIVE)
    assert fetched(phone) == Counter(NAMES) and acknowledged(phone) == Counter(SEGMENTS)
    assert undated((downloads / ARCHIVE).read_bytes()) == undated(received)


def test_killed_during_tar_then_run_again(tmp_path: Path, downloads: Path, phone: Phone, received: bytes, ends: Dict[str, int]) -> None:
    phone.recording = Recording(None, True, set())
    staging = downloads / STAGING
    part = staging / PART

    def flushing(name: Optional[str]) -> bool:
        """Whether the tar is being flushed with the file's bytes at its end while the file is still staged, or, for None, with the archive's end and no file left staged."""
        if not part.is_file():
            return False
        if name is None:
            return part.stat().st_size == len(received) and not any((staging / n).exists() for n in NAMES)
        return part.stat().st_size == ends[name] and (staging / name).is_file()

    # The first file, a segment inside a member, a member's first segment, whose header the tar writes before it, and the archive's end.
    for name in ["scan_metadata.json", "color_frames.bin.000003", "depth_frames.bin.000000", None]:
        with pulling(tmp_path, phone, 0.2):
            wait_for(lambda: flushing(name), f"the tar flushed with {name or 'its end'}")
    with pulling(tmp_path, phone, None):
        wait_for(lambda: taken(phone, downloads), "the recording taken")
    assert fetched(phone) == Counter(NAMES)
    assert undated((downloads / ARCHIVE).read_bytes()) == undated(received)


@pytest.mark.parametrize("resume", [pytest.param("color_frames.bin.000003", id="inside_member"), pytest.param("depth_frames.bin.000000", id="member_start"), pytest.param(None, id="archive_end")])
def test_tar_cut_short_with_garbage(tmp_path: Path, downloads: Path, phone: Phone, received: bytes, ends: Dict[str, int], resume: Optional[str]) -> None:
    index = len(NAMES) if resume is None else NAMES.index(resume)
    # As much as a crash leaves past the point the tar resumes at: a header and a segment.
    stage(downloads / STAGING, index, received[:ends[NAMES[index - 1]]] + random.Random("garbage").randbytes(512 + SEGMENT))
    # Every segment was acknowledged before the tar began.
    phone.recording = Recording(None, True, set(SEGMENTS))
    with pulling(tmp_path, phone, None):
        wait_for(lambda: taken(phone, downloads), "the recording taken")
    assert fetched(phone) == Counter()
    assert undated((downloads / ARCHIVE).read_bytes()) == undated(received)


@pytest.mark.parametrize("impossible", ["part_short", "file_missing"])
def test_impossible_staging_waits(tmp_path: Path, downloads: Path, phone: Phone, received: bytes, ends: Dict[str, int], impossible: str) -> None:
    staging = downloads / STAGING
    resume = NAMES.index("color_frames.bin.000003")
    offset = ends[NAMES[resume - 1]]
    if impossible == "part_short":
        part = stage(staging, resume, received[:offset - 1000])
        expected = f"Waiting: {part} is {offset - 1000} bytes, but the files already moved into it from {staging} end at byte {offset}"
    else:
        part = stage(staging, resume, received[:offset])
        (staging / "color_frames.bin.000005").unlink()
        expected = f"Waiting: {SCAN_ID}: its tar resumes at color_frames.bin.000003, but color_frames.bin.000005 after it is missing from {staging}"
    before = part.read_bytes()
    phone.recording = Recording(None, True, set(SEGMENTS))
    with pulling(tmp_path, phone, None):
        wait_for(lambda: waits(tmp_path), "a wait printed")
        polls = listings(phone)
        # The second poll after the wait begins once the first has met it again.
        wait_for(lambda: listings(phone) >= polls + 2, "two more polls")
    assert waits(tmp_path) == [expected]
    assert part.read_bytes() == before and not (downloads / ARCHIVE).exists()
    assert fetched(phone) == Counter() and phone.recording is not None


def test_app_off_screen_when_stored_is_due(tmp_path: Path, downloads: Path, phone: Phone, received: bytes) -> None:
    phone.recording = Recording(None, True, set())
    # The user leaves the app as it sends the last file, so the tar is written while it is off screen.
    phone.leaves_after = NAMES[-1]
    with pulling(tmp_path, phone, None):
        wait_for(lambda: len(waits(tmp_path)) >= 2, "two waits printed")
        refused = phone.refused
        wait_for(lambda: phone.refused > refused, "another poll")
        assert (downloads / ARCHIVE).is_file() and phone.recording is not None
        phone.on_screen = True
        back = time.monotonic()
        wait_for(lambda: taken(phone, downloads), "the recording taken")
    # Printed once for the recording, which the phone cannot be told is stored, and once for the phone, which then cannot list it, over every poll that met it.
    assert waits(tmp_path) == [NOT_ANSWERING, NOT_ANSWERING]
    assert fetched(phone) == Counter(NAMES)
    assert {(r.method, r.path) for r in phone.requests if r.time > back} == {("GET", "/recordings"), ("POST", f"/stored/{SCAN_ID}")}
    assert undated((downloads / ARCHIVE).read_bytes()) == undated(received)


def test_tar_already_stored_only_told(tmp_path: Path, downloads: Path, phone: Phone, received: bytes) -> None:
    archive = downloads / ARCHIVE
    archive.write_bytes(received)
    stat = archive.stat()
    (downloads / STAGING).mkdir()
    phone.recording = Recording(None, True, set(SEGMENTS))
    with pulling(tmp_path, phone, None):
        wait_for(lambda: taken(phone, downloads), "the recording taken")
    assert {(r.method, r.path) for r in phone.requests} == {("GET", "/recordings"), ("POST", f"/stored/{SCAN_ID}")}
    assert archive.read_bytes() == received and (archive.stat().st_ino, archive.stat().st_mtime_ns) == (stat.st_ino, stat.st_mtime_ns)


def test_disk_during_tar_at_most_recording_plus_segment(tmp_path: Path, downloads: Path, phone: Phone, received: bytes, ends: Dict[str, int]) -> None:
    phone.recording = Recording(None, True, set())
    staging = downloads / STAGING
    # Each sample's tar length and the bytes of the staging folder.
    samples: List[Tuple[int, int]] = []

    def sample() -> bool:
        """Samples the staging folder while the tar is written, the tar measured first: it only grows and the staged files only go, so a sample never holds more than the folder held as the tar was measured; returns whether the tar is stored."""
        try:
            length = (staging / PART).stat().st_size
        except FileNotFoundError:
            # Not begun, or stored.
            return (downloads / ARCHIVE).exists()
        total = length
        for entry in os.scandir(staging):
            if entry.name != PART:
                try:
                    total += entry.stat().st_size
                except FileNotFoundError:
                    # Moved into the tar after it was measured.
                    continue
        samples.append((length, total))
        return False

    with pulling(tmp_path, phone, 0.2):
        wait_for(sample, "the tar stored")
        wait_for(lambda: taken(phone, downloads), "the recording taken")
    # The folder was sampled as each flush held it, a file's bytes in the tar and the file still staged, and at the archive's end.
    assert set(ends.values()) | {len(received)} <= {length for length, _ in samples}
    assert max(total for _, total in samples) <= len(received) + SEGMENT
    assert undated((downloads / ARCHIVE).read_bytes()) == undated(received)


@pytest.mark.usefixtures("downloads")
def test_phone_kept_awake_during_slow_tar(tmp_path: Path, phone: Phone, received: bytes) -> None:
    # The folder the recording's config names.
    folder = tmp_path / "configured"
    folder.mkdir()
    phone.recording = Recording(folder, True, set())
    with pulling(tmp_path, phone, 0.6):
        wait_for(lambda: (folder / STAGING / PART).exists(), "the tar begun")
        began = time.monotonic()
        wait_for(lambda: (folder / ARCHIVE).exists(), "the tar stored")
        tar_s = time.monotonic() - began
        wait_for(lambda: taken(phone, folder), "the recording taken")
    first = max(i for i, r in enumerate(phone.requests) if r.time < began)
    last = next(i for i, r in enumerate(phone.requests) if r.path == f"/stored/{SCAN_ID}")
    window = phone.requests[first:last + 1]
    # The tar alone would keep the phone without a request past the 10 s after which it locks its screen.
    assert tar_s > 10, tar_s
    assert all(r.path == "/recordings" for r in window[1:-1]), window
    assert max(b.time - a.time for a, b in itertools.pairwise(window)) < 10, window
    assert undated((folder / ARCHIVE).read_bytes()) == undated(received)


def powershell(command: str) -> List[str]:
    """What PowerShell 7 prints running the command, line by line."""
    result = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-Command", command], capture_output=True, text=True, env=os.environ | {"POWERSHELL_TELEMETRY_OPTOUT": "1"})
    assert result.returncode == 0, result.stderr
    return result.stdout.splitlines()


def test_keeping_windows_awake_compiles_and_runs_only_on_windows() -> None:
    lines = [line.strip() for line in PULL.read_text().splitlines() if "Add-Type" in line or "[PullPs1.Power]::" in line]
    # kernel32's SetThreadExecutionState is declared and called only on Windows.
    guarded = [re.fullmatch(r"if \(\$env:OS -eq 'Windows_NT'\) \{ (.*) \}", line) for line in lines]
    assert len(lines) == 2 and all(guarded), lines
    declaration = guarded[0].group(1)
    assert declaration.startswith("Add-Type "), declaration
    assert powershell(f"$ErrorActionPreference = 'Stop'; {declaration}; [PullPs1.Power].GetMethod('SetThreadExecutionState').ToString()") == ["UInt32 SetThreadExecutionState(UInt32)"]


def test_parses_as_windows_powershell() -> None:
    errors, kinds = powershell(f"$tokens = $null; $errors = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile('{PULL}', [ref]$tokens, [ref]$errors); $errors.Count; ($tokens.Kind | Sort-Object -Unique) -join ' '")
    # Tokens PowerShell 7 added, which Windows PowerShell 5.1, where users paste pull.ps1, cannot parse: ??, ??=, ?., ?[, &&, ||, the ternary's ? and the clean block.
    seven = {"QuestionQuestion", "QuestionQuestionEquals", "QuestionDot", "QuestionLBracket", "AndAnd", "OrOr", "QuestionMark", "Clean"}
    assert errors == "0" and not set(kinds.split()) & seven, (errors, kinds)
    assert "-Parallel" not in PULL.read_text()

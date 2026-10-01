"""Reads an RGBD Scanner recording (.tar): metadata, the color and depth tables, the depth maps, their confidence maps when the depth source has them, the color frames, and a front recording's 8-bit H.264 depth tracks. `read` opens any format_version: 1 through FramesRecording, 2 to 5 through Recording.

Format history: 1 holds one frames.csv row per color/depth synchronizer pair instead of color.csv and depth.csv; 2 has color.csv and depth.csv without intrinsics in color.csv; 3 adds per-stream intrinsics; 4 adds metadata.json's depth_source and, for "arkit_scene_depth", confidence.bin; 5 adds the 8-bit depth tracks of "avfoundation_truedepth" recordings.

Pixels are in the sensor's native orientation; `upright` turns a frame the way the phone was held. A color frame and a depth frame were captured together when their timestamps are equal; a color frame that was dropped, or lost when the app was closed mid-recording, keeps its timestamp as a dropped row (index -1). Each table row carries its frame's intrinsics fx,fy,cx,cy in its own stream's pixels. metadata.json's depth_source says where the depth came from: "avfoundation_truedepth" (front) or "arkit_scene_depth" (rear), whose recordings also hold confidence.bin (UInt8 ARConfidenceLevel per depth pixel: 0 low, 1 medium, 2 high) and a camera pose per depth row. Each delivered depth row has the delivered map's row stride, bytes_per_row, which depth.bin drops. "avfoundation_truedepth" recordings also hold the depth maps as an earlier app encoded them, 8-bit H.264 tracks described by metadata.json's depth8_h264, in the earlier app's portrait mirrored layout (track pixel (r, c) is depth map pixel (c, r)); depth8_metres turns a track's codes back into metres in the sensor's orientation.
"""

import csv
import io
import json
import tarfile
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple, Union

import cv2
import numpy as np

DEPTH_DTYPES = {"fdep": "<f4", "hdep": "<f2"}
FILES = {"color.mov", "color.csv", "depth.bin", "depth.csv", "metadata.json"}
FRAMES_FILES = {"color.mov", "depth.bin", "frames.csv", "metadata.json"}
CONFIDENCE_FILE = "confidence.bin"
DEPTH_SOURCES = ("avfoundation_truedepth", "arkit_scene_depth")
HIGH_CONFIDENCE = 2
INTRINSICS = ("fx", "fy", "cx", "cy")
SAME_INSTANT_S = 0.0005


class Recording:
    def __init__(self, tar_path: Path, work_dir: Path) -> None:
        with tarfile.open(tar_path) as tar:
            members = {Path(m.name).name: m for m in tar.getmembers()}
            assert "metadata.json" in members, sorted(members)
            self.meta: Dict = json.load(tar.extractfile(members["metadata.json"]))
            version = self.meta["format_version"]
            assert version in (2, 3, 4, 5), version
            # Formats 2 and 3 predate depth_source, confidence maps and 8-bit depth tracks.
            assert ("depth_source" in self.meta) == (version >= 4), (version, sorted(self.meta))
            depth_source = self.meta["depth_source"] if version >= 4 else None
            assert depth_source is None or depth_source in DEPTH_SOURCES, depth_source
            # The depth source's metadata describes its confidence maps exactly when it delivers them.
            self.has_confidence = "confidence_pixel_format" in self.meta
            assert self.has_confidence == (depth_source == "arkit_scene_depth"), (depth_source, self.has_confidence)
            # The front camera's format 5 recordings, and only they, hold the 8-bit depth tracks.
            assert ("depth8_h264" in self.meta) == (version == 5 and depth_source == "avfoundation_truedepth"), (version, depth_source, "depth8_h264" in self.meta)
            depth8_files = {t["file"] for t in self.meta["depth8_h264"]["tracks"]} if "depth8_h264" in self.meta else set()
            assert set(members) == FILES | ({CONFIDENCE_FILE} if self.has_confidence else set()) | depth8_files, sorted(members)
            self.color_rows: List[Dict[str, str]] = list(csv.DictReader(io.TextIOWrapper(tar.extractfile(members["color.csv"]))))
            self.depth_rows: List[Dict[str, str]] = list(csv.DictReader(io.TextIOWrapper(tar.extractfile(members["depth.csv"]))))
            raw = tar.extractfile(members["depth.bin"]).read()
            raw_confidence = tar.extractfile(members[CONFIDENCE_FILE]).read() if self.has_confidence else None
            self.mov = work_dir / "color.mov"
            self.mov.write_bytes(tar.extractfile(members["color.mov"]).read())
            self.depth8_movs: Dict[str, Path] = {}
            for name in sorted(depth8_files):
                self.depth8_movs[name] = work_dir / name
                self.depth8_movs[name].write_bytes(tar.extractfile(members[name]).read())
        shape = (-1, self.meta["depth_height"], self.meta["depth_width"])
        self.depth = np.frombuffer(raw, dtype=DEPTH_DTYPES[self.meta["depth_pixel_format"]]).reshape(shape).astype(np.float32)
        self.confidence: Optional[np.ndarray] = None
        if raw_confidence is not None:
            assert self.meta["confidence_pixel_format"] == "L008" and self.meta["confidence_bytes_per_pixel"] == 1, self.meta["confidence_pixel_format"]
            self.confidence = np.frombuffer(raw_confidence, dtype=np.uint8).reshape(shape)
        self.colors = [r for r in self.color_rows if r["index"] != "-1"]
        self.depths = [r for r in self.depth_rows if r["index"] != "-1"]

    def depth8_track(self, file: str) -> Tuple[np.ndarray, np.ndarray]:
        """One 8-bit depth track: its codes, frames x encoded height x encoded width uint8 in the track's portrait mirrored layout, and each frame's presentation time in seconds."""
        assert file in self.depth8_movs, (file, sorted(self.depth8_movs))
        cap = cv2.VideoCapture(str(self.depth8_movs[file]))
        cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 0)
        codes, times = [], []
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            # The codes are gray, so the decoder's three channels are equal.
            assert np.array_equal(frame[..., 0], frame[..., 1]) and np.array_equal(frame[..., 0], frame[..., 2]), file
            codes.append(frame[..., 0])
            times.append(cap.get(cv2.CAP_PROP_POS_MSEC) / 1000)
        return np.stack(codes), np.array(times)

    def depth8_metres(self, codes: np.ndarray) -> np.ndarray:
        """A track's codes as Float32 metres, code / 255 * range_m with 0 meaning no reading, laid out back in the sensor's orientation like depth.bin's maps."""
        def _validate_inputs() -> None:
            assert codes.dtype == np.uint8 and codes.ndim == 3, (codes.dtype, codes.shape)

        _validate_inputs()

        spec = self.meta["depth8_h264"]
        # Track pixel (r, c) is map pixel (c, r): the map turned 90 degrees clockwise, then mirrored left to right.
        assert spec["layout"] == "portrait_mirrored", spec["layout"]
        metres = codes.astype(np.float32) / np.float32(255) * np.float32(spec["range_m"])
        return np.ascontiguousarray(np.transpose(metres, (0, 2, 1)))

    def color_frames(self) -> Iterator[np.ndarray]:
        return video_frames(self.mov)

    def pairs(self) -> List[Tuple[Dict[str, str], Dict[str, str]]]:
        """Each depth row with the color.csv row, delivered or dropped, captured at the same instant, matched by timestamp."""
        by_time = {round(float(r["timestamp"]) / SAME_INSTANT_S): r for r in self.color_rows}
        out = []
        for d in self.depths:
            c = by_time.get(round(float(d["timestamp"]) / SAME_INSTANT_S))
            if c is not None:
                out.append((c, d))
        return out


class FramesRecording:
    """A format_version 1 recording: color.mov, depth.bin, frames.csv (one row per color/depth synchronizer pair, each stream's index in color_index and depth_index) and metadata.json."""

    def __init__(self, tar_path: Path, work_dir: Path) -> None:
        with tarfile.open(tar_path) as tar:
            members = {Path(m.name).name: m for m in tar.getmembers()}
            assert set(members) == FRAMES_FILES, sorted(members)
            self.meta: Dict = json.load(tar.extractfile(members["metadata.json"]))
            assert self.meta["format_version"] == 1, self.meta["format_version"]
            self.rows: List[Dict[str, str]] = list(csv.DictReader(io.TextIOWrapper(tar.extractfile(members["frames.csv"]))))
            raw = tar.extractfile(members["depth.bin"]).read()
            self.mov = work_dir / "color.mov"
            self.mov.write_bytes(tar.extractfile(members["color.mov"]).read())
        self.depth = np.frombuffer(raw, dtype=DEPTH_DTYPES[self.meta["depth_pixel_format"]]).reshape(-1, self.meta["depth_height"], self.meta["depth_width"])
        self.confidence: Optional[np.ndarray] = None
        self.depth8_movs: Dict[str, Path] = {}
        # A pair row names a delivered frame of each stream by its index, each delivered frame exactly once, in order.
        self.colors = [r for r in self.rows if r["color_index"] not in ("", "-1")]
        self.depths = [r for r in self.rows if r["depth_index"] not in ("", "-1")]
        assert [int(r["color_index"]) for r in self.colors] == list(range(len(self.colors))), "color_index is not 0..n-1"
        assert [int(r["depth_index"]) for r in self.depths] == list(range(len(self.depths))), "depth_index is not 0..n-1"

    def color_frames(self) -> Iterator[np.ndarray]:
        return video_frames(self.mov)


def read(tar_path: Path, work_dir: Path) -> Union[Recording, FramesRecording]:
    """Opens a recording of any format_version with the reader of its format."""
    with tarfile.open(tar_path) as tar:
        members = {Path(m.name).name: m for m in tar.getmembers()}
        assert "metadata.json" in members, sorted(members)
        version = json.load(tar.extractfile(members["metadata.json"]))["format_version"]
    return FramesRecording(tar_path, work_dir) if version == 1 else Recording(tar_path, work_dir)


def video_frames(mov: Path) -> Iterator[np.ndarray]:
    """Yields a movie's frames in order, BGR, in sensor orientation (the track's display rotation is not applied)."""
    cap = cv2.VideoCapture(str(mov))
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 0)
    while True:
        ok, frame = cap.read()
        if not ok:
            return
        yield frame


def upright(image: np.ndarray, rotation_deg: str) -> np.ndarray:
    """Rotates a sensor-oriented image clockwise by the recorded upright rotation."""
    return np.ascontiguousarray(np.rot90(image, k=-(int(rotation_deg) // 90) % 4))


def valid(depth: np.ndarray) -> np.ndarray:
    return np.isfinite(depth) & (depth > 0)

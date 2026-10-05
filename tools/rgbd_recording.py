"""Reads an RGBD Scanner recording (.tar, format_version "4.0" or "4.1", the version of the app that wrote it, <major>.<minor>, the major the app version (v4) and the minor counting the app's changes within it; the two are laid out alike, 4.1 written by app 4.1, which stores a recording as a directory and streams it as this tar): its metadata, the color and depth tables, the color frames, the depth maps, the rear camera's confidence maps and poses, and the front camera's per-map calibration. color.bin, depth.bin and confidence.bin are memory-mapped in place inside the uncompressed tar, at each member's data offset, never extracted: a front recording is about 0.55 GB per second.

The archive is a POSIX ustar tar whose members sit under <id>/: metadata.json, color.bin, color.csv, depth.bin, depth.csv, and confidence.bin (rear) or calibration.jsonl (front). metadata.json's camera is "front" (the TrueDepth camera through AVFoundation, depth_source "avfoundation_truedepth") or "rear" (the LiDAR camera through ARKit world tracking, depth_source "arkit_scene_depth"); depth filtering is always off.

color.bin holds every delivered color frame uncompressed, frame n (color.csv's row with index n) at bytes [n*color_bytes_per_frame, (n+1)*color_bytes_per_frame), color_bytes_per_frame = color_width*color_height*3/2, no header: the camera's 420f buffer, 8-bit full-range YCbCr 4:2:0, its luma plane (color_height rows of color_width bytes, one Y per pixel) then its CbCr plane (color_height/2 rows of color_width bytes, one Cb, Cr byte pair per 2x2 pixels), rows tightly packed; `color_bgr` converts a frame to BGR through metadata.json's color_ycbcr_matrix. depth.bin holds every delivered depth map as Float32 metres ("fdep"), map n at bytes [n*depth_bytes_per_frame, (n+1)*depth_bytes_per_frame), rows tightly packed, NaN or 0 meaning no reading. The rear's confidence.bin holds one UInt8 ARConfidenceLevel map per depth map, in depth.bin's order and layout: 0 low, 1 medium, 2 high.

color.csv and depth.csv hold one row per frame delivered or dropped: index (-1 on a dropped row), timestamp (host-clock seconds, one clock for both tables), dropped (a dropped row's reason; its later cells are empty), the frame's intrinsics fx, fy, cx, cy in its own stream's pixels (empty on a delivered row only when the frame came without them), upright_rotation_deg and CoreMotion gravity. depth.csv adds bytes_per_row, the delivered map's row stride that depth.bin drops, and the front's AVDepthData filtered, accuracy and quality. The rear's color.csv adds ARKit's tracking_state and world_from_camera_<r><c>, rows 0 to 2 of ARFrame.camera.transform (camera to world, metres), which `world_from_camera` returns as a 4x4 matrix. The rear's depth intrinsics are its color intrinsics, whose principal point ARKit measures from the center of the upper-left pixel, carried to the depth map as its grid lies on the color image, measured on six rear scans from where depth edges land on color edges: f*s on both axes, cx*sx along x, where the first depth column's center sits on the first color column's center, and (cy+0.5)*sy-0.5 along y, where the depth rows span the color rows edge to edge, s = depth size / color size; the front's are each depth map's own calibration scaled from its reference dimensions with Apple's corner origin, f*s and c*s. The front's calibration.jsonl holds one line per delivered depth map, in depth.csv's order: {"index", "timestamp", "calibration"}, the map's AVCameraCalibrationData described, or null when it came without one.

Pixels and intrinsics are in the sensor's native orientation; `upright` turns a frame the way the phone was held. A color frame and a depth frame were captured together when their timestamps are equal (`pairs`).
"""

import csv
import io
import json
import tarfile
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

import numpy as np

FILES = {"metadata.json", "color.bin", "color.csv", "depth.bin", "depth.csv"}
CAMERA_FILES = {"front": {"calibration.jsonl"}, "rear": {"confidence.bin"}}
INTRINSICS = ["fx", "fy", "cx", "cy"]
ORIENTATION = ["upright_rotation_deg", "gravity_x", "gravity_y", "gravity_z", "gravity_ts"]
POSE = [f"world_from_camera_{r}{c}" for r in range(3) for c in range(4)]
COLOR_HEADERS = {
    "front": ["index", "timestamp", "dropped", *INTRINSICS, *ORIENTATION],
    "rear": ["index", "timestamp", "dropped", *INTRINSICS, *ORIENTATION, "tracking_state", *POSE],
}
DEPTH_HEADERS = {
    "front": ["index", "timestamp", "dropped", "filtered", "accuracy", "quality", *INTRINSICS, *ORIENTATION, "bytes_per_row"],
    "rear": ["index", "timestamp", "dropped", *INTRINSICS, *ORIENTATION, "bytes_per_row"],
}
HIGH_CONFIDENCE = 2
SAME_INSTANT_S = 0.0005
# Kr and Kb of each YCbCr matrix metadata.json's color_ycbcr_matrix can name (kCVImageBufferYCbCrMatrix_*).
YCBCR_MATRICES = {"ITU_R_601_4": (0.299, 0.114), "ITU_R_709_2": (0.2126, 0.0722)}


class Recording:
    """A format_version "4.0" or "4.1" recording: its metadata and tables read, its .bin members memory-mapped in place inside the tar."""

    def __init__(self, tar_path: Path) -> None:
        # Mode "r:" opens an uncompressed tar only, the one whose members can be memory-mapped in place.
        with tarfile.open(tar_path, "r:") as tar:
            members = {Path(m.name).name: m for m in tar.getmembers()}
            assert "metadata.json" in members, sorted(members)
            self.meta: Dict = json.load(tar.extractfile(members["metadata.json"]))
            assert self.meta["format_version"] in ("4.0", "4.1"), self.meta["format_version"]
            camera = self.meta["camera"]
            assert camera in CAMERA_FILES, camera
            names = sorted(m.name for m in tar.getmembers())
            assert names == sorted(f"{self.meta['id']}/{name}" for name in FILES | CAMERA_FILES[camera]), names
            self.color_rows = read_table(tar, members["color.csv"], COLOR_HEADERS[camera])
            self.depth_rows = read_table(tar, members["depth.csv"], DEPTH_HEADERS[camera])
            self.calibrations: Optional[List[Dict]] = None
            if camera == "front":
                self.calibrations = [json.loads(line) for line in tar.extractfile(members["calibration.jsonl"]).read().decode().splitlines()]
        meta = self.meta
        width, height = meta["color_width"], meta["color_height"]
        assert meta["color_pixel_format"] == "420f" and width % 2 == 0 and height % 2 == 0 and meta["color_bytes_per_frame"] == width * height * 3 // 2, (meta["color_pixel_format"], width, height, meta["color_bytes_per_frame"])
        self.color = map_frames(tar_path, members["color.bin"], np.dtype(np.uint8), (height * 3 // 2, width))
        depth_shape = (meta["depth_height"], meta["depth_width"])
        assert meta["depth_pixel_format"] == "fdep" and meta["depth_bytes_per_pixel"] == 4 and meta["depth_bytes_per_frame"] == depth_shape[0] * depth_shape[1] * 4, (meta["depth_pixel_format"], meta["depth_bytes_per_pixel"], meta["depth_bytes_per_frame"])
        self.depth = map_frames(tar_path, members["depth.bin"], np.dtype("<f4"), depth_shape)
        self.confidence: Optional[np.memmap] = None
        if camera == "rear":
            assert meta["confidence_pixel_format"] == "L008" and meta["confidence_bytes_per_pixel"] == 1, (meta["confidence_pixel_format"], meta["confidence_bytes_per_pixel"])
            self.confidence = map_frames(tar_path, members["confidence.bin"], np.dtype(np.uint8), depth_shape)
        self.colors = [r for r in self.color_rows if r["index"] != "-1"]
        self.depths = [r for r in self.depth_rows if r["index"] != "-1"]

    def color_bgr(self, index: int) -> np.ndarray:
        """Color frame `index` as 8-bit BGR, color_height x color_width x 3 in sensor orientation, converted through metadata.json's color_ycbcr_matrix."""
        return ycbcr_to_bgr(self.color[index], self.meta["color_ycbcr_matrix"])

    def color_frames(self) -> Iterator[np.ndarray]:
        """Yields every color frame in order, as `color_bgr` gives it."""
        return (self.color_bgr(i) for i in range(self.color.shape[0]))

    def pairs(self) -> List[Tuple[Dict[str, str], Dict[str, str]]]:
        """Each depth row with the color.csv row, delivered or dropped, captured at the same instant, matched by timestamp."""
        by_time = {round(float(r["timestamp"]) / SAME_INSTANT_S): r for r in self.color_rows}
        out = []
        for d in self.depths:
            c = by_time.get(round(float(d["timestamp"]) / SAME_INSTANT_S))
            if c is not None:
                out.append((c, d))
        return out

    def world_from_camera(self, row: Dict[str, str]) -> np.ndarray:
        """A delivered rear color row's ARFrame.camera.transform as a 4x4 float64 matrix: ARKit's camera frame to its world frame, metres."""
        def _validate_inputs() -> None:
            assert self.meta["camera"] == "rear", self.meta["camera"]
            assert row["index"] != "-1", row

        _validate_inputs()

        top = np.array([float(row[k]) for k in POSE], dtype=np.float64).reshape(3, 4)
        return np.vstack([top, [0, 0, 0, 1]])


def read_table(tar: tarfile.TarFile, member: tarfile.TarInfo, header: List[str]) -> List[Dict[str, str]]:
    """A color.csv or depth.csv member's rows, its header the camera's and every row as long as the header."""
    reader = csv.DictReader(io.TextIOWrapper(tar.extractfile(member)))
    assert reader.fieldnames == header, (member.name, reader.fieldnames)
    rows = list(reader)
    # DictReader keys a longer row's extra cells by None and gives a shorter row's missing cells the value None.
    assert all(len(r) == len(header) and None not in r.values() for r in rows), member.name
    return rows


def map_frames(tar_path: Path, member: tarfile.TarInfo, dtype: np.dtype, frame_shape: Tuple[int, int]) -> np.memmap:
    """A .bin member's frames memory-mapped read-only where its bytes sit in the uncompressed tar: frames x frame_shape of dtype."""
    def _validate_inputs() -> None:
        assert member.isreg(), member.name
        # The member holds whole frames only.
        assert member.size % (dtype.itemsize * frame_shape[0] * frame_shape[1]) == 0, (member.name, member.size, dtype, frame_shape)

    _validate_inputs()

    frames = member.size // (dtype.itemsize * frame_shape[0] * frame_shape[1])
    return np.memmap(tar_path, dtype=dtype, mode="r", offset=member.offset_data, shape=(frames, *frame_shape))


def ycbcr_planes(frame: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """A color.bin frame's luma plane, height x width uint8, and CbCr plane, height / 2 x width / 2 x 2 uint8 (Cb, Cr), each Cb, Cr pair covering 2 x 2 luma pixels."""
    def _validate_inputs() -> None:
        assert frame.dtype == np.uint8 and frame.ndim == 2 and frame.shape[0] % 3 == 0 and frame.shape[1] % 2 == 0, (frame.dtype, frame.shape)

    _validate_inputs()

    height = frame.shape[0] * 2 // 3
    return frame[:height], frame[height:].reshape(height // 2, frame.shape[1] // 2, 2)


def ycbcr_to_bgr(frame: np.ndarray, matrix: str) -> np.ndarray:
    """A color.bin frame as 8-bit BGR: full-range R = Y + 2(1-Kr)(Cr-128), B = Y + 2(1-Kb)(Cb-128), G = (Y - Kr R - Kb B) / (1 - Kr - Kb) with the named matrix's Kr and Kb, each Cb, Cr pair applied to its 2 x 2 luma pixels, rounded to the nearest level and clipped to 0..255."""
    def _validate_inputs() -> None:
        assert matrix in YCBCR_MATRICES, (matrix, sorted(YCBCR_MATRICES))

    _validate_inputs()

    luma, cbcr = ycbcr_planes(frame)
    kr, kb = YCBCR_MATRICES[matrix]
    height, width = luma.shape
    assert luma.dtype == np.uint8 and cbcr.dtype == np.uint8, (luma.dtype, cbcr.dtype)
    # Luma as (block row, row in block, block column, column in block), so each 2 x 2 block's Cb, Cr broadcast over its four pixels.
    y = luma.astype(np.float64).reshape(height // 2, 2, width // 2, 2)
    cb, cr = (cbcr[:, None, :, None, i].astype(np.float64) - 128 for i in (0, 1))
    r = y + 2 * (1 - kr) * cr
    b = y + 2 * (1 - kb) * cb
    g = (y - kr * r - kb * b) / (1 - kr - kb)
    bgr = np.clip(np.rint(np.stack([b, g, r], axis=-1)), 0, 255)
    assert bgr.dtype == np.float64, bgr.dtype
    return bgr.astype(np.uint8).reshape(height, width, 3)


def upright(image: np.ndarray, rotation_deg: str) -> np.ndarray:
    """Rotates a sensor-oriented image clockwise by the recorded upright rotation."""
    return np.ascontiguousarray(np.rot90(image, k=-(int(rotation_deg) // 90) % 4))


def valid(depth: np.ndarray) -> np.ndarray:
    return np.isfinite(depth) & (depth > 0)

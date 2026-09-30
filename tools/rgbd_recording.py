"""Reads an RGBD Scanner recording (.tar, format_version 3): metadata, the color and depth tables, the depth maps, and the color frames.

Pixels are in the sensor's native orientation; `upright` turns a frame the way the phone was held. A color frame and a depth frame were captured together when their timestamps are equal. Each table row carries its frame's intrinsics fx,fy,cx,cy in its own stream's pixels.
"""

import csv
import io
import json
import tarfile
from pathlib import Path
from typing import Dict, Iterator, List, Tuple

import cv2
import numpy as np

DEPTH_DTYPES = {"fdep": "<f4", "hdep": "<f2"}
FILES = {"color.mov", "color.csv", "depth.bin", "depth.csv", "metadata.json"}
INTRINSICS = ("fx", "fy", "cx", "cy")
SAME_INSTANT_S = 0.0005


class Recording:
    def __init__(self, tar_path: Path, work_dir: Path) -> None:
        with tarfile.open(tar_path) as tar:
            members = {Path(m.name).name: m for m in tar.getmembers()}
            assert set(members) == FILES, sorted(members)
            self.meta: Dict = json.load(tar.extractfile(members["metadata.json"]))
            self.color_rows: List[Dict[str, str]] = list(csv.DictReader(io.TextIOWrapper(tar.extractfile(members["color.csv"]))))
            self.depth_rows: List[Dict[str, str]] = list(csv.DictReader(io.TextIOWrapper(tar.extractfile(members["depth.csv"]))))
            raw = tar.extractfile(members["depth.bin"]).read()
            self.mov = work_dir / "color.mov"
            self.mov.write_bytes(tar.extractfile(members["color.mov"]).read())
        assert self.meta["format_version"] == 3, self.meta["format_version"]
        shape = (-1, self.meta["depth_height"], self.meta["depth_width"])
        self.depth = np.frombuffer(raw, dtype=DEPTH_DTYPES[self.meta["depth_pixel_format"]]).reshape(shape).astype(np.float32)
        self.colors = [r for r in self.color_rows if r["index"] != "-1"]
        self.depths = [r for r in self.depth_rows if r["index"] != "-1"]

    def color_frames(self) -> Iterator[np.ndarray]:
        """Yields the color frames in order, in sensor orientation (the track's display rotation is not applied)."""
        cap = cv2.VideoCapture(str(self.mov))
        cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 0)
        while True:
            ok, frame = cap.read()
            if not ok:
                return
            yield frame

    def pairs(self) -> List[Tuple[Dict[str, str], Dict[str, str]]]:
        """Color and depth rows captured at the same instant, matched by timestamp."""
        by_time = {round(float(r["timestamp"]) / SAME_INSTANT_S): r for r in self.colors}
        out = []
        for d in self.depths:
            c = by_time.get(round(float(d["timestamp"]) / SAME_INSTANT_S))
            if c is not None:
                out.append((c, d))
        return out


def upright(image: np.ndarray, rotation_deg: str) -> np.ndarray:
    """Rotates a sensor-oriented image clockwise by the recorded upright rotation."""
    return np.ascontiguousarray(np.rot90(image, k=-(int(rotation_deg) // 90) % 4))


def valid(depth: np.ndarray) -> np.ndarray:
    return np.isfinite(depth) & (depth > 0)

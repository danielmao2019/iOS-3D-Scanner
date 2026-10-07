"""Tests the tools on tiny synthetic format_version "4.6" front and rear recordings laid out exactly as the app streams them: the reader's tables, its frames memory-mapped inside the tar, the rear poses and the YCbCr to BGR conversion against values worked out by hand, that it still reads a "4.0" recording, whose color.csv lacks the three columns 4.3 added, decode_recording's output files, and that inspect_recording runs with every check passing but the two edge alignments, which need real images; and inspect_recording's spatial alignment on a larger synthetic rear recording whose color and depth show the same rectangles, through the recorded intrinsics, through deliberately wrong ones, and with its depth's near rectangles fattened.

Usage: python -m pytest tools/test_rgbd_recording.py
"""

import io
import json
import tarfile
from pathlib import Path
from typing import Dict, List

import cv2
import numpy as np
import pytest

from decode_recording import decode
from inspect_recording import inspect, spatial_alignment
from rgbd_recording import DEPTH_HEADERS, YCBCR_MATRICES, Recording, color_header

COLOR_WIDTH, COLOR_HEIGHT = 8, 6
DEPTH_WIDTH, DEPTH_HEIGHT = 4, 3
# The front calibration's reference dimensions, so its depth scale (1/4) differs from the rear's color-to-depth scale (1/2).
REFERENCE_WIDTH, REFERENCE_HEIGHT = 16, 12
# Five capture instants at 30 fps, each with a color row and a depth row; color row 2 and depth row 3 are dropped, so each stream delivers FRAMES frames.
TIMES = [f"{100 + i / 30:.9f}" for i in range(5)]
COLOR_DROPPED = {2: "writer_busy"}
DEPTH_DROPPED = {"front": {3: "late_data"}, "rear": {3: "no_scene_depth"}}
FRAMES = 4
# The synthetic recordings are app 4.6's, format_version "4.6".
MINOR = 6
ALIGNMENT_CHECK = "depth aligns best with its same-instant color frame"
SPATIAL_ALIGNMENT_CHECK = "depth edges land on the same-instant color frame's edges through the two frames' intrinsics: median residual scale within 0.005 of 1 and median shifts within 0.15 depth px, over at least 10 frames"
# The spatial alignment recording: a rear recording big enough to have structure, ALIGNED_PAIRS same-instant pairs, its depth a quarter of its color each way, each pair showing RECTANGLES random rectangles at NEAR_M before a background at FAR_M.
ALIGNED_COLOR_WIDTH, ALIGNED_COLOR_HEIGHT = 512, 384
ALIGNED_DEPTH_WIDTH, ALIGNED_DEPTH_HEIGHT = 128, 96
ALIGNED_SCALE = np.array([ALIGNED_DEPTH_WIDTH, ALIGNED_DEPTH_HEIGHT], np.float32) / np.array([ALIGNED_COLOR_WIDTH, ALIGNED_COLOR_HEIGHT], np.float32)
ALIGNED_PAIRS = 12
RECTANGLES = 8
NEAR_M, FAR_M = 0.6, 2.4

# Color frame 0's first 2x2 block has Y 100, 101 / 102, 103 with Cb 150, Cr 90; its second has Y 250 with Cb 128, Cr 255.
# ITU_R_601_4, Kr 0.299, Kb 0.114: R = Y + 1.402 * -38 = Y - 53.276, B = Y + 1.772 * 22 = Y + 38.984, G = Y - (0.299 * -53.276 + 0.114 * 38.984) / 0.587 = Y + 19.566; second block R = 250 + 1.402 * 127 = 428.054 clipped to 255, B = 250, G = 250 - 0.299 * 178.054 / 0.587 = 159.305.
# ITU_R_709_2, Kr 0.2126, Kb 0.0722: R = Y + 1.5748 * -38 = Y - 59.842, B = Y + 1.8556 * 22 = Y + 40.823, G = Y - (0.2126 * -59.8424 + 0.0722 * 40.8232) / 0.7152 = Y + 13.668; second block R = 250 + 1.5748 * 127 = 449.9996 clipped to 255, B = 250, G = 250 - 0.2126 * 199.9996 / 0.7152 = 190.548.
EXPECTED_BGR = {
    "ITU_R_601_4": ([[[139, 120, 47], [140, 121, 48]], [[141, 122, 49], [142, 123, 50]]], [250, 159, 255]),
    "ITU_R_709_2": ([[[141, 114, 40], [142, 115, 41]], [[143, 116, 42], [144, 117, 43]]], [250, 191, 255]),
}


def color_frames() -> np.ndarray:
    """The FRAMES color.bin frames, each COLOR_HEIGHT * 3 / 2 rows of COLOR_WIDTH bytes, random but for frame 0's two hand-worked 2x2 blocks."""
    frames = np.random.default_rng(0).integers(0, 256, (FRAMES, COLOR_HEIGHT * 3 // 2, COLOR_WIDTH), dtype=np.uint8)
    frames[0, 0:2, 0:2] = [[100, 101], [102, 103]]
    frames[0, 0:2, 2:4] = 250
    # The CbCr plane's first row: block 0's Cb, Cr in bytes 0 and 1, block 1's in bytes 2 and 3.
    frames[0, COLOR_HEIGHT, 0:4] = [150, 90, 128, 255]
    return frames


def depth_maps() -> np.ndarray:
    """The FRAMES Float32 depth maps in metres, one pixel NaN and one 0, both meaning no reading."""
    maps = 0.3 + 1.7 * np.random.default_rng(1).random((FRAMES, DEPTH_HEIGHT, DEPTH_WIDTH), dtype=np.float32)
    assert maps.dtype == np.float32, maps.dtype
    maps[0, 0, 0] = np.nan
    maps[1, 2, 3] = 0
    return maps


def confidence_maps() -> np.ndarray:
    return np.random.default_rng(2).integers(0, 3, (FRAMES, DEPTH_HEIGHT, DEPTH_WIDTH), dtype=np.uint8)


def pose(instant: int) -> np.ndarray:
    """The color frame at `instant`'s world_from_camera rows 0 to 2: a turn of 0.1 rad per instant about +y, then a translation."""
    a = 0.1 * instant
    return np.array([[np.cos(a), 0, np.sin(a), 0.01 * instant], [0, 1, 0, 0.5], [-np.sin(a), 0, np.cos(a), -0.02 * instant]], np.float32)


def f32(value: np.float32) -> str:
    """A Float32 as Swift's String(Float) writes it: the shortest decimal that reads back as the same Float32."""
    return str(np.float32(value))


def color_intrinsics(instant: int) -> np.ndarray:
    """fx, fy, cx, cy of the color frame at `instant`, in color pixels."""
    return np.array([6.9 + 0.01 * instant, 6.95 + 0.01 * instant, 3.6, 2.7], np.float32)


def calibration_intrinsics(instant: int) -> np.ndarray:
    """fx, fy, cx, cy of the front depth map at `instant`'s calibration, at the reference dimensions."""
    return np.array([13.8 + 0.02 * instant, 13.9 + 0.02 * instant, 7.7, 5.6], np.float32)


def arkit_depth_intrinsics(k: np.ndarray, s: np.ndarray) -> np.ndarray:
    """ARKit color intrinsics fx, fy, cx, cy carried to a depth map s = (sx, sy) times the color frame's size, in Float32 as the app does, as ARKit's depth grid lies on the color image: f * s, cx * sx and (cy + 0.5) * sy - 0.5."""
    half = np.float32(0.5)
    return np.concatenate([k[:2] * s, k[2:3] * s[0], (k[3:] + half) * s[1] - half])


def depth_intrinsics(camera: str, instant: int) -> np.ndarray:
    """fx, fy, cx, cy of the depth map at `instant` as the app computes them in Float32: the rear's color intrinsics carried as ARKit's depth grid lies on the color image, the front's calibration scaled with the corner origin."""
    if camera == "rear":
        return arkit_depth_intrinsics(color_intrinsics(instant), np.array([DEPTH_WIDTH, DEPTH_HEIGHT], np.float32) / np.array([COLOR_WIDTH, COLOR_HEIGHT], np.float32))
    s = np.array([DEPTH_WIDTH, DEPTH_HEIGHT], np.float32) / np.array([REFERENCE_WIDTH, REFERENCE_HEIGHT], np.float32)
    return calibration_intrinsics(instant) * np.concatenate([s, s])


def orientation(instant: int) -> List[str]:
    return ["90", "0.01000", "-0.99000", "0.05000", f"{float(TIMES[instant]) - 0.001:.9f}"]


def exposure_lens_arrival(time: str) -> List[str]:
    """exposure_duration_s, lens_position and received_ts of a color frame with timestamp `time`: a 1/120 s exposure, the lens at 0.8, received 30 ms after its timestamp."""
    return [f"{1 / 120:.9f}", "0.8", f"{float(time) + 0.03:.9f}"]


def delivered(dropped: Dict[int, str]) -> Dict[int, int]:
    """Each delivered row's instant with its index."""
    instants = [i for i in range(len(TIMES)) if i not in dropped]
    return {instant: index for index, instant in enumerate(instants)}


def table(header: List[str], dropped: Dict[int, str], cells: Dict[int, List[str]]) -> bytes:
    """A color.csv or depth.csv: the header, then a row per instant, a dropped row "-1,<timestamp>,<reason>" with every later cell empty."""
    index = delivered(dropped)
    lines = [",".join(header)]
    for instant, time in enumerate(TIMES):
        row = ["-1", time, dropped[instant]] + [""] * (len(header) - 3) if instant in dropped else [str(index[instant]), time, ""] + cells[instant]
        assert len(row) == len(header), (row, header)
        lines.append(",".join(row))
    return ("\n".join(lines) + "\n").encode()


def color_csv(camera: str, minor: int) -> bytes:
    """A format_version "4.<minor>" color.csv, with exposure_duration_s, lens_position and received_ts from minor 3 on."""
    cells = {}
    for instant in delivered(COLOR_DROPPED):
        cells[instant] = [f32(v) for v in color_intrinsics(instant)] + orientation(instant) + (exposure_lens_arrival(TIMES[instant]) if minor >= 3 else [])
        if camera == "rear":
            cells[instant] += ["limited_initializing" if instant == 0 else "normal"] + [f32(v) for v in pose(instant).ravel()]
    return table(color_header(camera, minor), COLOR_DROPPED, cells)


def depth_csv(camera: str) -> bytes:
    cells = {}
    for instant in delivered(DEPTH_DROPPED[camera]):
        k = [f32(v) for v in depth_intrinsics(camera, instant)]
        cells[instant] = (["0", "absolute", "high"] + k + orientation(instant) + ["64"]) if camera == "front" else (k + orientation(instant) + ["16"])
    return table(DEPTH_HEADERS[camera], DEPTH_DROPPED[camera], cells)


def calibration_jsonl() -> bytes:
    """One line per delivered front depth map: its index, its depth.csv timestamp and its calibration."""
    lines = []
    for instant, index in delivered(DEPTH_DROPPED["front"]).items():
        fx, fy, cx, cy = (float(v) for v in calibration_intrinsics(instant))
        calibration = {
            "intrinsic_matrix_row_major": [[fx, 0, cx], [0, fy, cy], [0, 0, 1]],
            "intrinsic_reference_width": REFERENCE_WIDTH,
            "intrinsic_reference_height": REFERENCE_HEIGHT,
            "extrinsic_matrix_row_major_3x4": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
            "pixel_size_mm": 0.0028,
            "lens_distortion_center": [cx, cy],
            "lens_distortion_lookup_table": [0, 0.001, 0.002],
            "inverse_lens_distortion_lookup_table": [0, -0.001, -0.002],
        }
        lines.append(json.dumps({"index": index, "timestamp": float(TIMES[instant]), "calibration": calibration}))
    return ("\n".join(lines) + "\n").encode()


def recording_id(camera: str) -> str:
    return f"rgbd_20261002_120000_{camera}"


def rear_calibration() -> Dict:
    """A rear recording's avfoundation_calibration, at the reference dimensions, taken at lens position 0.8 just before the first frame."""
    return {
        "intrinsic_matrix_row_major": [[13.8, 0, 7.7], [0, 13.8, 5.6], [0, 0, 1]],
        "intrinsic_reference_width": REFERENCE_WIDTH,
        "intrinsic_reference_height": REFERENCE_HEIGHT,
        "extrinsic_matrix_row_major_3x4": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
        "pixel_size_mm": 0.0014,
        "lens_distortion_center": [7.7, 5.6],
        "lens_distortion_lookup_table": [0, 0.001, 0.002],
        "inverse_lens_distortion_lookup_table": [0, -0.001, -0.002],
        "lens_position": 0.8,
        "captured_at": float(TIMES[0]) - 1,
    }


def metadata(camera: str, matrix: str, minor: int) -> Dict:
    meta = {
        "format_version": f"4.{minor}",
        "id": recording_id(camera),
        "name": f"2026-10-02 12:00:00 {camera.capitalize()}",
        "named_by_user": False,
        "duration_s": float(TIMES[-1]) - float(TIMES[0]),
        "recovered": False,
        "start_time_utc": "2026-10-02T12:00:00Z",
        "device_model": "iPhone14,3",
        "system_version": "26.0",
        "camera": camera,
        "depth_source": {"front": "avfoundation_truedepth", "rear": "arkit_scene_depth"}[camera],
        "frame_rate": 30.0,
        "color_width": COLOR_WIDTH,
        "color_height": COLOR_HEIGHT,
        "color_pixel_format": "420f",
        "color_bytes_per_frame": COLOR_WIDTH * COLOR_HEIGHT * 3 // 2,
        "color_ycbcr_matrix": matrix,
        "color_description": "synthetic 420f frames",
        "depth_width": DEPTH_WIDTH,
        "depth_height": DEPTH_HEIGHT,
        "depth_pixel_format": "fdep",
        "depth_bytes_per_pixel": 4,
        "depth_bytes_per_frame": DEPTH_WIDTH * DEPTH_HEIGHT * 4,
        "depth_filtering_enabled": False,
        "focus": {"front": "fixed", "rear": "autofocus"}[camera],
        "intrinsics_convention": "synthetic",
        "timestamp_clock": "host time (CMClockGetHostTimeClock), seconds; shared by color.csv, depth.csv and gravity_ts",
        "orientation_convention": "synthetic",
        "color_frames": FRAMES,
        "depth_frames": FRAMES,
    }
    if camera == "rear":
        meta.update({
            "confidence_pixel_format": "L008",
            "confidence_bytes_per_pixel": 1,
            "confidence_description": "synthetic",
            "pose_convention": "synthetic",
            "arkit_frame_semantics": ["sceneDepth"],
            "arkit_video_format": "1920x1440 60 fps AVCaptureDeviceTypeBuiltInWideAngleCamera",
            "arkit_video_formats": ["1920x1440 60 fps AVCaptureDeviceTypeBuiltInWideAngleCamera"],
        })
        if minor >= 4:
            meta.update({"avfoundation_calibration": rear_calibration(), "avfoundation_calibration_description": "synthetic"})
    else:
        meta.update({"calibration_description": "synthetic", "available_depth_formats": ["640x480 fdep"]})
    return meta


def members(camera: str, matrix: str, minor: int) -> Dict[str, bytes]:
    """Each archive member's name under <id>/ with its bytes, in format_version "4.<minor>"."""
    files = {
        "metadata.json": json.dumps(metadata(camera, matrix, minor), indent=2, sort_keys=True).encode(),
        "color.bin": color_frames().tobytes(),
        "color.csv": color_csv(camera, minor),
        "depth.bin": depth_maps().tobytes(),
        "depth.csv": depth_csv(camera),
    }
    if camera == "rear":
        files["confidence.bin"] = confidence_maps().tobytes()
    else:
        files["calibration.jsonl"] = calibration_jsonl()
    return files


def write_tar(path: Path, rec_id: str, files: Dict[str, bytes]) -> Path:
    """Writes the files as the POSIX ustar archive <id>/<name> and returns its path."""
    with tarfile.open(path, "w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(f"{rec_id}/{name}")
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    return path


def synthetic_tar(folder: Path, camera: str, matrix: str) -> Path:
    return write_tar(folder / f"{recording_id(camera)}.tar", recording_id(camera), members(camera, matrix, MINOR))


def aligned_color_intrinsics(instant: int) -> np.ndarray:
    """fx, fy, cx, cy of the spatial alignment recording's color frame at `instant`, in color pixels, its principal point off the frame's center."""
    return np.array([400 + 2 * instant, 402 + 2 * instant, 251.3 + 0.2 * instant, 194.6 - 0.1 * instant], np.float32)


def rectangles(instant: int) -> np.ndarray:
    """The RECTANGLES random rectangles seen at `instant`, each as x0, x1, y0, y1 in view directions x / z and y / z."""
    rng = np.random.default_rng(10 + instant)
    centers = rng.uniform([-0.4, -0.3], [0.4, 0.3], (RECTANGLES, 2))
    halves = rng.uniform(0.04, 0.15, (RECTANGLES, 2))
    return np.concatenate([centers - halves, centers + halves], axis=1)[:, [0, 2, 1, 3]]


def overlap(size: int, f: float, c: float, lo: float, hi: float) -> np.ndarray:
    """How much of each of `size` pixels lies between view directions lo and hi seen through focal length f and principal point c, pixel i spanning i - 0.5 to i + 0.5 under ARKit's pixel-center origin."""
    i = np.arange(size)
    return np.clip(np.minimum(i + 0.5, c + f * hi) - np.maximum(i - 0.5, c + f * lo), 0, 1)


def rectangle_cover(instant: int, width: int, height: int, k: np.ndarray) -> np.ndarray:
    """How much of each pixel of a width x height frame with intrinsics k the rectangles at `instant` cover, each laid over those before it."""
    fx, fy, cx, cy = (float(v) for v in k)
    cover = np.zeros((height, width))
    for x0, x1, y0, y1 in rectangles(instant):
        a = np.outer(overlap(height, fy, cy, y0, y1), overlap(width, fx, cx, x0, x1))
        cover = cover + a * (1 - cover)
    return cover


def aligned_members(fattening: int) -> Dict[str, bytes]:
    """The spatial alignment recording's members under <id>/: ALIGNED_PAIRS instants at 30 fps, each with a delivered color frame, its luma bright where the rectangles are, and a delivered depth map, near where they are grown by `fattening` depth px, each rasterized through its own recorded intrinsics."""
    color_lines, depth_lines = [",".join(color_header("rear", MINOR))], [",".join(DEPTH_HEADERS["rear"])]
    frames, maps = [], []
    for instant in range(ALIGNED_PAIRS):
        time = f"{200 + instant / 30:.9f}"
        orient = ["90", "0.01000", "-0.99000", "0.05000", time]
        color_k = aligned_color_intrinsics(instant)
        # Rasterized through these, the depth grid lies on the color image as ARKit's does: first column centers together along x, rows edge to edge along y.
        depth_k = arkit_depth_intrinsics(color_k, ALIGNED_SCALE)
        color_lines.append(",".join([str(instant), time, "", *(f32(v) for v in color_k), *orient, *exposure_lens_arrival(time), "normal", *(f32(v) for v in pose(instant).ravel())]))
        depth_lines.append(",".join([str(instant), time, "", *(f32(v) for v in depth_k), *orient, str(ALIGNED_DEPTH_WIDTH * 4)]))
        luma = np.rint(60 + 140 * rectangle_cover(instant, ALIGNED_COLOR_WIDTH, ALIGNED_COLOR_HEIGHT, color_k))
        assert luma.dtype == np.float64, luma.dtype
        frames.append(np.concatenate([luma.astype(np.uint8), np.full((ALIGNED_COLOR_HEIGHT // 2, ALIGNED_COLOR_WIDTH), 128, np.uint8)]))
        # Inverse depth is blended by coverage like the luma, so a depth edge lies where the color edge does to a fraction of a depth pixel; its grey dilation then moves every edge `fattening` px out of the near region, as real depth maps fatten foreground objects.
        inverse = 1 / FAR_M + (1 / NEAR_M - 1 / FAR_M) * rectangle_cover(instant, ALIGNED_DEPTH_WIDTH, ALIGNED_DEPTH_HEIGHT, depth_k)
        inverse = cv2.dilate(inverse, np.ones((2 * fattening + 1, 2 * fattening + 1), np.uint8))
        assert inverse.dtype == np.float64, inverse.dtype
        maps.append((1 / inverse).astype(np.float32))
    meta = metadata("rear", "ITU_R_709_2", MINOR) | {
        "duration_s": (ALIGNED_PAIRS - 1) / 30,
        "color_width": ALIGNED_COLOR_WIDTH,
        "color_height": ALIGNED_COLOR_HEIGHT,
        "color_bytes_per_frame": ALIGNED_COLOR_WIDTH * ALIGNED_COLOR_HEIGHT * 3 // 2,
        "depth_width": ALIGNED_DEPTH_WIDTH,
        "depth_height": ALIGNED_DEPTH_HEIGHT,
        "depth_bytes_per_frame": ALIGNED_DEPTH_WIDTH * ALIGNED_DEPTH_HEIGHT * 4,
        "color_frames": ALIGNED_PAIRS,
        "depth_frames": ALIGNED_PAIRS,
    }
    return {
        "metadata.json": json.dumps(meta, indent=2, sort_keys=True).encode(),
        "color.bin": np.stack(frames).tobytes(),
        "color.csv": ("\n".join(color_lines) + "\n").encode(),
        "depth.bin": np.stack(maps).tobytes(),
        "depth.csv": ("\n".join(depth_lines) + "\n").encode(),
        "confidence.bin": np.full((ALIGNED_PAIRS, ALIGNED_DEPTH_HEIGHT, ALIGNED_DEPTH_WIDTH), 2, np.uint8).tobytes(),
    }


def pixel_center_intrinsics(depth_row: Dict[str, str]) -> List[float]:
    """The spatial alignment recording's color intrinsics at a depth row's instant carried with the pixel-center origin on both axes, f * s and (c + 0.5) * s - 0.5."""
    k, half = aligned_color_intrinsics(int(depth_row["index"])), np.float32(0.5)
    return [float(v) for v in np.concatenate([k[:2] * ALIGNED_SCALE, (k[2:] + half) * ALIGNED_SCALE - half])]


def plain_intrinsics(depth_row: Dict[str, str]) -> List[float]:
    """The spatial alignment recording's color intrinsics at a depth row's instant scaled plainly on both axes, f * s and c * s."""
    return [float(v) for v in aligned_color_intrinsics(int(depth_row["index"])) * np.tile(ALIGNED_SCALE, 2)]


@pytest.mark.parametrize("matrix", sorted(YCBCR_MATRICES))
@pytest.mark.parametrize("camera", ["front", "rear"])
def test_reader(tmp_path: Path, camera: str, matrix: str) -> None:
    tar_path = synthetic_tar(tmp_path, camera, matrix)
    rec = Recording(tar_path)

    assert len(rec.color_rows) == len(rec.depth_rows) == len(TIMES)
    assert [r["index"] for r in rec.colors] == [r["index"] for r in rec.depths] == ["0", "1", "2", "3"]
    assert rec.format_minor == MINOR and [r["received_ts"] for r in rec.colors] == [exposure_lens_arrival(TIMES[i])[2] for i in delivered(COLOR_DROPPED)]
    with tarfile.open(tar_path) as tar:
        offsets = {Path(m.name).name: m.offset_data for m in tar.getmembers()}
    # Each .bin member is mapped in place inside the tar, never extracted.
    bins = {"color.bin": rec.color, "depth.bin": rec.depth} | ({"confidence.bin": rec.confidence} if camera == "rear" else {})
    for name, mapped in bins.items():
        assert isinstance(mapped, np.memmap) and Path(mapped.filename) == tar_path.resolve() and mapped.offset == offsets[name], name
    assert rec.color.dtype == np.uint8 and rec.color.shape == (FRAMES, COLOR_HEIGHT * 3 // 2, COLOR_WIDTH)
    assert np.array_equal(rec.color, color_frames())
    assert rec.depth.dtype == np.float32 and rec.depth.shape == (FRAMES, DEPTH_HEIGHT, DEPTH_WIDTH)
    assert np.array_equal(rec.depth, depth_maps(), equal_nan=True)
    if camera == "rear":
        assert rec.confidence.dtype == np.uint8 and np.array_equal(rec.confidence, confidence_maps())
        assert rec.calibrations is None
        row = rec.colors[2]
        assert np.allclose(rec.world_from_camera(row), np.vstack([pose(3), [0, 0, 0, 1]]), rtol=0, atol=1e-7)
    else:
        assert rec.confidence is None
        assert [line["index"] for line in rec.calibrations] == [0, 1, 2, 3]
        assert rec.calibrations[3]["timestamp"] == float(rec.depths[3]["timestamp"])

    # Depth instants 0, 1, 2 and 4 are delivered; the color frame at instant 2 was dropped, so instant 4's is color frame 3.
    pairs = rec.pairs()
    assert [(c["index"], d["index"]) for c, d in pairs] == [("0", "0"), ("1", "1"), ("-1", "2"), ("3", "3")]
    assert all(c["timestamp"] == d["timestamp"] for c, d in pairs)

    bgr = rec.color_bgr(0)
    assert bgr.dtype == np.uint8 and bgr.shape == (COLOR_HEIGHT, COLOR_WIDTH, 3)
    first, second = EXPECTED_BGR[matrix]
    assert np.array_equal(bgr[0:2, 0:2], first), bgr[0:2, 0:2].tolist()
    assert np.array_equal(bgr[0:2, 2:4], np.full((2, 2, 3), second)), bgr[0:2, 2:4].tolist()
    frames = list(rec.color_frames())
    assert len(frames) == FRAMES and all(np.array_equal(f, rec.color_bgr(i)) for i, f in enumerate(frames))


@pytest.mark.parametrize("camera", ["front", "rear"])
def test_reader_reads_4_0(tmp_path: Path, camera: str) -> None:
    rec = Recording(write_tar(tmp_path / "recording.tar", recording_id(camera), members(camera, "ITU_R_709_2", 0)))

    # App 4.0 wrote color.csv without the three columns 4.3 added, and everything else as 4.3 does.
    assert rec.meta["format_version"] == "4.0" and rec.format_minor == 0 and "received_ts" not in rec.color_rows[0]
    assert len(rec.color_rows) == len(rec.depth_rows) == len(TIMES)
    assert np.array_equal(rec.color, color_frames()) and np.array_equal(rec.depth, depth_maps(), equal_nan=True)


@pytest.mark.parametrize("change", ["format_version", "extra_member", "missing_member"])
def test_reader_rejects_other_formats(tmp_path: Path, change: str) -> None:
    files = members("rear", "ITU_R_709_2", MINOR)
    if change == "format_version":
        files["metadata.json"] = json.dumps(metadata("rear", "ITU_R_709_2", MINOR) | {"format_version": "3.0"}).encode()
    elif change == "extra_member":
        files["calibration.jsonl"] = calibration_jsonl()
    else:
        del files["confidence.bin"]
    tar_path = write_tar(tmp_path / "recording.tar", recording_id("rear"), files)

    with pytest.raises(AssertionError):
        Recording(tar_path)


@pytest.mark.parametrize("camera", ["front", "rear"])
def test_decode(tmp_path: Path, camera: str) -> None:
    tar_path = synthetic_tar(tmp_path, camera, "ITU_R_709_2")
    out = tmp_path / "decoded"

    summary = decode(tar_path, out)

    rec = Recording(tar_path)
    texts = ["color.csv", "depth.csv", "metadata.json"] + (["calibration.jsonl"] if camera == "front" else [])
    maps = ["depth"] + (["confidence"] if camera == "rear" else [])
    expected = {"decoded.json", *texts, *(f"color/{i:06d}.png" for i in range(FRAMES)), *(f"{m}/{i:06d}.npy" for m in maps for i in range(FRAMES))}
    assert {str(p.relative_to(out)) for p in out.rglob("*") if p.is_file()} == expected
    files = members(camera, "ITU_R_709_2", MINOR)
    for name in texts:
        assert (out / name).read_bytes() == files[name], name
    for i in range(FRAMES):
        assert np.array_equal(cv2.imread(str(out / "color" / f"{i:06d}.png"), cv2.IMREAD_UNCHANGED), rec.color_bgr(i)), i
        assert np.array_equal(np.load(out / "depth" / f"{i:06d}.npy"), depth_maps()[i], equal_nan=True), i
        if camera == "rear":
            assert np.array_equal(np.load(out / "confidence" / f"{i:06d}.npy"), confidence_maps()[i]), i
    assert json.loads((out / "decoded.json").read_text()) == summary
    assert summary["color"]["count"] == summary["depth"]["count"] == FRAMES and summary["copied"] == sorted(texts)


@pytest.mark.parametrize("camera", ["front", "rear"])
def test_inspect(tmp_path: Path, camera: str) -> None:
    checks = inspect(synthetic_tar(tmp_path, camera, "ITU_R_601_4"))

    # The synthetic frames are too few and too small for the two edge alignments, which may fail; every other check holds on a recording laid out as the format says.
    assert {name for name, ok in checks.items() if not ok} <= {ALIGNMENT_CHECK, SPATIAL_ALIGNMENT_CHECK}, checks


def test_spatial_alignment(tmp_path: Path) -> None:
    rec = Recording(write_tar(tmp_path / "aligned.tar", recording_id("rear"), aligned_members(0)))
    fattened_rec = Recording(write_tar(tmp_path / "fattened.tar", recording_id("rear"), aligned_members(1)))

    recorded = spatial_alignment(rec)
    # The pixel-center origin on both axes puts cx_d 0.5 * (1 - sx) = 0.375 depth px before the recorded one, which dx = -0.375 takes back, and leaves cy_d as recorded.
    pixel_center = spatial_alignment(rec, pixel_center_intrinsics)
    # Plain scaling on both axes leaves cx_d as recorded and puts cy_d 0.5 * (1 - sy) = 0.375 depth px past the recorded one, which dy = +0.375 takes back.
    plain = spatial_alignment(rec, plain_intrinsics)
    # A depth focal length 2% too long maps each depth pixel 2% too near the color principal point, which the scale k = 1.02 takes back.
    long_focal = spatial_alignment(rec, lambda d: [1.02 * float(d["fx"]), 1.02 * float(d["fy"]), float(d["cx"]), float(d["cy"])])
    # Near rectangles grown by one depth px move each + edge (far to near) back one px, taken back by d = +1, and each - edge forward one, taken back by d = -1: fattening +1 on both axes and no shift.
    fattened = spatial_alignment(fattened_rec)

    assert recorded["frames"] == ALIGNED_PAIRS and recorded["aligned"], recorded
    assert abs(recorded["k_median"] - 1) <= 0.005 and abs(recorded["dx_median"]) <= 0.15 and abs(recorded["dy_median"]) <= 0.15, recorded
    assert abs(recorded["fattening_x_median"]) <= 0.1 and abs(recorded["fattening_y_median"]) <= 0.1, recorded
    assert abs(pixel_center["dx_median"] + 0.375) <= 0.1 and abs(pixel_center["dy_median"]) <= 0.1 and not pixel_center["aligned"], pixel_center
    assert abs(plain["dx_median"]) <= 0.1 and abs(plain["dy_median"] - 0.375) <= 0.1 and not plain["aligned"], plain
    assert abs(long_focal["k_median"] - 1.02) <= 0.005 and not long_focal["aligned"], long_focal
    assert abs(fattened["dx_median"]) <= 0.1 and abs(fattened["dy_median"]) <= 0.1, fattened
    assert abs(fattened["fattening_x_median"] - 1) <= 0.2 and abs(fattened["fattening_y_median"] - 1) <= 0.2, fattened

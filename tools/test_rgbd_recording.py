"""Tests the format_version 7 tools on tiny synthetic front and rear recordings laid out exactly as the app archives them: the reader's tables, its frames memory-mapped inside the tar, the rear poses and the YCbCr to BGR conversion against values worked out by hand, decode_recording's output files, and that inspect_recording runs with every check passing but the edge alignment, which needs real images.

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
from inspect_recording import inspect
from rgbd_recording import COLOR_HEADERS, DEPTH_HEADERS, YCBCR_MATRICES, Recording

COLOR_WIDTH, COLOR_HEIGHT = 8, 6
DEPTH_WIDTH, DEPTH_HEIGHT = 4, 3
# The front calibration's reference dimensions, so its depth scale (1/4) differs from the rear's color-to-depth scale (1/2).
REFERENCE_WIDTH, REFERENCE_HEIGHT = 16, 12
# Five capture instants at 30 fps, each with a color row and a depth row; color row 2 and depth row 3 are dropped, so each stream delivers FRAMES frames.
TIMES = [f"{100 + i / 30:.9f}" for i in range(5)]
COLOR_DROPPED = {2: "writer_busy"}
DEPTH_DROPPED = {"front": {3: "late_data"}, "rear": {3: "no_scene_depth"}}
FRAMES = 4
ALIGNMENT_CHECK = "depth aligns best with its same-instant color frame"

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


def depth_intrinsics(camera: str, instant: int) -> np.ndarray:
    """fx, fy, cx, cy of the depth map at `instant` as the app computes them in Float32: the rear's color intrinsics carried with the pixel-center origin, the front's calibration scaled with the corner origin."""
    if camera == "rear":
        s = np.array([DEPTH_WIDTH, DEPTH_HEIGHT], np.float32) / np.array([COLOR_WIDTH, COLOR_HEIGHT], np.float32)
        k, half = color_intrinsics(instant), np.float32(0.5)
        return np.concatenate([k[:2] * s, (k[2:] + half) * s - half])
    s = np.array([DEPTH_WIDTH, DEPTH_HEIGHT], np.float32) / np.array([REFERENCE_WIDTH, REFERENCE_HEIGHT], np.float32)
    return calibration_intrinsics(instant) * np.concatenate([s, s])


def orientation(instant: int) -> List[str]:
    return ["90", "0.01000", "-0.99000", "0.05000", f"{float(TIMES[instant]) - 0.001:.9f}"]


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


def color_csv(camera: str) -> bytes:
    cells = {}
    for instant in delivered(COLOR_DROPPED):
        cells[instant] = [f32(v) for v in color_intrinsics(instant)] + orientation(instant)
        if camera == "rear":
            cells[instant] += ["limited_initializing" if instant == 0 else "normal"] + [f32(v) for v in pose(instant).ravel()]
    return table(COLOR_HEADERS[camera], COLOR_DROPPED, cells)


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


def metadata(camera: str, matrix: str) -> Dict:
    meta = {
        "format_version": 7,
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
    else:
        meta.update({"calibration_description": "synthetic", "available_depth_formats": ["640x480 fdep"]})
    return meta


def members(camera: str, matrix: str) -> Dict[str, bytes]:
    """Each archive member's name under <id>/ with its bytes."""
    files = {
        "metadata.json": json.dumps(metadata(camera, matrix), indent=2, sort_keys=True).encode(),
        "color.bin": color_frames().tobytes(),
        "color.csv": color_csv(camera),
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
    return write_tar(folder / f"{recording_id(camera)}.tar", recording_id(camera), members(camera, matrix))


@pytest.mark.parametrize("matrix", sorted(YCBCR_MATRICES))
@pytest.mark.parametrize("camera", ["front", "rear"])
def test_reader(tmp_path: Path, camera: str, matrix: str) -> None:
    tar_path = synthetic_tar(tmp_path, camera, matrix)
    rec = Recording(tar_path)

    assert len(rec.color_rows) == len(rec.depth_rows) == len(TIMES)
    assert [r["index"] for r in rec.colors] == [r["index"] for r in rec.depths] == ["0", "1", "2", "3"]
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


@pytest.mark.parametrize("change", ["format_version", "extra_member", "missing_member"])
def test_reader_rejects_other_formats(tmp_path: Path, change: str) -> None:
    files = members("rear", "ITU_R_709_2")
    if change == "format_version":
        files["metadata.json"] = json.dumps(metadata("rear", "ITU_R_709_2") | {"format_version": 5}).encode()
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
    files = members(camera, "ITU_R_709_2")
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

    # The synthetic frames are too few and too small for the edge alignment, which may fail; every other check holds on a recording laid out as the format says.
    assert {name for name, ok in checks.items() if not ok} <= {ALIGNMENT_CHECK}, checks

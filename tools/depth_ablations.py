"""Measures, on a front-camera recording, what each step of an earlier app's depth pipeline loses: builds each variant of the recording's depth maps, aligned frame by frame with depth.bin's raw Float32 maps in the sensor's orientation, and reports its metrics against them.

Variants:
  raw                  depth.bin as delivered
  float16              raw cast to Float16 metres (the earlier app's lossless face.depth)
  8bit_lossless        raw quantized as the phone quantizes it, code = trunc(min(max(z / range_m, 0), 1) * 255) in Float32 with NaN and z <= 0 -> 0, decoded as code / 255 * range_m, 0 meaning no reading
  8bit_h264_<track>    each of the phone's 8-bit H.264 tracks (metadata.json's depth8_h264), decoded the same way
  padding_misread      raw read depth_width floats apart from the start of each delivered buffer, its rows bytes_per_row apart, the padding read as 0 (no reading); only when the phone padded a row

Metrics, over all frames, a pixel being valid when finite and > 0: the valid fraction; invalid introduced, the fraction of raw-valid pixels the variant loses; valid introduced, the fraction of raw-invalid pixels it gives a reading; the mean and median absolute error in mm on pixels valid in both; the same errors on those pixels near a depth edge, within EDGE_RADIUS px of a raw jump over EDGE_JUMP_M between 4-neighbours or of a raw valid/invalid boundary.

Usage: python tools/depth_ablations.py <front recording.tar> [--out <dir>]   (--out saves each variant as <dir>/<variant>.npy, frames x depth_height x depth_width Float32 metres)
"""

import argparse
import tempfile
from pathlib import Path
from typing import Dict, Iterator, Tuple

import cv2
import numpy as np

from rgbd_recording import SAME_INSTANT_S, Recording, valid

EDGE_JUMP_M = 0.05
EDGE_RADIUS = 2


def quantized(raw: np.ndarray, range_m: float) -> np.ndarray:
    """The phone's 8-bit quantization of raw metres, decoded back to metres."""
    def _validate_inputs() -> None:
        assert raw.dtype == np.float32, raw.dtype
        assert range_m > 0, range_m

    _validate_inputs()

    q = np.clip(raw / np.float32(range_m), np.float32(0), np.float32(1)) * np.float32(255)
    codes = np.where(np.isnan(q) | (raw <= 0), np.float32(0), q).astype(np.uint8)
    return codes.astype(np.float32) / np.float32(255) * np.float32(range_m)


def padding_misread(raw: np.ndarray, bytes_per_row: np.ndarray) -> np.ndarray:
    """Each map read depth_width floats apart from the start of a buffer whose rows are its bytes_per_row apart, padding read as 0."""
    def _validate_inputs() -> None:
        assert raw.dtype == np.float32 and raw.ndim == 3, (raw.dtype, raw.shape)
        assert bytes_per_row.shape == (raw.shape[0],), (bytes_per_row.shape, raw.shape)
        assert np.all(bytes_per_row % 4 == 0) and np.all(bytes_per_row >= raw.shape[2] * 4), bytes_per_row

    _validate_inputs()

    n, h, w = raw.shape
    out = np.empty_like(raw)
    flat = np.arange(h * w)
    for i in range(n):
        stride = int(bytes_per_row[i]) // 4
        row, col = flat // stride, flat % stride
        inside = col < w
        frame = np.zeros(h * w, np.float32)
        frame[inside] = raw[i][row[inside], col[inside]]
        out[i] = frame.reshape(h, w)
    return out


def edges(raw: np.ndarray) -> np.ndarray:
    """Pixels within EDGE_RADIUS px of a raw depth jump over EDGE_JUMP_M between 4-neighbours, or of a valid/invalid boundary."""
    ok = valid(raw)
    z = np.where(ok, raw, 0)
    seed = np.zeros(raw.shape, bool)
    for axis in (1, 2):
        jump = (np.abs(np.diff(z, axis=axis)) > EDGE_JUMP_M) | (np.diff(ok.astype(np.int8), axis=axis) != 0)
        lo = [slice(None)] * 3
        hi = [slice(None)] * 3
        lo[axis], hi[axis] = slice(0, -1), slice(1, None)
        seed[tuple(lo)] |= jump
        seed[tuple(hi)] |= jump
    kernel = np.ones((2 * EDGE_RADIUS + 1, 2 * EDGE_RADIUS + 1), np.uint8)
    return np.stack([cv2.dilate(s.astype(np.uint8), kernel) > 0 for s in seed])


def metrics(variant: np.ndarray, raw: np.ndarray, near_edge: np.ndarray) -> Dict[str, float]:
    """The variant's metrics against raw."""
    def _validate_inputs() -> None:
        assert variant.dtype == np.float32 and variant.shape == raw.shape, (variant.dtype, variant.shape, raw.shape)
        assert near_edge.dtype == bool and near_edge.shape == raw.shape, (near_edge.dtype, near_edge.shape)

    _validate_inputs()

    ok_raw, ok = valid(raw), valid(variant)
    both = ok_raw & ok
    err_mm = np.abs(variant - raw) * 1000
    return {
        "valid_%": float(ok.mean() * 100),
        "invalid_introduced_%": float((ok_raw & ~ok).sum() / ok_raw.sum() * 100),
        "valid_introduced_%": float((~ok_raw & ok).sum() / (~ok_raw).sum() * 100),
        "mean_abs_mm": float(err_mm[both].mean()),
        "median_abs_mm": float(np.median(err_mm[both])),
        "edge_mean_abs_mm": float(err_mm[both & near_edge].mean()),
        "edge_median_abs_mm": float(np.median(err_mm[both & near_edge])),
    }


def variants(rec: Recording) -> Iterator[Tuple[str, np.ndarray]]:
    """Each variant's maps, Float32 metres aligned with rec.depth, one variant at a time; padding_misread only when a row was padded."""
    raw = rec.depth
    spec = rec.meta["depth8_h264"]
    yield "raw", raw
    yield "float16", raw.astype(np.float16).astype(np.float32)
    yield "8bit_lossless", quantized(raw, spec["range_m"])
    depth_ts = np.array([float(r["timestamp"]) for r in rec.depths])
    for track in spec["tracks"]:
        codes, times = rec.depth8_track(track["file"])
        assert codes.shape == (len(rec.depths), track["encoded_height"], track["encoded_width"]), (track["file"], codes.shape)
        assert np.all(np.abs(times - (depth_ts - depth_ts[0])) < SAME_INSTANT_S), f"{track['file']}: frames are not at depth.csv's times"
        yield Path(track["file"]).stem.replace("depth8_h264_", "8bit_h264_"), rec.depth8_metres(codes)
    bytes_per_row = np.array([int(r["bytes_per_row"]) for r in rec.depths])
    if np.any(bytes_per_row > raw.shape[2] * 4):
        yield "padding_misread", padding_misread(raw, bytes_per_row)
    else:
        print(f"padding_misread: phone does not pad rows (bytes_per_row {sorted(set(bytes_per_row.tolist()))} = depth_width * 4): variant identical to raw")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tar", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        rec = Recording(args.tar, Path(tmp))
        assert rec.meta["depth_source"] == "avfoundation_truedepth", rec.meta["depth_source"]
        assert rec.meta["depth_pixel_format"] == "fdep", rec.meta["depth_pixel_format"]
        assert rec.meta["depth8_h264_error"] is None, rec.meta["depth8_h264_error"]
        if args.out is not None:
            args.out.mkdir(parents=True, exist_ok=True)
        near_edge = edges(rec.depth)
        print(f"{rec.meta['id']}: {rec.depth.shape[0]} frames {rec.depth.shape[2]}x{rec.depth.shape[1]}, depth_filtering_enabled={rec.meta['depth_filtering_enabled']}, {near_edge.mean() * 100:.1f}% of pixels near a depth edge")
        # ponytail: each variant is held whole in memory with its error map, about 3x depth.bin's size; stream frame by frame if recordings outgrow RAM.
        rows: Dict[str, Dict[str, float]] = {}
        for name, v in variants(rec):
            rows[name] = metrics(v, rec.depth, near_edge)
            if args.out is not None:
                np.save(args.out / f"{name}.npy", v)
        keys = list(rows["raw"])
        print(f"{'variant':<28}" + "".join(f"{k:>21}" for k in keys))
        for name, m in rows.items():
            print(f"{name:<28}" + "".join(f"{m[k]:>21.3f}" for k in keys))


if __name__ == "__main__":
    main()

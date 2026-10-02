"""Checks an RGBD Scanner recording (.tar, format_version 7) and prints its statistics, then each check as PASS or FAIL.

Usage: python tools/inspect_recording.py <recording.tar>
"""

import argparse
from collections import Counter
from pathlib import Path
from typing import Dict, List

import cv2
import numpy as np

from rgbd_recording import HIGH_CONFIDENCE, INTRINSICS, ORIENTATION, POSE, SAME_INSTANT_S, Recording, valid, ycbcr_planes

TRACKING_STATES = {"normal", "not_available", "limited_initializing", "limited_excessive_motion", "limited_insufficient_features", "limited_relocalizing"}
# How far a Float32 intrinsic recomputed here may differ from the app's: a few units in the last place, far below the 0.43 depth px that the wrong origin convention moves cx, cy.
FLOAT32_RTOL = 4 * float(np.finfo(np.float32).eps)
# A Float32 rotation is orthonormal, with determinant +1, up to rounding.
ROTATION_TOL = 1e-4


def luma_gradient(rec: Recording, index: int) -> np.ndarray:
    """Color frame `index`'s luma resized to the depth map's size, its gradient magnitude scaled to mean 1."""
    luma, _ = ycbcr_planes(rec.color[index])
    small = cv2.resize(luma, (rec.depth.shape[2], rec.depth.shape[1]), interpolation=cv2.INTER_AREA)
    assert small.dtype == np.uint8, small.dtype
    g = small.astype(np.float32)
    grad = cv2.magnitude(cv2.Sobel(g, cv2.CV_32F, 1, 0), cv2.Sobel(g, cv2.CV_32F, 0, 1))
    return grad / grad.mean()


def alignment_offset(rec: Recording, grads: List[np.ndarray]) -> Dict[int, float]:
    """For each timestamp pair, how strongly the depth map's edges sit on color edges of the color frame `offset` frames away; the true pairing scores highest at offset 0."""
    scores: Dict[int, List[float]] = {o: [] for o in range(-3, 4)}
    for c, d in rec.pairs():
        if c["index"] == "-1":
            continue
        ci = int(c["index"])
        if ci < 3 or ci + 3 >= len(grads) or np.abs(grads[ci + 1] - grads[ci - 1]).mean() < 0.15:
            continue
        z = np.nan_to_num(rec.depth[int(d["index"])])
        log_z = np.log(np.clip(z, 0.1, 10))
        edges = cv2.Canny((np.clip((log_z - log_z.min()) / (np.ptp(log_z) + 1e-6), 0, 1) * 255).astype(np.uint8), 40, 120) > 0
        edges = cv2.dilate((edges & (z > 0)).astype(np.uint8), None) > 0
        if edges.sum() < 200:
            continue
        for o in scores:
            scores[o].append(float(grads[ci + o][edges].mean()))
    return {o: float(np.mean(v)) if v else float("nan") for o, v in scores.items()}


def carried_to_depth(rec: Recording) -> bool:
    """Whether every delivered depth row with a delivered same-instant color row, and there is one, has that row's intrinsics carried to the depth map with ARKit's pixel-center origin, f * s and (c + 0.5) * s - 0.5 with s = depth size / color size, computed in Float32 as the app does."""
    meta = rec.meta
    pairs = [(c, d) for c, d in rec.pairs() if c["index"] != "-1"]
    if not pairs:
        return False
    s = np.array([meta["depth_width"], meta["depth_height"]], np.float32) / np.array([meta["color_width"], meta["color_height"]], np.float32)
    half = np.float32(0.5)
    color = np.array([[float(c[k]) for k in INTRINSICS] for c, _ in pairs], np.float32)
    depth = np.array([[float(d[k]) for k in INTRINSICS] for _, d in pairs], np.float32)
    carried = np.concatenate([color[:, :2] * s, (color[:, 2:] + half) * s - half], axis=1)
    return bool(np.allclose(depth, carried, rtol=FLOAT32_RTOL, atol=0))


def scaled_to_depth(rec: Recording) -> bool:
    """Whether every delivered depth row has its calibration.jsonl line's intrinsic matrix scaled from the reference dimensions to the depth map with Apple's corner origin, f * s and c * s, computed in Float32 as the app does."""
    meta = rec.meta
    calibrations = [line["calibration"] for line in rec.calibrations]
    if any(cal is None for cal in calibrations):
        return False
    k = np.array([[cal["intrinsic_matrix_row_major"][r][c] for r, c in ((0, 0), (1, 1), (0, 2), (1, 2))] for cal in calibrations], np.float32)
    reference = np.array([[cal["intrinsic_reference_width"], cal["intrinsic_reference_height"]] for cal in calibrations], np.float32)
    s = np.array([meta["depth_width"], meta["depth_height"]], np.float32) / reference
    depth = np.array([[float(d[key]) for key in INTRINSICS] for d in rec.depths], np.float32)
    return bool(np.allclose(depth, k * np.concatenate([s, s], axis=1), rtol=FLOAT32_RTOL, atol=0))


def is_pose(rec: Recording, row: Dict[str, str]) -> bool:
    """Whether a delivered rear color row has a known tracking state and a world_from_camera whose rotation is orthonormal with determinant +1."""
    if row["tracking_state"] not in TRACKING_STATES or not all(row[k] for k in POSE):
        return False
    rotation = rec.world_from_camera(row)[:3, :3]
    return bool(np.allclose(rotation @ rotation.T, np.eye(3), rtol=0, atol=ROTATION_TOL)) and abs(np.linalg.det(rotation) - 1) < ROTATION_TOL


def depth_range(depth: np.ndarray) -> str:
    """The range of the depth readings, in metres."""
    assert depth.ndim == 1 and depth.size > 0, depth.shape
    return "min {:.3f} p1 {:.3f} median {:.3f} p99 {:.3f} max {:.3f} m ({} readings)".format(depth.min(), *np.percentile(depth, [1, 50, 99]), depth.max(), depth.size)


def dropped(rows: List[Dict[str, str]]) -> str:
    """How many rows were dropped, by reason."""
    counts = Counter(r["dropped"] for r in rows if r["index"] == "-1")
    return f"{sum(counts.values())} (" + ", ".join(f"{reason} {n}" for reason, n in sorted(counts.items())) + ")"


def fx_range(rows: List[Dict[str, str]]) -> str:
    """The range of fx over the rows that have intrinsics."""
    fx = [float(r["fx"]) for r in rows if r["fx"]]
    return f"{min(fx):.3f}..{max(fx):.3f} px over {len(fx)} frames" if fx else "no frame has intrinsics"


def inspect(tar_path: Path) -> Dict[str, bool]:
    """Prints a recording's statistics and each check as PASS or FAIL, and returns the checks."""
    rec = Recording(tar_path)
    meta = rec.meta
    rear = meta["camera"] == "rear"
    h, w = rec.depth.shape[1:]
    grads = [luma_gradient(rec, i) for i in range(rec.color.shape[0])]

    color_ts = np.array([float(r["timestamp"]) for r in rec.colors])
    depth_ts = np.array([float(r["timestamp"]) for r in rec.depths])
    pairs = rec.pairs()
    pairs_with_color = sum(c["index"] != "-1" for c, _ in pairs)
    # Color and depth are independent streams: depth from before the first or after the last color row is kept, and pairs with no color row.
    color_span = (min(float(r["timestamp"]) for r in rec.color_rows), max(float(r["timestamp"]) for r in rec.color_rows))
    depth_in_span = [d for d in rec.depths if color_span[0] <= float(d["timestamp"]) <= color_span[1]]
    paired_in_span = sum(color_span[0] <= float(d["timestamp"]) <= color_span[1] for _, d in pairs)
    is_valid = valid(rec.depth)
    gravity = np.array([[float(r[k]) for k in ("gravity_x", "gravity_y", "gravity_z")] for r in rec.colors if r["gravity_x"]])
    offsets = alignment_offset(rec, grads)
    best_offset = max(offsets, key=lambda o: offsets[o])
    coverage = is_valid.mean(axis=(1, 2)) * 100

    print(f"device {meta['device_model']} iOS {meta['system_version']} camera {meta['camera']} depth source {meta['depth_source']} focus {meta['focus']}")
    print(f"color {meta['color_width']}x{meta['color_height']} {meta['color_pixel_format']} {meta['color_ycbcr_matrix']}, depth {w}x{h} {meta['depth_pixel_format']}, filtering_enabled={meta['depth_filtering_enabled']}")
    print(f"configured {meta['frame_rate']:.2f} fps; color {len(rec.colors)} frames at {(len(color_ts) - 1) / (color_ts[-1] - color_ts[0]):.2f} fps; depth {len(rec.depths)} frames at {(len(depth_ts) - 1) / (depth_ts[-1] - depth_ts[0]):.2f} fps")
    print(f"dropped: color {dropped(rec.color_rows)}, depth {dropped(rec.depth_rows)}")
    print(f"depth frames with a color.csv row at the same instant: {len(pairs)}, of which with a delivered color frame: {pairs_with_color}")
    print(f"depth frames outside the color stream's time span: {len(rec.depths) - len(depth_in_span)}")
    print(f"upright rotations used: {sorted({r['upright_rotation_deg'] for r in rec.colors})}; |gravity| mean {np.linalg.norm(gravity, axis=1).mean():.3f} g")
    print(f"fx: color {fx_range(rec.colors)}, depth {fx_range(rec.depths)}")
    print("depth valid % per frame: min {:.1f} p5 {:.1f} p25 {:.1f} median {:.1f} p75 {:.1f} p95 {:.1f} max {:.1f}".format(coverage.min(), *np.percentile(coverage, [5, 25, 50, 75, 95]), coverage.max()))
    print("depth range: " + depth_range(rec.depth[is_valid]))
    if rear:
        print("depth range, high-confidence pixels only: " + depth_range(rec.depth[is_valid & (rec.confidence == HIGH_CONFIDENCE)]))
        print("confidence of valid pixels: " + " ".join(f"{level}:{(rec.confidence[is_valid] == level).mean() * 100:.1f}%" for level in range(3)))
        states = Counter(r["tracking_state"] for r in rec.colors)
        print("tracking state of color frames: " + " ".join(f"{state}:{n / len(rec.colors) * 100:.1f}%" for state, n in sorted(states.items())))
    bytes_per_row = sorted({int(r["bytes_per_row"]) for r in rec.depths})
    print(f"depth map bytes per row: {bytes_per_row} (packed: {w * meta['depth_bytes_per_pixel']})")
    print("edge alignment of depth to color frame at offset: " + " ".join(f"{o:+d}:{s:.3f}" for o, s in offsets.items()))

    has_intrinsics = all(r[k] for r in rec.colors + rec.depths for k in INTRINSICS)
    checks = {
        "color.bin holds color_frames frames, one per color.csv row with an index": rec.color.shape[0] == len(rec.colors) == meta["color_frames"],
        "depth.bin holds depth_frames maps, one per depth.csv row with an index": rec.depth.shape[0] == len(rec.depths) == meta["depth_frames"],
        "indices are 0..n-1": [int(r["index"]) for r in rec.colors] == list(range(len(rec.colors))) and [int(r["index"]) for r in rec.depths] == list(range(len(rec.depths))),
        "timestamps strictly increasing": bool(np.all(np.diff(color_ts) > 0) and np.all(np.diff(depth_ts) > 0)),
        "every depth frame within the color stream's time span has a color.csv row (delivered or dropped) at the same instant": paired_in_span == len(depth_in_span),
        "depth aligns best with its same-instant color frame": best_offset == 0,
        "metadata's depth_filtering_enabled is false": meta["depth_filtering_enabled"] is False,
    }
    if not rear:
        checks["every depth map unfiltered"] = all(r["filtered"] == "0" for r in rec.depths)
    checks["every color and depth frame has intrinsics"] = has_intrinsics
    if rear:
        checks["every depth frame's intrinsics are its same-instant color frame's carried to the depth map, f * s and (c + 0.5) * s - 0.5"] = has_intrinsics and carried_to_depth(rec)
    else:
        lines_match = len(rec.calibrations) == len(rec.depths) and all(line["index"] == int(d["index"]) and abs(line["timestamp"] - float(d["timestamp"])) < SAME_INSTANT_S for line, d in zip(rec.calibrations, rec.depths, strict=True))
        checks["calibration.jsonl has one line per depth frame, with its index and timestamp"] = lines_match
        checks["every depth frame's intrinsics are its calibration's scaled to the depth map, f * s and c * s"] = lines_match and has_intrinsics and scaled_to_depth(rec)
    checks["every depth map has its bytes per row, at least a packed row"] = all(r["bytes_per_row"] and int(r["bytes_per_row"]) >= w * meta["depth_bytes_per_pixel"] for r in rec.depths) and all(r["bytes_per_row"] == "" for r in rec.depth_rows if r["index"] == "-1")
    checks["every frame has orientation and gravity"] = all(r[k] for r in rec.colors + rec.depths for k in ORIENTATION)
    if rear:
        checks["every color frame has a tracking state and a world_from_camera with an orthonormal rotation of determinant +1"] = all(is_pose(rec, r) for r in rec.colors)
        checks["confidence.bin holds one map per depth map, each level 0, 1 or 2"] = rec.confidence.shape == rec.depth.shape and bool(np.all(rec.confidence <= HIGH_CONFIDENCE))
    checks["metadata has a name and a duration"] = all(k in meta for k in ("name", "named_by_user", "duration_s")) and bool(meta["name"]) and meta["duration_s"] > 0
    for name, ok in checks.items():
        print(f"[{'PASS' if ok else 'FAIL'}] {name}")
    return checks


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tar", type=Path)
    args = parser.parse_args()
    inspect(args.tar)


if __name__ == "__main__":
    main()

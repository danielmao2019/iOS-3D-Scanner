"""Checks an RGBD Scanner recording (.tar, format_version "4.0" or "4.1") and prints its statistics, then each check as PASS or FAIL.

Usage: python tools/inspect_recording.py <recording.tar>
"""

import argparse
from collections import Counter
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple, Union

import cv2
import numpy as np

from rgbd_recording import HIGH_CONFIDENCE, INTRINSICS, ORIENTATION, POSE, SAME_INSTANT_S, Recording, valid, ycbcr_planes

TRACKING_STATES = {"normal", "not_available", "limited_initializing", "limited_excessive_motion", "limited_insufficient_features", "limited_relocalizing"}
# How far a Float32 intrinsic recomputed here may differ from the app's: a few units in the last place, far below the 0.43 depth px that the wrong origin convention moves cx, cy.
FLOAT32_RTOL = 4 * float(np.finfo(np.float32).eps)
# A Float32 rotation is orthonormal, with determinant +1, up to rounding.
ROTATION_TOL = 1e-4
# The spatial alignment compares depth edges with color edges over at most ALIGNMENT_FRAMES evenly spaced same-instant pairs whose depth maps are at least ALIGNMENT_MIN_VALID valid, leaving out depth pixels within INVALID_MARGIN px of an invalid pixel or BORDER px of the map's edge.
ALIGNMENT_FRAMES = 40
ALIGNMENT_MIN_VALID = 0.3
INVALID_MARGIN = 2
BORDER = 4
# It searches the residual scale k about the color principal point on unsigned edges at zero shift; at that k, each depth edge polarity's shift in depth px against the color gradient along its axis, on a coarse grid and then a fine one around the coarse best; then k again with each polarity at its shift, and the shifts again at that k.
SCALES = np.linspace(0.95, 1.05, 41)
SHIFT_MAX = 1.5
COARSE_SHIFTS = np.linspace(-SHIFT_MAX, SHIFT_MAX, 13)
FINE_STEPS = np.linspace(-0.25, 0.25, 11)
# Each depth edge polarity with its axis and sign: + where inverse depth rises along the axis (far to near), - where it falls, so a fattened near object moves its + edges back and its - edges forward.
POLARITIES = {"x+": ("x", 1), "x-": ("x", -1), "y+": ("y", 1), "y-": ("y", -1)}
# The 95% interval of the median shifts over frames is bootstrapped from this many resamples, seeded.
BOOTSTRAP_RESAMPLES = 1000
BOOTSTRAP_SEED = 0
# Depth lands on color when, over at least ALIGNMENT_MIN_FRAMES frames, the median k is within SCALE_TOL of 1 and the median dx and dy within SHIFT_TOL depth px.
ALIGNMENT_MIN_FRAMES = 10
SCALE_TOL = 0.005
SHIFT_TOL = 0.15
# The intrinsics coordinate of pixel (0, 0)'s center for each camera: ARKit's origin is that center, Apple's AVFoundation origin the frame's upper-left corner, half a pixel before it.
PIXEL_CENTER = {"front": 0.5, "rear": 0.0}


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


def row_intrinsics(row: Dict[str, str]) -> List[float]:
    """A table row's recorded fx, fy, cx, cy."""
    return [float(row[k]) for k in INTRINSICS]


def depth_gradients(depth: np.ndarray) -> Tuple[Dict[str, np.ndarray], np.ndarray]:
    """A depth map's Sobel gradient of inverse depth along x and y, with the mask of its valid pixels at least INVALID_MARGIN px from an invalid pixel and BORDER px from the map's edge."""
    ok = valid(depth)
    inverse = np.zeros(depth.shape, np.float32)
    inverse[ok] = 1 / depth[ok]
    gradients = {"x": cv2.Sobel(inverse, cv2.CV_32F, 1, 0), "y": cv2.Sobel(inverse, cv2.CV_32F, 0, 1)}
    assert ok.dtype == np.bool_, ok.dtype
    side = 2 * INVALID_MARGIN + 1
    # cv2.erode takes the pixels beyond the map as valid, so only invalid pixels shrink the mask; the border is cut next.
    mask = cv2.erode(ok.astype(np.uint8), np.ones((side, side), np.uint8)) > 0
    mask[:BORDER] = False
    mask[-BORDER:] = False
    mask[:, :BORDER] = False
    mask[:, -BORDER:] = False
    return gradients, mask


def luma_gradients(rec: Recording, index: int, sigma: float) -> Dict[str, np.ndarray]:
    """Color frame `index`'s luma, Gaussian-blurred by sigma color px, as its Sobel gradient along x and y at full resolution."""
    luma, _ = ycbcr_planes(rec.color[index])
    assert luma.dtype == np.uint8, luma.dtype
    blurred = cv2.GaussianBlur(luma.astype(np.float32), (0, 0), sigma)
    return {"x": cv2.Sobel(blurred, cv2.CV_32F, 1, 0), "y": cv2.Sobel(blurred, cv2.CV_32F, 0, 1)}


def fit_alignment(depth_g: Dict[str, np.ndarray], mask: np.ndarray, color_g: Dict[str, np.ndarray], color_k: List[float], depth_k: List[float], origin: float) -> Tuple[float, float, float, float, float, float]:
    """The residual scale k, shift (dx, dy) and fattening (fattening_x, fattening_y) in depth px that carry the depth edges best onto the color edges, u_c = cx_c + k (u_d + d - cx_d) fx_c / fx_d and v_c = cy_c + k (v_d + d - cy_d) fy_c / fy_d in intrinsics coordinates (pixel index + origin) with d fitted per depth edge polarity, an axis' shift the mean of its two polarities' d and its fattening half their difference, and the polarities' mean normalized correlation over the mask."""
    fx_c, fy_c, cx_c, cy_c = color_k
    fx_d, fy_d, cx_d, cy_d = depth_k
    rows, cols = np.indices(mask.shape, dtype=np.float64)
    # Each depth pixel's intrinsics coordinates about the depth principal point.
    du, dv = cols + origin - cx_d, rows + origin - cy_d

    def color_pixels(k: float, dx: float, dy: float) -> Tuple[np.ndarray, np.ndarray]:
        x = cx_c - origin + k * (du + dx) * fx_c / fx_d
        y = cy_c - origin + k * (dv + dy) * fy_c / fy_d
        assert x.dtype == y.dtype == np.float64, (x.dtype, y.dtype)
        return x.astype(np.float32), y.astype(np.float32)

    # Only pixels that map inside the color frame at every scale and shift searched are compared, so each candidate is scored on the same pixels; k = SCALES[-1] at either extreme shift bounds them, the principal point being inside the frame.
    height, width = color_g["x"].shape
    for shift in (-SHIFT_MAX, SHIFT_MAX):
        x, y = color_pixels(SCALES[-1], shift, shift)
        mask = mask & (x >= 0) & (x <= width - 1) & (y >= 0) & (y <= height - 1)
    assert mask.any(), "no depth pixel maps inside the color frame at every scale and shift searched"

    def standardized(edges: np.ndarray) -> np.ndarray:
        assert edges.dtype == np.float32, edges.dtype
        values = edges[mask].astype(np.float64)
        return (values - values.mean()) / values.std()

    def correlation(target: np.ndarray, color: np.ndarray, k: float, dx: float, dy: float) -> float:
        samples = cv2.remap(color, *color_pixels(k, dx, dy), cv2.INTER_LINEAR)[mask]
        assert samples.dtype == np.float32, samples.dtype
        samples = samples.astype(np.float64)
        return target @ (samples - samples.mean()) / (target.size * samples.std())

    def best(score: Callable[[float], float], candidates: np.ndarray) -> Tuple[float, float]:
        return max((score(c), c) for c in candidates)

    magnitude = standardized(cv2.magnitude(depth_g["x"], depth_g["y"]))
    color_magnitude = cv2.magnitude(color_g["x"], color_g["y"])
    # Each polarity's depth edges, the positive part of its signed gradient, are compared with the unsigned color gradient along its axis.
    targets = {name: standardized(np.maximum(sign * depth_g[axis], 0)) for name, (axis, sign) in POLARITIES.items()}
    color_abs = {axis: np.abs(g) for axis, g in color_g.items()}

    def polarity_correlation(name: str, k: float, shift: float) -> float:
        axis, _ = POLARITIES[name]
        dx, dy = (shift, 0.0) if axis == "x" else (0.0, shift)
        return correlation(targets[name], color_abs[axis], k, dx, dy)

    def fit_shift(name: str, k: float) -> Tuple[float, float]:
        _, coarse = best(lambda s: polarity_correlation(name, k, s), COARSE_SHIFTS)
        return best(lambda s: polarity_correlation(name, k, s), np.clip(coarse + FINE_STEPS, -SHIFT_MAX, SHIFT_MAX))

    _, k = best(lambda s: correlation(magnitude, color_magnitude, s, 0.0, 0.0), SCALES)
    shifts = {name: fit_shift(name, k)[1] for name in POLARITIES}
    # Fattening moves an axis' two polarities oppositely, which pulls a k fitted on all edges at one shift; k is fitted again with each polarity at its own shift.
    _, k = best(lambda s: sum(polarity_correlation(name, s, shifts[name]) for name in POLARITIES), SCALES)
    fits = {name: fit_shift(name, k) for name in POLARITIES}
    d = {name: shift for name, (_, shift) in fits.items()}
    corr = np.mean([score for score, _ in fits.values()])
    return k, (d["x+"] + d["x-"]) / 2, (d["y+"] + d["y-"]) / 2, (d["x+"] - d["x-"]) / 2, (d["y+"] - d["y-"]) / 2, corr


def median_interval(values: np.ndarray) -> Tuple[float, float]:
    """The 95% bootstrap interval of the values' median, from BOOTSTRAP_RESAMPLES resamples with replacement drawn with BOOTSTRAP_SEED."""
    resamples = np.random.default_rng(BOOTSTRAP_SEED).integers(0, len(values), (BOOTSTRAP_RESAMPLES, len(values)))
    low, high = np.percentile(np.median(values[resamples], axis=1), [2.5, 97.5])
    return low, high


def spatial_alignment(rec: Recording, intrinsics_override: Optional[Callable[[Dict[str, str]], List[float]]] = None) -> Dict[str, Union[bool, int, float, Tuple[float, float]]]:
    """How well depth edges land on the same-instant color frame's edges when each depth pixel is mapped into the color frame through the two rows' intrinsics (`intrinsics_override(depth row)` in place of the depth row's, when given), from the residual scale k, shift and fattening fitted per pair over up to ALIGNMENT_FRAMES evenly spaced pairs: frames, k_median, k_iqr, dx_median, dy_median, their 95% bootstrap intervals dx_median_ci95 and dy_median_ci95, fattening_x_median, fattening_y_median (depth px), corr_median, and aligned, whether they pass."""
    depth_intrinsics = intrinsics_override or row_intrinsics
    origin = PIXEL_CENTER[rec.meta["camera"]]
    pairs = [(c, d) for c, d in rec.pairs() if c["index"] != "-1" and all(c[k] and d[k] for k in INTRINSICS) and valid(rec.depth[int(d["index"])]).mean() >= ALIGNMENT_MIN_VALID]
    n = min(ALIGNMENT_FRAMES, len(pairs))
    fits = []
    for i in range(n):
        c, d = pairs[i * (len(pairs) - 1) // max(n - 1, 1)]
        depth_g, mask = depth_gradients(rec.depth[int(d["index"])])
        # A map no larger than its border, like the synthetic tests' 4 x 3 ones, leaves no pixel to compare.
        if not mask.any():
            continue
        color_k, depth_k = row_intrinsics(c), depth_intrinsics(d)
        color_g = luma_gradients(rec, int(c["index"]), 0.5 * color_k[0] / depth_k[0])
        fits.append(fit_alignment(depth_g, mask, color_g, color_k, depth_k, origin))
    keys = ["k", "dx", "dy", "fattening_x", "fattening_y", "corr"]
    # A recording with no map to compare gets NaN statistics and fails on its frame count.
    result = {"frames": len(fits), "k_iqr": np.nan, "dx_median_ci95": (np.nan, np.nan), "dy_median_ci95": (np.nan, np.nan)} | {f"{key}_median": np.nan for key in keys}
    if fits:
        values = dict(zip(keys, np.array(fits).T, strict=True))
        p25, p75 = np.percentile(values["k"], [25, 75])
        result |= {f"{key}_median": np.median(v) for key, v in values.items()}
        result |= {"k_iqr": p75 - p25, "dx_median_ci95": median_interval(values["dx"]), "dy_median_ci95": median_interval(values["dy"])}
    result["aligned"] = bool(result["frames"] >= ALIGNMENT_MIN_FRAMES and abs(result["k_median"] - 1) <= SCALE_TOL and abs(result["dx_median"]) <= SHIFT_TOL and abs(result["dy_median"]) <= SHIFT_TOL)
    return result


def arkit_depth_intrinsics_match(rec: Recording) -> bool:
    """Whether every delivered depth row with a delivered same-instant color row, and there is one, has that row's intrinsics carried to the depth map as ARKit's depth grid lies on the color image, f * s, cx * sx and (cy + 0.5) * sy - 0.5 with s = depth size / color size, computed in Float32 as the app does."""
    meta = rec.meta
    pairs = [(c, d) for c, d in rec.pairs() if c["index"] != "-1"]
    if not pairs:
        return False
    s = np.array([meta["depth_width"], meta["depth_height"]], np.float32) / np.array([meta["color_width"], meta["color_height"]], np.float32)
    half = np.float32(0.5)
    color = np.array([[float(c[k]) for k in INTRINSICS] for c, _ in pairs], np.float32)
    depth = np.array([[float(d[k]) for k in INTRINSICS] for _, d in pairs], np.float32)
    carried = np.concatenate([color[:, :2] * s, color[:, 2:3] * s[0], (color[:, 3:] + half) * s[1] - half], axis=1)
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
    spatial = spatial_alignment(rec)
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
    dx_low, dx_high = spatial["dx_median_ci95"]
    dy_low, dy_high = spatial["dy_median_ci95"]
    print(f"spatial alignment of depth to its same-instant color frame through their intrinsics, over {spatial['frames']} frames: residual scale k median {spatial['k_median']:.4f} (IQR {spatial['k_iqr']:.4f}), shift median dx {spatial['dx_median']:+.3f} (95% {dx_low:+.3f}..{dx_high:+.3f}) dy {spatial['dy_median']:+.3f} (95% {dy_low:+.3f}..{dy_high:+.3f}) depth px, depth edge fattening median x {spatial['fattening_x_median']:+.3f} y {spatial['fattening_y_median']:+.3f} depth px, edge correlation median {spatial['corr_median']:.3f}")

    has_intrinsics = all(r[k] for r in rec.colors + rec.depths for k in INTRINSICS)
    checks = {
        "color.bin holds color_frames frames, one per color.csv row with an index": rec.color.shape[0] == len(rec.colors) == meta["color_frames"],
        "depth.bin holds depth_frames maps, one per depth.csv row with an index": rec.depth.shape[0] == len(rec.depths) == meta["depth_frames"],
        "indices are 0..n-1": [int(r["index"]) for r in rec.colors] == list(range(len(rec.colors))) and [int(r["index"]) for r in rec.depths] == list(range(len(rec.depths))),
        "timestamps strictly increasing": bool(np.all(np.diff(color_ts) > 0) and np.all(np.diff(depth_ts) > 0)),
        "every depth frame within the color stream's time span has a color.csv row (delivered or dropped) at the same instant": paired_in_span == len(depth_in_span),
        "depth aligns best with its same-instant color frame": best_offset == 0,
        "depth edges land on the same-instant color frame's edges through the two frames' intrinsics: median residual scale within 0.005 of 1 and median shifts within 0.15 depth px, over at least 10 frames": spatial["aligned"],
        "metadata's depth_filtering_enabled is false": meta["depth_filtering_enabled"] is False,
    }
    if not rear:
        checks["every depth map unfiltered"] = all(r["filtered"] == "0" for r in rec.depths)
    checks["every color and depth frame has intrinsics"] = has_intrinsics
    if rear:
        checks["every depth frame's intrinsics are its same-instant color frame's carried as ARKit's depth grid lies on the color image, f * s, cx * sx and (cy + 0.5) * sy - 0.5"] = has_intrinsics and arkit_depth_intrinsics_match(rec)
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

"""Measures the lens distortion a camera's color frames still carry once the distortion their recording describes is removed (front: Apple's table; rear: nothing, ARKit reporting none), as the radial model of `camera_models.radial_distort`: a point at undistorted normalized coordinates (x, y) of the frame's own intrinsic matrix appears at (x, y) * (1 + k1 r^2 + k2 r^4). Where the camera focuses (the rear), k1 and k2 may change with focus: the model then also has their slopes against the frame's relative focal change d = fx / fx_reference - 1, which tracks the lens position, k = k + slope * d, fx held within the range most edges were measured at (5th to 95th percentile). The phone's corrections file (phone_corrections.py) holds the result as the camera's lens_distortion, and the same measurement on frames aligned with it (align_recording.py) checks that nothing is left.

Plumb lines: straight edges in the world are straight in a pinhole image. Each frame of a recording, resampled onto its intrinsic matrix by align_recording.py with the corrections given (k1 = k2 = 0 to measure; the phone's corrections to check the frames an aligned recording holds) and brought to about FIT_WIDTH px wide, yields its long edges (line segments found by LSD, refined to gradient peaks across them, kept when a quadratic fits them within RMS_MAX px and they keep BORDER_MARGIN px from the black outside the recorded frame); the model's parameters minimize the edge points' distances from their own straight lines after undistortion, every edge weighted equally, with a robust loss for edges that are not straight in the world. The 95% intervals refit resampled recordings, the spread between scenes being what the fit's uncertainty comes from, and each recording is also held out in turn: its edges' straightness under no model, the constant model and the focus model fitted without it. The model applied is whichever of the three straightens held-out recordings best on average, so a fit that does not carry over to unseen recordings is not applied. `synthetic_check` draws straight lines, distorts them with a known k1, k2 and fits them.

Usage: python tools/lens_distortion_fit.py <recording.tar...> [--corrections <phone_id>.json]
"""

import argparse
import json
from multiprocessing import Pool
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import cv2
import numpy as np
from scipy.optimize import least_squares

from align_recording import Aligner
from rgbd_recording import Recording, ycbcr_planes

# Frames are fitted at about this width: the edge finder's lengths and thresholds are set for it.
FIT_WIDTH = 2000
FRAME_STEP = 3
MIN_LENGTH = 400
RMS_MAX = 0.6
# An edge's points: EDGE_POINTS gradient peaks across it, over EDGE_SPAN of its length, searched EDGE_SEARCH px either side in EDGE_STEP steps; a peak counts when it stands PEAK_OVER_MEDIAN times above its profile's median, and an edge when MIN_EDGE_POINTS count.
EDGE_POINTS = 80
EDGE_SPAN = (0.05, 0.95)
EDGE_SEARCH = 10
EDGE_STEP = 0.5
PEAK_OVER_MEDIAN = 4
MIN_EDGE_POINTS = 60
GRADIENT_SIGMA = 1.5
# Segments are clipped to their longest stretch at least BORDER_MARGIN px from the black that resampling leaves where a pixel's ray falls outside the recorded frame, sampled every CLIP_STEP px: the black border's own curved edge must not enter the fit.
CLIP_STEP = 2.0
BORDER_MARGIN = 8
# Distances above this (px) count less: an edge that is not straight in the world should not pull the fit.
LOSS_SCALE = 0.3
UNDISTORT_ITERATIONS = 10
# The focus model is fitted when the edges' frames span at least this relative focal change between their 5th and 95th percentiles of fx.
FOCUS_MIN_SPAN = 0.005
BOOTSTRAP = 40
SEED = 0
SYNTHETIC_K = (0.04, -0.06)
SYNTHETIC_IMAGES = 60
SYNTHETIC_LINES = 40
WORKERS = 16
# The corrections that leave a recording's own distortion as the only one removed.
NO_CORRECTION = {"lens_distortion": {"k1": 0.0, "k2": 0.0}, "depth_rotation": {"rotation_vector_rad": [0.0, 0.0, 0.0]}}

# An edge: its points' x and y in pixel-center coordinates, and the intrinsic matrix (fx, fy, cx, cy) of its image in the same coordinates.
Edge = Tuple[np.ndarray, np.ndarray, Tuple[float, float, float, float]]


class Edges:
    """Edges packed into arrays for vectorized fitting: points padded to one length with a mask, and each edge's intrinsic matrix."""

    def __init__(self, edges: List[Edge]) -> None:
        def _validate_inputs() -> None:
            assert len(edges) > 0, "no edges"

        _validate_inputs()

        length = max(len(u) for u, _, _ in edges)
        self.u = np.zeros((len(edges), length))
        self.v = np.zeros((len(edges), length))
        self.mask = np.zeros((len(edges), length), bool)
        for i, (u, v, _) in enumerate(edges):
            self.u[i, : len(u)], self.v[i, : len(v)], self.mask[i, : len(u)] = u, v, True
        self.fx, self.fy, self.cx, self.cy = (np.array([e[2][j] for e in edges])[:, None] for j in range(4))
        self.count = self.mask.sum(1, keepdims=True)

    def distances(self, k1: np.ndarray, k2: np.ndarray) -> np.ndarray:
        """Each point's signed distance (px) from its edge's total-least-squares line after undistorting with each edge's k1, k2 (edges x 1 arrays); 0 at padding."""
        xd, yd = (self.u - self.cx) / self.fx, (self.v - self.cy) / self.fy
        xu, yu = xd.copy(), yd.copy()
        for _ in range(UNDISTORT_ITERATIONS):
            r2 = xu * xu + yu * yu
            scale = 1 + k1 * r2 + k2 * r2 * r2
            xu, yu = xd / scale, yd / scale
        x, y = xu * self.fx, yu * self.fy
        cx = (x - (x * self.mask).sum(1, keepdims=True) / self.count) * self.mask
        cy = (y - (y * self.mask).sum(1, keepdims=True) / self.count) * self.mask
        sxx, syy, sxy = (cx * cx).sum(1, keepdims=True), (cy * cy).sum(1, keepdims=True), (cx * cy).sum(1, keepdims=True)
        # The line runs along the points' principal axis at angle theta; the distance is the component along its normal.
        theta = 0.5 * np.arctan2(2 * sxy, sxx - syy)
        return -cx * np.sin(theta) + cy * np.cos(theta)


def coefficients(params: np.ndarray, edges: Edges, fx_reference: Optional[float]) -> Tuple[np.ndarray, np.ndarray]:
    """Each edge's k1, k2 under the model: (k1, k2) constant, or with fx_reference given, (k1, k2, k1 slope, k2 slope) against the edge's relative focal change."""
    if fx_reference is None:
        return np.full_like(edges.fx, params[0]), np.full_like(edges.fx, params[1])
    change = edges.fx / fx_reference - 1
    return params[0] + params[2] * change, params[1] + params[3] * change


def fit(edges: Edges, fx_reference: Optional[float] = None) -> np.ndarray:
    """The model's parameters that straighten the edges: k1, k2, and with fx_reference given their slopes against the relative focal change."""
    def residuals(params: np.ndarray) -> np.ndarray:
        return (edges.distances(*coefficients(params, edges, fx_reference)) / np.sqrt(edges.count))[edges.mask]

    return least_squares(residuals, np.zeros(2 if fx_reference is None else 4), loss="soft_l1", f_scale=LOSS_SCALE / np.sqrt(EDGE_POINTS), x_scale="jac").x


def straightness(edges: Edges, params: np.ndarray, fx_reference: Optional[float] = None) -> float:
    """The median over edges of the RMS point distance (px) from the edge's line under the model."""
    distances = edges.distances(*coefficients(params, edges, fx_reference))
    return float(np.median(np.sqrt((distances**2).sum(1) / edges.count[:, 0])))


def displacement(k: Tuple[float, float], radius: float, focal: float) -> float:
    """How far (px) the model moves a point at normalized radius `radius` outward, for focal length `focal` px."""
    return (k[0] * radius**2 + k[1] * radius**4) * radius * focal


def edge_points(gradient: np.ndarray, x0: float, y0: float, x1: float, y1: float) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """The gradient-magnitude peaks across the segment (x0, y0)-(x1, y1) at EDGE_POINTS places along it: their x, their y, and whether each counts."""
    length = np.hypot(x1 - x0, y1 - y0)
    t = np.linspace(*EDGE_SPAN, EDGE_POINTS)
    px, py = x0 + t * (x1 - x0), y0 + t * (y1 - y0)
    nx, ny = -(y1 - y0) / length, (x1 - x0) / length
    offsets = np.arange(-EDGE_SEARCH, EDGE_SEARCH + EDGE_STEP / 2, EDGE_STEP)
    sample_x, sample_y = px[:, None] + offsets[None, :] * nx, py[:, None] + offsets[None, :] * ny
    profiles = cv2.remap(gradient, sample_x.astype(np.float32), sample_y.astype(np.float32), cv2.INTER_LINEAR)
    peak = profiles.argmax(1)
    counts = (peak > 0) & (peak < offsets.size - 1)
    k = np.clip(peak, 1, offsets.size - 2)
    rows = np.arange(EDGE_POINTS)
    a, b, c = profiles[rows, k - 1], profiles[rows, k], profiles[rows, k + 1]
    # A parabola through the peak and its two neighbours refines it wherever they curve down.
    curvature = a - 2 * b + c
    refinement = np.where(curvature < 0, 0.5 * (a - c) / np.where(curvature < 0, curvature, -1), 0)
    offset = offsets[k] + refinement * EDGE_STEP
    counts &= b > PEAK_OVER_MEDIAN * np.median(profiles, 1)
    return px + offset * nx, py + offset * ny, counts


def quadratic_rms(x: np.ndarray, y: np.ndarray) -> float:
    """The RMS residual (px) of a quadratic fitted across the points' principal axis, which a bow passes and a wiggle does not."""
    points = np.c_[x, y]
    centered = points - points.mean(0)
    axes = np.linalg.svd(centered, full_matrices=False)[2]
    along, across = centered @ axes[0], centered @ axes[1]
    design = np.c_[along**2, along, np.ones_like(along)]
    coef = np.linalg.lstsq(design, across, rcond=None)[0]
    return float(np.sqrt(np.mean((across - design @ coef) ** 2)))


def longest_run(flags: np.ndarray) -> Tuple[Optional[int], Optional[int]]:
    """The first and last index of the longest run of True, or None, None when there is none."""
    padded = np.concatenate([[False], flags, [False]]).astype(np.int8)
    starts, ends = np.flatnonzero(np.diff(padded) == 1), np.flatnonzero(np.diff(padded) == -1)
    if len(starts) == 0:
        return None, None
    i = np.argmax(ends - starts)
    return int(starts[i]), int(ends[i] - 1)


def image_edges(luma: np.ndarray, intrinsics: Tuple[float, float, float, float], filled: Optional[np.ndarray] = None) -> List[Edge]:
    """The image's long edges that fit a quadratic within RMS_MAX px, any orientation, each as its edge points with the image's intrinsic matrix (pixel-center coordinates), each segment clipped first to its longest stretch BORDER_MARGIN px from any pixel outside `filled` when it is given."""
    height, width = luma.shape
    near_border = None
    if filled is not None:
        near_border = cv2.dilate((~filled).astype(np.uint8), np.ones((2 * BORDER_MARGIN + 1, 2 * BORDER_MARGIN + 1), np.uint8)) > 0
    blurred = cv2.GaussianBlur(luma.astype(np.float32), (0, 0), GRADIENT_SIGMA)
    gradient = cv2.magnitude(cv2.Sobel(blurred, cv2.CV_32F, 1, 0), cv2.Sobel(blurred, cv2.CV_32F, 0, 1))
    half = cv2.resize(luma, (width // 2, height // 2), interpolation=cv2.INTER_AREA)
    lines = cv2.createLineSegmentDetector(cv2.LSD_REFINE_NONE).detect(half)[0]
    edges: List[Edge] = []
    if lines is None:
        return edges
    for x0, y0, x1, y1 in lines[:, 0].astype(np.float64) * 2:
        if near_border is not None:
            t = np.linspace(0, 1, max(2, int(np.hypot(x1 - x0, y1 - y0) / CLIP_STEP)))
            safe = ~near_border[np.clip(np.rint(y0 + t * (y1 - y0)).astype(int), 0, height - 1), np.clip(np.rint(x0 + t * (x1 - x0)).astype(int), 0, width - 1)]
            first, last = longest_run(safe)
            if first is None:
                continue
            x0, y0, x1, y1 = x0 + t[first] * (x1 - x0), y0 + t[first] * (y1 - y0), x0 + t[last] * (x1 - x0), y0 + t[last] * (y1 - y0)
        if np.hypot(x1 - x0, y1 - y0) < MIN_LENGTH:
            continue
        x, y, found = edge_points(gradient, x0, y0, x1, y1)
        if found.sum() < MIN_EDGE_POINTS:
            continue
        x, y = x[found], y[found]
        if quadratic_rms(x, y) <= RMS_MAX:
            edges.append((x, y, intrinsics))
    return edges


def pinhole_luma(rec: Recording, aligner: Aligner, index: int) -> Tuple[np.ndarray, Tuple[float, float, float, float], np.ndarray]:
    """Color frame `index`'s luma resampled by `aligner` onto the pinhole image of its intrinsic matrix, shrunk by a whole factor to about FIT_WIDTH px wide, with that image's intrinsic matrix in pixel-center coordinates and the mask of its pixels filled from the recorded frame (every full-size pixel they cover filled)."""
    frame = np.frombuffer(aligner.color_frame(index), np.uint8).reshape(rec.color.shape[1:])
    luma = ycbcr_planes(frame)[0]
    filled = aligner.color_filled(index)
    factor = max(1, round(rec.color_width / FIT_WIDTH))
    if factor > 1:
        luma = cv2.resize(luma, (rec.color_width // factor, rec.color_height // factor), interpolation=cv2.INTER_AREA)
        filled = filled[: luma.shape[0] * factor, : luma.shape[1] * factor].reshape(luma.shape[0], factor, luma.shape[1], factor).all(axis=(1, 3))
    k = {key: float(rec.colors[index][key]) for key in ("fx", "fy", "cx", "cy")}
    # Shrinking by a whole factor scales coordinates measured from the corner.
    shift = 0.5 if rec.color_principal_point_origin == "upper_left_pixel_center" else 0.0
    return np.ascontiguousarray(luma), (k["fx"] / factor, k["fy"] / factor, (k["cx"] + shift) / factor - 0.5, (k["cy"] + shift) / factor - 0.5), filled


# Each worker process's recording and aligner, built once per recording by `start_worker`.
WORKER: Dict[str, object] = {}


def start_worker(path: Path, correction: Dict) -> None:
    WORKER["rec"] = Recording(path)
    WORKER["aligner"] = Aligner(path, correction)


def frame_edges(index: int) -> List[Edge]:
    return image_edges(*pinhole_luma(WORKER["rec"], WORKER["aligner"], index))


def recording_edges(path: Path, correction: Dict) -> List[Edge]:
    """The edges of every FRAME_STEP-th color frame of a recording, resampled with the camera's correction."""
    count = Recording(path).color.shape[0]
    with Pool(WORKERS, start_worker, (path, correction)) as pool:
        return [e for edges in pool.map(frame_edges, range(0, count, FRAME_STEP)) for e in edges]


def synthetic_edges(seed: int) -> List[Edge]:
    """Edges of one synthetic 1920 x 1440 image of straight lines, distorted with SYNTHETIC_K under a typical ARKit intrinsic matrix."""
    width, height, intrinsics = 1920, 1440, (1435.0, 1435.0, 960.0, 720.0)
    fx, fy, cx, cy = intrinsics
    rng = np.random.default_rng(seed)
    drawn = np.full((height, width), 128, np.uint8)
    for _ in range(SYNTHETIC_LINES):
        x0, y0, x1, y1 = rng.integers(0, (width, height, width, height)).tolist()
        cv2.line(drawn, (x0, y0), (x1, y1), int(rng.choice((20, 235))), int(rng.integers(3, 12)), cv2.LINE_AA)
    drawn = cv2.GaussianBlur(drawn, (0, 0), 0.8)
    # Each distorted pixel takes the undistorted image's value where its undistorted position falls, found by fixed-point iteration.
    v, u = np.mgrid[0:height, 0:width].astype(np.float64)
    xd, yd = (u - cx) / fx, (v - cy) / fy
    xu, yu = xd.copy(), yd.copy()
    for _ in range(UNDISTORT_ITERATIONS):
        r2 = xu * xu + yu * yu
        scale = 1 + SYNTHETIC_K[0] * r2 + SYNTHETIC_K[1] * r2 * r2
        xu, yu = xd / scale, yd / scale
    distorted = cv2.remap(drawn, (xu * fx + cx).astype(np.float32), (yu * fy + cy).astype(np.float32), cv2.INTER_LINEAR)
    return image_edges(distorted, intrinsics)


def resampled_fits(groups: List[List[Edge]], fx_reference: Optional[float]) -> np.ndarray:
    """The model refitted on BOOTSTRAP resamples of the groups (recordings or images), one row of parameters per resample."""
    rng = np.random.default_rng(SEED)
    return np.array([fit(Edges([e for g in rng.choice(len(groups), len(groups)) for e in groups[g]]), fx_reference) for _ in range(BOOTSTRAP)])


def synthetic_check() -> Dict[str, object]:
    """Fits k1, k2 to SYNTHETIC_IMAGES synthetic images drawn with SYNTHETIC_K, with the 95% interval resampling images."""
    with Pool(WORKERS) as pool:
        images = [image for image in pool.map(synthetic_edges, range(SYNTHETIC_IMAGES)) if len(image) >= 3]
    k = fit(Edges([e for image in images for e in image]))
    low, high = np.percentile(resampled_fits(images, None), [2.5, 97.5], axis=0)
    return {"drawn": SYNTHETIC_K, "k1": float(k[0]), "k2": float(k[1]), "k1_95": [float(low[0]), float(high[0])], "k2_95": [float(low[1]), float(high[1])], "images": len(images)}


def measure(paths: List[Path], corrections: Optional[Dict]) -> Dict[str, object]:
    """The lens distortion left in the recordings' color frames (one camera, one phone) after the corrections given, or after none (`NO_CORRECTION`) when they are None: each recording's constant fit; the pooled constant fit and, when the frames span FOCUS_MIN_SPAN of relative focal change, the pooled focus fit, with 95% intervals refitting resampled recordings; each recording held out in turn under no model and each fitted one; the model applied (none, constant or focus, whichever straightens held-out recordings best on average) with its parameters; and the radial displacement (px) the applied model gives at fractions of the half-diagonal at the reference focal length."""
    per_take: List[List[Edge]] = []
    takes = []
    for path in paths:
        rec = Recording(path)
        correction = NO_CORRECTION if corrections is None else corrections[rec.camera]
        edges = recording_edges(path, correction)
        packed = Edges(edges)
        k = fit(packed)
        takes.append({"scan_id": rec.scan_id, "edges": len(edges), "fx_median": float(np.median(packed.fx)), "k1": float(k[0]), "k2": float(k[1]), "rms_none": straightness(packed, np.zeros(2)), "rms_fit": straightness(packed, k)})
        print(f"{rec.scan_id}: {len(edges)} edges, median fx {takes[-1]['fx_median']:.1f}, k1 {k[0]:+.4f} k2 {k[1]:+.4f}, median edge RMS {takes[-1]['rms_none']:.3f} px before, {takes[-1]['rms_fit']:.3f} px after", flush=True)
        per_take.append(edges)
    every = Edges([e for edges in per_take for e in edges])
    fx_low, fx_reference, fx_high = np.percentile(every.fx, [5, 50, 95])
    focus = fx_reference if fx_high / fx_low - 1 >= FOCUS_MIN_SPAN else None
    constant = fit(every)
    low, high = np.percentile(resampled_fits(per_take, None), [2.5, 97.5], axis=0)
    fits = {"constant": {"k1": float(constant[0]), "k2": float(constant[1]), "k1_95": [float(low[0]), float(high[0])], "k2_95": [float(low[1]), float(high[1])]}}
    if focus is not None:
        focused = fit(every, focus)
        low, high = np.percentile(resampled_fits(per_take, focus), [2.5, 97.5], axis=0)
        fits["focus"] = {"k1": float(focused[0]), "k2": float(focused[1]), "focus": {"fx_reference": float(focus), "fx_range": [float(fx_low), float(fx_high)], "k1_slope": float(focused[2]), "k2_slope": float(focused[3])},
                         "k1_95": [float(low[0]), float(high[0])], "k2_95": [float(low[1]), float(high[1])], "k1_slope_95": [float(low[2]), float(high[2])], "k2_slope_95": [float(low[3]), float(high[3])]}
    held_out = []
    # Holding a recording out needs another to fit on.
    for i, edges in enumerate(per_take if len(per_take) > 1 else []):
        rest = Edges([e for j, other in enumerate(per_take) if j != i for e in other])
        held = Edges(edges)
        row = {"scan_id": takes[i]["scan_id"], "none": straightness(held, np.zeros(2)), "constant": straightness(held, fit(rest))}
        if focus is not None:
            row["focus"] = straightness(held, fit(rest, focus), focus)
        held_out.append(row)
        print(f"held out {row}", flush=True)
    # The model applied is the one whose fits straighten the held-out recordings best on average; with one recording there is nothing to hold out, and the richest fitted model is applied.
    models = ["none", "constant"] + (["focus"] if focus is not None else [])
    mean_rms = {m: float(np.mean([row[m] for row in held_out])) for m in models} if held_out else {}
    model = min(models, key=lambda m: mean_rms[m]) if held_out else models[-1]
    applied = {"k1": 0.0, "k2": 0.0} if model == "none" else {key: fits[model][key] for key in ("k1", "k2", "focus") if key in fits[model]}
    fx, fy, cx, cy = per_take[0][0][2]
    corner = np.hypot(cx + 0.5, cy + 0.5) / fx
    reference = focus if focus is not None else float(np.median(every.fx))
    displacements = {f"{r:.2f}": displacement((applied["k1"], applied["k2"]), r * corner * fx / reference, reference) for r in (0.25, 0.5, 0.75, 1.0)}
    return {"model": model, "applied": applied, "held_out_mean_rms": mean_rms, "fits": fits, "displacement_px_at_half_diagonal_fraction": displacements, "edges": int(every.mask.shape[0]), "fit_image_width": int(round(2 * (cx + 0.5))), "takes": takes, "held_out": held_out}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tars", type=Path, nargs="+")
    parser.add_argument("--corrections", type=Path)
    args = parser.parse_args()
    corrections = None if args.corrections is None else json.loads(args.corrections.read_text())
    print(json.dumps(measure(args.tars, corrections), indent=2))


if __name__ == "__main__":
    main()

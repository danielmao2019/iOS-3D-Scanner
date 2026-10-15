"""Measures how far a phone's front depth maps sit from its front color frames once both are resampled onto their intrinsic matrices (align_recording.py), as the color edge minus the depth crease at outward corners, and the depth rotation that removes it, which the phone's corrections file (phone_corrections.py) holds as front depth_rotation; the same measurement on frames aligned with that rotation checks that nothing is left.

Creases: where two planes fitted to a depth map meet at an outward (convex) corner, their intersection line, projected into the same-instant color frame through the two intrinsic matrices, should lie on the color edge between the corner's two differently lit faces. Each crease's color luma profile across it, averaged along it, is fitted with a blurred step (`step_fit`), whose center t0 is the color edge's offset from the projected crease along the crease's image normal n (color px).

The offset model: t0 = O . n + beta_g * obliquity + b_g * (n_up . c_g), fitted over all creases with a robust loss, g being the crease's corner (its scan). O, the depth-to-color offset in sensor pixels (color edge minus depth crease), is fixed to the phone. beta_g * obliquity is corner g's rounding under its lighting: a rounded edge seen more from one face puts its shading edge off the planes' intersection, in proportion to how much more the camera sees that face (obliquity, the difference of the two faces' cosines to the view ray, signed toward the +n face). b_g is corner g's lighting: a brighter face pulls the shading edge toward it by a fixed distance on the corner, along c_g, the corner's crease normal in the upright image (n_up is n turned upright by the frame's upright_rotation_deg). O turns with the phone and b_g with the world, so the two separate only when a corner is scanned with the phone held both ways along an axis: upright and upside down for the sensor's y offset, sideways both ways for its x offset; `separable` says which axes the scans separate. The 95% interval resamples frames.

Usage: python tools/front_depth_rotation_fit.py <front recording.tar...> [--corrections <phone_id>.json] [--check] [--step N]
Each recording is aligned (align_recording.py) with the corrections' front lens distortion and no depth rotation (no corrections: Apple's table only), or, with --check, with the corrections' depth rotation too, which checks the frames an aligned recording holds.
"""

import argparse
import json
from multiprocessing import Pool
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import cv2
import numpy as np
from scipy.optimize import curve_fit, least_squares
from scipy.special import erf

from align_recording import Aligner
from rgbd_recording import Recording, ycbcr_planes

# Thresholds below are set for a 640 x 480 depth map and scaled to the map's size: pixel counts by its pixel count, lengths by its width.
REFERENCE_DEPTH_WIDTH = 640
REFERENCE_DEPTH_PIXELS = 640 * 480
# Planes: up to MAX_PLANES per map, each the RANSAC plane (RANSAC_ITERATIONS triples among RANSAC_SAMPLE points) with the most points within PLANE_TOLERANCE of their depth, kept when it has PLANE_MIN_POINTS, refitted to its largest connected part shrunk by CORE_ERODE px.
MAX_PLANES = 6
RANSAC_ITERATIONS = 200
RANSAC_SAMPLE = 20000
PLANE_TOLERANCE = 0.01
PLANE_MIN_FREE = 3000
PLANE_MIN_POINTS = 2500
CORE_MIN_POINTS = 1500
CORE_ERODE = 9
# Creases: planes at least MIN_CREASE_DEG apart whose intersection runs at least MIN_CREASE_PIXELS depth px within NEAR_FACES px of both faces, BORDER px inside the map, nearer than MIN_DISTANCE m.
MIN_CREASE_DEG = 45
MIN_CREASE_PIXELS = 40
NEAR_FACES = 14
BORDER = 8
MIN_DISTANCE = 0.15
CONVEX_MARGIN = 0.005
# Profiles: color luma every PROFILE_STEP px over +-PROFILE_HALF px across the crease, sampled at full-sensor scale (FULL_WIDTH px wide) whatever the color frame's width.
FULL_WIDTH = 4032
PROFILE_HALF = 60.0
PROFILE_STEP = 0.5
STEP_WINDOW = 40.0
# A step fit counts when it explains R2_MIN of the profile's variance with at least CONTRAST_MIN luma levels, within OFFSET_MAX full-sensor px of the crease and narrower than WIDTH_MAX.
R2_MIN = 0.9
CONTRAST_MIN = 8
OFFSET_MAX = 30
WIDTH_MAX = 12
# Creases count for an axis when their normal lies within this cosine of it.
AXIS_COSINE = 0.7
LOSS_SCALE = 3.0
BOOTSTRAP = 1000
SEED = 0
WORKERS = 16
# The corrections that leave Apple's table as the only one removed.
NO_CORRECTION = {"lens_distortion": {"k1": 0.0, "k2": 0.0}, "depth_rotation": {"rotation_vector_rad": [0.0, 0.0, 0.0]}}

OFFSETS = np.arange(-PROFILE_HALF, PROFILE_HALF + PROFILE_STEP / 2, PROFILE_STEP)


def step_model(t: np.ndarray, a: float, b: float, t0: float, w: float) -> np.ndarray:
    """A step from a to a + b centered at t0, blurred by a Gaussian of width w."""
    return a + b * 0.5 * (1 + erf((t - t0) / (np.sqrt(2) * abs(w) + 1e-6)))


def step_fit(profile: np.ndarray) -> Optional[Tuple[float, float, float, float]]:
    """A luma profile's step: center t0, width, contrast and R2, started from the steepest point within STEP_WINDOW px of the middle; None when the fit fails."""
    gradient = np.abs(np.gradient(profile))
    k = np.argmax(np.where(np.abs(OFFSETS) <= STEP_WINDOW, gradient, 0))
    try:
        p, _ = curve_fit(step_model, OFFSETS, profile, p0=[profile[:20].mean(), profile[-20:].mean() - profile[:20].mean(), OFFSETS[k], 3.0], maxfev=4000)
    except RuntimeError:
        return None
    residual = profile - step_model(OFFSETS, *p)
    return p[2], abs(p[3]), abs(p[1]), 1 - residual.var() / profile.var()


def planes(points: np.ndarray, usable: np.ndarray, shape: Tuple[int, int], rng: np.random.Generator) -> List[Tuple[np.ndarray, float, np.ndarray, np.ndarray]]:
    """Up to MAX_PLANES planes in a depth map's points (pixels x 3, camera frame), each its unit normal toward the camera, offset d (n . p + d = 0), pixel mask of its largest connected part, and that part's centroid."""
    height, width = shape
    area = width * height / REFERENCE_DEPTH_PIXELS
    side = max(3, int(round(CORE_ERODE * width / REFERENCE_DEPTH_WIDTH)) | 1)
    found = []
    free = usable.copy()
    for _ in range(MAX_PLANES):
        candidates = np.flatnonzero(free)
        if len(candidates) < PLANE_MIN_FREE * area:
            break
        sample = points[rng.choice(candidates, min(RANSAC_SAMPLE, len(candidates)), replace=False)]
        best = None
        for _ in range(RANSAC_ITERATIONS):
            a, b, c = sample[rng.choice(len(sample), 3, replace=False)]
            normal = np.cross(b - a, c - a)
            norm = np.linalg.norm(normal)
            if norm < 1e-9:
                continue
            normal /= norm
            support = (np.abs(sample @ normal - normal @ a) < PLANE_TOLERANCE * sample[:, 2]).sum()
            if best is None or support > best[0]:
                best = (support, normal, -normal @ a)
        _, normal, d = best
        inliers = free & (np.abs(points @ normal + d) < PLANE_TOLERANCE * np.abs(points[:, 2]))
        if inliers.sum() < PLANE_MIN_POINTS * area:
            break
        _, labels, stats, _ = cv2.connectedComponentsWithStats(inliers.reshape(height, width).astype(np.uint8), connectivity=4)
        part = labels == 1 + np.argmax(stats[1:, cv2.CC_STAT_AREA])
        core = cv2.erode(part.astype(np.uint8), np.ones((side, side), np.uint8)).astype(bool)
        chosen = points[(core if core.sum() > CORE_MIN_POINTS * area else part).ravel()]
        centroid = chosen.mean(0)
        normal = np.linalg.svd(chosen - centroid, full_matrices=False)[2][2]
        d = -normal @ centroid
        if d < 0:
            normal, d = -normal, -d
        found.append((normal, d, part, centroid))
        free &= ~inliers
    return found


def upright_vector(vector: np.ndarray, rotation_deg: int) -> np.ndarray:
    """A sensor-image direction (x right, y down) as the upright image shows it, turned clockwise by the frame's upright rotation."""
    angle = np.radians(rotation_deg)
    # A clockwise turn on screen (y down) is the matrix [[cos, -sin], [sin, cos]].
    return np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]]) @ vector


def frame_creases(luma: np.ndarray, filled: np.ndarray, depth: np.ndarray, color_k: Tuple[float, float, float, float], depth_k: Tuple[float, float, float, float], rotation_deg: int, rng: np.random.Generator) -> List[Dict]:
    """The convex creases of one aligned frame pair (luma, the mask of its pixels filled from the recorded frame, depth), each with its color edge offset t0 (full-sensor px), image normal n (sensor), upright normal, obliquity, distance (m), color position and step fit; color_k and depth_k from the image's corner."""
    height, width = depth.shape
    lengths = width / REFERENCE_DEPTH_WIDTH
    scale = FULL_WIDTH / luma.shape[1]
    fxd, fyd, cxd, cyd = depth_k
    fxc, fyc, cxc, cyc = color_k
    rows, cols = np.mgrid[0:height, 0:width].astype(np.float64)
    usable = (depth > 0).ravel()
    points = np.stack([(cols + 0.5 - cxd) / fxd * depth, (rows + 0.5 - cyd) / fyd * depth, depth], -1).reshape(-1, 3).astype(np.float64)
    found = planes(points, usable, (height, width), rng)
    distance_to = [cv2.distanceTransform((~p[2]).astype(np.uint8), cv2.DIST_L2, 3) for p in found]
    luma_f = luma.astype(np.float32)
    creases = []
    for i in range(len(found)):
        for j in range(i + 1, len(found)):
            na, da, mask_a, ca = found[i]
            nb, db, mask_b, cb = found[j]
            if np.degrees(np.arccos(min(1.0, abs(na @ nb)))) < MIN_CREASE_DEG:
                continue
            # Convex: each face's centroid lies behind the other face's plane, seen from the camera.
            if not (nb @ ca + db < -CONVEX_MARGIN and na @ cb + da < -CONVEX_MARGIN):
                continue
            direction = np.cross(na, nb)
            direction /= np.linalg.norm(direction)
            origin = np.linalg.solve(np.stack([na, nb, direction]), np.array([-da, -db, 0.0]))
            line = origin + np.linspace(-2, 2, 4001)[:, None] * direction
            line = line[line[:, 2] > MIN_DISTANCE]
            if len(line) < 10:
                continue
            ud, vd = line[:, 0] / line[:, 2] * fxd + cxd - 0.5, line[:, 1] / line[:, 2] * fyd + cyd - 0.5
            inside = (ud > BORDER * lengths) & (ud < width - 1 - BORDER * lengths) & (vd > BORDER * lengths) & (vd < height - 1 - BORDER * lengths)
            if inside.sum() < MIN_CREASE_PIXELS:
                continue
            ui, vi = ud[inside].round().astype(int), vd[inside].round().astype(int)
            near = (distance_to[i][vi, ui] < NEAR_FACES * lengths) & (distance_to[j][vi, ui] < NEAR_FACES * lengths)
            if near.sum() < MIN_CREASE_PIXELS:
                continue
            on = line[inside][near]
            xc, yc = on[:, 0] / on[:, 2] * fxc + cxc - 0.5, on[:, 1] / on[:, 2] * fyc + cyc - 0.5
            tangent = np.gradient(np.c_[xc, yc], axis=0)
            tangent /= np.linalg.norm(tangent, axis=1, keepdims=True) + 1e-12
            normal = np.median(np.c_[-tangent[:, 1], tangent[:, 0]], 0)
            normal /= np.linalg.norm(normal)
            # The profile is sampled every PROFILE_STEP full-sensor px, the same physical window at any color width.
            offsets = OFFSETS / scale
            sx, sy = xc[:, None] + offsets[None, :] * normal[0], yc[:, None] + offsets[None, :] * normal[1]
            within = (sx.min(1) > 2) & (sx.max(1) < luma.shape[1] - 3) & (sy.min(1) > 2) & (sy.max(1) < luma.shape[0] - 3)
            # A profile reaching the black that resampling leaves outside the recorded frame would carry that border's edge.
            within &= filled[np.clip(np.rint(sy), 0, luma.shape[0] - 1).astype(int), np.clip(np.rint(sx), 0, luma.shape[1] - 1).astype(int)].all(1)
            if within.sum() < MIN_CREASE_PIXELS:
                continue
            profile = cv2.remap(luma_f, sx[within].astype(np.float32), sy[within].astype(np.float32), cv2.INTER_LINEAR).mean(0).astype(np.float64)
            step = step_fit(profile)
            if step is None:
                continue
            middle = on[len(on) // 2]
            view = -middle / np.linalg.norm(middle)
            xm, ym = xc[len(xc) // 2], yc[len(yc) // 2]
            # Which face lies on the +n side: the face whose mask holds the depth pixel PROFILE_HALF full-sensor px along +n.
            probe_x, probe_y = xm + PROFILE_HALF / scale * normal[0], ym + PROFILE_HALF / scale * normal[1]
            pu = int(np.clip(round((probe_x + 0.5 - cxc) * fxd / fxc + cxd - 0.5), 0, width - 1))
            pv = int(np.clip(round((probe_y + 0.5 - cyc) * fyd / fyc + cyd - 0.5), 0, height - 1))
            if not (mask_a[pv, pu] or mask_b[pv, pu]):
                continue
            plus, minus = (na, nb) if mask_a[pv, pu] else (nb, na)
            t0, step_width, contrast, r2 = step
            creases.append({"t0": t0, "width": step_width, "contrast": contrast, "r2": r2, "nx": normal[0], "ny": normal[1], "n_up": upright_vector(normal, rotation_deg).tolist(), "obliquity": float(plus @ view - minus @ view),
                            "distance": float(np.linalg.norm(middle)), "x_full": xm * scale, "y_full": ym * scale, "rotation_deg": rotation_deg})
    return creases


# Each worker process's recording and aligner, built once per recording by `start_worker`.
WORKER: Dict[str, object] = {}


def start_worker(path: Path, correction: Dict) -> None:
    WORKER["rec"] = Recording(path)
    WORKER["aligner"] = Aligner(path, correction)


def pair_creases(job: Tuple[int, int]) -> List[Dict]:
    """The creases of one same-instant color and depth frame pair (indices), aligned."""
    color_index, depth_index = job
    rec, aligner = WORKER["rec"], WORKER["aligner"]
    frame = np.frombuffer(aligner.color_frame(color_index), np.uint8).reshape(rec.color.shape[1:])
    depth = np.frombuffer(aligner.depth_frame(depth_index)[0], np.float32).reshape(rec.depth.shape[1:])
    luma = ycbcr_planes(frame)[0]
    color_row, depth_row = rec.colors[color_index], rec.depths[depth_index]
    shift = 0.5 if rec.color_principal_point_origin == "upper_left_pixel_center" else 0.0
    color_k = tuple(float(color_row[k]) + (shift if k in ("cx", "cy") else 0.0) for k in ("fx", "fy", "cx", "cy"))
    depth_k = tuple(float(depth_row[k]) + (shift if k in ("cx", "cy") else 0.0) for k in ("fx", "fy", "cx", "cy"))
    creases = frame_creases(luma, aligner.color_filled(color_index), depth, color_k, depth_k, int(color_row["upright_rotation_deg"]), np.random.default_rng(SEED + color_index))
    for crease in creases:
        crease["frame"] = color_index
    return creases


def recording_creases(path: Path, correction: Dict, step: int) -> List[Dict]:
    """The convex creases of every step-th same-instant pair of a front recording, aligned with the camera's correction, each tagged with the scan."""
    rec = Recording(path)
    pairs = [(int(c["index"]), int(d["index"])) for c, d in rec.pairs() if c["index"] != "-1"][::step]
    with Pool(WORKERS, start_worker, (path, correction)) as pool:
        creases = [c for found in pool.map(pair_creases, pairs) for c in found]
    for crease in creases:
        crease["scan"] = rec.scan_id
    return creases


def usable(creases: List[Dict]) -> List[Dict]:
    """The creases whose step fit counts."""
    return [c for c in creases if c["r2"] > R2_MIN and c["contrast"] > CONTRAST_MIN and abs(c["t0"]) < OFFSET_MAX and c["width"] < WIDTH_MAX]


def corner_axes(creases: List[Dict]) -> Dict[str, np.ndarray]:
    """Each corner's (scan's) crease normal in the upright image, c_g: the dominant direction of its creases' upright normals, sign-normalized."""
    axes = {}
    for scan in sorted({c["scan"] for c in creases}):
        n_up = np.array([c["n_up"] for c in creases if c["scan"] == scan])
        principal = np.linalg.svd(n_up.T @ n_up)[0][:, 0]
        axes[scan] = principal * np.sign(principal[np.argmax(np.abs(principal))])
    return axes


def design(creases: List[Dict], axes: Dict[str, np.ndarray], lighting: bool) -> Tuple[np.ndarray, np.ndarray, List[str]]:
    """The model's design matrix (ox, oy, one rounding column per corner, then one lighting column per corner when `lighting`) and the observed t0, with the parameter names."""
    scans = sorted(axes)
    columns = [[c["nx"], c["ny"]] + [c["obliquity"] if c["scan"] == s else 0.0 for s in scans] + ([float(np.dot(c["n_up"], axes[s])) if c["scan"] == s else 0.0 for s in scans] if lighting else []) for c in creases]
    return np.array(columns), np.array([c["t0"] for c in creases]), ["ox", "oy"] + [f"beta:{s}" for s in scans] + ([f"b:{s}" for s in scans] if lighting else [])


def solve(matrix: np.ndarray, observed: np.ndarray) -> np.ndarray:
    return least_squares(lambda p: matrix @ p - observed, np.zeros(matrix.shape[1]), loss="soft_l1", f_scale=LOSS_SCALE).x


def separable(creases: List[Dict]) -> Dict[str, bool]:
    """Whether the scans separate each sensor axis' offset from the corners' lighting: some corner has creases across that axis seen with the phone held both ways along it, which flips the lighting's sign against the axis."""
    axes = corner_axes(creases)
    out = {}
    for axis, key in (("x", "nx"), ("y", "ny")):
        out[axis] = any({int(np.sign(c[key] * np.dot(c["n_up"], axes[scan]))) for c in creases if c["scan"] == scan and abs(c[key]) > AXIS_COSINE} == {-1, 1} for scan in axes)
    return out


def fit_offset(creases: List[Dict], lighting: bool) -> Dict[str, object]:
    """The offset model fitted to usable creases, with each parameter's 95% interval resampling frames (within scans)."""
    good = usable(creases)
    axes = corner_axes(good)
    matrix, observed, names = design(good, axes, lighting)
    params = solve(matrix, observed)
    keys = np.array([f"{c['scan']}:{c['frame']}" for c in good])
    groups = {k: np.flatnonzero(keys == k) for k in np.unique(keys)}
    labels = list(groups)
    rng = np.random.default_rng(SEED)
    draws = []
    for _ in range(BOOTSTRAP):
        pick = np.concatenate([groups[labels[i]] for i in rng.integers(0, len(labels), len(labels))])
        draws.append(solve(matrix[pick], observed[pick]))
    low, high = np.percentile(draws, [2.5, 97.5], axis=0)
    return {"creases": len(good), "frames": len(labels), "parameters": {n: {"value": float(v), "95": [float(lo), float(hi)]} for n, v, lo, hi in zip(names, params, low, high, strict=True)}, "lighting_modeled": lighting, "separable": separable(good)}


def rotation_vector(ox: float, oy: float, full_fx: float) -> List[float]:
    """The depth rotation that moves the depth map onto color: the depth map sees color ray n at R n, which a depth-to-color offset (ox, oy) (color edge minus depth, full-sensor px, focal length full_fx) puts at -(ox, oy), so R's rotation vector is (oy, -ox, 0) / full_fx to first order (a turn about x moves the image along -y, about y along +x)."""
    return [oy / full_fx, -ox / full_fx, 0.0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tars", type=Path, nargs="+")
    parser.add_argument("--corrections", type=Path)
    parser.add_argument("--check", action="store_true", help="aligns with the corrections' depth rotation too")
    parser.add_argument("--step", type=int, default=1)
    parser.add_argument("--save", type=Path, help="writes the creases found, one JSON object per line")
    args = parser.parse_args()
    corrections = None if args.corrections is None else json.loads(args.corrections.read_text())
    creases = []
    for path in args.tars:
        rec = Recording(path)
        correction = NO_CORRECTION if corrections is None else corrections["front"] if args.check else corrections["front"] | {"depth_rotation": NO_CORRECTION["depth_rotation"]}
        found = recording_creases(path, correction, args.step)
        print(f"{rec.scan_id}: {len(found)} convex creases, {len(usable(found))} usable", flush=True)
        creases += found
    if args.save is not None:
        args.save.write_text("".join(json.dumps(c) + "\n" for c in creases))
    result = {"lighting": fit_offset(creases, True), "no_lighting": fit_offset(creases, False)}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

"""Checks the front depth rotation measurement end to end against a known answer: renders a synthetic format 4.8 front recording of a lit outward corner with a rounded edge, scanned with the phone held in all four ways, whose depth maps sit off the color frames by a known rotation and whose lens is Apple's table plus a known residual radial distortion; measures the rotation from it with front_depth_rotation_fit.py, then measures again on its frames aligned with that rotation (align_recording.py's resampling), which must find nothing left.

The scene: a vertical outward corner of two walls meeting at 90 degrees, its edge rounded with radius EDGE_RADIUS, lit by a directional light from the upper left (the left wall brighter) and an ambient term, with luma noise; depth noise grows with the square of the distance. The camera sweeps around the corner from one wall to the other at 0.3 to 0.55 m, the phone held upright, upside down and sideways both ways.

The synthetic recording takes its frame sizes, intrinsic matrix and Apple distortion from a real front recording (`--like`).

Usage: python tools/check_front_depth_rotation.py <scratch folder> --like <front recording.tar>
"""

import argparse
import hashlib
import io
import json
import tarfile
from multiprocessing import Pool
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np

import front_depth_rotation_fit as fit
from align_recording import rotation_matrix
from camera_models import apple_distort, radial_distort
from rgbd_recording import Recording

# The known answer: the depth maps see color ray n at TRUE_ROTATION n, and the lens adds TRUE_RESIDUAL after Apple's table.
TRUE_ROTATION = [0.0025, -0.0045, 0.0]
TRUE_RESIDUAL = (-0.003, 0.002)
EDGE_RADIUS = 0.003
LIGHT = np.array([-0.6, 0.5, 0.6]) / np.linalg.norm([-0.6, 0.5, 0.6])
AMBIENT, DIFFUSE = 40.0, 170.0
LUMA_NOISE = 2.0
DEPTH_NOISE_AT_04 = 0.001
FRAMES_PER_HOLD = 30
HOLDS = (90, 270, 0, 180)
SEED = 0
WORKERS = 16
PHONE_ID = "SYNTHETIC"


def inverse_lens(x: np.ndarray, y: np.ndarray, intrinsics: Tuple[float, float, float, float], center: Tuple[float, float], table: List[float], size: Tuple[int, int], iterations: int = 30) -> Tuple[np.ndarray, np.ndarray]:
    """The pinhole coordinates whose ray the lens (TRUE_RESIDUAL, then Apple's table) puts at (x, y), by fixed-point iteration."""
    xu, yu = x.copy(), y.copy()
    for _ in range(iterations):
        xd, yd = apple_distort(*radial_distort(xu, yu, intrinsics, *TRUE_RESIDUAL), center, table, size)
        xu, yu = xu - (xd - x), yu - (yd - y)
    return xu, yu


def camera(yaw_deg: float, distance: float, pitch_deg: float, hold: int) -> Tuple[np.ndarray, np.ndarray]:
    """The color camera's world-from-camera rotation and position: on a circle around the corner's edge (world y up, the walls facing +z), looking at the edge, the phone held so that the frame's upright rotation is `hold`."""
    yaw, pitch = np.radians(yaw_deg), np.radians(pitch_deg)
    position = np.array([distance * np.sin(yaw) * np.cos(pitch), distance * np.sin(pitch), distance * np.cos(yaw) * np.cos(pitch)])
    forward = -position / np.linalg.norm(position)
    up = np.array([0.0, 1.0, 0.0])
    up_perp = up - (up @ forward) * forward
    up_perp /= np.linalg.norm(up_perp)
    # The sensor image's direction that points up in the world: rotating the frame clockwise by `hold` makes it point up on screen.
    up_in_image = {0: np.array([0.0, -1.0]), 90: np.array([-1.0, 0.0]), 180: np.array([0.0, 1.0]), 270: np.array([1.0, 0.0])}[hold]
    right_perp = np.cross(forward, up_perp)
    # The image directions of world up (u) and world right (r, u turned clockwise on screen) map to up_perp and right_perp, which fixes the camera's x (image right) and y (image down) axes in the world.
    right_in_image = np.array([-up_in_image[1], up_in_image[0]])
    x_axis = up_perp * up_in_image[0] + right_perp * right_in_image[0]
    y_axis = up_perp * up_in_image[1] + right_perp * right_in_image[1]
    return np.stack([x_axis, y_axis, forward], axis=1), position


def cast(origins: np.ndarray, directions: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """Each ray's distance to the corner along its direction (inf on a miss) and the surface normal there: the left wall z = x for x <= -r / sqrt 2, the right wall z = -x for x >= r / sqrt 2, and the rounded edge between, a cylinder of radius r about the vertical line x = 0, z = -r sqrt 2."""
    r = EDGE_RADIUS
    best = np.full(directions.shape[0], np.inf)
    normal = np.zeros_like(directions)
    for wall, sign in (("left", -1.0), ("right", 1.0)):
        # Plane z + sign * x = 0, normal (sign, 0, 1) / sqrt 2.
        n = np.array([sign, 0.0, 1.0]) / np.sqrt(2)
        denominator = directions @ n
        t = -(origins @ n) / np.where(np.abs(denominator) > 1e-12, denominator, 1e-12)
        hit = origins + t[:, None] * directions
        ok = (t > 0) & (sign * hit[:, 0] >= r / np.sqrt(2)) & (np.abs(hit[:, 0]) < 1.5) & (np.abs(hit[:, 1]) < 1.5)
        closer = ok & (t < best)
        best[closer] = t[closer]
        normal[closer] = n
    # The cylinder in the x-z plane, its front arc only (normals between the walls').
    center = np.array([0.0, -r * np.sqrt(2)])
    o, d = origins[:, [0, 2]] - center, directions[:, [0, 2]]
    a, b, c = (d * d).sum(1), 2 * (o * d).sum(1), (o * o).sum(1) - r * r
    disc = b * b - 4 * a * c
    t = (-b - np.sqrt(np.maximum(disc, 0))) / (2 * np.maximum(a, 1e-12))
    hit = o + t[:, None] * d
    n_xz = hit / r
    ok = (disc > 0) & (t > 0) & (n_xz[:, 1] >= np.cos(np.radians(45)) - 1e-9)
    closer = ok & (t < best)
    best[closer] = t[closer]
    normal[closer] = np.c_[n_xz[closer, 0], np.zeros(closer.sum()), n_xz[closer, 1]]
    return best, normal


def render(job: Tuple[int, float, float, float, int]) -> Tuple[bytes, bytes]:
    """One frame: its 420f color frame and Float32 depth map, raw (through the lens, depth off by TRUE_ROTATION)."""
    index, yaw, distance, pitch, hold = job
    rng = np.random.default_rng(SEED + index)
    world_from_camera, position = camera(yaw, distance, pitch, hold)
    color_rays, depth_rays = RAYS["color"], RAYS["depth"]
    t, normal = cast(np.broadcast_to(position, color_rays.shape), color_rays @ world_from_camera.T)
    shade = AMBIENT + DIFFUSE * np.maximum(normal @ LIGHT, 0)
    width, height = CALIBRATION["color_size"]
    luma = np.where(np.isfinite(t), shade, 0).reshape(height, width)
    luma = np.clip(np.rint(luma + rng.normal(0, LUMA_NOISE, luma.shape)), 0, 255).astype(np.uint8)
    color = np.concatenate([luma, np.full((height // 2, width), 128, np.uint8)])
    # The depth map's ray d is color ray R^T d; its reading is the hit's z along d.
    rotation = rotation_matrix(TRUE_ROTATION)
    color_dirs = depth_rays @ rotation
    t, _ = cast(np.broadcast_to(position, color_dirs.shape), color_dirs @ world_from_camera.T)
    points = t[:, None] * color_dirs
    z = (points @ rotation.T)[:, 2]
    z = np.where(np.isfinite(t), z + rng.normal(0, 1, z.shape) * DEPTH_NOISE_AT_04 * (z / 0.4) ** 2, np.nan).reshape(CALIBRATION["depth_size"][1], CALIBRATION["depth_size"][0])
    return color.tobytes(), z.astype("<f4").tobytes()


# Each worker's pixel rays of the raw color frame and depth map (color camera frame, z = 1), built once by `start_worker`, and the calibration taken from the real recording.
RAYS: Dict[str, np.ndarray] = {}
CALIBRATION: Dict[str, object] = {}


def pixel_rays(size: Tuple[int, int], intrinsics: Tuple[float, float, float, float], center: Tuple[float, float], table: List[float]) -> np.ndarray:
    """The color-camera ray (z = 1) of every pixel of a raw image of `size` through the lens."""
    rows, cols = np.mgrid[0:size[1], 0:size[0]].astype(np.float64)
    xu, yu = inverse_lens(cols.ravel() + 0.5, rows.ravel() + 0.5, intrinsics, center, table, size)
    fx, fy, cx, cy = intrinsics
    return np.stack([(xu - cx) / fx, (yu - cy) / fy, np.ones_like(xu)], 1)


def start_worker(color_rays: np.ndarray, depth_rays: np.ndarray, calibration: Dict[str, object]) -> None:
    RAYS["color"], RAYS["depth"] = color_rays, depth_rays
    CALIBRATION.update(calibration)


def real_calibration(path: Path) -> Dict[str, object]:
    """A real front recording's frame sizes, first color intrinsic matrix (from the corner) and first color distortion."""
    rec = Recording(path)
    assert rec.camera == "front" and rec.color_principal_point_origin == "upper_left_pixel_corner", (rec.camera, rec.color_principal_point_origin)
    distortion = rec.color_distortions[0]
    return {"color_size": (rec.color_width, rec.color_height), "depth_size": (rec.depth_width, rec.depth_height), "color_k": tuple(float(rec.colors[0][k]) for k in ("fx", "fy", "cx", "cy")), "center": tuple(distortion["center"]), "table": list(distortion["lookup_table"])}


def json_member(tar: tarfile.TarFile, name: str, content: Dict) -> None:
    data = (json.dumps(content, indent=2) + "\n").encode()
    info = tarfile.TarInfo(name)
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))


def write_recording(folder: Path, calibration: Dict[str, object]) -> Path:
    """Renders the synthetic recording with the real calibration into folder/<scan_id>.tar."""
    color_size, depth_size, color_k, center, table = (calibration[k] for k in ("color_size", "depth_size", "color_k", "center", "table"))
    scale = depth_size[0] / color_size[0]
    depth_k = tuple(v * scale for v in color_k)
    depth_center = (center[0] * scale, center[1] * scale)
    color_rays = pixel_rays(color_size, color_k, center, table)
    depth_rays = pixel_rays(depth_size, depth_k, depth_center, table)
    rng = np.random.default_rng(SEED)
    jobs = []
    for h, hold in enumerate(HOLDS):
        for i, yaw in enumerate(np.linspace(-40, 40, FRAMES_PER_HOLD)):
            jobs.append((len(jobs), float(yaw), float(rng.uniform(0.3, 0.55)), float(rng.uniform(-10, 10)), hold))
    with Pool(WORKERS, start_worker, (color_rays, depth_rays, calibration)) as pool:
        frames = pool.map(render, jobs)
    scan_id = "rgbd_20261010_000000_front"
    count = len(jobs)
    times = [1000.0 + i / 15 for i in range(count)]
    color_bin = b"".join(f[0] for f in frames)
    depth_bin = b"".join(f[1] for f in frames)
    # The inverse table is not read by the pipeline; the forward table stands in for it.
    distortion = {"lookup_table": table, "inverse_lookup_table": table}
    path = folder / f"{scan_id}.tar"
    with tarfile.open(path, "w", format=tarfile.GNU_FORMAT) as tar:
        for name, data in (("color_frames.bin", color_bin), ("depth_frames.bin", depth_bin)):
            info = tarfile.TarInfo(f"{scan_id}/{name}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        json_member(tar, f"{scan_id}/scan_metadata.json", {"format_version": "4.8", "scan_id": scan_id, "name": "synthetic corner", "start_time_utc": "2026-10-10T00:00:00Z", "duration_s": times[-1] - times[0], "phone_model": "synthetic", "phone_id": PHONE_ID, "ios_version": "0", "camera": "front", "frame_rate": 15.0, "recovered": False})
        json_member(tar, f"{scan_id}/color_frames_metadata.json", {"file": "color_frames.bin", "size": len(color_bin), "sha256": hashlib.sha256(color_bin).hexdigest(), "width": color_size[0], "height": color_size[1], "pixel_format": "420f", "ycbcr_matrix": "ITU_R_601_4", "frame_count": count,
                                                                       "frames": [{"timestamp": t, "upright_rotation_deg": job[4], "gravity": None, "gravity_timestamp": None, "exposure_duration_s": 0.01} for t, job in zip(times, jobs, strict=True)], "dropped": []})
        json_member(tar, f"{scan_id}/depth_frames_metadata.json", {"file": "depth_frames.bin", "size": len(depth_bin), "sha256": hashlib.sha256(depth_bin).hexdigest(), "width": depth_size[0], "height": depth_size[1], "pixel_format": "fdep", "frame_count": count,
                                                                       "frames": [{"timestamp": t, "filtered": False, "accuracy": "absolute", "quality": "high"} for t in times], "dropped": []})
        for name, size, k, c in (("color_intrinsics.json", color_size, color_k, center), ("depth_intrinsics.json", depth_size, depth_k, depth_center)):
            json_member(tar, f"{scan_id}/{name}", {"image_width": size[0], "image_height": size[1], "principal_point_origin": "upper_left_pixel_corner", "frames": [dict(zip(("fx", "fy", "cx", "cy"), k, strict=True))] * count,
                                                   "distortions": [distortion | {"center": list(c), "frame_ranges": [[0, count - 1]]}]})
        json_member(tar, f"{scan_id}/extrinsics.json", {"depth_to_color": [{"matrix": np.eye(3, 4).tolist(), "depth_frame_ranges": [[0, count - 1]]}]})
    return path


def measure(path: Path, correction: Dict) -> Dict[str, object]:
    """The offset fit with the corner's lighting modeled, and without it for comparison, on the recording's creases aligned with the correction."""
    creases = fit.recording_creases(path, correction, 1)
    return {"lighting": fit.fit_offset(creases, True), "no_lighting": fit.fit_offset(creases, False)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", type=Path)
    parser.add_argument("--like", type=Path, required=True)
    args = parser.parse_args()
    args.folder.mkdir(parents=True, exist_ok=True)
    calibration = real_calibration(args.like)
    raw = write_recording(args.folder, calibration)
    lens = {"k1": TRUE_RESIDUAL[0], "k2": TRUE_RESIDUAL[1]}
    before = measure(raw, {"lens_distortion": lens, "depth_rotation": {"rotation_vector_rad": [0.0, 0.0, 0.0]}})
    ox, oy = before["lighting"]["parameters"]["ox"]["value"], before["lighting"]["parameters"]["oy"]["value"]
    full_fx = calibration["color_k"][0] * fit.FULL_WIDTH / calibration["color_size"][0]
    measured = fit.rotation_vector(ox, oy, full_fx)
    # The offset the true rotation makes: rotation_vector inverted, (ox, oy) = (-ry, rx) * full_fx.
    true_offset = [-TRUE_ROTATION[1] * full_fx, TRUE_ROTATION[0] * full_fx]
    print(json.dumps({"before": before, "true_offset_full_px": true_offset, "true_rotation_vector": TRUE_ROTATION, "measured_rotation_vector": measured}, indent=2), flush=True)
    after = measure(raw, {"lens_distortion": lens, "depth_rotation": {"rotation_vector_rad": measured}})
    print(json.dumps({"after": after}, indent=2))


if __name__ == "__main__":
    main()

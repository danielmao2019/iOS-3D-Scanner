"""Tests the alignment pipeline: Apple's lookup-table distortion, the radial distortion and its focus-following coefficients against values worked out by hand; that a depth map of a plane, rendered through a lens (the rear's radial distortion on ARKit's depth grid, and the front's Apple table with its depth off by a rotation), aligns onto the plane's depth along every pinhole ray; that the front depth rotation measured as an offset moves the depth map the way the offset says; and that align_recording writes, from tiny synthetic 4.8 front and rear tars, aligned recordings the reader reads, with no distortions, identity depth-to-color, plainly scaled depth intrinsic matrices, the correction applied and frame files matching their recorded checksums.

Usage, from the repository's root: python -m pytest tools/test_align_recording.py
"""

import hashlib
import tarfile
from pathlib import Path
from typing import Tuple

import numpy as np
import pytest

from align_recording import align, align_depth, depth_intrinsic_matrix, lens_coefficients, rotation_matrix, source_coordinates
from camera_models import apple_distort, pixel_centers, radial_distort
from front_depth_rotation_fit import rotation_vector
from rgbd_recording import Recording
from test_rgbd_recording import synthetic_tar

PHONE_ID = "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E"
# A plane in the camera frame, n . p = d, tilted against both image axes, about 1 m away.
PLANE_NORMAL = np.array([0.2, -0.1, 1.0]) / np.linalg.norm([0.2, -0.1, 1.0])
PLANE_D = 1.0


def test_apple_distort() -> None:
    # Center (10, 10) in a 20 x 20 image: the table spans radius 0 to hypot(10, 10) = 14.142 in two steps of 7.071.
    table = [0.0, 0.01, 0.02]
    x, y = apple_distort(np.array([15.0, 10.0, 30.0]), np.array([10.0, 13.0, 10.0]), (10.0, 10.0), table, (20, 20))
    # (15, 10): radius 5, 0.7071 of the first step, magnification 0.007071, x = 10 + 5 * 1.007071.
    assert x[0] == pytest.approx(15.035355, abs=1e-6) and y[0] == pytest.approx(10.0)
    # (10, 13): radius 3, magnification 0.004243, y = 10 + 3 * 1.004243.
    assert x[1] == pytest.approx(10.0) and y[1] == pytest.approx(13.012728, abs=1e-6)
    # (30, 10): radius 20, beyond the table, its last entry 0.02, x = 10 + 20 * 1.02.
    assert x[2] == pytest.approx(30.4) and y[2] == pytest.approx(10.0)


def test_radial_distort() -> None:
    # Normalized (0.5, 0.25): r^2 = 0.3125, scale 1 + 0.1 * 0.3125 - 0.05 * 0.09765625 = 1.026367.
    x, y = radial_distort(np.array([150.0]), np.array([125.0]), (200.0, 400.0, 50.0, 25.0), 0.1, -0.05)
    assert x[0] == pytest.approx(50 + 0.5 * 1.0263672 * 200, abs=1e-5) and y[0] == pytest.approx(25 + 0.25 * 1.0263672 * 400, abs=1e-5)


def test_lens_coefficients_follow_focus_within_range() -> None:
    lens = {"k1": 0.05, "k2": -0.06, "focus": {"fx_reference": 1400.0, "fx_range": [1386.0, 1428.0], "k1_slope": -2.0, "k2_slope": 1.0}}
    assert lens_coefficients(lens, 1414.0) == pytest.approx((0.05 - 2.0 * 0.01, -0.06 + 1.0 * 0.01))
    # Beyond the measured range the focal length is held at the range's end.
    assert lens_coefficients(lens, 1500.0) == pytest.approx((0.05 - 2.0 * 0.02, -0.06 + 1.0 * 0.02))
    assert lens_coefficients({"k1": 0.01, "k2": 0.02}, 1500.0) == (0.01, 0.02)


def plane_depth(rays: np.ndarray) -> np.ndarray:
    """The depth (z) at which each ray (z = 1) meets the plane."""
    return PLANE_D / (rays @ PLANE_NORMAL)


def inverse(distort, x: np.ndarray, y: np.ndarray, iterations: int = 50) -> Tuple[np.ndarray, np.ndarray]:
    """The undistorted coordinates the lens `distort` sends to (x, y), by fixed-point iteration."""
    xu, yu = x.copy(), y.copy()
    for _ in range(iterations):
        xd, yd = distort(xu, yu)
        xu, yu = xu - (xd - x), yu - (yd - y)
    return xu, yu


def test_rear_depth_aligns_onto_plane() -> None:
    """A rear depth map on ARKit's grid (x: first depth column's center on the first color column's center; y: rows spanning the color rows), through a radial lens, aligned onto the plainly scaled pinhole grid."""
    color_width, color_height, depth_width, depth_height = 1920, 1440, 256, 192
    s = depth_width / color_width
    color = (1435.0, 1435.0, 961.3, 718.6)
    k1, k2 = 0.05, -0.06
    # ARKit's depth intrinsic matrix from pixel (0, 0)'s center, then from the corner.
    arkit = (color[0] * s, color[1] * s, color[2] * s, (color[3] + 0.5) * s - 0.5)
    recorded = (arkit[0], arkit[1], arkit[2] + 0.5, arkit[3] + 0.5)
    x, y = pixel_centers(depth_width, depth_height)
    xu, yu = inverse(lambda a, b: radial_distort(a, b, recorded, k1, k2), x, y)
    raw = plane_depth(np.stack([(xu - recorded[2]) / recorded[0], (yu - recorded[3]) / recorded[1], np.ones_like(xu)], -1)).astype(np.float32)
    plain = depth_intrinsic_matrix(dict(zip(("fx", "fy", "cx", "cy"), color)), s, s, "upper_left_pixel_center")
    output = (plain["fx"], plain["fy"], plain["cx"] + 0.5, plain["cy"] + 0.5)
    xd, yd, z = source_coordinates(depth_width, depth_height, output, recorded, lambda a, b: radial_distort(a, b, recorded, k1, k2))
    aligned, _ = align_depth(raw, xd, yd, z, None)
    ox, oy = pixel_centers(depth_width, depth_height)
    expected = plane_depth(np.stack([(ox - output[2]) / output[0], (oy - output[3]) / output[1], np.ones_like(ox)], -1))
    read = aligned > 0
    assert read.mean() > 0.97
    assert np.abs(aligned[read] - expected[read]).max() < 2e-4


def test_front_depth_aligns_onto_plane_through_rotation() -> None:
    """A front depth map registered to the distorted color image through Apple's table, off by a rotation: the depth map sees color ray n at R n and reads z along R n; aligned with R, it reads the plane's depth along every pinhole ray."""
    width, height = 640, 480
    k = (435.0, 435.0, 320.5, 238.4)
    center, table = (320.5, 238.4), [0.0, -0.0006, -0.0003, 0.002, 0.006, 0.011, 0.015]
    rotation = rotation_matrix([0.003, -0.006, 0.001])

    def lens(a: np.ndarray, b: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
        return apple_distort(a, b, center, table, (width, height))

    x, y = pixel_centers(width, height)
    xu, yu = inverse(lens, x, y)
    seen = np.stack([(xu - k[2]) / k[0], (yu - k[3]) / k[1], np.ones_like(xu)], -1)
    color_rays = seen @ rotation
    points = plane_depth(color_rays / color_rays[..., 2:])[..., None] * color_rays / color_rays[..., 2:]
    raw = (points @ rotation.T)[..., 2].astype(np.float32)
    xd, yd, z = source_coordinates(width, height, k, k, lens, rotation)
    aligned, _ = align_depth(raw, xd, yd, z, None)
    expected = plane_depth(np.stack([(x - k[2]) / k[0], (y - k[3]) / k[1], np.ones_like(x)], -1))
    read = aligned > 0
    assert read.mean() > 0.95
    assert np.abs(aligned[read] - expected[read]).max() < 2e-4


def test_rotation_moves_depth_by_the_measured_offset() -> None:
    """An offset (ox, oy), color edge minus depth crease in full-sensor px, means the depth map shows a point (ox, oy) away from color the other way; aligning with rotation_vector's rotation samples the depth map there."""
    full_fx, ox, oy = 2740.48, -15.0, -9.0
    rotation = rotation_matrix(rotation_vector(ox, oy, full_fx))
    k = (full_fx, full_fx, 2016.0, 1512.0)
    xd, yd, _ = source_coordinates(4032, 3024, k, k, lambda a, b: (a, b), rotation)
    # Near the principal point the aligned pixel samples the recorded map at its own position minus (ox, oy).
    assert xd[1512, 2016] - 2016.5 == pytest.approx(-ox, abs=0.05) and yd[1512, 2016] - 1512.5 == pytest.approx(-oy, abs=0.05)


@pytest.mark.parametrize("camera", ["front", "rear"])
def test_align_writes_aligned_recording(tmp_path: Path, camera: str) -> None:
    raw_path = synthetic_tar(tmp_path, camera, "ITU_R_601_4", "4.8")
    focus = {"focus": {"fx_reference": 6.9, "fx_range": [6.9, 6.93], "k1_slope": -1.0, "k2_slope": 0.5}} if camera == "rear" else {}
    correction = {"lens_distortion": {"k1": 0.01, "k2": -0.01} | focus} | ({"depth_rotation": {"rotation_vector_rad": [0.001, -0.002, 0.0]}} if camera == "front" else {})
    path = align(raw_path, {"phone_id": PHONE_ID, camera: correction}, tmp_path / "aligned")
    raw, rec = Recording(raw_path), Recording(path)
    assert rec.aligned and rec.scan_metadata["alignment"] == {"phone_id": PHONE_ID} | correction
    assert rec.color.shape == raw.color.shape and rec.depth.shape == raw.depth.shape and rec.depth.dtype == np.float32
    assert rec.color_distortions is None and rec.depth_distortions is None
    assert all(np.array_equal(t, np.eye(3, 4)) for t in rec.depth_to_color)
    assert rec.color_intrinsics["frames"] == raw.color_intrinsics["frames"]
    s = raw.depth_width / raw.color_width
    for color, depth in rec.pairs():
        if color["index"] == "-1":
            continue
        expected = depth_intrinsic_matrix({k: float(color[k]) for k in ("fx", "fy", "cx", "cy")}, s, s, rec.depth_principal_point_origin)
        assert {k: float(depth[k]) for k in expected} == pytest.approx(expected, rel=1e-6)
    with tarfile.open(path, "r:") as tar:
        for member in tar.getmembers():
            name = Path(member.name).name
            if name in rec.frame_files:
                data = tar.extractfile(member).read()
                assert (len(data), hashlib.sha256(data).hexdigest()) == rec.frame_files[name], name
    assert (rec.confidence is not None) == (camera == "rear")


def test_align_rejects_another_phones_corrections(tmp_path: Path) -> None:
    raw_path = synthetic_tar(tmp_path, "rear", "ITU_R_601_4", "4.8")
    with pytest.raises(AssertionError):
        align(raw_path, {"phone_id": "another phone", "rear": {"lens_distortion": {"k1": 0.0, "k2": 0.0}}}, tmp_path / "aligned")

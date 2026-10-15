"""Tests the measurements behind a phone's corrections on synthetic inputs with known answers: the plumb-line fit recovers k1, k2 from straight lines distorted with them, and their slopes when the distortion follows the focal length; the vectorized line distances equal the total-least-squares ones; the crease offset model recovers a depth-to-color offset from creases carrying corner rounding and lighting, separates the two only when a corner is seen with the phone held both ways along an axis, and turns upright normals the way upright_rotation_deg says.

Usage, from the repository's root: python -m pytest tools/test_phone_corrections.py
"""

from typing import List, Tuple

import numpy as np
import pytest

import front_depth_rotation_fit as creases
import lens_distortion_fit as plumb
from camera_models import radial_distort


def distorted_lines(k: Tuple[float, float], fx: float, count: int, seed: int) -> List[plumb.Edge]:
    """Straight lines across a 1920 x 1440 pinhole image, each sampled at 80 points and moved by the radial distortion k under focal length fx."""
    rng = np.random.default_rng(seed)
    intrinsics = (fx, fx, 959.5, 719.5)
    edges = []
    for _ in range(count):
        start, end = rng.uniform((100, 100), (1820, 1340), (2, 2))
        t = np.linspace(0, 1, 80)
        x, y = start[0] + t * (end[0] - start[0]), start[1] + t * (end[1] - start[1])
        xd, yd = radial_distort(x, y, intrinsics, *k)
        edges.append((xd, yd, intrinsics))
    return edges


def test_distances_equal_total_least_squares() -> None:
    edges = distorted_lines((0.05, -0.06), 1435.0, 20, 0)
    packed = plumb.Edges(edges)
    distances = packed.distances(np.zeros((20, 1)), np.zeros((20, 1)))
    for i, (x, y, _) in enumerate(edges):
        centered = np.c_[x, y] - np.c_[x, y].mean(0)
        normal = np.linalg.svd(centered, full_matrices=False)[2][1]
        assert np.abs(np.abs(distances[i, : len(x)]) - np.abs(centered @ normal)).max() < 1e-9


def test_plumb_fit_recovers_k() -> None:
    k = plumb.fit(plumb.Edges(distorted_lines((0.047, -0.058), 1435.0, 200, 1)))
    assert k[0] == pytest.approx(0.047, abs=1e-4) and k[1] == pytest.approx(-0.058, abs=2e-4)


def test_plumb_fit_recovers_focus_slopes() -> None:
    # k1 = 0.05 + 2.0 d, k2 = -0.06 - 1.0 d, d = fx / 1435 - 1, at three focal lengths.
    edges = []
    for i, fx in enumerate((1420.0, 1435.0, 1465.0)):
        d = fx / 1435.0 - 1
        edges += distorted_lines((0.05 + 2.0 * d, -0.06 - 1.0 * d), fx, 150, 10 + i)
    params = plumb.fit(plumb.Edges(edges), 1435.0)
    assert np.all(np.abs(params - [0.05, -0.06, 2.0, -1.0]) < [2e-4, 4e-4, 0.05, 0.1]), params


def synthetic_creases(offset: Tuple[float, float], holds: Tuple[int, ...], seed: int) -> List[dict]:
    """Creases of one vertical corner seen with the phone held each of `holds` ways: t0 = O . n + rounding * obliquity + lighting * (n_up . x), noise 1 px."""
    rng = np.random.default_rng(seed)
    out = []
    for hold in holds:
        for i in range(60):
            # The corner is vertical in the world, so its upright normal is +-x; the sensor normal is that turned back by the hold.
            n_up = np.array([1.0, 0.0]) * rng.choice((-1, 1)) + rng.normal(0, 0.05, 2)
            n_up /= np.linalg.norm(n_up)
            angle = -np.radians(hold)
            n = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]]) @ n_up
            obliquity = rng.uniform(-0.6, 0.6)
            t0 = offset[0] * n[0] + offset[1] * n[1] - 9.0 * obliquity + 4.0 * n_up[0] + rng.normal(0, 1)
            out.append({"t0": t0, "width": 8.0, "contrast": 50.0, "r2": 0.99, "nx": n[0], "ny": n[1], "n_up": n_up.tolist(), "obliquity": obliquity, "scan": "corner", "frame": len(out)})
    return out


def test_upright_vector_turns_clockwise() -> None:
    # Held with upright rotation 90, the sensor image's +x (right) shows as down on screen, its +y (down) as left.
    assert creases.upright_vector(np.array([1.0, 0.0]), 90) == pytest.approx([0.0, 1.0])
    assert creases.upright_vector(np.array([0.0, 1.0]), 90) == pytest.approx([-1.0, 0.0])


def test_offset_recovered_with_all_four_holds() -> None:
    fitted = creases.fit_offset(synthetic_creases((-15.0, -9.0), (0, 90, 180, 270), 0), True)
    assert fitted["separable"] == {"x": True, "y": True}
    assert fitted["parameters"]["ox"]["value"] == pytest.approx(-15.0, abs=0.3) and fitted["parameters"]["oy"]["value"] == pytest.approx(-9.0, abs=0.3)
    assert fitted["parameters"]["b:corner"]["value"] == pytest.approx(4.0, abs=0.3)


def test_offset_not_separable_with_one_hold() -> None:
    fitted = creases.fit_offset(synthetic_creases((-15.0, -9.0), (90,), 0), True)
    assert fitted["separable"] == {"x": False, "y": False}

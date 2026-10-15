"""The lens distortion models an RGBD Scanner recording's frames need, as maps from undistorted to distorted pixel coordinates: Apple's radial lookup table for the front camera, which a recording carries, and the radial polynomial k1, k2 for the rear camera, which ARKit leaves out and phone_corrections.py measures per phone.

Coordinates here are continuous pixel coordinates with the origin at the image's upper-left corner, pixel (i, j)'s center at (i + 0.5, j + 0.5), the convention of Apple's AVFoundation calibration (principal_point_origin "upper_left_pixel_corner"); a rear frame's ARKit intrinsic matrix, measured from pixel (0, 0)'s center, is moved to it by adding 0.5 to cx and cy (`corner_origin`).
"""

from typing import Dict, Sequence, Tuple

import numpy as np

# Intrinsic matrix entries in the order every recording file and this module use.
Intrinsics = Tuple[float, float, float, float]


def corner_origin(intrinsics: Intrinsics, origin: str) -> Intrinsics:
    """fx, fy, cx, cy measured from the image's upper-left corner, from a matrix measured from `origin`, a recording's principal_point_origin."""
    def _validate_inputs() -> None:
        assert origin in ("upper_left_pixel_corner", "upper_left_pixel_center"), origin

    _validate_inputs()

    fx, fy, cx, cy = intrinsics
    shift = 0.5 if origin == "upper_left_pixel_center" else 0.0
    return fx, fy, cx + shift, cy + shift


def lookup_table_radius(center: Sequence[float], size: Sequence[int]) -> float:
    """The radius Apple's lookup table spans: from the distortion center to the image's farthest corner."""
    return float(np.hypot(max(center[0], size[0] - center[0]), max(center[1], size[1] - center[1])))


def apple_distort(x: np.ndarray, y: np.ndarray, center: Sequence[float], table: Sequence[float], size: Sequence[int]) -> Tuple[np.ndarray, np.ndarray]:
    """Where undistorted points (x, y) of an image of `size` appear in the frame, by Apple's lensDistortionPointForPoint with lensDistortionLookupTable: each point moves radially from `center` by the table's magnification at its own radius, the table's entries evenly spaced from radius 0 to `lookup_table_radius` and its last entry holding beyond it."""
    def _validate_inputs() -> None:
        assert len(table) >= 2, len(table)
        assert x.shape == y.shape, (x.shape, y.shape)

    _validate_inputs()

    values = np.asarray(table, np.float64)
    vx, vy = x - center[0], y - center[1]
    radius = np.hypot(vx, vy)
    limit = lookup_table_radius(center, size)
    position = radius * (values.size - 1) / limit
    index = np.clip(np.floor(position).astype(np.int64), 0, values.size - 2)
    fraction = position - index
    magnification = np.where(radius < limit, (1 - fraction) * values[index] + fraction * values[index + 1], values[-1])
    return center[0] + vx * (1 + magnification), center[1] + vy * (1 + magnification)


def radial_distort(x: np.ndarray, y: np.ndarray, intrinsics: Intrinsics, k1: float, k2: float) -> Tuple[np.ndarray, np.ndarray]:
    """Where undistorted points (x, y) appear in the frame under the radial model of COLMAP's RADIAL and OpenCV's k1, k2: normalized coordinates (x - cx) / fx, (y - cy) / fy scaled by 1 + k1 r^2 + k2 r^4, r their distance from the principal point."""
    def _validate_inputs() -> None:
        assert x.shape == y.shape, (x.shape, y.shape)

    _validate_inputs()

    fx, fy, cx, cy = intrinsics
    xn, yn = (x - cx) / fx, (y - cy) / fy
    r2 = xn * xn + yn * yn
    scale = 1 + k1 * r2 + k2 * r2 * r2
    return cx + xn * scale * fx, cy + yn * scale * fy


def pixel_centers(width: int, height: int) -> Tuple[np.ndarray, np.ndarray]:
    """Every pixel center of a width x height image, x and y, height x width float64."""
    rows, cols = np.mgrid[0:height, 0:width].astype(np.float64)
    return cols + 0.5, rows + 0.5


def scaled_distortion(distortion: Dict, scale_x: float, scale_y: float) -> Dict:
    """An Apple distortion (center, lookup_table, image size) carried to an image scale_x by scale_y times as large; the table is radius-normalized, so only the center and the size move."""
    center, size = distortion["center"], distortion["size"]
    return {"center": (center[0] * scale_x, center[1] * scale_y), "lookup_table": distortion["lookup_table"], "size": (size[0] * scale_x, size[1] * scale_y)}

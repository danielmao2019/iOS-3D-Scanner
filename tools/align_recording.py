"""Aligns an RGBD Scanner recording: from a format 4.8 recording tar and its phone's corrections file (phone_corrections.py), writes <out>/<scan_id>.tar, an aligned recording, in which each color frame matches its color intrinsic matrix, each depth frame matches its depth intrinsic matrix, and each depth frame lies on its same-instant color frame.

Each frame is resampled onto the pinhole image of the intrinsic matrix it carries, every pixel taking the recorded frame's value where the lens put that pixel's ray:
- color: through the phone's lens distortion for the camera, which the recording does not describe (`camera_models.radial_distort`, its k1, k2 following the frame's focus where the corrections give their slopes, `lens_coefficients`), then, on the front, through the recorded Apple distortion (`camera_models.apple_distort`); the color intrinsic matrices stay as recorded.
- depth: onto the color frame's grid scaled to the depth map's size, the depth intrinsic matrix being the color one scaled plainly (`depth_intrinsic_matrix`), through the same lens on the depth map's own grid, which Apple and ARKit both lay on the color image; a front depth map after turning each ray by the phone's front depth rotation, the angle by which Apple's registration leaves the depth map off the color image.

An aligned recording is a format 4.8 recording (tools/rgbd_recording.py) with these differences: scan_metadata.json adds alignment, the corrections file's phone_id and what it said to apply to this camera (`camera_correction`); color_frames.bin holds the resampled 420f frames, luma and chroma each resampled bicubically, the recorded frame's edge pixels repeated over the half pixel beyond their centers, and a pixel whose ray falls outside the recorded frame black (Y 0, Cb and Cr 128); depth_frames.bin holds the resampled maps as Float32 metres ("fdep"), a value interpolated in inverse depth where the four recorded readings around its ray agree (DEPTH_AGREEMENT; extrapolated over the half pixel beyond the outermost pixel centers) and no reading (0) where they do not, which leaves a gap of about a pixel along each occluding edge instead of moving the edge or mixing its two surfaces; the rear's depth_frames_confidence.bin takes the nearest recorded level; the frames metadata record the new files' sizes and SHA-256s; color_intrinsics.json and depth_intrinsics.json carry no distortions, the rear's depth intrinsic matrices being their color frames' scaled plainly; and extrinsics.json's depth_to_color is the identity for every depth frame.

Usage: python tools/align_recording.py <recording.tar> --corrections <phone_id>.json --out <folder>
"""

import argparse
import hashlib
import io
import json
import tarfile
from multiprocessing import Pool
from pathlib import Path
from typing import Callable, Dict, Iterator, List, Optional, Tuple

import cv2
import numpy as np

from camera_models import Intrinsics, apple_distort, corner_origin, pixel_centers, radial_distort, scaled_distortion
from rgbd_recording import DEPTH_DTYPES, INTRINSICS, Recording, valid

# Four recorded depth readings around a ray agree when their inverse depths differ by at most DEPTH_AGREEMENT of the smallest, which a surface seen at up to about 85 degrees from a depth pixel's ray passes, or by at most DEPTH_AGREEMENT_INVERSE per metre, which TrueDepth's own spread passes (its readings scatter by a constant amount in inverse depth, about 0.03 per metre at the 90th percentile, quantized in steps of about 2.7 cm at 2 m); readings across an occluding edge differ by more.
DEPTH_AGREEMENT = 0.05
DEPTH_AGREEMENT_INVERSE = 0.1
# Black in full-range YCbCr.
BLACK_LUMA = 0
NEUTRAL_CHROMA = 128
WORKERS = 16
CHUNK = 8 << 20
# Maps undistorted to distorted pixel coordinates, both from the image's upper-left corner.
Distort = Callable[[np.ndarray, np.ndarray], Tuple[np.ndarray, np.ndarray]]
# Corner-origin x and y coordinates in a recorded frame, one per aligned pixel.
Coordinates = Tuple[np.ndarray, np.ndarray]


def rotation_matrix(rotation_vector: List[float]) -> np.ndarray:
    """The 3 x 3 rotation of a rotation vector (axis times angle in radians), by Rodrigues' formula."""
    matrix, _ = cv2.Rodrigues(np.asarray(rotation_vector, np.float64).reshape(3, 1))
    return matrix


def source_coordinates(width: int, height: int, output: Intrinsics, recorded: Intrinsics, distort: Distort, rotation: Optional[np.ndarray] = None) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """For every pixel of a width x height pinhole image with intrinsic matrix `output`, where its ray lies in the recorded frame, whose undistorted geometry is the intrinsic matrix `recorded` and whose lens is `distort`, after the ray is turned by `rotation` when one is given (both matrices from the image's corner): the recorded frame's x and y pixel coordinates from its corner, and the ray's z component after the turn, its own being 1."""
    x, y = pixel_centers(width, height)
    fx, fy, cx, cy = output
    rays = np.stack([(x - cx) / fx, (y - cy) / fy, np.ones_like(x)], axis=-1)
    if rotation is not None:
        rays = rays @ rotation.T
    z = rays[..., 2]
    rfx, rfy, rcx, rcy = recorded
    xd, yd = distort(rays[..., 0] / z * rfx + rcx, rays[..., 1] / z * rfy + rcy)
    return xd, yd, z


def outside(xd: np.ndarray, yd: np.ndarray, width: int, height: int) -> np.ndarray:
    """Which corner-origin coordinates fall outside a width x height frame."""
    return (xd < 0) | (xd > width) | (yd < 0) | (yd > height)


def remap_maps(xd: np.ndarray, yd: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """Corner-origin coordinates as cv2.remap's maps, which index pixel centers."""
    return (xd - 0.5).astype(np.float32), (yd - 0.5).astype(np.float32)


def align_color(frame: np.ndarray, luma: Coordinates, chroma: Coordinates) -> np.ndarray:
    """A 420f color frame (luma rows, then CbCr rows) resampled bicubically: its luma plane at the `luma` coordinates and its interleaved CbCr plane, a half-size image, at the `chroma` coordinates; the frame's edge pixels repeat over the half pixel beyond their centers, and coordinates outside the frame give black."""
    height = frame.shape[0] * 2 // 3
    width = frame.shape[1]
    luma_plane = cv2.remap(np.ascontiguousarray(frame[:height]), *remap_maps(*luma), cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)
    luma_plane[outside(*luma, width, height)] = BLACK_LUMA
    cbcr = np.ascontiguousarray(frame[height:]).reshape(height // 2, width // 2, 2)
    chroma_plane = cv2.remap(cbcr, *remap_maps(*chroma), cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)
    chroma_plane[outside(*chroma, width // 2, height // 2)] = NEUTRAL_CHROMA
    return np.concatenate([luma_plane, chroma_plane.reshape(height // 2, width)], axis=0)


def align_depth(depth: np.ndarray, xd: np.ndarray, yd: np.ndarray, z_ratio: np.ndarray, confidence: Optional[np.ndarray]) -> Tuple[np.ndarray, Optional[np.ndarray]]:
    """A depth map (and the rear's confidence map) resampled at recorded-map coordinates (xd, yd) from its corner: depth interpolated bilinearly in inverse depth, which is linear across a plane, where the four readings around agree (DEPTH_AGREEMENT), and extrapolated the same way over the half pixel between the outermost pixel centers and the map's edge, then divided by z_ratio, the turned ray's z component; no reading (0) where the readings disagree or the point lies outside the map; confidence the nearest level, 0 outside."""
    height, width = depth.shape
    readable = valid(depth)
    inverse = np.where(readable, 1 / np.where(readable, depth, 1), 0).astype(np.float64)
    # Each point's pixel-center coordinates, split into its top-left neighbour and the fraction past it, which runs from -0.5 to 1.5 at the map's edges.
    u = np.clip(xd - 0.5, -0.5, width - 0.5)
    v = np.clip(yd - 0.5, -0.5, height - 0.5)
    u0 = np.clip(np.floor(u).astype(np.int64), 0, width - 2)
    v0 = np.clip(np.floor(v).astype(np.int64), 0, height - 2)
    fu, fv = u - u0, v - v0
    corners = np.stack([inverse[v0, u0], inverse[v0, u0 + 1], inverse[v0 + 1, u0], inverse[v0 + 1, u0 + 1]])
    weights = np.stack([(1 - fu) * (1 - fv), fu * (1 - fv), (1 - fu) * fv, fu * fv])
    low, high = corners.min(axis=0), corners.max(axis=0)
    beyond = outside(xd, yd, width, height)
    agree = (low > 0) & ((high <= low * (1 + DEPTH_AGREEMENT)) | (high - low <= DEPTH_AGREEMENT_INVERSE)) & ~beyond
    interpolated = np.where(agree, (weights * corners).sum(axis=0), 1)
    aligned = np.where(agree, 1 / interpolated / z_ratio, 0).astype(np.float32)
    aligned_confidence = None
    if confidence is not None:
        nearest = np.argmax(weights, axis=0)
        level = confidence[v0 + nearest // 2, u0 + nearest % 2]
        aligned_confidence = np.where(beyond, 0, level).astype(np.uint8)
    return aligned, aligned_confidence


def lens_coefficients(lens: Dict, fx: float) -> Tuple[float, float]:
    """A camera's lens_distortion k1, k2 for a frame whose color focal length is fx: constant, or, with a focus entry, k + slope * (fx / fx_reference - 1) with fx held within the focus entry's fx_range, where it was measured."""
    if "focus" not in lens:
        return lens["k1"], lens["k2"]
    focus = lens["focus"]
    change = float(np.clip(fx, *focus["fx_range"])) / focus["fx_reference"] - 1
    return lens["k1"] + focus["k1_slope"] * change, lens["k2"] + focus["k2_slope"] * change


def depth_intrinsic_matrix(color: Dict[str, float], scale_x: float, scale_y: float, origin: str) -> Dict[str, float]:
    """A color intrinsic matrix scaled plainly to a depth map scale_x by scale_y times the color frame's size, whose grid is then the color grid's: f * s, and c * s from the corner, (c + 0.5) * s - 0.5 from pixel (0, 0)'s center."""
    shift = 0.5 if origin == "upper_left_pixel_center" else 0.0
    return {"fx": color["fx"] * scale_x, "fy": color["fy"] * scale_y, "cx": (color["cx"] + shift) * scale_x - shift, "cy": (color["cy"] + shift) * scale_y - shift}


def row_matrix(row: Dict[str, str]) -> Dict[str, float]:
    """A delivered frame row's intrinsic matrix."""
    assert all(row[k] for k in INTRINSICS), f"frame {row['index']} has no intrinsic matrix"
    return {k: float(row[k]) for k in INTRINSICS}


class Aligner:
    """The per-frame resampling of one recording (any format_version; `align` writes 4.8 ones) with its camera's correction from the phone corrections file; each worker process builds its own from the recording's path."""

    def __init__(self, path: Path, correction: Dict) -> None:
        rec = Recording(path)
        assert not rec.aligned, rec.path
        self.rec = rec
        self.origin = rec.color_principal_point_origin
        self.scale = (rec.depth_width / rec.color_width, rec.depth_height / rec.color_height)
        # A front recording carries its calibration per frame, constant in practice: its coordinates are computed once per distinct intrinsic matrix and distortion.
        self.cache: Dict[str, Tuple] = {}
        self.lens = correction["lens_distortion"]
        if rec.camera == "front":
            self.rotation = rotation_matrix(correction["depth_rotation"]["rotation_vector_rad"])

    def color_intrinsics(self, index: int) -> Intrinsics:
        """Color frame `index`'s recorded intrinsic matrix, from the image's corner."""
        k = row_matrix(self.rec.colors[index])
        return corner_origin((k["fx"], k["fy"], k["cx"], k["cy"]), self.origin)

    def recorded_depth_intrinsics(self, index: int) -> Intrinsics:
        """Depth frame `index`'s recorded intrinsic matrix, from the image's corner."""
        k = row_matrix(self.rec.depths[index])
        return corner_origin((k["fx"], k["fy"], k["cx"], k["cy"]), self.origin)

    def depth_intrinsics(self, index: int) -> Dict[str, float]:
        """Aligned depth frame `index`'s intrinsic matrix, measured from the recording's principal point origin: the front's as recorded, already its color frame's scaled plainly; the rear's the color matrix that ARKit's recorded depth matrix was carried from (cx * sx and (cy + 0.5) * sy - 0.5, from pixel (0, 0)'s center) scaled plainly, which puts the depth grid on the color grid."""
        k = row_matrix(self.rec.depths[index])
        if self.rec.camera == "front":
            return k
        sx, sy = self.scale
        color = {"fx": k["fx"] / sx, "fy": k["fy"] / sy, "cx": k["cx"] / sx, "cy": (k["cy"] + 0.5) / sy - 0.5}
        return depth_intrinsic_matrix(color, sx, sy, self.origin)

    def front_lens(self, distortion: Dict, intrinsics: Intrinsics, width: int, height: int, scale: float, k: Tuple[float, float]) -> Distort:
        """A front image's lens: the phone's radial distortion k in the normalized coordinates of `intrinsics`, then the Apple distortion recorded for a width x height image, both carried to that image scaled by `scale`."""
        carried = scaled_distortion({"center": distortion["center"], "lookup_table": distortion["lookup_table"], "size": (width, height)}, scale, scale)

        def distort(x: np.ndarray, y: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
            return apple_distort(*radial_distort(x, y, intrinsics, *k), carried["center"], carried["lookup_table"], carried["size"])

        return distort

    def color_coordinates(self, index: int) -> Tuple[Coordinates, Coordinates]:
        """Where each aligned luma pixel and each aligned chroma sample of color frame `index` lies in the recorded frame."""
        rec = self.rec
        k = self.color_intrinsics(index)
        lens = lens_coefficients(self.lens, k[0])
        planes = []
        # The CbCr plane is the frame at half size, each sample covering 2 x 2 pixels, so its geometry is the frame's scaled by one half.
        for scale in (1.0, 0.5):
            width, height = int(rec.color_width * scale), int(rec.color_height * scale)
            ks = (k[0] * scale, k[1] * scale, k[2] * scale, k[3] * scale)
            if rec.camera == "rear":
                planes.append(source_coordinates(width, height, ks, ks, lambda x, y: radial_distort(x, y, ks, *lens))[:2])
                continue
            distortion = rec.color_distortions[index]
            assert distortion is not None, f"color frame {index} has no distortion"
            key = json.dumps(["color", k, lens, distortion["center"], distortion["lookup_table"], scale])
            if key not in self.cache:
                self.cache[key] = source_coordinates(width, height, ks, ks, self.front_lens(distortion, ks, rec.color_width, rec.color_height, scale, lens))[:2]
            planes.append(self.cache[key])
        return planes[0], planes[1]

    def depth_coordinates(self, index: int) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Where each aligned pixel of depth frame `index` lies in the recorded map, and its ray's z component after the front's turn."""
        rec = self.rec
        matrix = self.depth_intrinsics(index)
        output = corner_origin((matrix["fx"], matrix["fy"], matrix["cx"], matrix["cy"]), self.origin)
        recorded = self.recorded_depth_intrinsics(index)
        # The lens is the color frame's: the depth matrix is the color one scaled by the depth map's size.
        lens = lens_coefficients(self.lens, recorded[0] / self.scale[0])
        if rec.camera == "rear":
            return source_coordinates(rec.depth_width, rec.depth_height, output, recorded, lambda x, y: radial_distort(x, y, recorded, *lens))
        distortion = rec.depth_distortions[index]
        transform = rec.depth_to_color[index]
        assert distortion is not None and transform is not None, f"depth frame {index} has no distortion or depth_to_color"
        # Apple registers depth to color, so the recorded transform is the identity; the phone's rotation is what that registration leaves.
        assert np.allclose(transform, np.eye(3, 4), atol=1e-6), transform
        key = json.dumps(["depth", output, recorded, lens, distortion["center"], distortion["lookup_table"]])
        if key not in self.cache:
            self.cache[key] = source_coordinates(rec.depth_width, rec.depth_height, output, recorded, self.front_lens(distortion, recorded, rec.depth_width, rec.depth_height, 1.0, lens), self.rotation)
        return self.cache[key]

    def color_filled(self, index: int) -> np.ndarray:
        """Which aligned pixels of color frame `index` take their value from the recorded frame, the rest being black."""
        x, y = self.color_coordinates(index)[0]
        return ~outside(x, y, self.rec.color_width, self.rec.color_height)

    def color_frame(self, index: int) -> bytes:
        return align_color(np.asarray(self.rec.color[index]), *self.color_coordinates(index)).tobytes()

    def depth_frame(self, index: int) -> Tuple[bytes, Optional[bytes]]:
        xd, yd, z = self.depth_coordinates(index)
        confidence = None if self.rec.confidence is None else np.asarray(self.rec.confidence[index])
        depth, aligned_confidence = align_depth(np.asarray(self.rec.depth[index]).astype(np.float32), xd, yd, z, confidence)
        return depth.tobytes(), None if aligned_confidence is None else aligned_confidence.tobytes()


# Each worker process's Aligner, built once by `start_worker`.
WORKER: Optional[Aligner] = None


def start_worker(path: Path, correction: Dict) -> None:
    global WORKER
    WORKER = Aligner(path, correction)


def worker_color(index: int) -> bytes:
    return WORKER.color_frame(index)


def worker_depth(index: int) -> Tuple[bytes, Optional[bytes]]:
    return WORKER.depth_frame(index)


class FrameStream(io.RawIOBase):
    """A tar member's bytes read from an iterator of frames, counted and hashed as they pass."""

    def __init__(self, frames: Iterator[bytes]) -> None:
        self.frames = frames
        self.pending = b""
        self.digest = hashlib.sha256()
        self.size = 0

    def readable(self) -> bool:
        return True

    def readinto(self, buffer) -> int:
        while not self.pending:
            frame = next(self.frames, None)
            if frame is None:
                return 0
            self.digest.update(frame)
            self.size += len(frame)
            self.pending = frame
        n = min(len(buffer), len(self.pending))
        buffer[:n] = self.pending[:n]
        self.pending = self.pending[n:]
        return n


def add_member(tar: tarfile.TarFile, name: str, size: int, stream: io.RawIOBase) -> None:
    info = tarfile.TarInfo(name)
    info.size = size
    tar.addfile(info, io.BufferedReader(stream, CHUNK))


def add_json(tar: tarfile.TarFile, name: str, content: Dict) -> None:
    data = (json.dumps(content, indent=2) + "\n").encode()
    add_member(tar, name, len(data), io.BytesIO(data))


def camera_correction(corrections: Dict, rec: Recording) -> Dict:
    """What the phone corrections file says to apply to the recording's camera, once the file is the recording's phone's: the lens distortion's k1, k2 (and focus entry) and, for the front, the depth rotation vector, without the measurements' intervals and sources."""
    def _validate_inputs() -> None:
        assert corrections["phone_id"] == rec.scan_metadata["phone_id"], (corrections["phone_id"], rec.scan_metadata["phone_id"])

    _validate_inputs()

    entry = corrections[rec.camera]
    lens = {key: entry["lens_distortion"][key] for key in ("k1", "k2", "focus") if key in entry["lens_distortion"]}
    applied = {"lens_distortion": lens}
    if rec.camera == "front":
        applied["depth_rotation"] = {"rotation_vector_rad": entry["depth_rotation"]["rotation_vector_rad"]}
    return applied


def align(path: Path, corrections: Dict, out: Path) -> Path:
    """Writes the aligned recording of the recording tar at `path`, with its phone's corrections, as out/<scan_id>.tar, under <scan_id>.partial until complete, and returns its path."""
    rec = Recording(path)
    assert rec.format_minor == 8, rec.format_version
    correction = camera_correction(corrections, rec)
    out.mkdir(parents=True, exist_ok=True)
    aligner = Aligner(path, correction)
    scan_id = rec.scan_id
    target, partial = out / f"{scan_id}.tar", out / f"{scan_id}.partial"
    color_count, depth_count = rec.color.shape[0], rec.depth.shape[0]
    depth_pixels = rec.depth_width * rec.depth_height
    with Pool(WORKERS, start_worker, (path, correction)) as pool, tarfile.open(partial, "w", format=tarfile.GNU_FORMAT) as tar:
        color_stream = FrameStream(pool.imap(worker_color, range(color_count), chunksize=2))
        add_member(tar, f"{scan_id}/color_frames.bin", color_count * rec.color[0].nbytes, color_stream)
        # Depth and confidence come from one resampling; the rear's confidence maps (49 KB each) wait in memory until the depth member is written.
        confidence: List[bytes] = []

        def depth_frames() -> Iterator[bytes]:
            for depth, level in pool.imap(worker_depth, range(depth_count), chunksize=8):
                if level is not None:
                    confidence.append(level)
                yield depth

        depth_stream = FrameStream(depth_frames())
        add_member(tar, f"{scan_id}/depth_frames.bin", depth_count * depth_pixels * DEPTH_DTYPES["fdep"].itemsize, depth_stream)
        depth_metadata = rec.depth_frames_metadata | {"size": depth_stream.size, "sha256": depth_stream.digest.hexdigest(), "pixel_format": "fdep"}
        if rec.camera == "rear":
            confidence_stream = FrameStream(iter(confidence))
            add_member(tar, f"{scan_id}/depth_frames_confidence.bin", depth_count * depth_pixels, confidence_stream)
            depth_metadata["confidence"] = rec.depth_frames_metadata["confidence"] | {"size": confidence_stream.size, "sha256": confidence_stream.digest.hexdigest()}

        add_json(tar, f"{scan_id}/scan_metadata.json", rec.scan_metadata | {"alignment": {"phone_id": corrections["phone_id"]} | correction})
        add_json(tar, f"{scan_id}/color_frames_metadata.json", rec.color_frames_metadata | {"size": color_stream.size, "sha256": color_stream.digest.hexdigest()})
        add_json(tar, f"{scan_id}/depth_frames_metadata.json", depth_metadata)
        add_json(tar, f"{scan_id}/color_intrinsics.json", {key: value for key, value in rec.color_intrinsics.items() if key != "distortions"})
        depth_intrinsics = {key: value for key, value in rec.depth_intrinsics.items() if key != "distortions"}
        add_json(tar, f"{scan_id}/depth_intrinsics.json", depth_intrinsics | {"frames": [aligner.depth_intrinsics(i) for i in range(depth_count)]})
        add_json(tar, f"{scan_id}/extrinsics.json", rec.extrinsics | {"depth_to_color": [{"matrix": np.eye(3, 4).tolist(), "depth_frame_ranges": [[0, depth_count - 1]]}]})
    partial.rename(target)
    return target


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tar", type=Path)
    parser.add_argument("--corrections", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    print(align(args.tar, json.loads(args.corrections.read_text()), args.out))


if __name__ == "__main__":
    main()

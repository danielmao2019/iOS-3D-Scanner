"""Reads an RGBD Scanner recording, a format_version "4.8" directory or a "4.0" to "4.7" tar, through one interface: its per-frame color and depth rows, its color frames, depth maps and the rear's confidence maps memory-mapped in place, never copied (a front recording is about 0.55 GB per second), the rear's poses and, from 4.8, the front frames' lens distortion, each depth frame's depth-to-color transform and the frame files' recorded sizes and SHA-256s. format_version is "4.<minor>", the version of the app that wrote it, the minor naming the app build. This docstring is the format's document; app/Sources/RGBDScanner/Recording.swift's header comment describes the writer.

Format 4.8. A recording is a directory <scan_id>/ holding exactly scan_metadata.json, color_frames.bin, color_frames_metadata.json, depth_frames.bin, depth_frames_metadata.json, color_intrinsics.json, depth_intrinsics.json, extrinsics.json and, for the rear, depth_frames_confidence.bin; the phone keeps it as Documents/<scan_id>/, and server/receive.py stores it as <out>/<scan_id>/. scan_id is rgbd_<yyyyMMdd_HHmmss>_<camera>, followed by _<the user's name for it reduced to [A-Za-z0-9_-], at most 40 characters> when the user named it. Each concern has one file: intrinsic parameters and extrinsics never share a file, and no file repeats another's indices or timestamps, frame n of a .bin file being entry n of its frames list.

The camera is "front", the TrueDepth camera through AVFoundation (color 4032x3024 and depth 640x480 at 15 fps on the test phone), or "rear", the LiDAR camera through ARKit world tracking (color 1920x1440, scene depth 256x192 with its confidence, 60 fps); depth filtering is always off. Every timestamp is a capture time in host-clock (CMClockGetHostTimeClock) seconds, one clock for every file; a color frame and a depth frame were captured together when their timestamps are equal (`pairs`). Pixels, intrinsics and the poses' camera frame are in the sensor's native orientation, unrotated and unmirrored; `upright` turns a frame the way the phone was held.

scan_metadata.json holds exactly format_version ("4.8"), scan_id, name, start_time_utc, duration_s (the last minus the first timestamp over every color and depth frame, delivered or dropped), phone_model, phone_id (UIDevice's identifierForVendor, or null when iOS gives none), ios_version, camera, frame_rate (the configured frames per second) and recovered (whether the recording was finished at a later launch, the app having been closed mid-recording).

color_frames.bin holds every delivered color frame uncompressed, frame n at bytes [n*w*h*3/2, (n+1)*w*h*3/2) for a w x h frame, no header: the camera's 420f buffer, 8-bit full-range YCbCr 4:2:0, its luma plane (h rows of w bytes, one Y per pixel) then its CbCr plane (h/2 rows of w bytes, one Cb, Cr byte pair per 2x2 pixels), rows tightly packed; `color_bgr` converts a frame to BGR through its ycbcr_matrix. depth_frames.bin holds every delivered depth map as the camera delivered it, in metres as little-endian Float32 ("fdep", 4 bytes per pixel) or Float16 ("hdep", 2 bytes), the most precise depth type the capture format offers (the rear's always Float32), map n at bytes [n*w*h*b, (n+1)*w*h*b) for b bytes per pixel, rows tightly packed, NaN or 0 meaning no reading. The rear's depth_frames_confidence.bin holds one UInt8 ARConfidenceLevel map per depth map, in depth_frames.bin's order and layout: 0 low, 1 medium, 2 high.

color_frames_metadata.json holds file ("color_frames.bin"), its size in bytes and sha256 (64 lowercase hex characters), width, height, pixel_format ("420f"), ycbcr_matrix (the kCVImageBufferYCbCrMatrix_ name, ITU_R_601_4 or ITU_R_709_2), frame_count, frames and dropped. frames[n] is color frame n: its timestamp; upright_rotation_deg, the clockwise rotation (0, 90, 180 or 270) that turns the frame upright, from AVCaptureDevice.RotationCoordinator's videoRotationAngleForHorizonLevelCapture; gravity, CoreMotion's gravity in g in the phone's device frame (x right, y toward the top of the phone held in portrait, z out of the screen), and gravity_timestamp, its sample time, both null before the first motion sample; and exposure_duration_s, the frame's own exposure time in seconds. dropped lists the frames the camera or the app dropped, in time order, each its timestamp and reason (late, out_of_buffers, discontinuity, unknown, dropped, writer_busy, ...); they have no bytes.

depth_frames_metadata.json holds the same for depth_frames.bin, file, size, sha256, width, height, pixel_format ("fdep" or "hdep"), frame_count, frames and dropped (reasons such as no_scene_depth), and, for the rear, confidence: depth_frames_confidence.bin's file, size, sha256 and pixel_format ("L008"). A front depth frame is its timestamp, filtered (AVDepthData's isDepthDataFiltered), accuracy (absolute or relative) and quality (high or low); a rear one is its timestamp only.

color_intrinsics.json and depth_intrinsics.json each hold image_width and image_height, principal_point_origin, frames and, for the front, distortions. frames[n] is frame n's intrinsic matrix fx, fy, cx, cy in its own stream's pixels, or null when the frame came without one. The principal point origin is "upper_left_pixel_corner" for the front, AVFoundation measuring from the frame's upper-left corner, half a pixel before pixel (0, 0)'s center, and "upper_left_pixel_center" for the rear, ARCamera.intrinsics measuring from pixel (0, 0)'s center (as ARCamera.h says). The front's color intrinsics are each color frame's own intrinsic matrix; its depth intrinsics are each depth frame's AVDepthData.cameraCalibrationData.intrinsicMatrix carried from the calibration's reference dimensions to the depth map by plain scaling, f*s and c*s. The rear's color intrinsics are ARCamera.intrinsics; its depth intrinsics carry them to the depth map as its grid lies on the color image, measured on six rear scans from where depth edges land on color edges: f*s on both axes, cx*sx along x, where the first depth column's center sits on the first color column's center, and (cy+0.5)*sy-0.5 along y, where the depth rows span the color rows edge to edge, s = depth size / color size. Each front distortion is Apple's lens distortion from an AVCameraCalibrationData: center, its lensDistortionCenter carried from the calibration's reference dimensions to the image (center * image size / reference size, the matrix's origin), and lookup_table and inverse_lookup_table, its lensDistortionLookupTable and inverseLensDistortionLookupTable as Float32 values, copied as they are, radius-normalized (they span the distance from the center to the farthest corner). Each distinct distortion appears once, with frame_ranges, inclusive [first, last] runs of the frames it applies to, which together cover every frame whose distortion is known exactly once. A depth frame's distortion is its own calibration's, unknown when it came without one; a color frame's is the one of the depth frame with the same timestamp, else of the latest earlier depth frame, else of the first depth frame, unknown when no depth frame had a calibration. ARKit reports no distortion, so the rear has none.

extrinsics.json holds depth_to_color, each distinct 3x4 row-major transform (rotation, then translation in metres) from a depth frame's camera to the color camera once, with depth_frame_ranges, inclusive runs of the depth frames it applies to, which together cover every depth frame with a known transform exactly once: for the front, each depth frame's AVCameraCalibrationData.extrinsicMatrix (identity in practice, Apple registering depth to color), a depth frame without a calibration in no run; for the rear, identity for every depth frame (ARKit registering scene depth to the captured image). The rear's camera_poses[n] is color frame n's pose: tracking_state (normal, not_available, limited_initializing, limited_excessive_motion, limited_insufficient_features or limited_relocalizing) and world_from_camera, rows 0 to 2 of ARCamera.transform, row-major: the transform from ARKit's camera frame (+x toward increasing column of the sensor-oriented image, +y toward decreasing row, +z toward the viewer, looking along -z) to its gravity-aligned world frame (+y up, origin where tracking started), metres; `world_from_camera` returns it as a 4x4 matrix.

`color_rows` and `depth_rows` give both layouts one row per frame, delivered or dropped, in time order, every value a string: index (-1 on a dropped row), timestamp, dropped (a dropped row's reason; its other cells are empty) and fx, fy, cx, cy (empty when the frame came without intrinsics); color rows add upright_rotation_deg, gravity_x, gravity_y, gravity_z, gravity_ts (empty before the first motion sample), exposure_duration_s and, for the rear, tracking_state and world_from_camera_00 to world_from_camera_23; front depth rows add filtered ("1" or "0"), accuracy and quality. `colors` and `depths` are the delivered rows, frame n the row with index n.

Formats 4.0 to 4.7 differ as follows. A recording is an uncompressed POSIX ustar tar whose members sit under <id>/: metadata.json, color.bin, color.csv, depth.bin, depth.csv, and confidence.bin (rear) or calibration.jsonl (front); color.bin, depth.bin (always "fdep") and confidence.bin are laid out as color_frames.bin, depth_frames.bin and depth_frames_confidence.bin and are memory-mapped at each member's data offset inside the tar. metadata.json holds the scan's facts under other names (id, device_model, system_version, color_width, color_ycbcr_matrix, depth_width, ...) with frame counts, byte sizes, depth_source, focus and prose conventions, and no file records the frames' sizes or SHA-256s. color.csv and depth.csv are `color_rows` and `depth_rows` as written, but depth rows also carry upright_rotation_deg, gravity and bytes_per_row (the delivered map's row stride, which depth.bin drops), and color.csv lacks exposure_duration_s before minor 3 and, from minor 3, also has lens_position (the capture device's lensPosition, 0 to 1) and received_ts (the host-clock seconds at which the app received the frame), both read when the frame reached the app and so later than its exposure by the capture pipeline's latency. The front's calibration.jsonl holds one line per delivered depth map, in depth.csv's order, {"index", "timestamp", "calibration"}, the map's AVCameraCalibrationData described at its reference dimensions, or null when it came without one; nothing records the color frames' distortion or depth-to-color transform. Minors 4 to 6 add to a rear recording's metadata.json avfoundation_calibration, Apple's calibration of the wide camera ARKit captures through, taken through AVFoundation as the rear camera started: its intrinsic matrix at its own reference dimensions, extrinsics, pixel size, lens distortion center and lookup tables, with the camera's lens position and the host-clock seconds when it was taken. It does not describe ARKit's frames, whatever its avfoundation_calibration_description says: measured on four rear takes (2026-10-06 and 2026-10-07), their straight edges bow against its tables' prediction with the opposite sign and a different radial profile, 1.3 times the prediction near the center and 0.6 times toward the edges; minor 7 no longer records it.
"""

import csv
import io
import json
import re
import tarfile
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple, Union

import numpy as np

# Format 4.8's files: every recording's, and each camera's own.
FILES = {"scan_metadata.json", "color_frames.bin", "color_frames_metadata.json", "depth_frames.bin", "depth_frames_metadata.json", "color_intrinsics.json", "depth_intrinsics.json", "extrinsics.json"}
CAMERA_FILES = {"front": set(), "rear": {"depth_frames_confidence.bin"}}
SCAN_METADATA_KEYS = {"format_version", "scan_id", "name", "start_time_utc", "duration_s", "phone_model", "phone_id", "ios_version", "camera", "frame_rate", "recovered"}
# Formats 4.0 to 4.7's tar members: every recording's, and each camera's own.
MEMBERS = {"metadata.json", "color.bin", "color.csv", "depth.bin", "depth.csv"}
CAMERA_MEMBERS = {"front": {"calibration.jsonl"}, "rear": {"confidence.bin"}}
# Where each camera's color and depth intrinsics measure the principal point from, in every format.
PRINCIPAL_POINT_ORIGINS = {"front": "upper_left_pixel_corner", "rear": "upper_left_pixel_center"}
INTRINSICS = ["fx", "fy", "cx", "cy"]
ORIENTATION = ["upright_rotation_deg", "gravity_x", "gravity_y", "gravity_z", "gravity_ts"]
POSE = [f"world_from_camera_{r}{c}" for r in range(3) for c in range(4)]
# color.csv's columns from format minor 3 on, after gravity_ts.
EXPOSURE_LENS_ARRIVAL = ["exposure_duration_s", "lens_position", "received_ts"]
DEPTH_HEADERS = {
    "front": ["index", "timestamp", "dropped", "filtered", "accuracy", "quality", *INTRINSICS, *ORIENTATION, "bytes_per_row"],
    "rear": ["index", "timestamp", "dropped", *INTRINSICS, *ORIENTATION, "bytes_per_row"],
}
# Format 4.8's rows, keyed as the tars' tables key them, less what 4.8 no longer records.
COLOR_KEYS = {"front": ["index", "timestamp", "dropped", *INTRINSICS, *ORIENTATION, "exposure_duration_s"], "rear": ["index", "timestamp", "dropped", *INTRINSICS, *ORIENTATION, "exposure_duration_s", "tracking_state", *POSE]}
DEPTH_KEYS = {"front": ["index", "timestamp", "dropped", "filtered", "accuracy", "quality", *INTRINSICS], "rear": ["index", "timestamp", "dropped", *INTRINSICS]}
# Format 4.8's depth pixel formats, each with the little-endian dtype of its metres.
DEPTH_DTYPES = {"fdep": np.dtype("<f4"), "hdep": np.dtype("<f2")}
HIGH_CONFIDENCE = 2
SAME_INSTANT_S = 0.0005
# Kr and Kb of each YCbCr matrix a recording's ycbcr_matrix can name (kCVImageBufferYCbCrMatrix_*).
YCBCR_MATRICES = {"ITU_R_601_4": (0.299, 0.114), "ITU_R_709_2": (0.2126, 0.0722)}


class Recording:
    """A format_version "4.8" recording directory or "4.0" to "4.7" recording tar: its metadata and per-frame rows read, its frames memory-mapped in place."""

    # Every format's.
    path: Path
    format_version: str
    # The minor of format_version: 0 to 7 for a tar, 8 for a directory.
    format_minor: int
    camera: str
    scan_id: str
    color_width: int
    color_height: int
    depth_width: int
    depth_height: int
    # The kCVImageBufferYCbCrMatrix_ name `color_bgr` converts through.
    ycbcr_matrix: str
    # The configured frames per second.
    frame_rate: float
    # Each stream's PRINCIPAL_POINT_ORIGINS entry.
    color_principal_point_origin: str
    depth_principal_point_origin: str
    color_rows: List[Dict[str, str]]
    depth_rows: List[Dict[str, str]]
    colors: List[Dict[str, str]]
    depths: List[Dict[str, str]]
    # Frames x 420f frame (height * 3 / 2 rows of width bytes), frames x depth map in metres (Float32, or Float16 for a 4.8 "hdep" recording), and the rear's frames x confidence map.
    color: np.memmap
    depth: np.memmap
    confidence: Optional[np.memmap]
    # A tar's metadata.json and, for the front, calibration.jsonl's lines; None for a directory.
    meta: Optional[Dict]
    calibrations: Optional[List[Dict]]
    # A directory's JSON files as read; None for a tar.
    scan_metadata: Optional[Dict]
    color_frames_metadata: Optional[Dict]
    depth_frames_metadata: Optional[Dict]
    color_intrinsics: Optional[Dict]
    depth_intrinsics: Optional[Dict]
    extrinsics: Optional[Dict]
    # A directory's frame files, each with the size and SHA-256 its frames metadata records; None for a tar.
    frame_files: Optional[Dict[str, Tuple[int, str]]]
    # A front directory's distortions entry of each color and depth frame, or None for a frame in no run; None for a rear directory and a tar.
    color_distortions: Optional[List[Optional[Dict]]]
    depth_distortions: Optional[List[Optional[Dict]]]
    # A directory's depth_to_color matrix of each depth frame, 3 x 4 float64, or None for a frame in no run; None for a tar.
    depth_to_color: Optional[List[Optional[np.ndarray]]]

    def __init__(self, path: Union[str, Path]) -> None:
        def _validate_inputs() -> None:
            assert isinstance(path, (str, Path)), type(path)

        _validate_inputs()

        def _normalize_inputs() -> Path:
            return Path(path)

        path = _normalize_inputs()

        self.path = path
        if path.is_dir():
            self._read_directory()
        else:
            self._read_tar()
        self.colors = [r for r in self.color_rows if r["index"] != "-1"]
        self.depths = [r for r in self.depth_rows if r["index"] != "-1"]

    def _read_tar(self) -> None:
        """Reads a format 4.0 to 4.7 tar, its .bin members memory-mapped in place inside it."""
        # Mode "r:" opens an uncompressed tar only, the one whose members can be memory-mapped in place.
        with tarfile.open(self.path, "r:") as tar:
            members = {Path(m.name).name: m for m in tar.getmembers()}
            assert "metadata.json" in members, sorted(members)
            self.meta = json.load(tar.extractfile(members["metadata.json"]))
            # Major 4, the minor naming the app build that wrote it; from minor 8 on, a recording is a directory.
            version = re.fullmatch(r"4\.([0-7])", self.meta["format_version"])
            assert version is not None, self.meta["format_version"]
            self.format_version = self.meta["format_version"]
            self.format_minor = int(version.group(1))
            camera = self.meta["camera"]
            assert camera in CAMERA_MEMBERS, camera
            names = sorted(m.name for m in tar.getmembers())
            assert names == sorted(f"{self.meta['id']}/{name}" for name in MEMBERS | CAMERA_MEMBERS[camera]), names
            self.color_rows = read_table(tar, members["color.csv"], color_header(camera, self.format_minor))
            self.depth_rows = read_table(tar, members["depth.csv"], DEPTH_HEADERS[camera])
            self.calibrations = None
            if camera == "front":
                self.calibrations = [json.loads(line) for line in tar.extractfile(members["calibration.jsonl"]).read().decode().splitlines()]
        meta = self.meta
        self.camera, self.scan_id, self.frame_rate = camera, meta["id"], meta["frame_rate"]
        self.color_width, self.color_height, self.ycbcr_matrix = meta["color_width"], meta["color_height"], meta["color_ycbcr_matrix"]
        self.depth_width, self.depth_height = meta["depth_width"], meta["depth_height"]
        self.color_principal_point_origin = self.depth_principal_point_origin = PRINCIPAL_POINT_ORIGINS[camera]
        width, height = self.color_width, self.color_height
        assert meta["color_pixel_format"] == "420f" and width % 2 == 0 and height % 2 == 0 and meta["color_bytes_per_frame"] == width * height * 3 // 2, (meta["color_pixel_format"], width, height, meta["color_bytes_per_frame"])
        self.color = map_frames(self.path, members["color.bin"], np.dtype(np.uint8), (height * 3 // 2, width))
        depth_shape = (self.depth_height, self.depth_width)
        assert meta["depth_pixel_format"] == "fdep" and meta["depth_bytes_per_pixel"] == 4 and meta["depth_bytes_per_frame"] == depth_shape[0] * depth_shape[1] * 4, (meta["depth_pixel_format"], meta["depth_bytes_per_pixel"], meta["depth_bytes_per_frame"])
        self.depth = map_frames(self.path, members["depth.bin"], np.dtype("<f4"), depth_shape)
        self.confidence = None
        if camera == "rear":
            assert meta["confidence_pixel_format"] == "L008" and meta["confidence_bytes_per_pixel"] == 1, (meta["confidence_pixel_format"], meta["confidence_bytes_per_pixel"])
            self.confidence = map_frames(self.path, members["confidence.bin"], np.dtype(np.uint8), depth_shape)
        self.scan_metadata = self.color_frames_metadata = self.depth_frames_metadata = self.color_intrinsics = self.depth_intrinsics = self.extrinsics = None
        self.frame_files = self.color_distortions = self.depth_distortions = self.depth_to_color = None

    def _read_directory(self) -> None:
        """Reads a format 4.8 directory, checking that it holds exactly its camera's files, every list one entry per frame, every run within the frames and disjoint from the others, and every frame file the frames its metadata counts at the size it records."""
        directory = self.path
        names = sorted(p.name for p in directory.iterdir())
        assert "scan_metadata.json" in names, names

        def load(name: str) -> Dict:
            return json.loads((directory / name).read_text())

        self.scan_metadata = load("scan_metadata.json")
        assert self.scan_metadata["format_version"] == "4.8", self.scan_metadata["format_version"]
        camera = self.scan_metadata["camera"]
        assert camera in CAMERA_FILES, camera
        assert names == sorted(FILES | CAMERA_FILES[camera]), names
        assert directory.name == self.scan_metadata["scan_id"], (directory.name, self.scan_metadata["scan_id"])
        self.format_version, self.format_minor = "4.8", 8
        self.camera, self.scan_id, self.frame_rate = camera, self.scan_metadata["scan_id"], self.scan_metadata["frame_rate"]
        self.meta = self.calibrations = None

        color, depth = load("color_frames_metadata.json"), load("depth_frames_metadata.json")
        self.color_frames_metadata, self.depth_frames_metadata = color, depth
        self.color_width, self.color_height, self.ycbcr_matrix = color["width"], color["height"], color["ycbcr_matrix"]
        self.depth_width, self.depth_height = depth["width"], depth["height"]
        width, height = self.color_width, self.color_height
        assert color["file"] == "color_frames.bin" and color["pixel_format"] == "420f" and width % 2 == 0 and height % 2 == 0, (color["file"], color["pixel_format"], width, height)
        assert depth["file"] == "depth_frames.bin" and depth["pixel_format"] in DEPTH_DTYPES, (depth["file"], depth["pixel_format"])
        assert color["frame_count"] == len(color["frames"]) and depth["frame_count"] == len(depth["frames"]), (color["frame_count"], len(color["frames"]), depth["frame_count"], len(depth["frames"]))
        self.color = map_file(directory, color, np.dtype(np.uint8), (height * 3 // 2, width), color["frame_count"])
        depth_shape = (self.depth_height, self.depth_width)
        self.depth = map_file(directory, depth, DEPTH_DTYPES[depth["pixel_format"]], depth_shape, depth["frame_count"])
        assert ("confidence" in depth) == (camera == "rear"), sorted(depth)
        frame_files = [color, depth]
        self.confidence = None
        if camera == "rear":
            confidence = depth["confidence"]
            assert confidence["file"] == "depth_frames_confidence.bin" and confidence["pixel_format"] == "L008", (confidence["file"], confidence["pixel_format"])
            self.confidence = map_file(directory, confidence, np.dtype(np.uint8), depth_shape, depth["frame_count"])
            frame_files.append(confidence)
        # Whether each SHA-256 is the file's own is for inspect_recording to check, which reads every byte.
        assert all(re.fullmatch(r"[0-9a-f]{64}", f["sha256"]) for f in frame_files), [f["sha256"] for f in frame_files]
        self.frame_files = {f["file"]: (f["size"], f["sha256"]) for f in frame_files}

        self.color_intrinsics, self.depth_intrinsics = load("color_intrinsics.json"), load("depth_intrinsics.json")
        for intrinsics, frames in ((self.color_intrinsics, color), (self.depth_intrinsics, depth)):
            assert (intrinsics["image_width"], intrinsics["image_height"]) == (frames["width"], frames["height"]), (intrinsics["image_width"], intrinsics["image_height"], frames["width"], frames["height"])
            assert intrinsics["principal_point_origin"] == PRINCIPAL_POINT_ORIGINS[camera], (camera, intrinsics["principal_point_origin"])
            assert len(intrinsics["frames"]) == frames["frame_count"], (frames["file"], len(intrinsics["frames"]), frames["frame_count"])
            # ARKit reports no distortion.
            assert ("distortions" in intrinsics) == (camera == "front"), sorted(intrinsics)
        self.color_principal_point_origin = self.color_intrinsics["principal_point_origin"]
        self.depth_principal_point_origin = self.depth_intrinsics["principal_point_origin"]
        self.color_distortions = self.depth_distortions = None
        if camera == "front":
            self.color_distortions = per_frame(self.color_intrinsics["distortions"], "frame_ranges", color["frame_count"])
            self.depth_distortions = per_frame(self.depth_intrinsics["distortions"], "frame_ranges", depth["frame_count"])

        self.extrinsics = load("extrinsics.json")
        assert all(np.shape(t["matrix"]) == (3, 4) for t in self.extrinsics["depth_to_color"]), self.extrinsics["depth_to_color"]
        transforms = per_frame(self.extrinsics["depth_to_color"], "depth_frame_ranges", depth["frame_count"])
        # ARKit registers scene depth to the captured image, so every rear depth frame has one.
        assert camera == "front" or all(t is not None for t in transforms), "a rear depth frame in no depth_to_color run"
        self.depth_to_color = [None if t is None else np.array(t["matrix"], np.float64) for t in transforms]
        assert ("camera_poses" in self.extrinsics) == (camera == "rear"), sorted(self.extrinsics)
        poses = self.extrinsics["camera_poses"] if camera == "rear" else [None] * color["frame_count"]
        assert len(poses) == color["frame_count"], (len(poses), color["frame_count"])

        colors = [color_row(n, frame, k, pose) for n, (frame, k, pose) in enumerate(zip(color["frames"], self.color_intrinsics["frames"], poses, strict=True))]
        depths = [depth_row(camera, n, frame, k) for n, (frame, k) in enumerate(zip(depth["frames"], self.depth_intrinsics["frames"], strict=True))]
        self.color_rows = with_dropped(colors, color["dropped"], COLOR_KEYS[camera])
        self.depth_rows = with_dropped(depths, depth["dropped"], DEPTH_KEYS[camera])

    def color_bgr(self, index: int) -> np.ndarray:
        """Color frame `index` as 8-bit BGR, color_height x color_width x 3 in sensor orientation, converted through the recording's ycbcr_matrix."""
        return ycbcr_to_bgr(self.color[index], self.ycbcr_matrix)

    def color_frames(self) -> Iterator[np.ndarray]:
        """Yields every color frame in order, as `color_bgr` gives it."""
        return (self.color_bgr(i) for i in range(self.color.shape[0]))

    def pairs(self) -> List[Tuple[Dict[str, str], Dict[str, str]]]:
        """Each depth row with the color row, delivered or dropped, captured at the same instant, matched by timestamp."""
        by_time = {round(float(r["timestamp"]) / SAME_INSTANT_S): r for r in self.color_rows}
        out = []
        for d in self.depths:
            c = by_time.get(round(float(d["timestamp"]) / SAME_INSTANT_S))
            if c is not None:
                out.append((c, d))
        return out

    def world_from_camera(self, row: Dict[str, str]) -> np.ndarray:
        """A delivered rear color row's ARFrame.camera.transform as a 4x4 float64 matrix: ARKit's camera frame to its world frame, metres."""
        def _validate_inputs() -> None:
            assert self.camera == "rear", self.camera
            assert row["index"] != "-1", row

        _validate_inputs()

        top = np.array([float(row[k]) for k in POSE], dtype=np.float64).reshape(3, 4)
        return np.vstack([top, [0, 0, 0, 1]])


def color_header(camera: str, minor: int) -> List[str]:
    """color.csv's header for a camera in a format_version "4.<minor>" recording, with EXPOSURE_LENS_ARRIVAL after gravity_ts from minor 3 on."""
    def _validate_inputs() -> None:
        assert camera in CAMERA_MEMBERS, camera
        assert minor >= 0, minor

    _validate_inputs()

    exposure_lens_arrival = EXPOSURE_LENS_ARRIVAL if minor >= 3 else []
    pose = ["tracking_state", *POSE] if camera == "rear" else []
    return ["index", "timestamp", "dropped", *INTRINSICS, *ORIENTATION, *exposure_lens_arrival, *pose]


def read_table(tar: tarfile.TarFile, member: tarfile.TarInfo, header: List[str]) -> List[Dict[str, str]]:
    """A color.csv or depth.csv member's rows, its header the camera's and every row as long as the header."""
    reader = csv.DictReader(io.TextIOWrapper(tar.extractfile(member)))
    assert reader.fieldnames == header, (member.name, reader.fieldnames)
    rows = list(reader)
    # DictReader keys a longer row's extra cells by None and gives a shorter row's missing cells the value None.
    assert all(len(r) == len(header) and None not in r.values() for r in rows), member.name
    return rows


def map_frames(tar_path: Path, member: tarfile.TarInfo, dtype: np.dtype, frame_shape: Tuple[int, int]) -> np.memmap:
    """A .bin member's frames memory-mapped read-only where its bytes sit in the uncompressed tar: frames x frame_shape of dtype."""
    def _validate_inputs() -> None:
        assert member.isreg(), member.name
        # The member holds whole frames only.
        assert member.size % (dtype.itemsize * frame_shape[0] * frame_shape[1]) == 0, (member.name, member.size, dtype, frame_shape)

    _validate_inputs()

    frames = member.size // (dtype.itemsize * frame_shape[0] * frame_shape[1])
    return np.memmap(tar_path, dtype=dtype, mode="r", offset=member.offset_data, shape=(frames, *frame_shape))


def map_file(directory: Path, entry: Dict, dtype: np.dtype, frame_shape: Tuple[int, int], frames: int) -> np.memmap:
    """A format 4.8 frame file, named by its frames metadata entry, memory-mapped read-only as frames x frame_shape of dtype, once the size the entry records and its size on disk both hold exactly that many frames."""
    def _validate_inputs() -> None:
        assert entry["size"] == frames * dtype.itemsize * frame_shape[0] * frame_shape[1] == (directory / entry["file"]).stat().st_size, (entry["file"], entry["size"], frames, frame_shape, (directory / entry["file"]).stat().st_size)

    _validate_inputs()

    return np.memmap(directory / entry["file"], dtype=dtype, mode="r", shape=(frames, *frame_shape))


def per_frame(entries: List[Dict], ranges_key: str, count: int) -> List[Optional[Dict]]:
    """Each of `count` frames' entry, the one whose inclusive [first, last] runs under ranges_key hold it, or None for a frame in no run; the runs lie within the frames and never overlap."""
    frames: List[Optional[Dict]] = [None] * count
    for entry in entries:
        for first, last in entry[ranges_key]:
            assert 0 <= first <= last < count, (ranges_key, first, last, count)
            assert all(f is None for f in frames[first:last + 1]), (ranges_key, "overlapping run", first, last)
            frames[first:last + 1] = [entry] * (last - first + 1)
    return frames


def cell(value: Optional[float]) -> str:
    """A nullable JSON number as a row's cell, empty for null."""
    return "" if value is None else str(value)


def intrinsics_cells(intrinsics: Optional[Dict[str, float]]) -> Dict[str, str]:
    """A format 4.8 intrinsics frames entry as the fx, fy, cx, cy cells, empty for null."""
    def _validate_inputs() -> None:
        assert intrinsics is None or sorted(intrinsics) == sorted(INTRINSICS), intrinsics

    _validate_inputs()

    return {k: "" if intrinsics is None else str(intrinsics[k]) for k in INTRINSICS}


def color_row(index: int, frame: Dict, intrinsics: Optional[Dict[str, float]], pose: Optional[Dict]) -> Dict[str, str]:
    """Format 4.8 color frame `index` as its COLOR_KEYS row, from its frames entry, its intrinsics and, for the rear, its camera pose."""
    def _validate_inputs() -> None:
        assert sorted(frame) == sorted(["timestamp", "upright_rotation_deg", "gravity", "gravity_timestamp", "exposure_duration_s"]), sorted(frame)
        assert frame["gravity"] is None or len(frame["gravity"]) == 3, frame["gravity"]
        assert pose is None or (sorted(pose) == ["tracking_state", "world_from_camera"] and np.shape(pose["world_from_camera"]) == (3, 4)), pose

    _validate_inputs()

    gravity = [None, None, None] if frame["gravity"] is None else frame["gravity"]
    row = {"index": str(index), "timestamp": str(frame["timestamp"]), "dropped": "", **intrinsics_cells(intrinsics), "upright_rotation_deg": str(frame["upright_rotation_deg"])}
    row |= {f"gravity_{axis}": cell(g) for axis, g in zip("xyz", gravity, strict=True)}
    row |= {"gravity_ts": cell(frame["gravity_timestamp"]), "exposure_duration_s": str(frame["exposure_duration_s"])}
    if pose is not None:
        row["tracking_state"] = pose["tracking_state"]
        row |= {k: str(v) for k, v in zip(POSE, (v for r in pose["world_from_camera"] for v in r), strict=True)}
    return row


def depth_row(camera: str, index: int, frame: Dict, intrinsics: Optional[Dict[str, float]]) -> Dict[str, str]:
    """Format 4.8 depth frame `index` as its DEPTH_KEYS row, from its frames entry and its intrinsics."""
    def _validate_inputs() -> None:
        assert camera in CAMERA_FILES, camera
        assert sorted(frame) == sorted(["timestamp", "filtered", "accuracy", "quality"] if camera == "front" else ["timestamp"]), (camera, sorted(frame))
        assert camera == "rear" or isinstance(frame["filtered"], bool), frame["filtered"]

    _validate_inputs()

    row = {"index": str(index), "timestamp": str(frame["timestamp"]), "dropped": ""}
    if camera == "front":
        row |= {"filtered": "1" if frame["filtered"] else "0", "accuracy": frame["accuracy"], "quality": frame["quality"]}
    return row | intrinsics_cells(intrinsics)


def with_dropped(rows: List[Dict[str, str]], dropped: List[Dict], keys: List[str]) -> List[Dict[str, str]]:
    """A format 4.8 stream's delivered rows with a row for each dropped frame, index -1, its reason in dropped and every other cell empty, in time order."""
    def _validate_inputs() -> None:
        assert all(list(r) == keys for r in rows), keys
        assert all(sorted(d) == ["reason", "timestamp"] for d in dropped), dropped

    _validate_inputs()

    lost = [dict.fromkeys(keys, "") | {"index": "-1", "timestamp": str(d["timestamp"]), "dropped": d["reason"]} for d in dropped]
    return sorted(rows + lost, key=lambda r: float(r["timestamp"]))


def ycbcr_planes(frame: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """A color frame's luma plane, height x width uint8, and CbCr plane, height / 2 x width / 2 x 2 uint8 (Cb, Cr), each Cb, Cr pair covering 2 x 2 luma pixels."""
    def _validate_inputs() -> None:
        assert frame.dtype == np.uint8 and frame.ndim == 2 and frame.shape[0] % 3 == 0 and frame.shape[1] % 2 == 0, (frame.dtype, frame.shape)

    _validate_inputs()

    height = frame.shape[0] * 2 // 3
    return frame[:height], frame[height:].reshape(height // 2, frame.shape[1] // 2, 2)


def ycbcr_to_bgr(frame: np.ndarray, matrix: str) -> np.ndarray:
    """A color frame as 8-bit BGR: full-range R = Y + 2(1-Kr)(Cr-128), B = Y + 2(1-Kb)(Cb-128), G = (Y - Kr R - Kb B) / (1 - Kr - Kb) with the named matrix's Kr and Kb, each Cb, Cr pair applied to its 2 x 2 luma pixels, rounded to the nearest level and clipped to 0..255."""
    def _validate_inputs() -> None:
        assert matrix in YCBCR_MATRICES, (matrix, sorted(YCBCR_MATRICES))

    _validate_inputs()

    luma, cbcr = ycbcr_planes(frame)
    kr, kb = YCBCR_MATRICES[matrix]
    height, width = luma.shape
    assert luma.dtype == np.uint8 and cbcr.dtype == np.uint8, (luma.dtype, cbcr.dtype)
    # Luma as (block row, row in block, block column, column in block), so each 2 x 2 block's Cb, Cr broadcast over its four pixels.
    y = luma.astype(np.float64).reshape(height // 2, 2, width // 2, 2)
    cb, cr = (cbcr[:, None, :, None, i].astype(np.float64) - 128 for i in (0, 1))
    r = y + 2 * (1 - kr) * cr
    b = y + 2 * (1 - kb) * cb
    g = (y - kr * r - kb * b) / (1 - kr - kb)
    bgr = np.clip(np.rint(np.stack([b, g, r], axis=-1)), 0, 255)
    assert bgr.dtype == np.float64, bgr.dtype
    return bgr.astype(np.uint8).reshape(height, width, 3)


def upright(image: np.ndarray, rotation_deg: str) -> np.ndarray:
    """Rotates a sensor-oriented image clockwise by the recorded upright rotation."""
    return np.ascontiguousarray(np.rot90(image, k=-(int(rotation_deg) // 90) % 4))


def valid(depth: np.ndarray) -> np.ndarray:
    return np.isfinite(depth) & (depth > 0)

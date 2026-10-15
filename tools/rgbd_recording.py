"""Reads an RGBD Scanner recording, an uncompressed tar of format_version "4.0" to "4.8" or "5.0.0" to "5.2", through one interface: its per-frame color and depth rows, its color frames, depth maps and the rear's confidence maps memory-mapped in place at each member's data offset inside the tar, never extracted (a front recording is about 0.55 GB per second), or, from 5.0.2, decoded from their lossless encoding, the rear's poses and, from 4.8, the front frames' lens distortion, each depth frame's depth-to-color transform and the frame files' recorded sizes and SHA-256s. format_version is the version of the app that wrote it: "4.<minor>", the minor naming the app build, then "<major>.<minor>.<patch>" from 5.0.0. This docstring is the format's document; app/Sources/RGBDScanner/Recording.swift's header comment describes the writer.

Format 4.8, which 5.0.0 and 5.0.1 keep and 5.0.2 to 5.2 encode as described below. A recording is <scan_id>.tar, whose members are exactly <scan_id>/<file> for scan_metadata.json, color_frames.bin, color_frames_metadata.json, depth_frames.bin, depth_frames_metadata.json, color_intrinsics.json, depth_intrinsics.json, extrinsics.json and, for the rear, depth_frames_confidence.bin. The phone keeps these files as Documents/<scan_id>/ and uploads them one by one, and server/receive.py, once all of them have arrived with their checksums, writes them into <out>/<scan_id>.tar in the upload manifest's order, a GNU tar (a member can exceed 8 GiB). scan_id is rgbd_<yyyyMMdd_HHmmss>_<camera>, followed by _<the user's name for it reduced to [A-Za-z0-9_-], at most 40 characters> when the user named it. Each concern has one file: intrinsic parameters and extrinsics never share a file, and no file repeats another's indices or timestamps, frame n of a .bin file being entry n of its frames list.

The camera is "front", the TrueDepth camera through AVFoundation (color 1920x1440, and 4032x3024 before 5.0.1, and depth 640x480 on the test phone), or "rear", the LiDAR camera through ARKit world tracking (color 1920x1440, scene depth 256x192 with its confidence, every fourth of ARKit's 60 fps frames); both record at 15 fps, the rear at 60 fps before 5.0.0; depth filtering is always off. Every timestamp is a capture time in host-clock (CMClockGetHostTimeClock) seconds, one clock for every file; a color frame and a depth frame were captured together when their timestamps are equal (`pairs`). Pixels, intrinsics and the poses' camera frame are in the sensor's native orientation, unrotated and unmirrored; `upright` turns a frame the way the phone was held.

scan_metadata.json holds exactly format_version ("4.8" or "5.0.0" to "5.2"), scan_id, name, start_time_utc, duration_s (the last minus the first timestamp over every color and depth frame, delivered or dropped), phone_model, phone_id (UIDevice's identifierForVendor, or null when iOS gives none), ios_version, camera, frame_rate (the configured frames per second), recovered (whether the recording was finished at a later launch, the app having been closed mid-recording), from 5.2, author (the app's user who recorded it, null when the app did not know it), and, in an aligned recording, which tools/align_recording.py writes from a recording and documents, alignment.

color_frames.bin holds every delivered color frame uncompressed, frame n at bytes [n*w*h*3/2, (n+1)*w*h*3/2) for a w x h frame, no header: the camera's 420f buffer, 8-bit full-range YCbCr 4:2:0, its luma plane (h rows of w bytes, one Y per pixel) then its CbCr plane (h/2 rows of w bytes, one Cb, Cr byte pair per 2x2 pixels), rows tightly packed; `color_bgr` converts a frame to BGR through its ycbcr_matrix. depth_frames.bin holds every delivered depth map as the camera delivered it, in metres as little-endian Float32 ("fdep", 4 bytes per pixel) or Float16 ("hdep", 2 bytes), the most precise depth type the capture format offers (the rear's always Float32), map n at bytes [n*w*h*b, (n+1)*w*h*b) for b bytes per pixel, rows tightly packed, NaN or 0 meaning no reading. The rear's depth_frames_confidence.bin holds one UInt8 ARConfidenceLevel map per depth map, in depth_frames.bin's order and layout: 0 low, 1 medium, 2 high.

color_frames_metadata.json holds file ("color_frames.bin"), its size in bytes and sha256 (64 lowercase hex characters), width, height, pixel_format ("420f"), ycbcr_matrix (the kCVImageBufferYCbCrMatrix_ name, ITU_R_601_4 or ITU_R_709_2), frame_count, frames and dropped. frames[n] is color frame n: its timestamp; upright_rotation_deg, the clockwise rotation (0, 90, 180 or 270) that turns the frame upright, from AVCaptureDevice.RotationCoordinator's videoRotationAngleForHorizonLevelCapture; gravity, CoreMotion's gravity in g in the phone's device frame (x right, y toward the top of the phone held in portrait, z out of the screen), and gravity_timestamp, its sample time, both null before the first motion sample; and exposure_duration_s, the frame's own exposure time in seconds. dropped lists the frames the camera or the app dropped, in time order, each its timestamp and reason (late, out_of_buffers, discontinuity, unknown, dropped, writer_busy, ...); they have no bytes.

depth_frames_metadata.json holds the same for depth_frames.bin, file, size, sha256, width, height, pixel_format ("fdep" or "hdep"), frame_count, frames and dropped (reasons such as no_scene_depth), and, for the rear, confidence: depth_frames_confidence.bin's file, size, sha256 and pixel_format ("L008"). A front depth frame is its timestamp, filtered (AVDepthData's isDepthDataFiltered), accuracy (absolute or relative) and quality (high or low); a rear one is its timestamp only.

color_intrinsics.json and depth_intrinsics.json each hold image_width and image_height, principal_point_origin, frames and, for the front, distortions. frames[n] is frame n's intrinsic matrix fx, fy, cx, cy in its own stream's pixels, or null when the frame came without one. The principal point origin is "upper_left_pixel_corner" for the front, AVFoundation measuring from the frame's upper-left corner, half a pixel before pixel (0, 0)'s center, and "upper_left_pixel_center" for the rear, ARCamera. The front's color intrinsics are Apple's per-frame intrinsic matrices, which Apple carries from the calibration's reference dimensions about pixel centers, the principal point of a frame scaled by s at (c + 0.5) * s - 0.5; from 5.0.1, whose color frames are so scaled, the app carries them about the frame's corner, at c * s, as it carries the depth intrinsics and the distortion centers.intrinsics measuring from pixel (0, 0)'s center (as ARCamera.h says). The front's color intrinsics are each color frame's own intrinsic matrix; its depth intrinsics are each depth frame's AVDepthData.cameraCalibrationData.intrinsicMatrix carried from the calibration's reference dimensions to the depth map by plain scaling, f*s and c*s. The rear's color intrinsics are ARCamera.intrinsics; its depth intrinsics carry them to the depth map as its grid lies on the color image, measured on six rear scans from where depth edges land on color edges: f*s on both axes, cx*sx along x, where the first depth column's center sits on the first color column's center, and (cy+0.5)*sy-0.5 along y, where the depth rows span the color rows edge to edge, s = depth size / color size. Each front distortion is Apple's lens distortion from an AVCameraCalibrationData: center, its lensDistortionCenter carried from the calibration's reference dimensions to the image (center * image size / reference size, the matrix's origin), and lookup_table and inverse_lookup_table, its lensDistortionLookupTable and inverseLensDistortionLookupTable as Float32 values, copied as they are, radius-normalized (they span the distance from the center to the farthest corner). Each distinct distortion appears once, with frame_ranges, inclusive [first, last] runs of the frames it applies to, which together cover every frame whose distortion is known exactly once. A depth frame's distortion is its own calibration's, unknown when it came without one; a color frame's is the one of the depth frame with the same timestamp, else of the latest earlier depth frame, else of the first depth frame, unknown when no depth frame had a calibration. ARKit reports no distortion, so the rear has none.

extrinsics.json holds depth_to_color, each distinct 3x4 row-major transform (rotation, then translation in metres) from a depth frame's camera to the color camera once, with depth_frame_ranges, inclusive runs of the depth frames it applies to, which together cover every depth frame with a known transform exactly once: for the front, each depth frame's AVCameraCalibrationData.extrinsicMatrix (identity in practice, Apple registering depth to color), a depth frame without a calibration in no run; for the rear, identity for every depth frame (ARKit registering scene depth to the captured image). The rear's camera_poses[n] is color frame n's pose: tracking_state (normal, not_available, limited_initializing, limited_excessive_motion, limited_insufficient_features or limited_relocalizing) and world_from_camera, rows 0 to 2 of ARCamera.transform, row-major: the transform from ARKit's camera frame (+x toward increasing column of the sensor-oriented image, +y toward decreasing row, +z toward the viewer, looking along -z) to its gravity-aligned world frame (+y up, origin where tracking started), metres; `world_from_camera` returns it as a 4x4 matrix.

`color_rows` and `depth_rows` give every version one row per frame, delivered or dropped, in time order, every value a string: index (-1 on a dropped row), timestamp, dropped (a dropped row's reason; its other cells are empty) and fx, fy, cx, cy (empty when the frame came without intrinsics); color rows add upright_rotation_deg, gravity_x, gravity_y, gravity_z, gravity_ts (empty before the first motion sample), exposure_duration_s and, for the rear, tracking_state and world_from_camera_00 to world_from_camera_23; front depth rows add filtered ("1" or "0"), accuracy and quality. `colors` and `depths` are the delivered rows, frame n the row with index n.

Format 5.0.2 stores every frame losslessly encoded and otherwise keeps 4.8's files and JSON; the reader tells an encoded recording by its frames metadata's encoding, and one whose frame members' entries record no sha256 by those entries, as the app numbered compression 5.0.1 and uploading while recording 5.0.2 before they were renumbered 5.0.2 and 5.0.3. Each frame member holds its frames concatenated, frame n the compressed_size bytes after frames 0 to n-1, each one raw DEFLATE stream (RFC 1951); color_frames_metadata.json, depth_frames_metadata.json and its confidence entry add encoding, "row_delta_deflate" for the color frames and "deflate" for the depth and confidence maps, and their size and sha256 are the encoded member's. A row_delta_deflate stream inflates to the 420f frame with every row after its plane's first (the luma plane's height rows, then the CbCr plane's height / 2 rows) replaced by its bytewise difference, mod 256, from the row above; a deflate stream inflates to the map as stored in 4.8. Each color frames entry adds compressed_size and raw_sha256, the SHA-256 the app took of the frame's bytes before encoding them, and each depth frames entry the same for its map and, for the rear, confidence_compressed_size and confidence_raw_sha256 for its confidence map. `color` decodes a frame each time it is indexed; `depth` and `confidence` are decoded whole when the tar is read.

Format 5.0.3, which 5.1 and 5.2 keep, is 5.0.2 uploaded while it was recorded: the app sent each frame member in segments, each hashed for its upload, which the receiver joined into the member, so the frame members' entries record their size and no sha256; every frame's raw_sha256 still checks the member's every byte.

Formats 4.0 to 4.7 differ as follows. A recording's tar, POSIX ustar as apps 4.0 to 4.5 streamed it and GNU from app 4.6 on, when the receiver began assembling it, has its members under <id>/: metadata.json, color.bin, color.csv, depth.bin, depth.csv, and confidence.bin (rear) or calibration.jsonl (front); color.bin, depth.bin (always "fdep") and confidence.bin are laid out as color_frames.bin, depth_frames.bin and depth_frames_confidence.bin. metadata.json holds the scan's facts under other names (id, device_model, system_version, color_width, color_ycbcr_matrix, depth_width, ...) with frame counts, byte sizes, depth_source, focus and prose conventions, and no file records the frames' sizes or SHA-256s. color.csv and depth.csv are `color_rows` and `depth_rows` as written, but depth rows also carry upright_rotation_deg, gravity and bytes_per_row (the delivered map's row stride, which depth.bin drops), and color.csv lacks exposure_duration_s before minor 3 and, from minor 3, also has lens_position (the capture device's lensPosition, 0 to 1) and received_ts (the host-clock seconds at which the app received the frame), both read when the frame reached the app and so later than its exposure by the capture pipeline's latency. The front's calibration.jsonl holds one line per delivered depth map, in depth.csv's order, {"index", "timestamp", "calibration"}, the map's AVCameraCalibrationData described at its reference dimensions, or null when it came without one; nothing records the color frames' distortion or depth-to-color transform. Minors 4 to 6 add to a rear recording's metadata.json avfoundation_calibration, Apple's calibration of the wide camera ARKit captures through, taken through AVFoundation as the rear camera started: its intrinsic matrix at its own reference dimensions, extrinsics, pixel size, lens distortion center and lookup tables, with the camera's lens position and the host-clock seconds when it was taken. It does not describe ARKit's frames, whatever its avfoundation_calibration_description says: measured on four rear takes (2026-10-06 and 2026-10-07), their straight edges bow against its tables' prediction with the opposite sign and a different radial profile, 1.3 times the prediction near the center and 0.6 times toward the edges; minor 7 no longer records it.
"""

import csv
import io
import json
import re
import tarfile
import zlib
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple, Union

import numpy as np

# Format 4.8's files: every recording's, and each camera's own.
FILES = {"scan_metadata.json", "color_frames.bin", "color_frames_metadata.json", "depth_frames.bin", "depth_frames_metadata.json", "color_intrinsics.json", "depth_intrinsics.json", "extrinsics.json"}
CAMERA_FILES = {"front": set(), "rear": {"depth_frames_confidence.bin"}}
SCAN_METADATA_KEYS = {"format_version", "scan_id", "name", "start_time_utc", "duration_s", "phone_model", "phone_id", "ios_version", "camera", "frame_rate", "recovered"}
# The versions whose scan_metadata.json also holds the recording's author.
AUTHOR_VERSIONS = {"5.2"}
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
# Format 5.0.2's encodings of the color frames and of the depth and confidence maps.
COLOR_ENCODING = "row_delta_deflate"
MAP_ENCODING = "deflate"
# The keys format 5.0.2's frames entries add for their frame as stored, and the rear's depth frames entries for their confidence map.
STORED_KEYS = ["compressed_size", "raw_sha256"]
CONFIDENCE_STORED_KEYS = ["confidence_compressed_size", "confidence_raw_sha256"]
# Format 4.8's depth pixel formats, each with the little-endian dtype of its metres.
DEPTH_DTYPES = {"fdep": np.dtype("<f4"), "hdep": np.dtype("<f2")}
HIGH_CONFIDENCE = 2
SAME_INSTANT_S = 0.0005
# Kr and Kb of each YCbCr matrix a recording's ycbcr_matrix can name (kCVImageBufferYCbCrMatrix_*).
YCBCR_MATRICES = {"ITU_R_601_4": (0.299, 0.114), "ITU_R_709_2": (0.2126, 0.0722)}


class Recording:
    """A format_version "4.0" to "4.8" or "5.0.0" to "5.2" recording tar: its metadata and per-frame rows read, its frames memory-mapped in place inside it or, from 5.0.2, decoded."""

    # Every format's.
    path: Path
    format_version: str
    # The minor of format_version, 0 to 8, and 8 for 5.0.0 to 5.2, which keep 4.8's files.
    format_minor: int
    # Whether the frame members hold encoded frames, as from 5.0.2.
    encoded: bool
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
    # Frames x 420f frame (height * 3 / 2 rows of width bytes), frames x depth map in metres (Float32, or Float16 for a 4.8 "hdep" recording), and the rear's frames x confidence map: memory-mapped, or for 5.0.2 the color frames decoded as indexed and the maps decoded.
    color: Union[np.memmap, "EncodedColorFrames"]
    depth: np.ndarray
    confidence: Optional[np.ndarray]
    # Format 4.0 to 4.7's metadata.json and, for the front, calibration.jsonl's lines; None for 4.8.
    meta: Optional[Dict]
    calibrations: Optional[List[Dict]]
    # Format 4.8's JSON files as read; None for 4.0 to 4.7.
    scan_metadata: Optional[Dict]
    color_frames_metadata: Optional[Dict]
    depth_frames_metadata: Optional[Dict]
    color_intrinsics: Optional[Dict]
    depth_intrinsics: Optional[Dict]
    extrinsics: Optional[Dict]
    # Format 4.8's frame files, each with the size and SHA-256 its frames metadata records, the SHA-256 None for 5.0.3 to 5.2; None for 4.0 to 4.7.
    frame_files: Optional[Dict[str, Tuple[int, Optional[str]]]]
    # Whether this is an aligned recording (tools/align_recording.py): format 4.8 with alignment in scan_metadata.json, its frames resampled onto their intrinsic matrices, no distortions and every depth_to_color the identity; False for 4.0 to 4.7.
    aligned: bool
    # A front recording's Apple distortion of each color and depth frame, center (in that frame's pixels), lookup_table and inverse_lookup_table, or None where unknown: 4.8's distortions entries, and for 4.0 to 4.7 each depth frame's calibration.jsonl line carried to the depth map and each color frame's taken from the depth frames by 4.8's rule (`front_distortions`); None for a rear or aligned recording.
    color_distortions: Optional[List[Optional[Dict]]]
    depth_distortions: Optional[List[Optional[Dict]]]
    # Each depth frame's depth_to_color matrix, 3 x 4 float64, or None where unknown: 4.8's runs, and for 4.0 to 4.7 a front frame's calibration.jsonl extrinsic matrix and the identity for every rear frame.
    depth_to_color: List[Optional[np.ndarray]]

    def __init__(self, path: Union[str, Path]) -> None:
        def _validate_inputs() -> None:
            assert isinstance(path, (str, Path)), type(path)

        _validate_inputs()

        def _normalize_inputs() -> Path:
            return Path(path)

        path = _normalize_inputs()

        self.path = path
        # Mode "r:" opens an uncompressed tar only, the one whose members can be memory-mapped in place.
        with tarfile.open(path, "r:") as tar:
            members = {Path(m.name).name: m for m in tar.getmembers()}
            # Format 4.8 names its metadata scan_metadata.json, 4.0 to 4.7 metadata.json.
            if "scan_metadata.json" in members:
                self._read_4_8(tar, members)
            else:
                self._read_4_0_to_4_7(tar, members)
        self.colors = [r for r in self.color_rows if r["index"] != "-1"]
        self.depths = [r for r in self.depth_rows if r["index"] != "-1"]

    def _read_4_0_to_4_7(self, tar: tarfile.TarFile, members: Dict[str, tarfile.TarInfo]) -> None:
        """Reads a format 4.0 to 4.7 tar's members, its .bin members memory-mapped in place inside it."""
        assert "metadata.json" in members, sorted(members)
        self.meta = json.load(tar.extractfile(members["metadata.json"]))
        # Major 4, the minor naming the app build that wrote it; minor 8 names its metadata scan_metadata.json.
        version = re.fullmatch(r"4\.([0-7])", self.meta["format_version"])
        assert version is not None, self.meta["format_version"]
        self.format_version = self.meta["format_version"]
        self.format_minor = int(version.group(1))
        self.encoded = False
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
        self.frame_files = self.color_distortions = self.depth_distortions = None
        self.aligned = False
        delivered_depths = [r for r in self.depth_rows if r["index"] != "-1"]
        if camera == "rear":
            self.depth_to_color = [np.eye(3, 4) for _ in delivered_depths]
            return
        assert len(self.calibrations) == len(delivered_depths), (len(self.calibrations), len(delivered_depths))
        calibrations = [line["calibration"] for line in self.calibrations]
        self.depth_to_color = [None if c is None else np.array(c["extrinsic_matrix_row_major_3x4"], np.float64) for c in calibrations]
        colors = [r for r in self.color_rows if r["index"] != "-1"]
        self.color_distortions, self.depth_distortions = front_distortions(calibrations, [float(r["timestamp"]) for r in delivered_depths], [float(r["timestamp"]) for r in colors], (self.color_width, self.color_height), (self.depth_width, self.depth_height))

    def _read_4_8(self, tar: tarfile.TarFile, members: Dict[str, tarfile.TarInfo]) -> None:
        """Reads a format 4.8 or 5.0.0 to 5.2 tar's members, checking that they are exactly its camera's files under <scan_id>/, every list one entry per frame, every run within the frames and disjoint from the others, and every frame member the frames its metadata counts at the size it records, memory-mapped in place inside the tar."""
        def load(name: str) -> Dict:
            return json.load(tar.extractfile(members[name]))

        self.scan_metadata = load("scan_metadata.json")
        assert self.scan_metadata["format_version"] in ("4.8", "5.0.0", "5.0.1", "5.0.2", "5.0.3", "5.1", "5.2"), self.scan_metadata["format_version"]
        camera = self.scan_metadata["camera"]
        assert camera in CAMERA_FILES, camera
        names = sorted(m.name for m in tar.getmembers())
        assert names == sorted(f"{self.scan_metadata['scan_id']}/{name}" for name in FILES | CAMERA_FILES[camera]), names
        self.format_version, self.format_minor = self.scan_metadata["format_version"], 8
        self.aligned = "alignment" in self.scan_metadata
        self.camera, self.scan_id, self.frame_rate = camera, self.scan_metadata["scan_id"], self.scan_metadata["frame_rate"]
        self.meta = self.calibrations = None

        color, depth = load("color_frames_metadata.json"), load("depth_frames_metadata.json")
        self.color_frames_metadata, self.depth_frames_metadata = color, depth
        # Told by the frames metadata, as a recording made before the renumbering carries compression's and uploading's earlier numbers.
        self.encoded = "encoding" in color
        self.color_width, self.color_height, self.ycbcr_matrix = color["width"], color["height"], color["ycbcr_matrix"]
        self.depth_width, self.depth_height = depth["width"], depth["height"]
        width, height = self.color_width, self.color_height
        assert color["file"] == "color_frames.bin" and color["pixel_format"] == "420f" and width % 2 == 0 and height % 2 == 0, (color["file"], color["pixel_format"], width, height)
        assert depth["file"] == "depth_frames.bin" and depth["pixel_format"] in DEPTH_DTYPES, (depth["file"], depth["pixel_format"])
        assert color["frame_count"] == len(color["frames"]) and depth["frame_count"] == len(depth["frames"]), (color["frame_count"], len(color["frames"]), depth["frame_count"], len(depth["frames"]))
        assert ("confidence" in depth) == (camera == "rear"), sorted(depth)
        frame_files = [color, depth] + ([depth["confidence"]] if camera == "rear" else [])
        assert all(("encoding" in f) == self.encoded for f in frame_files), [sorted(f) for f in frame_files]
        depth_shape = (self.depth_height, self.depth_width)
        if self.encoded:
            assert color["encoding"] == COLOR_ENCODING and depth["encoding"] == MAP_ENCODING, (color["encoding"], depth["encoding"])
            self.color = EncodedColorFrames(self.path, members[color["file"]], color, width, height)
            self.depth = decode_maps(self.path, members[depth["file"]], depth["size"], [f["compressed_size"] for f in depth["frames"]], DEPTH_DTYPES[depth["pixel_format"]], depth_shape)
        else:
            self.color = map_counted_frames(self.path, members[color["file"]], color, np.dtype(np.uint8), (height * 3 // 2, width), color["frame_count"])
            self.depth = map_counted_frames(self.path, members[depth["file"]], depth, DEPTH_DTYPES[depth["pixel_format"]], depth_shape, depth["frame_count"])
        self.confidence = None
        if camera == "rear":
            confidence = depth["confidence"]
            assert confidence["file"] == "depth_frames_confidence.bin" and confidence["pixel_format"] == "L008", (confidence["file"], confidence["pixel_format"])
            if self.encoded:
                assert confidence["encoding"] == MAP_ENCODING, confidence["encoding"]
                self.confidence = decode_maps(self.path, members[confidence["file"]], confidence["size"], [f["confidence_compressed_size"] for f in depth["frames"]], np.dtype(np.uint8), depth_shape)
            else:
                self.confidence = map_counted_frames(self.path, members[confidence["file"]], confidence, np.dtype(np.uint8), depth_shape, depth["frame_count"])
        # Whether each SHA-256 is its member's own is for inspect_recording to check, which reads every byte; 5.0.3 to 5.2 record none.
        assert len({"sha256" in f for f in frame_files}) == 1 and ("sha256" in frame_files[0] or self.format_version in ("5.0.2", "5.0.3", "5.1", "5.2")), [sorted(f) for f in frame_files]
        assert all(re.fullmatch(r"[0-9a-f]{64}", f["sha256"]) for f in frame_files if "sha256" in f), [f.get("sha256") for f in frame_files]
        self.frame_files = {f["file"]: (f["size"], f.get("sha256")) for f in frame_files}

        self.color_intrinsics, self.depth_intrinsics = load("color_intrinsics.json"), load("depth_intrinsics.json")
        for intrinsics, frames in ((self.color_intrinsics, color), (self.depth_intrinsics, depth)):
            assert (intrinsics["image_width"], intrinsics["image_height"]) == (frames["width"], frames["height"]), (intrinsics["image_width"], intrinsics["image_height"], frames["width"], frames["height"])
            assert intrinsics["principal_point_origin"] == PRINCIPAL_POINT_ORIGINS[camera], (camera, intrinsics["principal_point_origin"])
            assert len(intrinsics["frames"]) == frames["frame_count"], (frames["file"], len(intrinsics["frames"]), frames["frame_count"])
            # ARKit reports no distortion, and aligned frames have none left.
            assert ("distortions" in intrinsics) == (camera == "front" and not self.aligned), sorted(intrinsics)
        self.color_principal_point_origin = self.color_intrinsics["principal_point_origin"]
        self.depth_principal_point_origin = self.depth_intrinsics["principal_point_origin"]
        self.color_distortions = self.depth_distortions = None
        if camera == "front" and not self.aligned:
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

        colors = [color_row(n, frame, k, pose, self.encoded) for n, (frame, k, pose) in enumerate(zip(color["frames"], self.color_intrinsics["frames"], poses, strict=True))]
        depths = [depth_row(camera, n, frame, k, self.encoded) for n, (frame, k) in enumerate(zip(depth["frames"], self.depth_intrinsics["frames"], strict=True))]
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


def scan_metadata_keys(version: str) -> set:
    """The keys a format 4.8 or later recording's scan_metadata.json holds: SCAN_METADATA_KEYS, and author for AUTHOR_VERSIONS."""
    return SCAN_METADATA_KEYS | ({"author"} if version in AUTHOR_VERSIONS else set())


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


def map_counted_frames(tar_path: Path, member: tarfile.TarInfo, entry: Dict, dtype: np.dtype, frame_shape: Tuple[int, int], frames: int) -> np.memmap:
    """A format 4.8 frame member memory-mapped as `map_frames` maps it, once the size its frames metadata entry records and its size in the tar both hold exactly `frames` frames."""
    def _validate_inputs() -> None:
        assert entry["size"] == frames * dtype.itemsize * frame_shape[0] * frame_shape[1] == member.size, (member.name, entry["size"], frames, frame_shape, member.size)

    _validate_inputs()

    return map_frames(tar_path, member, dtype, frame_shape)


class EncodedColorFrames:
    """A format 5.0.2 color frame member's frames, each decoded from its row_delta_deflate stream inside the tar when indexed, as format 4.8 stores it: frames x (height * 3 / 2) x width uint8."""

    def __init__(self, tar_path: Path, member: tarfile.TarInfo, entry: Dict, width: int, height: int) -> None:
        def _validate_inputs() -> None:
            assert member.isreg(), member.name
            assert entry["encoding"] == COLOR_ENCODING, entry["encoding"]
            assert entry["size"] == sum(f["compressed_size"] for f in entry["frames"]) == member.size, (member.name, entry["size"], member.size)
            assert width % 2 == 0 and height % 2 == 0, (width, height)

        _validate_inputs()

        self.width, self.height = width, height
        self.shape = (len(entry["frames"]), height * 3 // 2, width)
        self.dtype = np.dtype(np.uint8)
        self._starts = np.concatenate([[0], np.cumsum([f["compressed_size"] for f in entry["frames"]])])
        self._bytes = np.memmap(tar_path, dtype=np.uint8, mode="r", offset=member.offset_data, shape=(member.size,))

    def __len__(self) -> int:
        return self.shape[0]

    def __getitem__(self, index: int) -> np.ndarray:
        """Frame `index`, decoded: inflated, then each plane's rows summed down its columns, mod 256, undoing the delta from the row above."""
        def _validate_inputs() -> None:
            assert isinstance(index, (int, np.integer)) and 0 <= index < len(self), index

        _validate_inputs()

        rows = np.frombuffer(inflate(self._bytes[self._starts[index]:self._starts[index + 1]].tobytes()), dtype=np.uint8)
        assert rows.size == self.shape[1] * self.shape[2], (index, rows.size, self.shape)
        rows = rows.reshape(self.shape[1:])
        return np.concatenate([np.cumsum(rows[:self.height], axis=0, dtype=np.uint8), np.cumsum(rows[self.height:], axis=0, dtype=np.uint8)])


def decode_maps(tar_path: Path, member: tarfile.TarInfo, size: int, compressed_sizes: List[int], dtype: np.dtype, frame_shape: Tuple[int, int]) -> np.ndarray:
    """A format 5.0.2 map member's maps, each inflated from its deflate stream, the streams' compressed sizes summing to the size its metadata records and to the member's: frames x frame_shape of dtype."""
    def _validate_inputs() -> None:
        assert member.isreg(), member.name
        assert size == sum(compressed_sizes) == member.size, (member.name, size, sum(compressed_sizes), member.size)

    _validate_inputs()

    data = np.memmap(tar_path, dtype=np.uint8, mode="r", offset=member.offset_data, shape=(member.size,))
    starts = np.concatenate([[0], np.cumsum(compressed_sizes)])
    maps = np.empty((len(compressed_sizes), *frame_shape), dtype)
    for n in range(len(compressed_sizes)):
        raw = inflate(data[starts[n]:starts[n + 1]].tobytes())
        assert len(raw) == maps[n].nbytes, (member.name, n, len(raw), maps[n].nbytes)
        maps[n] = np.frombuffer(raw, dtype).reshape(frame_shape)
    return maps


def inflate(stream: bytes) -> bytes:
    """A raw DEFLATE stream's bytes, the stream ending exactly where `stream` does."""
    decompressor = zlib.decompressobj(-15)
    raw = decompressor.decompress(stream)
    assert decompressor.eof and not decompressor.unused_data, (decompressor.eof, len(decompressor.unused_data))
    return raw


def stored(frame: Dict, keys: List[str]) -> bool:
    """Whether a format 5.0.2 frames entry's compressed size under keys[0] is a positive integer and its raw SHA-256 under keys[1] 64 lowercase hex characters."""
    size, sha256 = (frame[k] for k in keys)
    return isinstance(size, int) and size > 0 and isinstance(sha256, str) and re.fullmatch(r"[0-9a-f]{64}", sha256) is not None


def per_frame(entries: List[Dict], ranges_key: str, count: int) -> List[Optional[Dict]]:
    """Each of `count` frames' entry, the one whose inclusive [first, last] runs under ranges_key hold it, or None for a frame in no run; the runs lie within the frames and never overlap."""
    frames: List[Optional[Dict]] = [None] * count
    for entry in entries:
        for first, last in entry[ranges_key]:
            assert 0 <= first <= last < count, (ranges_key, first, last, count)
            assert all(f is None for f in frames[first:last + 1]), (ranges_key, "overlapping run", first, last)
            frames[first:last + 1] = [entry] * (last - first + 1)
    return frames


def front_distortions(calibrations: List[Optional[Dict]], depth_times: List[float], color_times: List[float], color_size: Tuple[int, int], depth_size: Tuple[int, int]) -> Tuple[List[Optional[Dict]], List[Optional[Dict]]]:
    """A format 4.0 to 4.7 front recording's per-frame distortions, as 4.8 records them: each depth frame's calibration.jsonl line (None where it has none) carried from its reference dimensions to the depth map, and each color frame's from the depth frame captured with it, else the latest earlier one, else the first, among the depth frames with a calibration, carried to the color frame."""
    def carried(calibration: Dict, size: Tuple[int, int]) -> Dict:
        scale_x, scale_y = size[0] / calibration["intrinsic_reference_width"], size[1] / calibration["intrinsic_reference_height"]
        center = calibration["lens_distortion_center"]
        return {"center": [center[0] * scale_x, center[1] * scale_y], "lookup_table": calibration["lens_distortion_lookup_table"], "inverse_lookup_table": calibration["inverse_lens_distortion_lookup_table"]}

    depth = [None if c is None else carried(c, depth_size) for c in calibrations]
    known = [(t, c) for t, c in zip(depth_times, calibrations, strict=True) if c is not None]
    color: List[Optional[Dict]] = []
    for t in color_times:
        earlier = [c for depth_time, c in known if depth_time <= t + SAME_INSTANT_S]
        source = earlier[-1] if earlier else (known[0][1] if known else None)
        color.append(None if source is None else carried(source, color_size))
    return color, depth


def cell(value: Optional[float]) -> str:
    """A nullable JSON number as a row's cell, empty for null."""
    return "" if value is None else str(value)


def intrinsics_cells(intrinsics: Optional[Dict[str, float]]) -> Dict[str, str]:
    """A format 4.8 intrinsics frames entry as the fx, fy, cx, cy cells, empty for null."""
    def _validate_inputs() -> None:
        assert intrinsics is None or sorted(intrinsics) == sorted(INTRINSICS), intrinsics

    _validate_inputs()

    return {k: "" if intrinsics is None else str(intrinsics[k]) for k in INTRINSICS}


def color_row(index: int, frame: Dict, intrinsics: Optional[Dict[str, float]], pose: Optional[Dict], encoded: bool) -> Dict[str, str]:
    """Format 4.8 color frame `index` as its COLOR_KEYS row, from its frames entry, with STORED_KEYS when `encoded`, its intrinsics and, for the rear, its camera pose."""
    def _validate_inputs() -> None:
        assert sorted(frame) == sorted(["timestamp", "upright_rotation_deg", "gravity", "gravity_timestamp", "exposure_duration_s"] + (STORED_KEYS if encoded else [])), sorted(frame)
        assert not encoded or stored(frame, STORED_KEYS), frame
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


def depth_row(camera: str, index: int, frame: Dict, intrinsics: Optional[Dict[str, float]], encoded: bool) -> Dict[str, str]:
    """Format 4.8 depth frame `index` as its DEPTH_KEYS row, from its frames entry, with STORED_KEYS and for the rear CONFIDENCE_STORED_KEYS when `encoded`, and its intrinsics."""
    def _validate_inputs() -> None:
        assert camera in CAMERA_FILES, camera
        stored_keys = (STORED_KEYS + (CONFIDENCE_STORED_KEYS if camera == "rear" else [])) if encoded else []
        assert sorted(frame) == sorted((["timestamp", "filtered", "accuracy", "quality"] if camera == "front" else ["timestamp"]) + stored_keys), (camera, sorted(frame))
        assert not encoded or (stored(frame, STORED_KEYS) and (camera == "front" or stored(frame, CONFIDENCE_STORED_KEYS))), frame
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

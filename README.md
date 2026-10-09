# iOS-3D-Scanner

## App versions

Newest first, one line per change: what it was in the previous version -> what it is in this version. A recording's `format_version` names the app version that wrote it (integers 1, 3 and 5 for v1 to v3, "4.<minor>" from 4.0 on).

### 4.8 (2026-10-08, 0fb92cb)
- Recording: a tar of `metadata.json`, `color.csv`, `depth.csv`, `color.bin`, `depth.bin` and `confidence.bin` or `calibration.jsonl` -> a folder of `scan_metadata.json`, `color_frames.bin`, `color_frames_metadata.json`, `depth_frames.bin`, `depth_frames_metadata.json`, `depth_frames_confidence.bin` (rear), `color_intrinsics.json`, `depth_intrinsics.json` and `extrinsics.json`.
- Intrinsic parameters and extrinsics: mixed in `color.csv` (intrinsic matrix beside the pose) and `calibration.jsonl` (intrinsic parameters beside the extrinsic matrix) -> separate files, one concern each.
- Front calibration: repeated on every depth frame -> each distinct distortion and depth-to-color transform stored once with the frame runs it applies to.
- Checksums: only in the upload's manifest -> each frame file's size and SHA-256 in its frames metadata.
- Phone: model only -> also the phone's ID, to find its per-phone corrections.
- Dropped fields: lens position, received time, depth-row orientation, row stride, byte counts, filter flag, focus, depth source, the device's format lists and the prose descriptions -> removed; the format is documented once in `tools/rgbd_recording.py`.
- Server: each recording reassembled into a tar -> stored as the same folder.

### 4.7 (2026-10-07, 9b4b230)
- Rear calibration: Apple's AVFoundation calibration in every rear recording -> removed, measured not to describe ARKit's frames.
- Gallery: 4.1-4.5 recordings shown as unreadable -> listed again once their files are hashed at first launch.

### 4.6.1 (2026-10-07, measurement build, never on the main line)
- Front format: the largest depth map -> the smallest (it took 16:9: 1920x1080 color with 160x90 depth), to compare one corner at two depth resolutions.

### 4.6 (2026-10-07, 674b23f)
- Upload: one tar streamed by the app, stopped when the app left the screen -> each file sent by iOS's background transfer service, continuing after the app leaves the screen, and reassembled into the tar by the receiver.
- Hashing: while uploading -> while recording, from the frame bytes already in memory.
- Gallery file: `recording.json` without a file list -> with each file's size, SHA-256 and upload state (which hid 4.1-4.5 recordings until 4.7).

### 4.5 (2026-10-07, cf2cd91)
- Rear calibration source: the 640x480 AVFoundation format -> the full 4:3 format (later measured not to describe ARKit's frames either).

### 4.4 (2026-10-07, 5b79c80)
- Rear calibration: none, ARKit gives only a pinhole intrinsic matrix -> Apple's calibration of the rear camera, from its 640x480 AVFoundation format, taken when the rear camera starts and stored in every rear recording.

### 4.3 (2026-10-06, a1281fe)
- Color rows: no exposure, lens or arrival data -> each color frame's exposure time, the camera's lens position and when the app received it.

### 4.2 (2026-10-05, 8b75b48)
- Front frame rate: 30 fps, falling to 17-19 fps with writer drops after 8 s -> the highest rate within the storage's write budget: 15 fps for 4032x3024 color with 640x480 depth.

### 4.1 (2026-10-05, 8a6011e)
- Finishing: the tar packed after Stop, Record waiting for it -> a recording finished by renaming its directory, Record available the moment Stop is pressed.
- Upload: the packed tar file -> a tar streamed from the recording's files with its SHA-256 appended, checked by the receiver.
- Writing: a zero-filled allocation and copy per color frame -> reused page-aligned color buffers, frame files written past the page cache.

### 4.0 (2026-10-02 as v4, numbered 4.0 on 2026-10-05; 58ebb87, 01f0e2c, 92c7507)
- Cameras: front TrueDepth plus a choice of rear source and filter setting -> front TrueDepth through AVFoundation and rear LiDAR through ARKit only, depth filtering always off, autofocus wherever the lens can move.
- Color: compressed `color.mov` (lossy) -> every delivered frame uncompressed in `color.bin` as the camera's 420f planes, a frame dropped as `writer_busy` when the queued writes would pass 512 MiB.
- Rear depth intrinsic matrix: ARKit's scaled to the depth map -> carried per axis as the depth grid lies on the color image (x first-pixel centers, y edge to edge), measured on six rear scans.
- Rear poses: none -> ARKit's tracking state and camera transform for every color frame.
- Front calibration: the first depth frame's, in metadata -> every depth frame's full Apple calibration in `calibration.jsonl`.
- Removed: the rear AVFoundation source, the depth filter setting and the 8-bit H.264 depth tracks -> gone.
- Version: integer `format_version` -> app and recording version "4.0", the major the app version, the minor counting changes within it.

### v3 (2026-10-01, ablation build)
- Rear depth source: AVFoundation LiDAR only (4032x3024 color, 320x240 depth, nothing nearer than 0.7 m) -> a Depth source switch between that and ARKit (1920x1440 color, 256x192 depth, down to about 0.2 m).
- Rear ARKit confidence: none -> `confidence.bin`, ARKit's per-pixel confidence map.
- Depth filter: always off -> an Off/On setting for every source (Apple's depth filter for TrueDepth and LiDAR, `sceneDepth` or `smoothedSceneDepth` for ARKit).
- Old app's depth: not recorded -> every front recording also saves the old app's 8-bit H.264 depth track three ways.
- Depth rows: no row stride -> `depth.csv` records each depth map's bytes per row.
- Names: date, time and camera -> also the depth source and filter setting (e.g. `rear_lidar_filteroff`).

### v2 (2026-09-30)
- Pairing: synchronizer pairs in one `frames.csv`, each color frame with the depth frame one step earlier -> independent `color.csv` and `depth.csv`, each frame with its own capture timestamp.
- Orientation: not recorded, frames came out sideways -> every frame records its upright rotation and gravity, and `color.mov` plays upright.
- Depth intrinsic matrix: at the 4032x3024 reference size -> in the depth map's own pixels.
- Formats: limited to 30 fps formats -> the highest resolution per stream at the fastest frame rate both streams support.
- Naming: none -> a name prompt at Record (Later or Start) and again at Stop if deferred, defaulting to the date and time.
- Screen: color only -> a color/depth view toggle, with counters of the frames actually saved.
- Gallery: swipe to delete without confirmation -> rows with name, date and time, duration, size and upload state, and a delete that asks for confirmation and removes the phone's copy only.
- Upload: a manual Upload button, two uploads of one recording could collide -> automatic upload after naming, one at a time, Retry only after a failure.
- Robustness: a crash or leaving the app lost the recording, recordings of 8 GB or more crashed packing -> recording stops cleanly when the app leaves the screen, is recovered after a crash, and packs at any size.

### v1 (2026-09-30, first build)
- Cameras: none -> front TrueDepth and rear LiDAR camera, both through AVFoundation, depth filtering off.
- Recording: none -> color as a compressed `color.mov`, depth as raw `depth.bin`, color and depth paired by Apple's synchronizer into one `frames.csv` at a fixed 30 fps.
- Intrinsics: none -> each color frame's intrinsic matrix, and each depth frame's at the 4032x3024 calibration reference size.
- Upload: none -> the recording packed into a tar and uploaded to the receiver with an Upload button; swipe to delete.

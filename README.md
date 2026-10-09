# iOS-3D-Scanner

## App versions

Newest first, one line per change, each saying what the previous version did and what this version does. A recording's `format_version` names the app version that wrote it (integers 1, 3 and 5 for v1 to v3, "4.<minor>" from 4.0 on).

### 4.8 (2026-10-08, 0fb92cb)
- Recording: 4.7 a tar of `metadata.json`, `color.csv`, `depth.csv`, `color.bin`, `depth.bin` and `confidence.bin` or `calibration.jsonl`. 4.8 a folder of `scan_metadata.json`, `color_frames.bin`, `color_frames_metadata.json`, `depth_frames.bin`, `depth_frames_metadata.json`, `depth_frames_confidence.bin` (rear), `color_intrinsics.json`, `depth_intrinsics.json` and `extrinsics.json`.
- Intrinsic parameters and extrinsics: 4.7 mixed in `color.csv` (intrinsic matrix beside the pose) and `calibration.jsonl` (intrinsic parameters beside the extrinsic matrix). 4.8 separate files, one concern each.
- Front calibration: 4.7 repeated on every depth frame. 4.8 each distinct distortion and depth-to-color transform stored once with the frame runs it applies to.
- Checksums: 4.7 only in the upload's manifest. 4.8 each frame file's size and SHA-256 in its frames metadata.
- Phone: 4.7 model only. 4.8 also the phone's ID, to find its per-phone corrections.
- Dropped fields: 4.7 lens position, received time, depth-row orientation, row stride, byte counts, filter flag, focus, depth source, the device's format lists and the prose descriptions. 4.8 removed; the format is documented once in `tools/rgbd_recording.py`.
- Server: 4.7 each recording reassembled into a tar. 4.8 stored as the same folder.

### 4.7 (2026-10-07, 9b4b230)
- Rear calibration: 4.6 Apple's AVFoundation calibration in every rear recording. 4.7 removed, measured not to describe ARKit's frames.
- Gallery: 4.6 4.1-4.5 recordings shown as unreadable. 4.7 listed again once their files are hashed at first launch.

### 4.6.1 (2026-10-07, measurement build, never on the main line)
- Front format: 4.6 the largest depth map. 4.6.1 the smallest (it took 16:9: 1920x1080 color with 160x90 depth), to compare one corner at two depth resolutions.

### 4.6 (2026-10-07, 674b23f)
- Upload: 4.5 one tar streamed by the app, stopped when the app left the screen. 4.6 each file sent by iOS's background transfer service, continuing after the app leaves the screen, and reassembled into the tar by the receiver.
- Hashing: 4.5 while uploading. 4.6 while recording, from the frame bytes already in memory.
- Gallery file: 4.5 `recording.json` without a file list. 4.6 with each file's size, SHA-256 and upload state (which hid 4.1-4.5 recordings until 4.7).

### 4.5 (2026-10-07, cf2cd91)
- Rear calibration source: 4.4 the 640x480 AVFoundation format. 4.5 the full 4:3 format (later measured not to describe ARKit's frames either).

### 4.4 (2026-10-07, 5b79c80)
- Rear calibration: 4.3 none, ARKit gives only a pinhole intrinsic matrix. 4.4 Apple's calibration of the rear camera, from its 640x480 AVFoundation format, taken when the rear camera starts and stored in every rear recording.

### 4.3 (2026-10-06, a1281fe)
- Color rows: 4.2 no exposure, lens or arrival data. 4.3 each color frame's exposure time, the camera's lens position and when the app received it.

### 4.2 (2026-10-05, 8b75b48)
- Front frame rate: 4.1 30 fps, falling to 17-19 fps with writer drops after 8 s. 4.2 the highest rate within the storage's write budget: 15 fps for 4032x3024 color with 640x480 depth.

### 4.1 (2026-10-05, 8a6011e)
- Finishing: 4.0 the tar packed after Stop, Record waiting for it. 4.1 a recording finished by renaming its directory, Record available the moment Stop is pressed.
- Upload: 4.0 the packed tar file. 4.1 a tar streamed from the recording's files with its SHA-256 appended, checked by the receiver.
- Writing: 4.0 a zero-filled allocation and copy per color frame. 4.1 reused page-aligned color buffers, frame files written past the page cache.

### 4.0 (2026-10-02 as v4, numbered 4.0 on 2026-10-05; 58ebb87, 01f0e2c, 92c7507)
- Cameras: v3 front TrueDepth plus a choice of rear source and filter setting. 4.0 front TrueDepth through AVFoundation and rear LiDAR through ARKit only, depth filtering always off, autofocus wherever the lens can move.
- Color: v3 compressed `color.mov` (lossy). 4.0 every delivered frame uncompressed in `color.bin` as the camera's 420f planes, a frame dropped as `writer_busy` when the queued writes would pass 512 MiB.
- Rear depth intrinsic matrix: v3 ARKit's scaled to the depth map. 4.0 carried per axis as the depth grid lies on the color image (x first-pixel centers, y edge to edge), measured on six rear scans.
- Rear poses: v3 none. 4.0 ARKit's tracking state and camera transform for every color frame.
- Front calibration: v3 the first depth frame's, in metadata. 4.0 every depth frame's full Apple calibration in `calibration.jsonl`.
- Removed: v3 the rear AVFoundation source, the depth filter setting and the 8-bit H.264 depth tracks. 4.0 gone.
- Version: v3 integer `format_version`. 4.0 app and recording version "4.0", the major the app version, the minor counting changes within it.

### v3 (2026-10-01, ablation build)
- Rear depth source: v2 AVFoundation LiDAR only (4032x3024 color, 320x240 depth, nothing nearer than 0.7 m). v3 a Depth source switch between that and ARKit (1920x1440 color, 256x192 depth, down to about 0.2 m).
- Rear ARKit confidence: v2 none. v3 `confidence.bin`, ARKit's per-pixel confidence map.
- Depth filter: v2 always off. v3 an Off/On setting for every source (Apple's depth filter for TrueDepth and LiDAR, `sceneDepth` or `smoothedSceneDepth` for ARKit).
- Old app's depth: v2 not recorded. v3 every front recording also saves the old app's 8-bit H.264 depth track three ways.
- Depth rows: v2 no row stride. v3 `depth.csv` records each depth map's bytes per row.
- Names: v2 date, time and camera. v3 also the depth source and filter setting (e.g. `rear_lidar_filteroff`).

### v2 (2026-09-30)
- Pairing: v1 synchronizer pairs in one `frames.csv`, each color frame with the depth frame one step earlier. v2 independent `color.csv` and `depth.csv`, each frame with its own capture timestamp.
- Orientation: v1 not recorded, frames came out sideways. v2 every frame records its upright rotation and gravity, and `color.mov` plays upright.
- Depth intrinsic matrix: v1 at the 4032x3024 reference size. v2 in the depth map's own pixels.
- Formats: v1 limited to 30 fps formats. v2 the highest resolution per stream at the fastest frame rate both streams support.
- Naming: v1 none. v2 a name prompt at Record (Later or Start) and again at Stop if deferred, defaulting to the date and time.
- Screen: v1 color only. v2 a color/depth view toggle, with counters of the frames actually saved.
- Gallery: v1 swipe to delete without confirmation. v2 rows with name, date and time, duration, size and upload state, and a delete that asks for confirmation and removes the phone's copy only.
- Upload: v1 a manual Upload button, two uploads of one recording could collide. v2 automatic upload after naming, one at a time, Retry only after a failure.
- Robustness: v1 a crash or leaving the app lost the recording, recordings of 8 GB or more crashed packing. v2 recording stops cleanly when the app leaves the screen, is recovered after a crash, and packs at any size.

### v1 (2026-09-30, first build)
- Cameras: v1 front TrueDepth and rear LiDAR camera, both through AVFoundation, depth filtering off.
- Recording: v1 color as a compressed `color.mov`, depth as raw `depth.bin`, color and depth paired by Apple's synchronizer into one `frames.csv` at a fixed 30 fps.
- Intrinsic matrices: v1 each color frame's intrinsic matrix, and each depth frame's at the 4032x3024 calibration reference size.
- Upload: v1 the recording packed into a tar and uploaded to the receiver with an Upload button; swipe to delete.

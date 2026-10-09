# iOS-3D-Scanner

## App versions

Newest first. Each line is one change: what the previous version did, then what this version does. A recording's `format_version` is the version of the app that wrote it, without the "v": the integers 1, 3 and 5 for v1 to v3, and "4.0" to "4.8" from v4.0 on.

### v4.8 (2026-10-08, 0fb92cb; fixed 2026-10-09 in 7404d9f and 2a93830)
- Package contents: v4.7 packed `metadata.json`, `color.csv`, `depth.csv`, `color.bin`, `depth.bin`, and `calibration.jsonl` (front) or `confidence.bin` (rear). v4.8 packs `scan_metadata.json`, `color_frames.bin`, `color_frames_metadata.json`, `depth_frames.bin`, `depth_frames_metadata.json`, `color_intrinsics.json`, `depth_intrinsics.json`, `extrinsics.json`, and `depth_frames_confidence.bin` (rear).
- Intrinsic parameters and extrinsics: v4.7 stored each color frame's intrinsic matrix in `color.csv` next to ARKit's pose, and Apple's intrinsic parameters in `calibration.jsonl` next to Apple's extrinsic matrix. v4.8 stores all intrinsic parameters in `color_intrinsics.json` and `depth_intrinsics.json`, and all extrinsics in `extrinsics.json`.
- Front calibration: v4.7 repeated Apple's full calibration on every depth frame. v4.8 stores each distinct distortion table and depth-to-color transform once, with the ranges of frames it applies to.
- Checksums: v4.7 sent each file's SHA-256 only in the upload manifest. v4.8 also stores the size and SHA-256 of each frame file in `color_frames_metadata.json` and `depth_frames_metadata.json`.
- Phone identity: v4.7 recorded the phone model. v4.8 also records the phone's ID, which names the phone's correction file.
- Removed fields: v4.7 recorded the lens position, the arrival time, orientation on depth rows, the row stride, byte counts, the filter flag, the focus mode, the depth source, the camera's format lists and prose descriptions of the format. v4.8 records none of them, and the format is documented in `tools/rgbd_recording.py`.
- Displayed text: v4.7 showed non-ASCII symbols in the recording indicator, status lines, gallery rows and messages. v4.8 shows ASCII text only.

### v4.7 (2026-10-07, 9b4b230)
- Rear calibration: v4.6 stored Apple's AVFoundation calibration in every rear recording. v4.7 stores none, because measurements showed that calibration does not describe ARKit's frames.
- Gallery: v4.6 showed recordings made by v4.1 to v4.5 as unreadable. v4.7 lists them again, after hashing their files once at first launch.

### v4.6.1 (2026-10-07, measurement build from v4.6, never on the main line)
- Front format: v4.6 chose the largest depth map. v4.6.1 chose the smallest, which selected 1920x1080 color with 160x90 depth, to compare one corner at two depth resolutions.

### v4.6 (2026-10-07, 674b23f)
- Upload: v4.5 streamed one tar from the app, and the upload stopped when the app left the screen. v4.6 hands each file to iOS's background transfer service, which keeps sending after the app leaves the screen, and the receiver packs the files into the tar.
- Hashing: v4.5 hashed each recording while uploading it. v4.6 hashes each frame file while recording it, from bytes already in memory.
- Gallery file: v4.5 wrote `recording.json` without a file list. v4.6 lists each file's size, SHA-256 and upload state, and as a result could not read recordings made by v4.1 to v4.5.

### v4.5 (2026-10-07, cf2cd91)
- Rear calibration source: v4.4 took Apple's calibration from the 640x480 AVFoundation format. v4.5 takes it from the full 4:3 format.

### v4.4 (2026-10-07, 5b79c80)
- Rear calibration: v4.3 recorded only ARKit's intrinsic matrix, which has no distortion. v4.4 also stores Apple's AVFoundation calibration of the rear camera, taken each time the rear camera starts.

### v4.3 (2026-10-06, a1281fe)
- Color frame metadata: v4.2 recorded no exposure, lens or arrival data. v4.3 records each color frame's exposure time, the lens position, and when the app received the frame.

### v4.2 (2026-10-05, 8b75b48)
- Front frame rate: v4.1 recorded at 30 fps, which fell to 17-19 fps after 8 s because the storage could not keep up. v4.2 records at the highest rate the storage sustains: 15 fps for 4032x3024 color with 640x480 depth.

### v4.1 (2026-10-05, 8a6011e)
- Finishing: v4.0 packed the tar after Stop, and Record waited for it. v4.1 finishes a recording by renaming its folder, so Record is available as soon as Stop is pressed.
- Upload: v4.0 uploaded the packed tar file. v4.1 builds the tar from the recording's files while uploading and appends its SHA-256, which the receiver checks.
- Writing: v4.0 allocated and copied a new buffer for every color frame. v4.1 reuses page-aligned buffers and writes frame files past the page cache.

### v4.0 (2026-10-02 as v4, numbered 4.0 on 2026-10-05; 58ebb87, 01f0e2c, 92c7507)
- Cameras: v3 offered a choice of rear depth source and a depth filter setting. v4.0 records the front TrueDepth camera through AVFoundation and the rear LiDAR camera through ARKit only, always with depth filtering off and with autofocus wherever the lens can move.
- Color: v3 stored color as a compressed `color.mov`. v4.0 stores every delivered color frame uncompressed in `color.bin`, and drops a frame as `writer_busy` when the queued writes would exceed 512 MiB.
- Rear depth intrinsic matrix: v3 scaled ARKit's intrinsic matrix to the depth map by the size ratio. v4.0 carries it to the depth map separately per axis, as measured from where depth edges land on color edges in six rear scans.
- Rear poses: v3 recorded none. v4.0 records ARKit's tracking state and camera transform for every color frame.
- Front calibration: v3 stored the first depth frame's calibration in the metadata. v4.0 stores every depth frame's full Apple calibration in `calibration.jsonl`.
- Ablation options: v3 offered the rear AVFoundation source, the depth filter setting and three 8-bit H.264 depth tracks. v4.0 removes all three.
- Version numbering: v3 wrote an integer `format_version`. v4.0 writes "4.0", whose major number is the app version and whose minor number counts changes within it.

### v3 (2026-10-01, ablation build)
- Rear depth source: v2 recorded the rear through AVFoundation's LiDAR camera only, at 4032x3024 color and 320x240 depth, with nothing nearer than 0.7 m. v3 adds a switch to ARKit, at 1920x1440 color and 256x192 depth, reaching about 0.2 m.
- Rear confidence: v2 recorded none. v3 records ARKit's per-pixel confidence map in `confidence.bin`.
- Depth filter: v2 always recorded with depth filtering off. v3 offers an Off/On setting for every source: Apple's depth filter for TrueDepth and LiDAR, and `sceneDepth` or `smoothedSceneDepth` for ARKit.
- Old app's depth: v2 did not record it. v3 also saves the old app's 8-bit H.264 depth track in three ways with every front recording.
- Depth rows: v2 did not record the row stride. v3 records each depth map's bytes per row in `depth.csv`.
- Recording names: v2 named a recording by its date, time and camera. v3 also includes the depth source and the filter setting, as in `rear_lidar_filteroff`.

### v2 (2026-09-30)
- Pairing: v1 stored Apple's synchronizer pairs in one `frames.csv`, each color frame paired with the depth frame one step earlier. v2 records color and depth as independent streams in `color.csv` and `depth.csv`, each frame with its own capture timestamp.
- Orientation: v1 did not record how the phone was held, so frames came out sideways. v2 records each frame's upright rotation and gravity, and `color.mov` plays upright.
- Depth intrinsic matrix: v1 gave it at the 4032x3024 calibration reference size. v2 gives it in the depth map's own pixels.
- Formats: v1 was limited to formats that run at 30 fps. v2 uses the highest resolution for each stream at the fastest frame rate both streams support.
- Naming: v1 had no names. v2 asks for a name at Record, with Later or Start, and again at Stop if deferred, and defaults to the date and time.
- Screen: v1 showed color only. v2 switches between color and depth views and counts only the frames actually saved.
- Gallery: v1 deleted with a swipe and no confirmation. v2 shows each recording's name, date and time, duration, size and upload state, and asks for confirmation before deleting the phone's copy.
- Upload: v1 uploaded with a manual Upload button, and two uploads of one recording could collide. v2 uploads automatically after naming, one recording at a time, and shows Retry only after a failure.
- Robustness: v1 lost a recording on a crash or when the app left the screen, and crashed while packing recordings of 8 GB or more. v2 stops cleanly when the app leaves the screen, recovers recordings after a crash, and packs recordings of any size.

### v1 (2026-09-30, first build)
- Cameras: v1 records the front TrueDepth camera and the rear LiDAR camera, both through AVFoundation, with depth filtering off.
- Recording: v1 stores color as a compressed `color.mov` and depth as raw `depth.bin`, and pairs them with Apple's synchronizer into one `frames.csv` at a fixed 30 fps.
- Intrinsic matrices: v1 stores each color frame's intrinsic matrix, and each depth frame's at the 4032x3024 calibration reference size.
- Upload: v1 packs each recording into a tar and uploads it to the receiver with an Upload button, and deletes recordings with a swipe.

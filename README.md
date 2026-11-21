# iOS-3D-Scanner

## Setup

You need a computer (Mac, Linux, or Windows with WSL), an iPhone with a depth camera (TrueDepth on the front; LiDAR on the back of Pro models), a USB cable, and an Apple ID (a free one works).

### 1. Prepare the computer (once)
- Mac: install Xcode from the App Store and open it once, run `brew install xtool-org/tap/xtool`, then run `xtool setup`, choose Password and sign in with your Apple ID.
- Linux: install Swift from swift.org/install/linux, run `sudo apt-get install usbmuxd`, download Xcode.xip from developer.apple.com/download/all, put the xtool AppImage from the xtool GitHub releases on your PATH as `xtool`, then run `xtool setup`, choose Password, sign in, and give it the path to Xcode.xip.
- Windows: install WSL (Ubuntu) and usbipd, attach the iPhone to WSL with usbipd, and follow the Linux steps inside WSL.

### 2. Get the code
- `git clone https://github.com/danielmao2019/iOS-3D-Scanner && cd iOS-3D-Scanner`
- Write `server/users.json`, which git ignores, so no server address enters the repo or shows in the app: each receiver's server by name with its address, and the users the app offers at launch, each with its configs, a server by name and the data root on its machine that recordings are stored in: `{"servers": {"<name>": "http://<computer-ip>:8765"}, "users": [{"name": "<user>", "configs": [{"server": "<name>", "data_root": "/absolute/folder"}]}]}`.
- Linux and WSL: `export USBMUXD_SOCKET_ADDRESS=UNIX:/var/run/usbmuxd` in every new terminal before building.
- Mac: delete the line `. ~/.local/share/swiftly/env.sh` from `app/build.sh`, since Swift comes with Xcode there.

### 3. Install the app
- Plug in the iPhone, unlock it and tap Trust.
- `cd app && ./build.sh run` builds, signs and installs RGBD Scanner.
- On the iPhone, turn on Settings > Privacy & Security > Developer Mode and restart, then trust your Apple ID under Settings > General > VPN & Device Management.
- With a free Apple ID the app stops opening after 7 days; run `./build.sh run` again, and recordings already on the phone are kept.

### 4. Receive recordings
- On each computer `server/users.json` names, run `python3 server/receive.py` with a copy of `server/token`, the upload token the build wrote; it listens on port 8765 and stores each recording in the data root of the config it was recorded with, which must already exist on that computer.
- Put the phone and the computer on the same Wi-Fi and allow port 8765 through the firewall. Campus Wi-Fi often blocks traffic between devices.
- Without Wi-Fi, by cable: record with the Wired transfer config, with the phone plugged into a Windows computer that has the Apple Devices app, unlocked and trusting it, and RGBD Scanner open on screen, and in PowerShell on that computer run `irm https://raw.githubusercontent.com/danielmao2019/iOS-3D-Scanner/main/server/pull.ps1 | iex`, which installs nothing and runs until Ctrl+C; on a Mac, or on Linux with usbmuxd, run the same command in PowerShell 7 (`pwsh`). It takes each Wired transfer recording's frames over the cable while it records, in segments of about 64 MB, each deleted from the phone once the computer has checked its SHA-256, and the rest after Stop, then builds `<folder>/<scan_id>.tar`, the same file the receiver writes, deleting each segment once it is in the tar, so the computer needs free space for the recording plus about 64 MB, and once the tar is complete the phone deletes the recording; `<folder>` is the computer's Downloads folder, or the folder set with Folder beside the config on the phone, which must already exist on that computer. It keeps the phone's screen awake, and on Windows the computer from sleeping, while it works. Recordings made while it was not running, and a tar cut short, are taken and finished the next time it runs.
- Each recording arrives as `<data root>/<scan_id>.tar`, or `<folder>/<scan_id>.tar` by cable. `tools/rgbd_recording.py` reads it and documents its format, and `python3 tools/inspect_recording.py <tar>` checks it.

### 5. Record
- Open the app, choose a user's config, where the recordings go, and allow the camera and local network access; a user can add configs on the phone, on a server `server/users.json` names, and Configs on the scanner goes back.
- Choose Front or Rear, tap Record, name the recording or tap Later, then tap Stop.
- With a server config, a recording's frames upload while it records, in segments of about 64 MB, each deleted from the phone once the computer has stored it; the rest uploads after Stop, and once the computer answers that the recording is stored in its data root, the recording leaves the phone, and the config's list shows the recordings the computer holds in that data root. With This phone, every user's first config, it stays on the phone and uploads nowhere, and only these recordings have a delete button. With Wired transfer, every user's second config, it stays on the phone until a computer takes it over the cable (step 4), and leaves the phone once that computer has stored it. Uploads continue after the app leaves the screen, but stop if the app is closed from the app switcher.
- Recordings are compressed losslessly, both cameras at 15 fps: about 1.6 GB per minute for the front and 1.3 GB per minute for the rear, depending on the scene.
- The rear lens distortion and the front depth offset are not in the recordings; they are measured once per phone.

## App versions

Newest first. Each line is one change: what the previous version did, then what this version does. App versions are numbered 1.<minor>.<patch>; v1.4.6.1 and v1.5.0.0 to v1.5.0.3, which had three numbers before every version took the leading "1.", keep four. A recording's `format_version` is the version of the app that wrote it, without the "v": "1.6.0" for v1.6.0, while apps before it wrote their version without the leading "1.": the integers 1, 3 and 5 for v1.1.0 to v1.3.0, "4.0" to "4.8" for v1.4.0 to v1.4.8, "5.0.0" to "5.0.3" for v1.5.0.0 to v1.5.0.3, "5.1" for v1.5.1 and "5.2" for v1.5.2.

### v1.6.0 (2026-11-20)
- Wired transfer: v1.5.2 sent recordings to a computer only by uploading them over Wi-Fi to a receiver, and kept the others on the phone. v1.6.0 adds Wired transfer, every user's second config: a computer the phone is plugged into by USB cable takes its recordings with `server/pull.ps1`, a PowerShell command that needs only the Apple Devices app, while the app is on screen, each frames file's segments as soon as the recording closes them, deleting each from the phone once its SHA-256 is checked, and the rest after Stop, and stores each recording as the same `<scan_id>.tar` the receiver writes, in that computer's Downloads folder or in the folder the user set with Folder beside the config, building the tar from the segments and deleting each once it is in the tar, so that computer needs free space for the recording plus one segment, after which the phone deletes the recording; the phone keeps its screen awake while a computer takes recordings, and `server/pull.ps1` keeps the computer from sleeping while it works.
- Version numbers: v1.5.2 and earlier were numbered without the leading "1.", as 5.2, 4.8 or 1. v1.6.0 numbers every app version, earlier ones included, as 1.<minor>.<patch>, and writes `format_version` "1.6.0"; recordings made before keep the numbers they were written with.

### v1.5.2 (2026-10-17)
- Users: v1.5.1 kept recordings on the phone or uploaded them to one server, set in the app, into the folder its receiver was started with, and listed them with no author. v1.5.2 opens on a page of users, each with its configs: This phone, which keeps recordings on the phone and uploads nowhere, then servers with the data root on each one's machine that recordings are stored in, from `server/users.json`, plus those added on the phone; a recording goes where the config chosen when it was made says, every list showing all users' recordings of its config, as configs such as This phone are shared, each with its author, which scan_metadata.json now records, and Configs on the scanner goes back to the page. The app shows and saves servers by name only, their addresses coming from `server/users.json`, which git ignores, and nothing is chosen by default. The receiver stores each recording in the data root its requests name, refuses a request naming none, and answers `GET /stored/<scan_id>` and `GET /recordings` for that data root, the listing with each recording's author. A recording with no config, from before v1.5.0.3, or that v1.5.0.3 or v1.5.1 uploaded to a server alone, which no receiver from v1.5.2 takes, stays on the phone under This phone.

### v1.5.1 (2026-10-16, adbd090)
- Naming prompt: v1.5.0.3's prompt at Record offered Start and Later only, so the only way back without recording was closing the app, and Start with no name did what Later does, as did Save after Stop. v1.5.1 adds Cancel, which goes back without recording, and disables Start and Save while the name is blank.

### v1.5.0.3 (2026-10-16, cf84618)
- Upload: v1.5.0.2 uploaded a recording after Stop and kept every frame on the phone. v1.5.0.3 writes each frames file in segments of about 64 MB and uploads each segment as soon as it is full, while recording, deleting it from the phone once the receiver has checked its SHA-256 and stored it; after Stop the last segments, the JSON files and a manifest naming the recording follow, and the receiver joins each frames file's segments into the same tar as before. The frame members' entries no longer record a SHA-256 of the whole member, which the phone no longer holds; each frame's raw SHA-256 still checks every byte. The receiver must be this version's `server/receive.py`.
- After upload: v1.5.0.2 kept every recording on the phone. v1.5.0.3 deletes an uploaded recording from the phone once the receiver answers `GET /stored/<scan_id>` that its tar is stored, lists in its place the recordings the receiver holds, from `GET /recordings`, and offers Keep recordings on this phone, which keeps a recording on the phone and uploads nowhere; only such recordings have a delete button.

### v1.5.0.2 (2026-10-16, 05cb46a)
- Frame storage: v1.5.0.1 stored every frame uncompressed. v1.5.0.2 compresses every frame losslessly on the phone before writing it: each color frame's rows are delta-coded against the row above and deflated with zlib's run-length strategy, and each depth and confidence map is deflated, so a recording takes 2.2 to 3.5 times less space and upload time, depending on the scene (3.5 times on a front test recording at 4032x3024 and 3.1 times on a rear one on 2026-10-16, 2.2 times on a noisier front scene). Each frame's metadata records its compressed size and the SHA-256 of its raw bytes, and `inspect_recording.py` checks that every frame decodes back to exactly those bytes.

### v1.5.0.1 (2026-10-16, 6c49eb1)
- Front color: v1.5.0.0 recorded the front's color at 4032x3024, 18.3 MB a frame, so a front recording wrote about 293 MB/s. v1.5.0.1 records it at 1920x1440, the camera's 4:3 view at 1920 wide, 4.1 MB a frame, with the same 640x480 depth, the largest and most precise depth that size offers, so a front recording writes about 81 MB/s, 4.8 GB per minute. Apple carries each color frame's intrinsic matrix from the calibration's 4032x3024 about pixel centers, which a frame of that size did not show; v1.5.0.1 carries its principal point about the frame's corner, as the depth intrinsics and the distortion centers are carried, 0.26 px further right and down, so the color and depth intrinsics agree.

### v1.5.0.0 (2026-10-15, 9845ed4)
- Frame rate: v1.4.8 recorded the rear at ARKit's 60 fps and the front at the highest rate within a 300 MB/s storage write budget, 15 fps. v1.5.0.0 records both cameras at a fixed 15 fps, the rear as every fourth of ARKit's 60 fps frames, so a rear recording writes about 4 GB per minute instead of 16 GB.

### v1.4.8 (2026-10-08, 0fb92cb; fixed 2026-10-09 in 7404d9f)
- Package contents: v1.4.7 packed `metadata.json`, `color.csv`, `depth.csv`, `color.bin`, `depth.bin`, and `calibration.jsonl` (front) or `confidence.bin` (rear). v1.4.8 packs `scan_metadata.json`, `color_frames.bin`, `color_frames_metadata.json`, `depth_frames.bin`, `depth_frames_metadata.json`, `color_intrinsics.json`, `depth_intrinsics.json`, `extrinsics.json`, and `depth_frames_confidence.bin` (rear).
- Intrinsic parameters and extrinsics: v1.4.7 stored each color frame's intrinsic matrix in `color.csv` next to ARKit's pose, and Apple's intrinsic parameters in `calibration.jsonl` next to Apple's extrinsic matrix. v1.4.8 stores all intrinsic parameters in `color_intrinsics.json` and `depth_intrinsics.json`, and all extrinsics in `extrinsics.json`.
- Front calibration: v1.4.7 repeated Apple's full calibration on every depth frame. v1.4.8 stores each distinct distortion table and depth-to-color transform once, with the ranges of frames it applies to.
- Checksums: v1.4.7 sent each file's SHA-256 only in the upload manifest. v1.4.8 also stores the size and SHA-256 of each frame file in `color_frames_metadata.json` and `depth_frames_metadata.json`.
- Phone identity: v1.4.7 recorded the phone model. v1.4.8 also records the phone's ID, which names the phone's correction file.
- Removed fields: v1.4.7 recorded the lens position, the arrival time, orientation on depth rows, the row stride, byte counts, the filter flag, the focus mode, the depth source, the camera's format lists and prose descriptions of the format. v1.4.8 records none of them, and the format is documented in `tools/rgbd_recording.py`.

### v1.4.7 (2026-10-07, 9b4b230)
- Rear calibration: v1.4.6 stored Apple's AVFoundation calibration in every rear recording. v1.4.7 stores none, because measurements showed that calibration does not describe ARKit's frames.
- Gallery: v1.4.6 showed recordings made by v1.4.1 to v1.4.5 as unreadable. v1.4.7 lists them again, after hashing their files once at first launch.

### v1.4.6.1 (2026-10-07, measurement build from v1.4.6, never on the main line)
- Front format: v1.4.6 chose the largest depth map. v1.4.6.1 chose the smallest, which selected 1920x1080 color with 160x90 depth, to compare one corner at two depth resolutions.

### v1.4.6 (2026-10-07, 674b23f)
- Upload: v1.4.5 streamed one tar from the app, and the upload stopped when the app left the screen. v1.4.6 hands each file to iOS's background transfer service, which keeps sending after the app leaves the screen, and the receiver packs the files into the tar.
- Hashing: v1.4.5 hashed each recording while uploading it. v1.4.6 hashes each frame file while recording it, from bytes already in memory.
- Gallery file: v1.4.5 wrote `recording.json` without a file list. v1.4.6 lists each file's size, SHA-256 and upload state, and as a result could not read recordings made by v1.4.1 to v1.4.5.

### v1.4.5 (2026-10-07, cf2cd91)
- Rear calibration source: v1.4.4 took Apple's calibration from the 640x480 AVFoundation format. v1.4.5 takes it from the full 4:3 format.

### v1.4.4 (2026-10-07, 5b79c80)
- Rear calibration: v1.4.3 recorded only ARKit's intrinsic matrix, which has no distortion. v1.4.4 also stores Apple's AVFoundation calibration of the rear camera, taken each time the rear camera starts.

### v1.4.3 (2026-10-06, a1281fe)
- Color frame metadata: v1.4.2 recorded no exposure, lens or arrival data. v1.4.3 records each color frame's exposure time, the lens position, and when the app received the frame.

### v1.4.2 (2026-10-05, 8b75b48)
- Front frame rate: v1.4.1 recorded at 30 fps, which fell to 17-19 fps after 8 s because the storage could not keep up. v1.4.2 records at the highest rate the storage sustains: 15 fps for 4032x3024 color with 640x480 depth.

### v1.4.1 (2026-10-05, 8a6011e)
- Finishing: v1.4.0 packed the tar after Stop, and Record waited for it. v1.4.1 finishes a recording by renaming its folder, so Record is available as soon as Stop is pressed.
- Upload: v1.4.0 uploaded the packed tar file. v1.4.1 builds the tar from the recording's files while uploading and appends its SHA-256, which the receiver checks.
- Writing: v1.4.0 allocated and copied a new buffer for every color frame. v1.4.1 reuses page-aligned buffers and writes frame files past the page cache.

### v1.4.0 (2026-10-02 as v4, numbered 4.0 on 2026-10-05; 58ebb87, 01f0e2c, 92c7507)
- Cameras: v1.3.0 offered a choice of rear depth source and a depth filter setting. v1.4.0 records the front TrueDepth camera through AVFoundation and the rear LiDAR camera through ARKit only, always with depth filtering off and with autofocus wherever the lens can move.
- Color: v1.3.0 stored color as a compressed `color.mov`. v1.4.0 stores every delivered color frame uncompressed in `color.bin`, and drops a frame as `writer_busy` when the queued writes would exceed 512 MiB.
- Rear depth intrinsic matrix: v1.3.0 scaled ARKit's intrinsic matrix to the depth map by the size ratio. v1.4.0 carries it to the depth map separately per axis, as measured from where depth edges land on color edges in six rear scans.
- Rear poses: v1.3.0 recorded none. v1.4.0 records ARKit's tracking state and camera transform for every color frame.
- Front calibration: v1.3.0 stored the first depth frame's calibration in the metadata. v1.4.0 stores every depth frame's full Apple calibration in `calibration.jsonl`.
- Ablation options: v1.3.0 offered the rear AVFoundation source, the depth filter setting and three 8-bit H.264 depth tracks. v1.4.0 removes all three.
- Version numbering: v1.3.0 wrote an integer `format_version`. v1.4.0 writes "4.0", whose major number is the app version and whose minor number counts changes within it.

### v1.3.0 (2026-10-01, ablation build)
- Rear depth source: v1.2.0 recorded the rear through AVFoundation's LiDAR camera only, at 4032x3024 color and 320x240 depth, with nothing nearer than 0.7 m. v1.3.0 adds a switch to ARKit, at 1920x1440 color and 256x192 depth, reaching about 0.2 m.
- Rear confidence: v1.2.0 recorded none. v1.3.0 records ARKit's per-pixel confidence map in `confidence.bin`.
- Depth filter: v1.2.0 always recorded with depth filtering off. v1.3.0 offers an Off/On setting for every source: Apple's depth filter for TrueDepth and LiDAR, and `sceneDepth` or `smoothedSceneDepth` for ARKit.
- Old app's depth: v1.2.0 did not record it. v1.3.0 also saves the old app's 8-bit H.264 depth track in three ways with every front recording.
- Depth rows: v1.2.0 did not record the row stride. v1.3.0 records each depth map's bytes per row in `depth.csv`.
- Recording names: v1.2.0 named a recording by its date, time and camera. v1.3.0 also includes the depth source and the filter setting, as in `rear_lidar_filteroff`.

### v1.2.0 (2026-09-30)
- Pairing: v1.1.0 stored Apple's synchronizer pairs in one `frames.csv`, each color frame paired with the depth frame one step earlier. v1.2.0 records color and depth as independent streams in `color.csv` and `depth.csv`, each frame with its own capture timestamp.
- Orientation: v1.1.0 did not record how the phone was held, so frames came out sideways. v1.2.0 records each frame's upright rotation and gravity, and `color.mov` plays upright.
- Depth intrinsic matrix: v1.1.0 gave it at the 4032x3024 calibration reference size. v1.2.0 gives it in the depth map's own pixels.
- Formats: v1.1.0 was limited to formats that run at 30 fps. v1.2.0 uses the highest resolution for each stream at the fastest frame rate both streams support.
- Naming: v1.1.0 had no names. v1.2.0 asks for a name at Record, with Later or Start, and again at Stop if deferred, and defaults to the date and time.
- Screen: v1.1.0 showed color only. v1.2.0 switches between color and depth views and counts only the frames actually saved.
- Gallery: v1.1.0 deleted with a swipe and no confirmation. v1.2.0 shows each recording's name, date and time, duration, size and upload state, and asks for confirmation before deleting the phone's copy.
- Upload: v1.1.0 uploaded with a manual Upload button, and two uploads of one recording could collide. v1.2.0 uploads automatically after naming, one recording at a time, and shows Retry only after a failure.
- Robustness: v1.1.0 lost a recording on a crash or when the app left the screen, and crashed while packing recordings of 8 GB or more. v1.2.0 stops cleanly when the app leaves the screen, recovers recordings after a crash, and packs recordings of any size.

### v1.1.0 (2026-09-30, first build)
- Cameras: v1.1.0 records the front TrueDepth camera and the rear LiDAR camera, both through AVFoundation, with depth filtering off.
- Recording: v1.1.0 stores color as a compressed `color.mov` and depth as raw `depth.bin`, and pairs them with Apple's synchronizer into one `frames.csv` at a fixed 30 fps.
- Intrinsic matrices: v1.1.0 stores each color frame's intrinsic matrix, and each depth frame's at the 4032x3024 calibration reference size.
- Upload: v1.1.0 packs each recording into a tar and uploads it to the receiver with an Upload button, and deletes recordings with a swipe.

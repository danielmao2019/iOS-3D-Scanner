"""Renders every color frame of an RGBD Scanner recording (.tar) upright, side by side with the depth map captured at the same instant, as an H.264 video; a depth map whose color frame was dropped or lost is shown next to a "color lost" panel.

Usage: python tools/render_video.py <recording.tar> <out.mp4> --ffmpeg <ffmpeg with libx264>
"""

import argparse
import subprocess
import tempfile
from pathlib import Path

import cv2
import numpy as np

from rgbd_recording import Recording, upright, valid

BOX = 640


def fit(image: np.ndarray, interpolation: int) -> np.ndarray:
    """Letterboxes an image into a BOX x BOX panel, so the video keeps one size whichever way the phone was held."""
    scale = BOX / max(image.shape[:2])
    resized = cv2.resize(image, (round(image.shape[1] * scale), round(image.shape[0] * scale)), interpolation=interpolation)
    panel = np.zeros((BOX, BOX, 3), np.uint8)
    y, x = (BOX - resized.shape[0]) // 2, (BOX - resized.shape[1]) // 2
    panel[y:y + resized.shape[0], x:x + resized.shape[1]] = resized
    return panel


def legend(width: int, lo: float, hi: float) -> np.ndarray:
    bar = np.full((56, width, 3), 255, np.uint8)
    bar[6:24, 20:width - 20] = cv2.applyColorMap(np.tile(np.linspace(0, 255, width - 40).astype(np.uint8), (18, 1)), cv2.COLORMAP_TURBO)
    for t in np.linspace(lo, hi, 6):
        x = int(20 + (t - lo) / (hi - lo) * (width - 41))
        cv2.line(bar, (x, 24), (x, 30), (0, 0, 0), 1)
        cv2.putText(bar, f"{t:.2f} m", (max(0, x - 24), 46), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 1, cv2.LINE_AA)
    return bar


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tar", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--ffmpeg", required=True)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        rec = Recording(args.tar, Path(tmp))
        lo, hi = np.percentile(rec.depth[valid(rec.depth)][::97], [2, 98])
        depth_at = {c["timestamp"]: d for c, d in rec.pairs()}
        frames = rec.color_frames()
        writer = None
        rendered = 0
        for row in rec.color_rows:
            d = depth_at.get(row["timestamp"])
            if row["index"] == "-1":
                if d is None:
                    continue
                color = np.zeros((BOX, BOX, 3), np.uint8)
                cv2.putText(color, "color lost", (BOX // 2 - 80, BOX // 2), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2, cv2.LINE_AA)
            else:
                color = fit(upright(next(frames), row["upright_rotation_deg"]), cv2.INTER_AREA)
            if d is None:
                vis = np.zeros_like(color)
                text = f"color {row['index']} t={float(row['timestamp']):.3f}s  no depth at this instant"
            else:
                z = rec.depth[int(d["index"])]
                ok = valid(z)
                vis = cv2.applyColorMap((np.clip((np.nan_to_num(z) - lo) / (hi - lo), 0, 1) * 255).astype(np.uint8), cv2.COLORMAP_TURBO)
                vis[~ok] = 0
                vis = fit(upright(vis, d["upright_rotation_deg"]), cv2.INTER_NEAREST)
                color_label = f"color lost ({row['dropped']})" if row["index"] == "-1" else f"color {row['index']}"
                text = f"{color_label} / depth {d['index']}  t={float(row['timestamp']):.3f}s  valid {ok.mean() * 100:.1f}%"
            width = color.shape[1] + vis.shape[1]
            label = np.full((28, width, 3), 255, np.uint8)
            cv2.putText(label, text, (6, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1, cv2.LINE_AA)
            image = np.vstack([label, np.hstack([color, vis]), legend(width, lo, hi)])
            if writer is None:
                writer = subprocess.Popen(
                    [args.ffmpeg, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{image.shape[1]}x{image.shape[0]}", "-r", "30", "-i", "-",
                     "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-movflags", "+faststart", str(args.out)],
                    stdin=subprocess.PIPE,
                )
            writer.stdin.write(image.tobytes())
            rendered += 1
        assert next(frames, None) is None, "color.mov holds more frames than color.csv delivers"
        writer.stdin.close()
        assert writer.wait() == 0
        print(f"wrote {args.out}: {rendered} frames, {rendered - len(rec.colors)} of them with color lost")


if __name__ == "__main__":
    main()

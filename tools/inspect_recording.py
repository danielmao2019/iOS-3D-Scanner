"""Checks an RGBD Scanner recording (.tar) and prints its statistics.

Usage: python tools/inspect_recording.py <recording.tar>
"""

import argparse
import tempfile
from pathlib import Path
from typing import Dict, List

import cv2
import numpy as np

from rgbd_recording import INTRINSICS, Recording, valid


def alignment_offset(rec: Recording, grads: List[np.ndarray]) -> Dict[int, float]:
    """For each timestamp pair, how strongly the depth map's edges sit on color edges of the color frame `offset` frames away; the true pairing scores highest at offset 0."""
    h, w = rec.depth.shape[1:]
    scores: Dict[int, List[float]] = {o: [] for o in range(-3, 4)}
    for c, d in rec.pairs():
        ci = int(c["index"])
        if ci < 3 or ci + 3 >= len(grads) or np.abs(grads[ci + 1] - grads[ci - 1]).mean() < 0.15:
            continue
        z = np.nan_to_num(rec.depth[int(d["index"])])
        log_z = np.log(np.clip(z, 0.1, 10))
        edges = cv2.Canny((np.clip((log_z - log_z.min()) / (np.ptp(log_z) + 1e-6), 0, 1) * 255).astype(np.uint8), 40, 120) > 0
        edges = cv2.dilate((edges & (z > 0)).astype(np.uint8), None) > 0
        if edges.sum() < 200:
            continue
        for o in scores:
            scores[o].append(float(grads[ci + o][edges].mean()))
    return {o: float(np.mean(v)) if v else float("nan") for o, v in scores.items()}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tar", type=Path)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        rec = Recording(args.tar, Path(tmp))
        meta = rec.meta
        h, w = rec.depth.shape[1:]
        grads = []
        for frame in rec.color_frames():
            g = cv2.cvtColor(cv2.resize(frame, (w, h), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY).astype(np.float32)
            grad = cv2.magnitude(cv2.Sobel(g, cv2.CV_32F, 1, 0), cv2.Sobel(g, cv2.CV_32F, 0, 1))
            grads.append(grad / grad.mean())

        color_ts = np.array([float(r["timestamp"]) for r in rec.colors])
        depth_ts = np.array([float(r["timestamp"]) for r in rec.depths])
        pairs = rec.pairs()
        gravity = np.array([[float(r[k]) for k in ("gravity_x", "gravity_y", "gravity_z")] for r in rec.colors if r["gravity_x"]])
        offsets = alignment_offset(rec, grads)
        best_offset = max(offsets, key=lambda o: offsets[o])
        coverage = valid(rec.depth).mean(axis=(1, 2)) * 100

        print(f"device {meta['device_model']} iOS {meta['system_version']} camera {meta['camera']}")
        print(f"color {meta['color_width']}x{meta['color_height']}, depth {w}x{h} {meta['depth_pixel_format']}, filtering_enabled={meta['depth_filtering_enabled']}")
        print(f"configured {meta['frame_rate']:.2f} fps; color {len(rec.colors)} frames at {(len(color_ts) - 1) / (color_ts[-1] - color_ts[0]):.2f} fps; depth {len(rec.depths)} frames at {(len(depth_ts) - 1) / (depth_ts[-1] - depth_ts[0]):.2f} fps; {len(pairs)} pairs by timestamp")
        print(f"dropped: color {len(rec.color_rows) - len(rec.colors)}, depth {len(rec.depth_rows) - len(rec.depths)}")
        print(f"upright rotations used: {sorted({r['upright_rotation_deg'] for r in rec.colors})}; |gravity| mean {np.linalg.norm(gravity, axis=1).mean():.3f} g")
        print("depth valid % per frame: min {:.1f} p5 {:.1f} p25 {:.1f} median {:.1f} p75 {:.1f} p95 {:.1f} max {:.1f}".format(coverage.min(), *np.percentile(coverage, [5, 25, 50, 75, 95]), coverage.max()))
        print("edge alignment of depth to color frame at offset: " + " ".join(f"{o:+d}:{s:.3f}" for o, s in offsets.items()))

        checks = {
            "color frames in video == color.csv indices": len(grads) == len(rec.colors) == meta["color_frames"],
            "depth maps in depth.bin == depth.csv indices": rec.depth.shape[0] == len(rec.depths) == meta["depth_frames"],
            "indices are 0..n-1": [int(r["index"]) for r in rec.colors] == list(range(len(rec.colors))) and [int(r["index"]) for r in rec.depths] == list(range(len(rec.depths))),
            "timestamps strictly increasing": bool(np.all(np.diff(color_ts) > 0) and np.all(np.diff(depth_ts) > 0)),
            "every depth frame has a color frame at the same instant": len(pairs) == len(rec.depths),
            "depth aligns best with its same-instant color frame": best_offset == 0,
            "no depth map filtered": all(r["filtered"] == "0" for r in rec.depths),
            "every frame has orientation and gravity": len(gravity) == len(rec.colors) and all(r["gravity_x"] for r in rec.depths),
            "every color and depth frame has intrinsics": all(r[k] for r in rec.colors + rec.depths for k in INTRINSICS),
            "metadata has a name and a duration": all(k in meta for k in ("name", "named_by_user", "duration_s")) and bool(meta["name"]) and meta["duration_s"] > 0,
        }
        for name, ok in checks.items():
            print(f"[{'PASS' if ok else 'FAIL'}] {name}")


if __name__ == "__main__":
    main()

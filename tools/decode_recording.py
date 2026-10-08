"""Decodes RGBD Scanner recordings (format_version "4.8" directories and "4.0" to "4.7" .tars) into per-frame files in a directory next to each recording: a tar's named like the tar without .tar, a directory's named like it with _decoded added.

Each output directory holds color/<index:06d>.png (every color frame converted from full-range YCbCr 4:2:0 to BGR through the recording's ycbcr_matrix, 8-bit lossless PNG, sensor orientation), depth/<index:06d>.npy (metres, sensor orientation, the map as stored, Float32 or a 4.8 "hdep" recording's Float16, NaN and 0 kept), confidence/<index:06d>.npy (uint8 ARConfidenceLevel, rear recordings), the recording's every other file copied verbatim (a directory's six JSON files; a tar's tables, metadata.json and, for a front recording, calibration.jsonl), and decoded.json, a machine summary. A directory is decoded under <name>.partial and renamed when complete, so an existing output directory is complete and is skipped unless --force.

Usage: python tools/decode_recording.py <recording directory, recording.tar, or directory of recordings...> [--force]
"""

import argparse
import json
import shutil
import tarfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List

import cv2
import numpy as np

from rgbd_recording import Recording

PNG_WRITERS = 16


def write_color(rec: Recording, out: Path) -> int:
    """Writes every color frame, converted to BGR, as out/color/<index:06d>.png and returns how many."""
    folder = out / "color"
    folder.mkdir()
    count = rec.color.shape[0]
    start = time.time()

    def write(index: int) -> None:
        assert cv2.imwrite(str(folder / f"{index:06d}.png"), rec.color_bgr(index)), index

    # Each writer converts the frame it writes, so at most PNG_WRITERS frames are in memory at once.
    with ThreadPoolExecutor(PNG_WRITERS) as pool:
        for done, _ in enumerate(pool.map(write, range(count)), 1):
            if done % 50 == 0:
                print(f"  color {done}/{count} ({time.time() - start:.0f} s)", flush=True)
    return count


def write_maps(maps: np.ndarray, folder: Path) -> None:
    folder.mkdir(parents=True)
    for i, m in enumerate(maps):
        np.save(folder / f"{i:06d}.npy", m)


def size(folder: Path) -> int:
    return sum(p.stat().st_size for p in folder.rglob("*") if p.is_file())


def decode(path: Path, out: Path) -> Dict:
    """Decodes one recording into out and returns its decoded.json summary."""
    rec = Recording(path)
    # Format 4.8 is a directory; 4.0 to 4.7 a tar.
    directory = rec.format_minor >= 8
    color_bin, depth_bin, confidence_bin = ("color_frames.bin", "depth_frames.bin", "depth_frames_confidence.bin") if directory else ("color.bin", "depth.bin", "confidence.bin")
    print(f"  {rec.camera}, {len(rec.colors)} color rows with an index, {len(rec.depths)} depth rows with an index", flush=True)
    out.mkdir()

    # The .bin files are decoded below; every other file is text, copied as it is.
    copied = []
    if directory:
        for p in sorted(rec.path.iterdir()):
            if p.suffix != ".bin":
                shutil.copyfile(p, out / p.name)
                copied.append(p.name)
    else:
        with tarfile.open(rec.path, "r:") as tar:
            for m in tar.getmembers():
                name = Path(m.name).name
                if not name.endswith(".bin"):
                    (out / name).write_bytes(tar.extractfile(m).read())
                    copied.append(name)

    assert rec.color.shape[0] == len(rec.colors), f"{color_bin} holds {rec.color.shape[0]} frames, the color rows {len(rec.colors)} with an index"
    n_color = write_color(rec, out)

    assert rec.depth.shape[0] == len(rec.depths), f"{depth_bin} holds {rec.depth.shape[0]} maps, the depth rows {len(rec.depths)} with an index"
    write_maps(rec.depth, out / "depth")
    depth_shape = {"width": rec.depth_width, "height": rec.depth_height}
    summary = {
        "source": rec.path.name,
        "format_version": rec.format_version,
        "camera": rec.camera,
        "copied": sorted(copied),
        "color": {"count": n_color, "width": rec.color_width, "height": rec.color_height, "files": "color/<index:06d>.png", "format": "PNG, 8-bit RGB, lossless (cv2.imread returns it BGR)",
                  "holds": f"every {color_bin} frame in order, index = the color row's index, sensor orientation, converted from full-range YCbCr 4:2:0 through {rec.ycbcr_matrix}"},
        "depth": {"count": rec.depth.shape[0], **depth_shape, "files": "depth/<index:06d>.npy", "format": f"npy {rec.depth.dtype.name}, metres",
                  "holds": f"every {depth_bin} map in order, index = the depth row's index, sensor orientation, the stored values (NaN and 0 = no reading)"},
    }

    if rec.confidence is not None:
        assert rec.confidence.shape == rec.depth.shape, (rec.confidence.shape, rec.depth.shape)
        write_maps(rec.confidence, out / "confidence")
        summary["confidence"] = {"count": rec.confidence.shape[0], **depth_shape, "files": "confidence/<index:06d>.npy", "format": "npy uint8",
                                 "holds": f"every {confidence_bin} map, one per depth map with the same index, ARConfidenceLevel per pixel (0 low, 1 medium, 2 high)"}

    summary["bytes"] = size(out)
    (out / "decoded.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", type=Path, nargs="+")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    # A format 4.8 recording is a directory holding color_frames.bin, which no decoded directory does.
    recordings: List[Path] = []
    for p in args.inputs:
        assert p.exists(), p
        if p.is_file() or (p / "color_frames.bin").is_file():
            recordings.append(p)
        else:
            recordings += sorted(p.rglob("*.tar")) + sorted(f.parent for f in p.rglob("color_frames.bin"))
    assert recordings and all(r.suffix == ".tar" or (r / "color_frames.bin").is_file() for r in recordings), recordings

    for path in recordings:
        out = path.with_suffix("") if path.suffix == ".tar" else path.with_name(f"{path.name}_decoded")
        print(f"{path}", flush=True)
        if out.exists() and not args.force:
            assert (out / "decoded.json").is_file(), f"{out} exists without decoded.json"
            print(f"  skipped: {out} is complete", flush=True)
            continue
        partial = out.with_name(out.name + ".partial")
        # A .partial directory is left by an interrupted run.
        if partial.exists():
            shutil.rmtree(partial)
        start = time.time()
        summary = decode(path, partial)
        if out.exists():
            shutil.rmtree(out)
        partial.rename(out)
        print(f"  wrote {out}: {summary['color']['count']} color, {summary['depth']['count']} depth, {summary['bytes'] / 1e9:.1f} GB in {time.time() - start:.0f} s", flush=True)


if __name__ == "__main__":
    main()

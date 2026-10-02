"""Decodes RGBD Scanner recordings (.tar, format_version 7) into per-frame files in a directory next to each tar, named like the tar without .tar.

Each output directory holds color/<index:06d>.png (every color.bin frame converted from full-range YCbCr 4:2:0 to BGR through metadata.json's color_ycbcr_matrix, 8-bit lossless PNG, sensor orientation), depth/<index:06d>.npy (Float32 metres, sensor orientation, depth.bin's map as stored, NaN and 0 kept), confidence/<index:06d>.npy (uint8 ARConfidenceLevel, rear recordings), the recording's tables, metadata.json and, for a front recording, calibration.jsonl copied verbatim, and decoded.json, a machine summary. A directory is decoded under <name>.partial and renamed when complete, so an existing output directory is complete and is skipped unless --force.

Usage: python tools/decode_recording.py <recording.tar or directory of recordings...> [--force]
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


def decode(tar_path: Path, out: Path) -> Dict:
    """Decodes one recording into out and returns its decoded.json summary."""
    rec = Recording(tar_path)
    meta = rec.meta
    print(f"  {meta['camera']}, {len(rec.colors)} color rows with an index, {len(rec.depths)} depth rows with an index", flush=True)
    out.mkdir()

    copied = []
    with tarfile.open(tar_path, "r:") as tar:
        for m in tar.getmembers():
            name = Path(m.name).name
            # The .bin members are decoded below; every other member is text, copied as it is.
            if not name.endswith(".bin"):
                (out / name).write_bytes(tar.extractfile(m).read())
                copied.append(name)

    assert rec.color.shape[0] == len(rec.colors), f"color.bin holds {rec.color.shape[0]} frames, the color table {len(rec.colors)} rows with an index"
    n_color = write_color(rec, out)

    assert rec.depth.shape[0] == len(rec.depths), f"depth.bin holds {rec.depth.shape[0]} maps, the depth table {len(rec.depths)} rows with an index"
    write_maps(rec.depth, out / "depth")
    depth_shape = {"width": meta["depth_width"], "height": meta["depth_height"]}
    summary = {
        "source": tar_path.name,
        "format_version": meta["format_version"],
        "camera": meta["camera"],
        "copied": sorted(copied),
        "color": {"count": n_color, "width": meta["color_width"], "height": meta["color_height"], "files": "color/<index:06d>.png", "format": "PNG, 8-bit RGB, lossless (cv2.imread returns it BGR)",
                  "holds": f"every color.bin frame in order, index = the color table's index, sensor orientation, converted from full-range YCbCr 4:2:0 through {meta['color_ycbcr_matrix']}"},
        "depth": {"count": rec.depth.shape[0], **depth_shape, "files": "depth/<index:06d>.npy", "format": "npy float32, metres",
                  "holds": "every depth.bin map in order, index = the depth table's index, sensor orientation, the stored values (NaN and 0 = no reading)"},
    }

    if rec.confidence is not None:
        assert rec.confidence.shape == rec.depth.shape, (rec.confidence.shape, rec.depth.shape)
        write_maps(rec.confidence, out / "confidence")
        summary["confidence"] = {"count": rec.confidence.shape[0], **depth_shape, "files": "confidence/<index:06d>.npy", "format": "npy uint8",
                                 "holds": "every confidence.bin map, one per depth map with the same index, ARConfidenceLevel per pixel (0 low, 1 medium, 2 high)"}

    summary["bytes"] = size(out)
    (out / "decoded.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", type=Path, nargs="+")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    tars: List[Path] = []
    for p in args.inputs:
        assert p.exists(), p
        tars += sorted(p.rglob("*.tar")) if p.is_dir() else [p]
    assert tars and all(t.suffix == ".tar" for t in tars), tars

    for tar_path in tars:
        out = tar_path.with_suffix("")
        print(f"{tar_path}", flush=True)
        if out.exists() and not args.force:
            assert (out / "decoded.json").is_file(), f"{out} exists without decoded.json"
            print(f"  skipped: {out} is complete", flush=True)
            continue
        partial = out.with_name(out.name + ".partial")
        # A .partial directory is left by an interrupted run.
        if partial.exists():
            shutil.rmtree(partial)
        start = time.time()
        summary = decode(tar_path, partial)
        if out.exists():
            shutil.rmtree(out)
        partial.rename(out)
        print(f"  wrote {out}: {summary['color']['count']} color, {summary['depth']['count']} depth, {summary['bytes'] / 1e9:.1f} GB in {time.time() - start:.0f} s", flush=True)


if __name__ == "__main__":
    main()

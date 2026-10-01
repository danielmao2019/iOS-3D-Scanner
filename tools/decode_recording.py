"""Decodes RGBD Scanner recordings (.tar, any format_version) into per-frame files in a directory next to each tar, named like the tar without .tar.

Each output directory holds color/<index:06d>.png (every color.mov frame, BGR 8-bit lossless PNG, sensor orientation, decoded with orientation auto-rotation off), depth/<index:06d>.npy (Float32 metres, sensor orientation, depth.bin's map as stored, NaN and 0 kept), confidence/<index:06d>.npy (uint8 ARConfidenceLevel) when the recording has confidence.bin, depth8/<track>/<index:06d>.npy (uint8 codes in the track's stored layout) for each 8-bit H.264 depth track, the recording's tables and metadata.json copied verbatim, and decoded.json, a machine summary. A directory is decoded under <name>.partial and renamed when complete, so an existing output directory is complete and is skipped unless --force.

Usage: python tools/decode_recording.py <recording.tar or directory of recordings...> [--force]
"""

import argparse
import json
import shutil
import tarfile
import tempfile
import time
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List, Union

import cv2
import numpy as np
from rgbd_recording import FramesRecording, Recording, read

PNG_WRITERS = 16
# ponytail: bounds the frames held in memory while PNGs are written (a 4032x3024 frame is 36 MB).
PNG_IN_FLIGHT = 48


def write_color(rec: Union[Recording, FramesRecording], out: Path) -> int:
    """Writes every color frame as out/color/<index:06d>.png and returns how many."""
    folder = out / "color"
    folder.mkdir()
    shape = (rec.meta["color_height"], rec.meta["color_width"], 3)
    pending: List[Future] = []
    start = time.time()
    count = 0
    with ThreadPoolExecutor(PNG_WRITERS) as pool:
        for frame in rec.color_frames():
            # Landscape sensor shape: a decoder that applied the track's display rotation would yield it portrait.
            assert frame.shape == shape and frame.dtype == np.uint8, (frame.shape, frame.dtype, shape)
            pending.append(pool.submit(cv2.imwrite, str(folder / f"{count:06d}.png"), frame))
            count += 1
            if len(pending) >= PNG_IN_FLIGHT:
                assert pending.pop(0).result()
            if count % 50 == 0:
                print(f"  color {count}/{len(rec.colors)} ({time.time() - start:.0f} s)", flush=True)
        for f in pending:
            assert f.result()
    return count


def write_maps(maps: np.ndarray, folder: Path) -> None:
    folder.mkdir(parents=True)
    for i, m in enumerate(maps):
        np.save(folder / f"{i:06d}.npy", m)


def size(folder: Path) -> int:
    return sum(p.stat().st_size for p in folder.rglob("*") if p.is_file())


def decode(tar_path: Path, out: Path, work_dir: Path) -> Dict:
    """Decodes one recording into out and returns its decoded.json summary."""
    rec = read(tar_path, work_dir)
    meta = rec.meta
    print(f"  format {meta['format_version']}, {len(rec.colors)} color rows with an index, {len(rec.depths)} depth rows with an index", flush=True)
    out.mkdir()

    copied = []
    with tarfile.open(tar_path) as tar:
        for m in tar.getmembers():
            name = Path(m.name).name
            if name.endswith(".csv") or name == "metadata.json":
                (out / name).write_bytes(tar.extractfile(m).read())
                copied.append(name)

    n_color = write_color(rec, out)
    assert n_color == len(rec.colors), f"color.mov holds {n_color} frames, the color table {len(rec.colors)} rows with an index"

    assert meta["depth_pixel_format"] == "fdep" and rec.depth.dtype == np.float32, (meta["depth_pixel_format"], rec.depth.dtype)
    assert rec.depth.shape[0] == len(rec.depths), f"depth.bin holds {rec.depth.shape[0]} maps, the depth table {len(rec.depths)} rows with an index"
    write_maps(rec.depth, out / "depth")
    depth_shape = {"width": meta["depth_width"], "height": meta["depth_height"]}
    summary = {
        "source": tar_path.name,
        "format_version": meta["format_version"],
        "camera": meta["camera"],
        "tables": sorted(copied),
        "color": {"count": n_color, "width": meta["color_width"], "height": meta["color_height"], "files": "color/<index:06d>.png", "format": "PNG, 8-bit RGB, lossless (cv2.imread returns it BGR)",
                  "holds": "every color.mov frame in order, index = the color table's index, sensor orientation (decoded with orientation auto-rotation off)"},
        "depth": {"count": rec.depth.shape[0], **depth_shape, "files": "depth/<index:06d>.npy", "format": "npy float32, metres",
                  "holds": "every depth.bin map in order, index = the depth table's index, sensor orientation, the stored values (NaN and 0 = no reading)"},
    }

    if rec.confidence is not None:
        assert rec.confidence.shape == rec.depth.shape, (rec.confidence.shape, rec.depth.shape)
        write_maps(rec.confidence, out / "confidence")
        summary["confidence"] = {"count": rec.confidence.shape[0], **depth_shape, "files": "confidence/<index:06d>.npy", "format": "npy uint8",
                                 "holds": "every confidence.bin map, one per depth map with the same index, ARConfidenceLevel per pixel (0 low, 1 medium, 2 high)"}

    if rec.depth8_movs:
        summary["depth8"] = {}
        for file in sorted(rec.depth8_movs):
            codes, _ = rec.depth8_track(file)
            assert codes.shape[0] == len(rec.depths), f"{file} holds {codes.shape[0]} frames, the depth table {len(rec.depths)} rows with an index"
            track = Path(file).stem
            write_maps(codes, out / "depth8" / track)
            summary["depth8"][track] = {"count": codes.shape[0], "width": codes.shape[2], "height": codes.shape[1], "files": f"depth8/{track}/<index:06d>.npy", "format": "npy uint8 codes",
                                        "holds": f"every frame of {file} decoded, one per depth map with the same index, in the track's stored layout (metadata.json's depth8_h264); code / 255 * range_m metres, 0 = no reading"}

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
        with tempfile.TemporaryDirectory() as tmp:
            summary = decode(tar_path, partial, Path(tmp))
        if out.exists():
            shutil.rmtree(out)
        partial.rename(out)
        print(f"  wrote {out}: {summary['color']['count']} color, {summary['depth']['count']} depth, {summary['bytes'] / 1e9:.1f} GB in {time.time() - start:.0f} s", flush=True)


if __name__ == "__main__":
    main()

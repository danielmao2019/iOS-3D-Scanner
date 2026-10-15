"""Measures one phone's corrections, what its recordings do not describe and align_recording.py needs, from ordinary handheld scans that phone made, and writes them as <out>/<phone_id>.json:
- front.lens_distortion and rear.lens_distortion: the radial distortion k1, k2 (`camera_models.radial_distort`, following focus where that straightens unseen scans better) the camera's color frames still carry once their recorded distortion is removed (front: Apple's table; rear: none, ARKit reporting none), from straight edges in scans of any scene with long straight edges (lens_distortion_fit.py), 0 when no fit straightens unseen scans better than none;
- front.depth_rotation: the rotation that moves the front depth maps onto the front color frames, from scans of outward corners (front_depth_rotation_fit.py), measured on frames aligned with front.lens_distortion. rotation_vector_rad is what align_recording.py applies; offset_full_sensor_px is the measured color edge minus depth crease in sensor pixels of the 4032-wide full sensor, with the fit it comes from.

Each entry lists the scans it was measured on and its 95% intervals. A format 4.8 scan must carry the phone_id given; earlier formats record none, and the caller vouches that the phone made them.

Usage: python tools/phone_corrections.py --phone-id <id> --phone-model <model> --rear <tars...> --front-lens <tars...> --front-corners <tars...> --out <folder>
"""

import argparse
import json
from pathlib import Path
from typing import Dict, List

import front_depth_rotation_fit
import lens_distortion_fit
from rgbd_recording import Recording


def lens_entry(paths: List[Path]) -> Dict[str, object]:
    """A camera's lens_distortion from plumb lines in its scans' frames with only their recorded distortion removed: the applied model's k1, k2 (and focus entry) first, then the model chosen, the held-out straightness that chose it, every fitted model with its intervals and the scans."""
    measured = lens_distortion_fit.measure(paths, None)
    return measured["applied"] | {"model": measured["model"], "held_out_mean_rms_px": measured["held_out_mean_rms"], "fits": measured["fits"], "displacement_px_at_half_diagonal_fraction": measured["displacement_px_at_half_diagonal_fraction"], "fit_image_width": measured["fit_image_width"],
                                  "measured_on": [{"scan_id": t["scan_id"], "edges": t["edges"], "k1": t["k1"], "k2": t["k2"]} for t in measured["takes"]], "held_out": measured["held_out"]}


def rotation_entry(paths: List[Path], lens: Dict[str, float]) -> Dict[str, object]:
    """front.depth_rotation from the creases of outward-corner scans aligned with the front lens distortion and no rotation."""
    correction = {"lens_distortion": {"k1": lens["k1"], "k2": lens["k2"]}, "depth_rotation": {"rotation_vector_rad": [0.0, 0.0, 0.0]}}
    creases = []
    for path in paths:
        creases += front_depth_rotation_fit.recording_creases(path, correction, 1)
    fitted = front_depth_rotation_fit.fit_offset(creases, True)
    assert all(fitted["separable"].values()), f"the corner scans do not separate the offset from the corners' lighting along every sensor axis: {fitted['separable']}"
    rec = Recording(paths[0])
    full_fx = float(rec.colors[0]["fx"]) * front_depth_rotation_fit.FULL_WIDTH / rec.color_width
    ox, oy = fitted["parameters"]["ox"], fitted["parameters"]["oy"]
    return {"rotation_vector_rad": front_depth_rotation_fit.rotation_vector(ox["value"], oy["value"], full_fx), "offset_full_sensor_px": {"ox": ox, "oy": oy}, "full_sensor_fx": full_fx, "fit": fitted, "measured_on": [Recording(p).scan_id for p in paths]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phone-id", required=True)
    parser.add_argument("--phone-model", required=True)
    parser.add_argument("--rear", type=Path, nargs="+", required=True)
    parser.add_argument("--front-lens", type=Path, nargs="+", required=True)
    parser.add_argument("--front-corners", type=Path, nargs="+", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    for path in args.rear + args.front_lens + args.front_corners:
        rec = Recording(path)
        assert rec.format_minor < 8 or rec.scan_metadata["phone_id"] == args.phone_id, (path, rec.scan_metadata["phone_id"])
    rear_lens = lens_entry(args.rear)
    front_lens = lens_entry(args.front_lens)
    corrections = {"phone_id": args.phone_id, "phone_model": args.phone_model, "front": {"lens_distortion": front_lens, "depth_rotation": rotation_entry(args.front_corners, front_lens)}, "rear": {"lens_distortion": rear_lens}}
    args.out.mkdir(parents=True, exist_ok=True)
    target = args.out / f"{args.phone_id}.json"
    target.write_text(json.dumps(corrections, indent=2) + "\n")
    print(target)


if __name__ == "__main__":
    main()

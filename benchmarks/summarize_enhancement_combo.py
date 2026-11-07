#!/usr/bin/env python3
"""Summarize four isolated short combo runs; never calls them playback FPS."""
import argparse
import json
from pathlib import Path
import statistics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs=4, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    loaded = [(path, json.loads(path.read_text())) for path in args.reports]
    keys = ("input_sha256", "width", "height", "source_pairs", "source_fps", "target_fps", "rife_tier", "rife_model_sha256")
    reference = tuple(loaded[0][1][k] for k in keys)
    seen, results = set(), []
    for path, data in loaded:
        if tuple(data[k] for k in keys) != reference:
            raise ValueError("Mismatched fixture, dimensions, model or interval count")
        mode = (data["backend"], data["scheduling"])
        if mode in seen:
            raise ValueError("Duplicate comparison mode")
        seen.add(mode)
        frames, pairs = data["sr_frames"], data["rife_pairs"]
        count = data["source_pairs"]
        if len(frames) != count * 2 or data["output_frames"] != len(frames) or len(pairs) != count:
            raise ValueError("Incomplete run")
        if any(abs(frame["pts_seconds"] - index/48) > 1e-9 for index, frame in enumerate(frames)):
            raise ValueError("Output timestamp gap/order error")
        if data["maximum_pending_batches"] > (1 if mode[1] == "serial" else 2):
            raise ValueError("Queue bound violated")
        # Both workers are serial, so intersections cannot double-count time.
        overlap = sum(max(0, min(r["end_uptime"], s["end_uptime"]) - max(r["start_uptime"], s["start_uptime"]))
                      for r in pairs for s in frames) * 1000
        results.append({"report": str(path), "backend": mode[0], "scheduling": mode[1],
                        "amortized_pair_ms": data["amortized_pair_ms"],
                        "pair_completion_mean_ms": statistics.mean(data["pair_completion_ms"]),
                        "pair_completion_max_ms": max(data["pair_completion_ms"]),
                        "sr_mean_ms": statistics.mean(r["sr_call_ms"] for r in frames),
                        "rife_mean_ms": statistics.mean(r["call_ms"] for r in pairs),
                        "backpressure_total_ms": sum(data["producer_backpressure_ms"]),
                        "rife_sr_call_overlap_ms": overlap,
                        "peak_process_rss_mib": data["process_lifetime_peak_rss_bytes"] / 1024**2,
                        "maximum_pending_batches": data["maximum_pending_batches"]})
    if seen != {(b, s) for b in ("mpsgraph", "coreml") for s in ("serial", "pipeline")}:
        raise ValueError("Expected MPSGraph/Core ML × serial/pipeline")
    report = {"fixture": dict(zip(keys, reference)), "results": results,
              "checks": "matching input, count, ordered timestamps and queue bounds passed",
              "limits": "Four short unpaced runs, not sustained playback. Call overlap includes waits and is not simultaneous GPU/ANE execution. Process RSS includes setup and is not total GPU memory. No utilization or dropped-frame measurement."}
    with args.output.open("x") as target:
        json.dump(report, target, indent=2, allow_nan=False)
        target.write("\n")
    print(args.output)


if __name__ == "__main__":
    main()

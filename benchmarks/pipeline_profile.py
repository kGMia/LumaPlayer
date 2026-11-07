#!/usr/bin/env python3
"""Opt-in, no-window RIFE + FSRCNNX prefetch comparison. Never drives an existing player."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from ipc import command


def distribution(values):
    values = sorted(v for v in values if isinstance(v, (int, float)) and math.isfinite(v))
    if not values:
        return None
    return {"count": len(values), "mean": statistics.mean(values),
            "p50": values[math.ceil(len(values) * .50) - 1],
            "p95": values[math.ceil(len(values) * .95) - 1], "max": values[-1]}


def parse_events(text):
    events = []
    for line in text.splitlines():
        if "IIVE_PROFILE {" in line:
            events.append(json.loads(line.split("IIVE_PROFILE ", 1)[1]))
    return events


def summarize_events(events, warmup):
    stages = {}
    outputs = [e for e in events if e.get("stage") == "sr" and e.get("event") == "output"]
    jobs = [e for e in events if e.get("event") == "job" and e.get("outputs", 0) > 0 and e.get("state") == "active"]
    # Warm-up is a source-timeline duration, not a polling-sample count.
    source_start = min((e["pts"] for e in outputs), default=0)
    for stage in ("rife", "sr"):
        selected = [e for e in jobs if e["stage"] == stage and e["pts"] >= source_start + warmup]
        ready = [e for e in events if e.get("stage") == stage and e.get("event") == "output"
                 and e["pts"] >= source_start + warmup]
        stages[stage] = {key: distribution([e.get(key) for e in selected]) for key in
                        ("dispatch_ms", "processing_ms", "input_ms", "model_call_ms", "gpu_span_ms", "cpu_wait_ms", "output_ms", "backpressure_ms")}
        stages[stage]["ready_ms"] = distribution([e["ready_ms"] for e in ready])
        stages[stage]["ready_depth_peak"] = max((e["queued"] + 1 for e in ready), default=None)
    # Receive/send are FFmpeg API calls, not isolated hardware decoder execution.
    stages["decode_api"] = {
        event + "_ms": distribution([e["duration_ms"] for e in events
                                      if e.get("stage") == "decode" and e["event"] == event and e["result"] == 0])
        for event in ("send", "receive")}
    steady = [e for e in outputs if e["pts"] >= source_start + warmup]
    elapsed = steady[-1]["time_s"] - steady[0]["time_s"] if len(steady) > 1 else 0
    fps = (len(steady) - 1) / elapsed if elapsed > 0 else None
    monotonic = all(b["pts"] > a["pts"] for a, b in zip(outputs, outputs[1:]))
    return {"stages": stages, "output_frames": len(outputs), "ordered_pts": monotonic,
            "warm_output_frames": len(steady), "pipeline_emission_fps": fps,
            "render_call_ms": None, "swap_call_ms": None, "display_fps": None}


def _anonymize_path_token(raw):
    if not isinstance(raw, str) or not raw:
        return None
    if raw.startswith("media-"):
        return raw
    h = 1469598103934665603
    for b in raw.encode("utf-8", errors="replace"):
        h ^= b
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return f"media-{h:016x}"


def _sanitize_vf_list(raw_vf):
    if not isinstance(raw_vf, list):
        return []
    out = []
    for item in raw_vf:
        if not isinstance(item, dict):
            continue
        entry = {k: item[k] for k in ("label", "name", "enabled") if k in item}
        if isinstance(item.get("params"), dict):
            params = {}
            for k, v in item["params"].items():
                params[k] = "<redacted-path>" if isinstance(v, str) and "/" in v else v
            entry["params"] = params
        out.append(entry)
    return out


def counter_changes(records, key):
    """Observed positive increments; counter resets are not negative dropped frames."""
    total, resets, previous, media = 0, 0, None, None
    for r in records:
        value = r.get(key)
        current_media = r.get("media-id") or _anonymize_path_token(r.get("path"))
        if not isinstance(value, (float, int)) or not math.isfinite(value):
            previous = None
            continue
        if previous is not None and current_media == media:
            if value < previous:
                resets += 1
            else:
                total += value - previous
        previous, media = value, current_media
    return {"observed_increase": total, "resets": resets}


def effective_filters(record):
    filters = _sanitize_vf_list(record.get("vf"))
    meta = record.get("iive-rife") or {}
    for f in filters:
        if f.get("label") == "iive-rife" and meta.get("requested_tier") in ("fast", "balanced", "hq"):
            # mpv's vf property retains construction options after vf-command.
            params = dict(f.get("params", {}))
            if params.get("tier") != meta["requested_tier"]:
                params["initial_tier"] = params.get("tier")
            params["tier"] = meta["requested_tier"]
            f["params"] = params
    return filters


def media_switch_events(records):
    """Observed startup intervals; do not sum overlapping stages or infer display latency."""
    clocks = [r.get("monotonic_s") for r in records]
    clocks = [t for t in clocks if isinstance(t, (int, float)) and not isinstance(t, bool) and math.isfinite(t) and t > 0]
    origin = min(clocks) if clocks else None
    end = max(clocks) if clocks else None
    stages = ("candidate_command_to_start_ms", "start_to_loaded_ms", "loaded_to_restart_ms",
              "start_to_restart_ms", "loaded_to_initial_plan_ms", "initial_warmup_pause_ms",
              "loaded_to_observed_fresh_submit_ms", "start_to_end_ms")
    events = {}
    overwritten = 0
    for record in records:
        count = record.get("media-switch-history-overwritten")
        if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
            overwritten = max(overwritten, count)  # cumulative, never sum repeated snapshots
        samples = record.get("media-switch-timing")
        if not isinstance(samples, list):
            continue
        for sample in samples:
            if not isinstance(sample, dict):
                continue
            epoch, start = sample.get("epoch"), sample.get("start_observed_s")
            if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch <= 0:
                continue
            if not isinstance(start, (int, float)) or isinstance(start, bool) or not math.isfinite(start) or start <= 0:
                continue
            event = events.setdefault((epoch, start), {"epoch": epoch, "start_observed_s": start})
            if sample.get("state") in ("opening", "loaded", "started", "ended", "failed"):
                event["state"] = sample["state"]
            for key in stages:
                value = sample.get(key)
                if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0:
                    event[key] = value
            for key in ("initial_plan_seen", "initial_plan_changed"):
                if isinstance(sample.get(key), bool):
                    event[key] = sample[key]
    ordered = sorted(events.values(), key=lambda event: event["start_observed_s"])
    for event in ordered:
        start = event["start_observed_s"]
        event["recording_scope"] = ("unknown" if origin is None else
            "before-recording" if start < origin else "during-recording" if start <= end else "outside-recording")
        event["start_elapsed_s"] = start-origin if origin is not None else None
    return {"observed_events": len(ordered), "events_omitted": max(0, len(ordered)-32),
            "started_during_recording": sum(e["recording_scope"] == "during-recording" for e in ordered),
            "retained_before_recording": sum(e["recording_scope"] == "before-recording" for e in ordered),
            "history_overwritten_counter": overwritten, "events": ordered[-32:],
            "limits": "Client-queue event observations; intervals overlap and include event delivery delay. Command association is a candidate, not click latency. Fresh GL submission observed after FILE_LOADED may miss an earlier frame and is not physical display presentation. Audio may have no render observation. Missing stages remain unavailable; no pure network/decode/compile timing."}


def render_slow_events(records):
    """Summarize bounded native wall-time events, never GPU/display timings."""
    origin = next((r["monotonic_s"] for r in records if isinstance(r.get("monotonic_s"), (int, float))), 0)
    events, seen = [], set()
    overwritten = 0
    phases = [f"{name}_ms" for name in ("make_current", "context_wait", "update", "draw",
              "luma_collect", "luma_enqueue", "swap", "report_swap")]
    for record in records:
        timing = record.get("render-timing") or {}
        missed = timing.get("slow_frames_overwritten", 0)
        if isinstance(missed, int) and missed >= 0:
            overwritten += missed
        for event in timing.get("slow_frames", []):
            stamp = event.get("time_s")
            if not isinstance(stamp, (int, float)) or not math.isfinite(stamp):
                continue
            key = (record.get("media-id"), stamp, event.get("frame_serial"))
            if key in seen:
                continue
            seen.add(key)
            costs = {k: event[k] for k in phases if isinstance(event.get(k), (int, float))
                     and math.isfinite(event[k]) and event[k] >= 0}
            gap = event.get("submit_gap_ms")
            gap = gap if isinstance(gap, (int, float)) and math.isfinite(gap) and gap >= 0 else None
            # Early builds used CLOCK_MONOTONIC for events but systemUptime for
            # snapshots. They cannot be subtracted (sleep changes the offset).
            clock = timing.get("slow_event_clock", "legacy-unmapped")
            observed = record.get("monotonic_s")
            observed = observed - origin if isinstance(observed, (int, float)) and math.isfinite(observed) else None
            events.append({"elapsed_s": stamp - origin if clock == "system-uptime" else None,
                           "observed_at_s": observed, "clock": clock, "frame_serial": event.get("frame_serial"),
                           "explicit_redraw": event.get("explicit_redraw"), "mpv_frame": event.get("mpv_frame"),
                           "submit_gap_ms": gap, "largest_call": max(costs, key=costs.get) if costs else None,
                           **costs})
    selected = sorted(events, key=lambda e: max([e.get("submit_gap_ms") or 0] +
                      [e.get(k, 0) for k in phases]), reverse=True)[:32]
    return {"observed_events": len(events), "overwritten_before_snapshot": overwritten,
            "events_omitted": max(0, len(events) - 32),
            "events": sorted(selected, key=lambda e: e["elapsed_s"] if e["elapsed_s"] is not None else (e["observed_at_s"] or 0)),
            "note": "CPU wall time; largest call is not a proven root cause. Gaps include pause/seek/occlusion."}


def player_context(records):
    """Bounded incident windows and configuration segments from existing 4 Hz samples.

    No extra capture/readback, no inference of GPU utilisation, and no media paths.
    """
    def mode(r):
        filters = effective_filters(r)
        rife = next((f.get("params", {}) for f in filters if f.get("label") == "iive-rife"), {})
        meta = r.get("iive-rife") or {}
        return {"media_id": r.get("media-id") or _anonymize_path_token(r.get("path")),
                "tier": rife.get("tier"), "target_fps": rife.get("fps"),
                "protection": rife.get("fallback"), "state": meta.get("state"),
                "generation": meta.get("generation"), "phase": r.get("playback-phase")}

    groups, incidents, transitions = [], [], []
    previous_policy = None
    origin = next((r["monotonic_s"] for r in records if isinstance(r.get("monotonic_s"), (int, float))), 0)
    def elapsed(r):
        t = r.get("monotonic_s")
        return t - origin if isinstance(t, (int, float)) and math.isfinite(t) else None

    for i, r in enumerate(records):
        key = mode(r)
        if not groups or groups[-1]["mode"] != key:
            groups.append({"mode": key, "records": [], "baseline": records[i - 1:i] if i else []})
        groups[-1]["records"].append(r)
        policy = r.get("rife-performance-policy")
        if isinstance(policy, dict) and policy != previous_policy:
            transitions.append({"elapsed_s": elapsed(r), "policy": {
                k: policy.get(k) for k in ("requested_tier", "effective_tier", "stage", "reason", "automatic")}})
            previous_policy = policy
        if not i or elapsed(r) is None:
            continue
        a = records[i - 1]
        if mode(a)["media_id"] != key["media_id"]:
            continue
        av, bv = a.get("frame-drop-count"), r.get("frame-drop-count")
        if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in (av, bv)) or bv <= av:
            continue
        if incidents and elapsed(r) - incidents[-1]["end_s"] <= 1 and incidents[-1]["mode"] == key:
            event = incidents[-1]
            event["end_s"] = elapsed(r)
            event["observed_drops"] += bv - av
        else:
            incidents.append({"start_s": elapsed(r), "end_s": elapsed(r),
                              "observed_drops": bv - av, "mode": key})

    segments = []
    for group in groups:
        rs = group["records"]
        segments.append({"mode": group["mode"], "start_s": elapsed(rs[0]), "end_s": elapsed(rs[-1]),
                         # Attribute the boundary delta to the receiving segment;
                         # counter_changes still excludes cross-media/reset deltas.
                         "samples": len(rs), "drops": counter_changes(group["baseline"] + rs, "frame-drop-count"),
                         "render_callback_fps": distribution([r.get("render-callback-fps") for r in rs]),
                         "footprint_bytes": distribution([r.get("process-memory-bytes") for r in rs])})
    # Keep the largest 16 incidents, ordered chronologically. Raw JSONL remains complete.
    selected = sorted(sorted(incidents, key=lambda e: e["observed_drops"], reverse=True)[:16], key=lambda e: e["start_s"])
    for event in selected:
        rs = [r for r in records if elapsed(r) is not None and
              event["start_s"] - 2 <= elapsed(r) <= event["end_s"] + 2 and
              mode(r)["media_id"] == event["mode"]["media_id"]]
        event["context_samples_total"] = len(rs)
        if len(rs) > 24:
            rs = [rs[round(i * (len(rs) - 1) / 23)] for i in range(24)]
        event["context"] = [{"elapsed_s": elapsed(r), "mode": mode(r),
            **{k: r.get(k) for k in ("frame-drop-count", "avsync", "process-memory-bytes", "process-cpu-percent", "render-timing")},
            "rife": {k: (r.get("iive-rife") or {}).get(k) for k in
                     ("processing_ms", "p95_processing_ms", "pair_budget_ms", "queued", "inflight", "input_ms", "model_call_ms", "gpu_span_ms", "cpu_wait_ms", "output_ms", "tier_switch_ms", "tier_switch_pending", "tier_switches")}}
            for r in rs]
    return {"playback_segments": segments[:64], "segments_omitted": max(0, len(segments) - 64),
            "drop_incidents": selected, "drop_incidents_total": len(incidents),
            "policy_transitions": transitions[:64], "policy_transitions_omitted": max(0, len(transitions) - 64)}


def rife_error_events(records):
    """Deduplicate persistent per-generation diagnostics; do not invent legacy causes."""
    events, seen = [], set()
    for record in records:
        meta = record.get("iive-rife")
        if not isinstance(meta, dict) or meta.get("error_stage") not in (
                "initialization", "input", "push", "output", "tier-preparation", "finish"):
            continue
        fields = {k: meta.get(k) for k in ("error_id", "error_stage", "error_code", "error_reason",
                  "error_generation", "error_events", "error_input_pts")}
        media = record.get("media-id") or _anonymize_path_token(record.get("path"))
        key = (media, *(str(v) for v in fields.values()))
        if key in seen:
            continue
        seen.add(key)
        events.append({"media_id": media, "observed_at_s": record.get("monotonic_s"), **fields})
    return {"observed_events": len(events), "events_omitted": max(0, len(events)-32),
            "events": events[-32:], "scope": "Sampled failures, not an exhaustive trace; legacy logs have no cause codes."}


def describe_player_metrics(path):
    """Summarize a user-recorded --metrics file without launching or controlling a GUI."""
    records = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    active = [r for r in records if r.get("playback-phase") == "playing"
              and r.get("media-loaded") and not r.get("seeking")
              and not r.get("enhancement-warming")]
    last = active[-1] if active else (records[-1] if records else {})
    src_vp = last.get("video-params") if isinstance(last.get("video-params"), dict) else {}
    out_vp = last.get("video-out-params") if isinstance(last.get("video-out-params"), dict) else {}
    media_ids = []
    for r in records:
        token = r.get("media-id") or _anonymize_path_token(r.get("path"))
        if token and token not in media_ids:
            media_ids.append(token)
    drops = [r["frame-drop-count"] for r in active if isinstance(r.get("frame-drop-count"), (int, float))]
    dec_drops = [r["decoder-frame-drop-count"] for r in active if isinstance(r.get("decoder-frame-drop-count"), (int, float))]
    queues = {}
    degradation_events = {}
    fallback_triggered = False
    for stage in ("iive-rife", "iive-fi", "iive-sr"):
        stage_records = [r for r in records if isinstance(r.get(stage), dict)]
        active_stage_records = [
            r for r in stage_records
            if r[stage].get("state") in ("active", "scene-cut-hold", "finished")
            or r[stage].get("p95_processing_ms") is not None
        ]
        meta_source = last if isinstance(last.get(stage), dict) else (active_stage_records[-1] if active_stage_records else (stage_records[-1] if stage_records else {}))
        meta = meta_source.get(stage) if isinstance(meta_source.get(stage), dict) else None
        last_active_meta = {}
        for r in stage_records:
            st = str(r[stage].get("state", ""))
            if st in ("active", "scene-cut-hold", "finished"):
                last_active_meta = r[stage]
            if r[stage].get("fallback") == "yes" or st.startswith("degraded") or st == "error-bypass":
                fallback_triggered = True
                if stage not in degradation_events:
                    degradation_events[stage] = {
                        "state": st,
                        "time_pos": r.get("time-pos"),
                        "p50_processing_ms": r[stage].get("p50_processing_ms") or last_active_meta.get("p50_processing_ms"),
                        "p95_processing_ms": r[stage].get("p95_processing_ms") or last_active_meta.get("p95_processing_ms"),
                        "peak_processing_ms": r[stage].get("peak_processing_ms") or last_active_meta.get("peak_processing_ms"),
                        "pair_budget_ms": r[stage].get("pair_budget_ms") or last_active_meta.get("pair_budget_ms"),
                        "input_surface": r[stage].get("input_surface") or last_active_meta.get("input_surface"),
                        **{key: r[stage].get(key) for key in ("error_stage", "error_code", "error_reason", "error_input_pts", "error_generation")},
                    }
        queued_samples = [
            int(r[stage]["queued"]) for r in active
            if isinstance(r.get(stage), dict) and str(r[stage].get("queued", "")).isdigit()
        ]
        if any(
            isinstance(r.get(stage), dict) and (
                r[stage].get("fallback") == "yes"
                or str(r[stage].get("state", "")).startswith("degraded")
                or r[stage].get("state") == "error-bypass"
            )
            for r in active
        ):
            fallback_triggered = True
        if meta:
            queues[stage] = {
                "state": meta.get("state"),
                "backend": meta.get("backend"),
                "input_surface": meta.get("input_surface"),
                "input_path": meta.get("input_path"),
                "output_path": meta.get("output_path"),
                "prefetch_mode": meta.get("prefetch_mode"),
                "prefetch_limit": meta.get("prefetch_limit"),
                "pair_budget_ms": meta.get("pair_budget_ms"),
                "queue_ahead_ms": meta.get("queue_ahead_ms"),
                "queue_budget_ms": meta.get("queue_budget_ms"),
                "time_prefetch_blocked": meta.get("time_prefetch_blocked"),
                "time_prefetch_deferrals": meta.get("time_prefetch_deferrals"),
                "ready_peak": meta.get("ready_peak"),
                "max_queued_sampled": max(queued_samples) if queued_samples else None,
                "p50_processing_ms": meta.get("p50_processing_ms"),
                "p95_processing_ms": meta.get("p95_processing_ms"),
                "last_gpu_span_ms": meta.get("gpu_span_ms"),
                "last_cpu_wait_ms": meta.get("cpu_wait_ms"),
                "p95_dispatch_ms": meta.get("p95_dispatch_ms"),
                "p95_ready_ms": meta.get("p95_ready_ms"),
                "p95_backpressure_ms": meta.get("p95_backpressure_ms"),
                "shared_inputs": meta.get("shared_inputs"),
                "normalized_inputs": meta.get("normalized_inputs"),
                "copied_inputs": meta.get("copied_inputs"),
                "reused_outputs": meta.get("reused_outputs"),
                "preroll_bypassed": meta.get("preroll_bypassed"),
                "initialization_ms": meta.get("initialization_ms"),
                "compilation_cache_hit": meta.get("compilation_cache_hit"),
                "initializations": meta.get("initializations"),
                "preparation_generation": meta.get("preparation_generation"),
                "prepare_weights_ms": meta.get("prepare_weights_ms"),
                "prepare_context_ms": meta.get("prepare_context_ms"),
                "prepare_pool_ms": meta.get("prepare_pool_ms"),
                "prepare_compile_ms": meta.get("prepare_compile_ms"),
                "prepare_probe_ms": meta.get("prepare_probe_ms"),
                "fallback": meta.get("fallback"),
            }
        else:
            queues[stage] = None
    peak_footprint = max(
        (r.get("process-peak-sampled-footprint-bytes") or r.get("process-memory-bytes")
         for r in active
         if isinstance(r.get("process-peak-sampled-footprint-bytes") or r.get("process-memory-bytes"), (int, float))),
        default=None,
    )
    return {
        "schema": 2,
        "scope": "player sampled telemetry; not physical display measurement",
        "total_snapshots": len(records),
        "active_snapshots": len(active),
        "media_ids": media_ids,
        "decoder": {
            "requested": last.get("hwdec"),
            "active": last.get("hwdec-current"),
            "video_codec": last.get("video-codec"),
        },
        "resolution": {
            "source": {
                "w": src_vp.get("w"),
                "h": src_vp.get("h"),
                "pixelformat": src_vp.get("pixelformat"),
                "container_fps": last.get("container-fps"),
            },
            "output": {
                "w": out_vp.get("w"),
                "h": out_vp.get("h"),
                "pixelformat": out_vp.get("pixelformat"),
            },
            "viewport": {
                "w": last.get("viewport-width"),
                "h": last.get("viewport-height"),
            },
        },
        "enhancement": {
            "filters": effective_filters(last),
            "vo_passes": last.get("vo-passes") if isinstance(last.get("vo-passes"), list) else [],
            "fallback_triggered": fallback_triggered,
            "degradation_events": degradation_events,
        },
        "queues": queues,
        "render_callback_fps": distribution([r.get("render-callback-fps") for r in active]),
        "estimated_vf_fps": distribution([r.get("estimated-vf-fps") for r in active]),
        "avsync_ms": distribution([
            r["avsync"] * 1000.0 for r in active
            if isinstance(r.get("avsync"), (int, float)) and math.isfinite(r["avsync"])
        ]),
        "frame_drop_delta": counter_changes(active, "frame-drop-count")["observed_increase"] if drops else None,
        "decoder_drop_delta": counter_changes(active, "decoder-frame-drop-count")["observed_increase"] if dec_drops else None,
        "frame_drop_counter": counter_changes(records, "frame-drop-count"),
        "rife_tier_commands": counter_changes(records, "iive-rife-tier-commands"),
        "filter_rebuild_seeks": counter_changes(records, "iive-filter-rebuild-seeks"),
        **player_context(records),
        "render_slow_events": render_slow_events(records),
        "media_switches": media_switch_events(records),
        "process_cpu_percent": distribution([r.get("process-cpu-percent") for r in active]),
        "footprint_bytes": distribution([r.get("process-memory-bytes") for r in active]),
        "resident_bytes": distribution([r.get("process-resident-bytes") for r in active]),
        "peak_sampled_footprint_bytes": peak_footprint,
        "display_fps": None,
        "last_render_window": active[-1].get("render-timing") if active else None,
        "last_filter_windows": {stage: active[-1].get(stage) for stage in ("iive-rife", "iive-fi", "iive-sr")} if active else {},
        "rife_errors": rife_error_events(records),
        "note": "Window P95 values are not merged into a session P95; paused redraws are not playback FPS.",
    }


def get(socket, key):
    reply = command(["get_property", key], socket)
    return reply.get("data") if reply.get("error") == "success" else None


def run_one(args, depth, repetition, directory):
    name = f"prefetch-{depth}-repeat-{repetition}"
    log_path = directory / (name + ".log")
    sample_path = directory / (name + ".jsonl")
    with tempfile.TemporaryDirectory(prefix="iive-profile-", dir="/tmp") as temp:
        socket = str(Path(temp) / "mpv.sock")
        filters = (f"@iive-rife:iive-rife=fps={args.fps}:tier={args.tier}:fallback=no:prefetch={depth},"
                   f"@iive-sr:iive-fsrcnnx=tier=fast:fallback=no:prefetch={depth}")
        cmd = ["/usr/bin/time", "-l", str(args.mpv), "--no-config", "--vo=null", "--ao=null",
               f"--hwdec={args.hwdec}", "--untimed", "--keep-open=yes", "--idle=yes", "--term-status-msg=", "--input-terminal=no",
               "--msg-level=all=info", "--msg-color=no", f"--input-ipc-server={socket}", f"--vf={filters}", str(args.input)]
        env = dict(os.environ, IIVE_PROFILE="1")
        env.pop("IIVE_PROFILE_PREFETCH", None)
        start = time.monotonic()
        end = None
        snapshots = []
        error = None
        with log_path.open("w") as log, sample_path.open("w") as sample_file:
            child = subprocess.Popen(cmd, stdout=log, stderr=log, env=env, start_new_session=True)
            try:
                while time.monotonic() - start < args.timeout:
                    if child.poll() is not None:
                        raise RuntimeError(f"player exited before EOF: {child.returncode}")
                    if Path(socket).exists():
                        snap = {key: get(socket, key) for key in
                                ("eof-reached", "time-pos", "frame-drop-count", "decoder-frame-drop-count",
                                 "hwdec-current", "video-out-params", "vf-metadata/iive-rife", "vf-metadata/iive-sr")}
                        snap["elapsed_s"] = time.monotonic() - start
                        snapshots.append(snap)
                        sample_file.write(json.dumps(snap) + "\n")
                        if snap["eof-reached"]:
                            end = time.monotonic()
                            break
                    time.sleep(.15)
                else:
                    raise TimeoutError("EOF timeout")
            except Exception as exc:
                error = str(exc)
            finally:
                if child.poll() is None:
                    try:
                        command(["quit"], socket)
                    except Exception:
                        pass
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        import signal
                        os.killpg(child.pid, signal.SIGTERM)
                        try:
                            child.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait()
        text = log_path.read_text(errors="replace")
        events = parse_events(text)
        result = summarize_events(events, args.warmup_seconds)
        rss = re.search(r"(\d+)\s+maximum resident set size", text)
        footprint = re.search(r"(\d+)\s+peak memory footprint", text)
        final = snapshots[-1] if snapshots else {}
        rife = final.get("vf-metadata/iive-rife") or {}
        sr = final.get("vf-metadata/iive-sr") or {}
        result.update(prefetch=depth, repetition=repetition, error=error, exit_code=child.returncode,
                      launch_to_eof_s=None if end is None else end-start,
                      peak_resident_bytes=int(rss[1]) if rss else None,
                      peak_footprint_bytes=int(footprint[1]) if footprint else None,
                      dropped=final.get("frame-drop-count"), decoder_dropped=final.get("decoder-frame-drop-count"),
                      decoder=final.get("hwdec-current"), output=final.get("video-out-params"),
                      rife=rife, sr=sr, command=cmd, log=log_path.name, samples=sample_path.name)
        result["valid"] = (not error and child.returncode == 0 and result["ordered_pts"]
                           and result["warm_output_frames"] >= 20 and int(rife.get("generated", "0")) > 0
                           and rife.get("fallback") == "no" and sr.get("fallback") == "no"
                           and sr.get("backend") == "fsrcnnx8-mpsgraph"
                           and all(result["stages"][stage]["processing_ms"] is not None for stage in ("rife", "sr"))
                           and result["stages"]["decode_api"]["receive_ms"] is not None
                           and int(rife.get("emitted", "0")) == int(sr.get("emitted", "-1"))
                           and result["output_frames"] == int(sr.get("emitted", "-1")))
        result["sustained_realtime_proven"] = False
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--mpv", type=Path, default=ROOT / "build/mpv/mpv")
    parser.add_argument("--fps", type=int, choices=(48, 60), default=48)
    parser.add_argument("--tier", choices=("fast", "balanced", "hq"), default="fast")
    parser.add_argument("--hwdec", choices=("no", "videotoolbox-copy"), default="no")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--warmup-seconds", type=float, default=1)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--summarize-player", type=Path)
    args = parser.parse_args()
    if args.summarize_player:
        print(json.dumps(describe_player_metrics(args.summarize_player), indent=2))
        return
    if not args.input or not args.output:
        parser.error("--input and a new --output directory are required")
    if args.repetitions < 1 or args.warmup_seconds < 0 or args.timeout <= 0:
        parser.error("invalid repetitions, warm-up or timeout")
    args.input = args.input.resolve(strict=True)
    args.mpv = args.mpv.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=False)
    probe = subprocess.check_output([shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe", "-v", "error",
                                    "-show_streams", "-show_format", "-of", "json", str(args.input)], text=True)
    with args.input.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    with args.mpv.open("rb") as binary:
        binary_digest = hashlib.file_digest(binary, "sha256").hexdigest()
    chip_query = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True)
    chip = chip_query.stdout.strip() if chip_query.returncode == 0 else None
    artifacts = {}
    for relative in ("build/mpv/libmpv.2.dylib", "native/RIFEBackend/.build/release/libIIVERIFE.dylib", "native/FSRCNNXMetal/.build/release/libIIVEFSR.dylib"):
        binary = ROOT / relative
        if binary.exists():
            with binary.open("rb") as stream:
                artifacts[relative] = hashlib.file_digest(stream, "sha256").hexdigest()
    report = {"artifacts_sha256": artifacts, "schema": 1, "scope": "no-window untimed decode + RIFE + FSRCNNX; no render/display",
              "input": str(args.input), "sha256": digest, "probe": json.loads(probe),
              "system": platform.platform(), "chip": chip,
              "mpv_sha256": binary_digest,
              "warmup_source_seconds": args.warmup_seconds, "fps": args.fps, "tier": args.tier,
              "notes": ["Each repetition starts a fresh process; OS/model caches are not forcibly purged.",
                        "Model-call time includes CPU work and GPU waits; this is not pure GPU kernel time.",
                        "Decoder API calls are all-run wall times; hardware work can be asynchronous.",
                        "Raw tracing adds overhead. Null-output drops are not physical display drops.",
                        "Fixed depth overrides the default adaptive policy for both filters; ready batch capacity stays 8."],
              "runs": []}
    rng = random.Random(args.seed)
    base_depths = [1, 2, 4]
    rng.shuffle(base_depths)
    for repetition in range(1, args.repetitions + 1):
        offset = (repetition-1) % 3
        depths = base_depths[offset:] + base_depths[:offset]
        for depth in depths:
            print(f"prefetch={depth}, repetition={repetition}", flush=True)
            report["runs"].append(run_one(args, depth, repetition, args.output))
            (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    report["comparison"] = {str(depth): {
        "valid_runs": sum(r["valid"] for r in report["runs"] if r["prefetch"] == depth),
        "emission_fps_across_runs": distribution([r["pipeline_emission_fps"] for r in report["runs"] if r["prefetch"] == depth and r["valid"]]),
        "max_resident_bytes": max((r["peak_resident_bytes"] for r in report["runs"] if r["prefetch"] == depth and r["peak_resident_bytes"] is not None), default=None),
        "max_footprint_bytes": max((r["peak_footprint_bytes"] for r in report["runs"] if r["prefetch"] == depth and r["peak_footprint_bytes"] is not None), default=None)
    } for depth in (1, 2, 4)}
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["comparison"], indent=2))
    if not all(r["valid"] for r in report["runs"]):
        raise SystemExit("Some runs are invalid; inspect report errors/bypass/counters before interpreting performance.")


if __name__ == "__main__":
    main()

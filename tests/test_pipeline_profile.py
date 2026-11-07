import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("profile_report", Path(__file__).resolve().parents[1] / "benchmarks/pipeline_profile.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class ProfileTests(unittest.TestCase):
    def test_media_switches_merge_partial_history_without_inventing_missing_phases(self):
        opening = {"epoch": 1, "start_observed_s": 10, "state": "opening", "start_to_loaded_ms": None}
        ready = dict(opening, state="started", start_to_loaded_ms=50, loaded_to_restart_ms=20,
                     initial_warmup_pause_ms=None, loaded_to_observed_fresh_submit_ms=float("nan"))
        result = profile.media_switch_events([
            {"media-switch-timing": [opening]},
            {"media-switch-timing": [ready], "media-switch-history-overwritten": 3},
            {"media-switch-timing": [dict(ready, state="ended", start_to_loaded_ms=None)], "media-switch-history-overwritten": 3}])
        self.assertEqual(result["observed_events"], 1)
        self.assertEqual(result["events"][0]["start_to_loaded_ms"], 50)
        self.assertEqual(result["events"][0]["state"], "ended")
        self.assertNotIn("initial_warmup_pause_ms", result["events"][0])
        self.assertNotIn("loaded_to_observed_fresh_submit_ms", result["events"][0])
        self.assertEqual(result["history_overwritten_counter"], 3)

    def test_media_switches_bound_output_and_accept_legacy_logs(self):
        self.assertEqual(profile.media_switch_events([{}])["events"], [])
        samples = [{"epoch": i+1, "start_observed_s": i+1} for i in range(40)]
        samples += [{"epoch": True, "start_observed_s": 100}, {"epoch": 99, "start_observed_s": float("inf")}]
        result = profile.media_switch_events([{"media-switch-timing": samples}])
        self.assertEqual(result["observed_events"], 40)
        self.assertEqual(len(result["events"]), 32)
        self.assertEqual(result["events_omitted"], 8)

    def test_rife_errors_keep_failures_without_repeating_bypass_samples(self):
        failure = {"error_stage": "output", "error_code": "403", "error_reason": "output-surface-wrap",
                   "error_generation": "3", "error_events": "1", "error_input_pts": "325.6"}
        records = [{"monotonic_s": i, "media-id": "media-one", "iive-rife": failure} for i in range(10)]
        records += [{"media-id": "media-one", "iive-rife": {}},
                    {"media-id": "media-two", "iive-rife": failure}]
        result = profile.rife_error_events(records)
        self.assertEqual(result["observed_events"], 2)
        self.assertEqual(result["events"][0]["error_input_pts"], "325.6")
        self.assertEqual(result["events"][0]["observed_at_s"], 0)
        repeated = records[:2] + [{"media-id": "media-one", "iive-rife": dict(failure, error_id="2")}]
        self.assertEqual(profile.rife_error_events(repeated)["observed_events"], 2)
        self.assertEqual(profile.rife_error_events([{"iive-rife": {"state": "error-bypass"}}])["events"], [])

    def test_rife_errors_bounded_across_seek_generations(self):
        records = [{"media-id": "media-one", "iive-rife": {
            "error_stage": "push", "error_code": "206", "error_generation": str(i)}} for i in range(40)]
        result = profile.rife_error_events(records)
        self.assertEqual(result["observed_events"], 40)
        self.assertEqual(result["events_omitted"], 8)
        self.assertEqual(result["events"][0]["error_generation"], "8")

    def test_media_switches_separate_retained_history_from_recording(self):
        events = [{"epoch": i, "start_observed_s": t} for i, t in enumerate([90, 100, 105, 111], 1)]
        result = profile.media_switch_events([
            {"monotonic_s": 100, "media-switch-timing": events}, {"monotonic_s": 110}])
        self.assertEqual(result["started_during_recording"], 2)
        self.assertEqual(result["retained_before_recording"], 1)
        self.assertEqual([e["recording_scope"] for e in result["events"]],
                         ["before-recording", "during-recording", "during-recording", "outside-recording"])
        self.assertEqual(result["events"][0]["start_elapsed_s"], -10)
        unknown = profile.media_switch_events([{"monotonic_s": float("nan"), "media-switch-timing": events}])
        self.assertEqual(unknown["events"][0]["recording_scope"], "unknown")

    def test_slow_render_events_bounded_deduplicated_and_timed(self):
        events = [{"time_s": 100 + i, "frame_serial": i, "draw_ms": i,
                   "update_ms": 1, "luma_collect_ms": float("nan"), "submit_gap_ms": i + 1}
                  for i in range(40)]
        records = [{"monotonic_s": 100, "media-id": "one", "render-timing": {"slow_event_clock": "system-uptime", "slow_frames": events}},
                   {"monotonic_s": 140, "media-id": "one", "render-timing": {"slow_frames": events[-2:], "slow_frames_overwritten": 3}}]
        result = profile.render_slow_events(records)
        self.assertEqual(result["observed_events"], 40)
        self.assertEqual(result["events_omitted"], 8)
        self.assertEqual(result["overwritten_before_snapshot"], 3)
        self.assertEqual(result["events"][0]["elapsed_s"], 8)
        self.assertEqual(result["events"][-1]["largest_call"], "draw_ms")
        self.assertNotIn("luma_collect_ms", result["events"][0])
        self.assertEqual(profile.render_slow_events([{}])["events"], [])

    def test_legacy_render_clock_is_not_subtracted_from_uptime(self):
        records = [{"monotonic_s": 100, "render-timing": {}},
                   {"monotonic_s": 102, "render-timing": {"slow_frames": [
                       {"time_s": 57709, "frame_serial": 1, "draw_ms": 30}]}}]
        event = profile.render_slow_events(records)["events"][0]
        self.assertIsNone(event["elapsed_s"])
        self.assertEqual(event["observed_at_s"], 2)
        self.assertEqual(event["clock"], "legacy-unmapped")

    def test_segment_boundary_keeps_drop_delta(self):
        records = [{"monotonic_s": i, "media-id": "one", "frame-drop-count": drops,
                    "iive-rife": {"state": "active", "requested_tier": tier},
                    "vf": [{"label": "iive-rife", "params": {"tier": "balanced"}}]}
                   for i, (drops, tier) in enumerate([(0, "balanced"), (21, "fast"), (93, "fast")])]
        segments = profile.player_context(records)["playback_segments"]
        self.assertEqual([s["drops"]["observed_increase"] for s in segments], [0, 93])
        records[1]["media-id"] = records[2]["media-id"] = "two"
        segments = profile.player_context(records)["playback_segments"]
        self.assertEqual(sum(s["drops"]["observed_increase"] for s in segments), 72)

    def test_live_tier_metadata_overrides_initial_vf_option(self):
        record = {"vf": [{"label": "iive-rife", "params": {"tier": "balanced", "fps": "48"}}],
                  "iive-rife": {"requested_tier": "fast"}}
        result = profile.effective_filters(record)
        self.assertEqual(result[0]["params"]["tier"], "fast")
        self.assertEqual(result[0]["params"]["initial_tier"], "balanced")
        self.assertEqual(record["vf"][0]["params"]["tier"], "balanced")

    def test_counter_resets_and_incident_context(self):
        records = []
        for i, drops in enumerate([0, 2, 5, 0, 1, 1, 1]):
            records.append({"monotonic_s": 100 + i * .25, "media-id": "media-test",
                "frame-drop-count": drops, "process-memory-bytes": 100 + i,
                "playback-phase": "playing", "render-callback-fps": 48,
                "vf": [{"label": "iive-rife", "params": {"tier": "balanced" if i < 3 else "fast", "fallback": "yes"}}],
                "iive-rife": {"state": "active", "generation": "1"},
                "rife-performance-policy": {"stage": "requested" if i < 3 else "fast"}})
        self.assertEqual(profile.counter_changes(records, "frame-drop-count"),
                         {"observed_increase": 6, "resets": 1})
        context = profile.player_context(records)
        self.assertEqual(len(context["playback_segments"]), 2)
        self.assertEqual(len(context["policy_transitions"]), 2)
        self.assertEqual(context["drop_incidents_total"], 2)
        self.assertEqual(context["drop_incidents"][0]["observed_drops"], 5)
        window = context["drop_incidents"][0]["context"]
        self.assertEqual(window[0]["elapsed_s"], 0)
        self.assertGreater(window[-1]["elapsed_s"], .5)

    def test_percentiles_ignore_missing_and_use_nearest_rank(self):
        self.assertIsNone(profile.distribution([None, float("nan")]))
        result = profile.distribution([100, 1, 2, 3, None])
        self.assertEqual(result["p50"], 2)
        self.assertEqual(result["p95"], 100)
        self.assertEqual(result["count"], 4)

    def test_warmup_excluded_and_throughput_not_display(self):
        events = [{"stage": "sr", "event": "output", "pts": pts, "time_s": wall,
                   "ready_ms": 2, "queued": 0} for pts, wall in [(0, 10), (1, 20), (2, 20.5), (3, 21)]]
        summary = profile.summarize_events(events, 1)
        self.assertEqual(summary["warm_output_frames"], 3)
        self.assertEqual(summary["pipeline_emission_fps"], 2)
        self.assertIsNone(summary["display_fps"])
        self.assertIsNone(summary["stages"]["decode_api"]["receive_ms"])
        events.append(dict(events[-1]))
        self.assertFalse(profile.summarize_events(events, 1)["ordered_pts"])

    def test_gpu_span_and_cpu_wait_ignore_unavailable_and_legacy_samples(self):
        # Parser fixtures only; never used as benchmark results.
        base = {"event": "job", "stage": "sr", "state": "active", "outputs": 1, "pts": 2}
        events = [dict(base), dict(base, gpu_span_ms=None, cpu_wait_ms=None),
                  dict(base, gpu_span_ms=8, cpu_wait_ms=5),
                  dict(base, gpu_span_ms=12, cpu_wait_ms=7)]
        result = profile.summarize_events(events, 0)["stages"]["sr"]
        self.assertEqual(result["gpu_span_ms"]["count"], 2)
        self.assertEqual(result["gpu_span_ms"]["mean"], 10)
        self.assertEqual(result["cpu_wait_ms"]["mean"], 6)
        self.assertIsNone(result["model_call_ms"])

    def test_parse_prefixed_native_trace(self):
        events = profile.parse_events('ordinary mpv log\n[iive-rife] IIVE_PROFILE {"event":"job","stage":"rife"}\n')
        self.assertEqual(events, [{"event": "job", "stage": "rife"}])
        with self.assertRaises(ValueError):
            profile.parse_events('IIVE_PROFILE {invalid}')


    def test_describe_player_metrics_filters_inactive_and_redacts_paths(self):
        import json
        import tempfile
        samples = [
            {
                "playback-phase": "warming-play",
                "media-loaded": True,
                "seeking": False,
                "path": "/Users/secret/Movies/private_clip.mkv",
                "render-callback-fps": 12.0,
                "process-memory-bytes": 100_000_000,
            },
            {
                "playback-phase": "playing",
                "media-loaded": True,
                "seeking": False,
                "enhancement-warming": False,
                "media-id": "media-1234567890abcdef",
                "hwdec": "videotoolbox-copy",
                "hwdec-current": "videotoolbox-copy",
                "video-codec": "hevc",
                "container-fps": 23.976,
                "estimated-vf-fps": 47.952,
                "render-callback-fps": 47.8,
                "avsync": 0.004,
                "frame-drop-count": 2,
                "decoder-frame-drop-count": 0,
                "viewport-width": 1920,
                "viewport-height": 1080,
                "video-params": {"w": 1920, "h": 1080, "pixelformat": "nv12"},
                "video-out-params": {"w": 3840, "h": 2160, "pixelformat": "nv12"},
                "vf": [{"label": "iive-rife", "name": "iive-rife", "enabled": True, "params": {"fps": "48", "tier": "fast"}}],
                "vo-passes": ["IIVE FSRCNNX 8 / aggregation"],
                "process-cpu-percent": 42.5,
                "process-memory-bytes": 320_000_000,
                "process-peak-sampled-footprint-bytes": 350_000_000,
                "process-resident-bytes": 280_000_000,
                "render-timing": {"samples": 60, "draw_p50_ms": 1.1, "draw_p95_ms": 2.4, "swap_p50_ms": 0.3, "swap_p95_ms": 0.9},
                "iive-rife": {
                    "state": "active", "input_surface": "shared-iosurface", "prefetch_mode": "default",
                    "prefetch_limit": "2", "pair_budget_ms": "41.708", "queued": "1", "ready_peak": "3",
                    "p50_processing_ms": "14.2", "p95_processing_ms": "19.8",
                    "p95_dispatch_ms": "0.02", "p95_ready_ms": "6.1", "p95_backpressure_ms": "0.01",
                    "fallback": "no"
                },
                "iive-sr": None,
                "iive-fi": None,
            },
            {
                "playback-phase": "paused",
                "media-loaded": True,
                "seeking": False,
                "render-callback-fps": 1.0,
                "process-memory-bytes": 900_000_000,
            },
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as tmp:
            for item in samples:
                tmp.write(json.dumps(item) + "\n")
            tmp_path = Path(tmp.name)
        try:
            summary = profile.describe_player_metrics(tmp_path)
            self.assertEqual(summary["total_snapshots"], 3)
            self.assertEqual(summary["active_snapshots"], 1)
            self.assertIsNone(summary["display_fps"])
            self.assertEqual(summary["decoder"]["active"], "videotoolbox-copy")
            self.assertEqual(summary["resolution"]["source"]["w"], 1920)
            self.assertEqual(summary["resolution"]["output"]["w"], 3840)
            self.assertEqual(summary["queues"]["iive-rife"]["prefetch_limit"], "2")
            self.assertEqual(summary["peak_sampled_footprint_bytes"], 350_000_000)
            serialized = json.dumps(summary)
            self.assertNotIn("private_clip.mkv", serialized)
            self.assertNotIn("/Users/secret", serialized)
        finally:
            tmp_path.unlink(missing_ok=True)

if __name__ == "__main__":
    unittest.main()

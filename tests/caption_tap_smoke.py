#!/usr/bin/env python3
"""Two-second synthetic PCM side-tap check; no window, sound, ASR or model download."""
import array
import base64
import json
import math
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import wave

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="iive-caption-") as directory:
    directory = Path(directory)
    source, endpoint = directory / "tone.wav", directory / "ipc"
    with wave.open(str(source), "wb") as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(48000)
        audio.writeframes(b"".join(struct.pack("<hh", *(2 * [int(8000 * math.sin(i * 2 * math.pi * 440 / 48000))])) for i in range(96000)))
    log_path = directory / "mpv.log"
    log = log_path.open("wb")
    process = subprocess.Popen([
        str(root / "build/mpv/mpv"), "--no-config", "--vo=null", "--ao=null",
        "--audio-display=no", "--idle=yes", "--keep-open=yes", "--pause=yes",
        "--af=@iive-captions:iive-captions", f"--input-ipc-server={endpoint}", str(source),
    ], stdout=log, stderr=log)
    client = socket.socket(socket.AF_UNIX)
    try:
        deadline = time.monotonic() + 5
        while not endpoint.exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("mpv failed to initialize: " + log_path.read_text())
            time.sleep(0.03)
        client.connect(str(endpoint)); client.settimeout(3)
        reader = client.makefile("rb")
        sequence = 0
        def command(*args):
            global sequence
            sequence += 1
            client.sendall((json.dumps({"command": args, "request_id": sequence}) + "\n").encode())
            while True:
                response = json.loads(reader.readline())
                if response.get("request_id") == sequence:
                    return response
        deadline = time.monotonic() + 5
        while command("get_property", "audio-params").get("error") != "success":
            assert time.monotonic() < deadline, "audio did not initialize"
            time.sleep(0.03)
        command("set_property", "pause", False)
        samples, packets, end = 0, 0, None
        finished = False
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            response = command("get_property", "af-metadata/iive-captions")
            meta = response.get("data", {})
            if "pcm" in meta:
                pcm = array.array("f", base64.b64decode(meta["pcm"]))
                pts = float(meta["pts"])
                assert command("af-command", "iive-captions", "ack", f"{meta['serial']}:{meta['samples']}")["error"] == "success"
                assert 0 < len(pcm) <= 32000 and all(math.isfinite(v) for v in pcm)
                assert any(abs(v) > 0.01 for v in pcm), "silent or invalid downmix"
                assert end is None or abs(pts - end) < 0.001, (pts, end)
                assert int(meta["dropped"]) == 0
                end = pts + len(pcm) / 16000
                samples += len(pcm); packets += 1
            if meta.get("state") == "finished":
                finished = True
                break
            time.sleep(0.1)
        assert finished and 31980 <= samples <= 32020, (finished, samples)
        print(json.dumps({"test": "synthetic_pcm_tap", "samples": samples, "packets": packets,
                          "sample_rate": 16000, "pts_contiguous": True, "finished": finished,
                          "speech_model_run": False, "gui_or_audio_output": False}))
    finally:
        client.close(); log.close()
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()

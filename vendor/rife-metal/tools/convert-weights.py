#!/usr/bin/env python3
"""
Converts audited Practical-RIFE v4.26 / v4.25-lite checkpoints into .rmw.

Source download (one-time setup):
    python3 -m venv /tmp/gdown-venv && /tmp/gdown-venv/bin/pip install gdown
    /tmp/gdown-venv/bin/gdown 1gViYvvQrtETBgU1w8axZSsr7YUuw31uy
    unzip RIFEv4.26_0921.zip
    cp -r train_log/* third_party/Practical-RIFE/train_log/

Usage:
    python3 tools/convert-weights.py \\
        --pytorch-checkpoint third_party/Practical-RIFE/train_log/flownet.pkl \\
        --out Sources/RifeMetal/Resources/rife-v4.26.rmw

Architecture (v4.26):
    - v4.26: channels [192, 128, 96, 64, 32], scales [16, 8, 4, 2, 1]
    - v4.25-lite: channels [192, 128, 96, 64, 24], scales [32, 16, 8, 4, 1]
    - Both overwrite the mask at each stage; only flow accumulates
    - scale_list = [16, 8, 4, 2, 1]
    - Encoder Head: 3 → 4 ch (cnn0..cnn3)
    - Each ResConv has weight + bias + beta (per-channel learnable scale)
    - lastconv emits 4*13 = 52 channels (PixelShuffle r=2 → 13 ch: 4 flow + 1 mask + 8 feat)
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import torch

from _rmw_format import write_rmw


_V4_26 = {
    "ifblock_channels": [192, 128, 96, 64, 32],
    "scale_list":       [16, 8, 4, 2, 1],
}

_PROFILES = {
    "rife-v4.26": _V4_26,
    # Official RIFE_HDv3.py inference(), not IFNet.forward's stale default.
    "rife-v4.25-lite": {"ifblock_channels": [192, 128, 96, 64, 24],
                        "scale_list": [32, 16, 8, 4, 1]},
}

# in_channels for conv0's first layer per IFBlock.
# block0: 15 (3+3 imgs + 4+4 encoded feats + 1 timestep — no prev_flow yet)
# block1..4: 28 (3+3 imgs + 4+4 encoded feats + 1 timestep + 1 mask + 8 feat + 4 prev_flow)
# Verified against actual flownet.pkl shapes via tools/dump-pkl-keys.py.
_BLOCK_IN_CH = [15, 28, 28, 28, 28]


def _require(state, key, expected_shape):
    if key not in state:
        raise KeyError(f"missing key {key!r}")
    actual = tuple(state[key].shape)
    if actual != expected_shape:
        raise ValueError(
            f"shape mismatch for {key!r} — expected {expected_shape}, got {actual}"
        )
    return state[key]


def _to_rmw_array(tensor, name):
    """Convert a PyTorch tensor to a numpy array in the layout write_rmw expects.

    4D tensors are special-cased by name:
      - ResConv `*.beta`: PyTorch shape [1, c, 1, 1]. Reshaped to [1, 1, 1, c] so the
        Swift IFBlockBuilder gets a canonical NHWC broadcast shape with no runtime fix-up.
      - Conv / ConvTranspose weights: PyTorch shape (O, I, kH, kW). Permuted to HWIO
        (kH, kW, I, O), which is the layout MPSGraph requires.
    All other tensors (1D biases, etc.) are left as-is.
    """
    arr = tensor.detach().cpu().numpy().astype(np.float32)
    if arr.ndim == 4:
        if name.endswith(".beta"):
            arr = arr.reshape(1, 1, 1, -1)
        else:
            arr = np.transpose(arr, (2, 3, 1, 0))  # OIHW → HWIO
    if not np.isfinite(arr).all() or (np.abs(arr) > np.finfo(np.float16).max).any():
        raise ValueError(f"non-finite or out-of-fp16-range weights: {name}")
    return arr


def _collect_tensors(state, model="rife-v4.26"):
    """Extract and validate all 158 tensors for rife-v4.26.

    Returns (list_of_(name, ndarray), list_of_error_strings).
    errors is non-empty if any key is missing or has an unexpected shape.
    """
    tensors = []
    errors = []

    def add(name, expected_shape):
        try:
            t = _require(state, name, expected_shape)
            arr = _to_rmw_array(t, name)
            tensors.append((name, arr))
        except (KeyError, ValueError) as e:
            errors.append(str(e))

    # Encoder Head (8 tensors)
    add("encode.cnn0.weight", (16,  3, 3, 3))
    add("encode.cnn0.bias",   (16,))
    add("encode.cnn1.weight", (16, 16, 3, 3))
    add("encode.cnn1.bias",   (16,))
    add("encode.cnn2.weight", (16, 16, 3, 3))
    add("encode.cnn2.bias",   (16,))
    add("encode.cnn3.weight", (16,  4, 4, 4))
    add("encode.cnn3.bias",   (4,))

    # Per-block tensors: 5 blocks × 30 tensors each = 150 tensors
    for i, c in enumerate(_PROFILES[model]["ifblock_channels"]):
        in_ch = _BLOCK_IN_CH[i]

        # conv0: two-layer nn.Sequential; each layer is itself nn.Sequential([Conv2d, LeakyReLU]).
        # Triple-nested key path: conv0.{outer_idx}.{inner_idx=0 for Conv2d}.{weight|bias}
        # Verified via tools/dump-pkl-keys.py (Task 1).
        add(f"block{i}.conv0.0.0.weight", (c // 2, in_ch, 3, 3))
        add(f"block{i}.conv0.0.0.bias",   (c // 2,))
        add(f"block{i}.conv0.1.0.weight", (c, c // 2, 3, 3))
        add(f"block{i}.conv0.1.0.bias",   (c,))

        # convblock: 8 × ResConv, each with conv.weight + conv.bias + beta (4 tensors each = 24)
        for j in range(8):
            add(f"block{i}.convblock.{j}.conv.weight", (c, c, 3, 3))
            add(f"block{i}.convblock.{j}.conv.bias",   (c,))
            add(f"block{i}.convblock.{j}.beta",        (1, c, 1, 1))

        # lastconv: ConvTranspose2d(c → 4*13=52) + PixelShuffle(2).
        # PyTorch ConvTranspose2d weight shape: [in_channels, out_channels, kH, kW].
        # PixelShuffle is parameterless; only index 0 has parameters.
        add(f"block{i}.lastconv.0.weight", (c, 4 * 13, 4, 4))
        add(f"block{i}.lastconv.0.bias",   (4 * 13,))

    expected_names = {name for name, _ in tensors}
    if not errors:
        # Official archives retain training-only teacher/timestep branches;
        # the audited IFNet inference source does not invoke either branch.
        extras = {key for key in state if key not in expected_names
                  and not key.startswith(("teacher.", "caltime."))}
        if extras:
            errors.append("unexpected tensor keys: " + ", ".join(sorted(extras)))
    return tensors, errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pytorch-checkpoint", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--model", choices=sorted(_PROFILES), default="rife-v4.26")
    args = parser.parse_args()

    if not args.pytorch_checkpoint.exists():
        print(f"checkpoint not found: {args.pytorch_checkpoint}", file=sys.stderr)
        print("see this script's docstring for download instructions.", file=sys.stderr)
        return 2

    state = torch.load(args.pytorch_checkpoint, map_location="cpu", weights_only=True)
    if isinstance(state, dict) and "state_dict" in state:
        state = state["state_dict"]
    state = {k.removeprefix("module."): v for k, v in state.items()}

    tensors, errors = _collect_tensors(state, args.model)
    if errors:
        print(f"convert-weights: {len(errors)} schema error(s):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 3

    write_rmw(
        out_path=args.out,
        model=args.model,
        ifblock_channels=_PROFILES[args.model]["ifblock_channels"],
        scale_list=_PROFILES[args.model]["scale_list"],
        tensors=tensors,
    )
    print(f"wrote {args.out} ({len(tensors)} tensors)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

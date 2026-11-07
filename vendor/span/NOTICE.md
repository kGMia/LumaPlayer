# SPAN inference reference

Source: https://github.com/hongyuanyu/SPAN at `c77a5917759f09e66fbc7124220c5afc5ee221e5`.
Authors: Cheng Wan, Hongyuan Yu, Zhiqi Li, Yihang Chen, Yajun Zou, Yuqing Liu, Xuanwu Yin, Kunlong Zuo; BasicSR Authors 2018–2022.
License: Apache-2.0, included as `LICENSE.txt`.

`span_arch.py` removes only the BasicSR registry dependency/decorator and CUDA demo. Conversion fuses the official Conv3XC branches once, preserves in-place SiLU feature semantics, and checks output agreement. No training or archive scripts are run.

Checkpoint: official README's Google Drive `span.zip`, member `spanx2_ch48.pth`, `params_ema`; SHA-256 `561fd5cf419a23d4de1231ce258180f61aee4aa8caa1aaaa783769c7301847bc`. The associated official test log specifies 48 features, x2, mean `[0.4488,0.4371,0.4040]`, input range 255. Weights remain external experimental artifacts, not included in the player release. Repository declares Apache-2.0; the archive has no separate weight license statement.

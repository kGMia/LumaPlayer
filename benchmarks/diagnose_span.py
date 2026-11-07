#!/usr/bin/env python3
"""Small, bounded SPAN layer probes. CPU_ONLY tensors; not performance telemetry."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--precision', choices=['fp32','fp16','mixed-attention'], default='fp32')
    parser.add_argument('--size', type=int, default=128)
    parser.add_argument('--case', choices=['constant','ramp','noise','real_image'], default='noise')
    parser.add_argument('--image', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 8 <= args.size <= 128 or args.output.exists():
        parser.error('Use size 8..128 and a NEW output file')
    import torch
    import numpy as np
    import coremltools as ct
    from span_coreml_model import load_fused, compute_precision, check_toolchain, parity_cases, CHECKPOINT_SHA256
    check_toolchain(torch, ct)
    torch.set_num_threads(4)
    model, fusion_error = load_fused(ROOT/'.research/span/spanx2_ch48.pth')
    names = ['stem','block1','block2','block3','block4','block5','block6','conv2','concat_conv','raw_output','clipped_rgb']
    class Probes(torch.nn.Module):
        def __init__(self):
            super().__init__(); self.network = model
        def forward(self, pixels):
            m = self.network
            a = m.conv_1((pixels/255.0-m.mean)*m.img_range)
            b1,_,_ = m.block_1(a)
            b2,_,_ = m.block_2(b1)
            b3,_,_ = m.block_3(b2)
            b4,_,_ = m.block_4(b3)
            b5,_,_ = m.block_5(b4)
            b6,first,_ = m.block_6(b5)
            c = m.conv_2(b6)
            d = m.conv_cat(torch.cat([a,c,b1,first],1))
            output = m.upsampler(d)
            return a,b1,b2,b3,b4,b5,b6,c,d,output,output.clamp(0,1)*255
    cases = parity_cases(args.size,args.size,args.image)
    if args.case not in cases:
        parser.error('real_image requires --image of exact size')
    pixels = cases[args.case]
    x = torch.from_numpy(pixels.copy()).permute(2,0,1)[None].float()
    probes = Probes().eval()
    with torch.inference_mode():
        expected = probes(x)
        probe_error = (expected[-2]-model(x/255)).abs().max().item()
        if probe_error > 1e-5:
            raise ValueError('Probe topology differs from original model')
        traced = torch.jit.trace(probes,x)
    converted = ct.convert(traced, inputs=[ct.TensorType(name='pixels',shape=x.shape)],
        outputs=[ct.TensorType(name=name) for name in names], minimum_deployment_target=ct.target.macOS15,
        compute_precision=compute_precision(ct,args.precision), compute_units=ct.ComputeUnit.CPU_ONLY)
    actual = converted.predict({'pixels':x.numpy()})
    layers = {}
    for name, reference in zip(names, expected):
        ref = reference.numpy(); value = actual[name]; difference = np.abs(value-ref)
        finite = bool(np.isfinite(ref).all() and np.isfinite(value).all())
        layers[name] = {'finite':finite,'reference_abs_max':float(np.abs(ref).max()),
            'mae':float(difference.mean()) if finite else None,
            'max_error':float(difference.max()) if finite else None,
            'rmse':float(np.sqrt((difference*difference).mean())) if finite else None}
    result = {'precision':args.precision,'case':args.case,'size':args.size,'torch':torch.__version__,
        'coremltools':ct.__version__,'checkpoint_sha256':CHECKPOINT_SHA256,
        'input_rgb_sha256':hashlib.sha256(pixels.tobytes()).hexdigest(),
        'fusion_max_error':fusion_error,'probe_topology_max_error':probe_error,'layers':layers,
        'note':'Diagnostic tensor outputs can change optimization/fusion. CPU_ONLY, no image quantization or playback performance claim. Errors before clipped_rgb are model feature units, not RGB code values.'}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n')
    print(args.output)

if __name__ == '__main__':
    main()

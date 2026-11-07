#!/usr/bin/env python3
"""Audited SPAN x2 -> fixed-size Core ML image model, with parity gates.
Requires PyTorch, NumPy, Pillow, coremltools. Never imports downloaded archive code.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'vendor/span'))
SHA256 = '561fd5cf419a23d4de1231ce258180f61aee4aa8caa1aaaa783769c7301847bc'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path, default=ROOT/'.research/span/spanx2_ch48.pth')
    parser.add_argument('--width', type=int, default=128)
    parser.add_argument('--height', type=int, default=128)
    parser.add_argument('--precision', choices=['fp32', 'fp16', 'mixed-attention'], default='fp32')
    parser.add_argument('--parity-image', type=Path, help='Optional same-sized RGB8 SDR fixture; adds to, never replaces, pressure cases')
    parser.add_argument('--allow-parity-risk', action='store_true',
                        help='Export diagnostic-only models despite numeric discrepancies; never player-ready')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if any(n < 8 or n > 1920 or n % 2 for n in (args.width, args.height)):
        parser.error('Use even dimensions from 8 to 1920')
    if any(path.exists() for path in (args.output,args.output.with_suffix('.json'),args.output.with_suffix('.validation.json'))) or args.output.suffix != '.mlpackage':
        parser.error('Output must be a NEW .mlpackage directory')
    if hashlib.sha256(args.checkpoint.read_bytes()).hexdigest() != SHA256:
        parser.error('Unrecognized checkpoint checksum')
    import torch
    import numpy as np
    import coremltools as ct
    from PIL import Image
    from span_coreml_model import load_fused, ImageModel, compute_precision, check_toolchain, parity_cases
    check_toolchain(torch, ct)
    torch.set_num_threads(4)
    torch.manual_seed(24)
    fused, error = load_fused(args.checkpoint)
    wrapper = ImageModel(fused).eval()
    # Fixed dimensions encourage specialization. No per-frame compilation.
    with torch.inference_mode():
        example = torch.rand(1, 3, args.height, args.width) * 255
        traced = torch.jit.trace(wrapper, example)
    converted = ct.convert(traced, convert_to='mlprogram',
        inputs=[ct.ImageType(name='image', shape=example.shape, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name='upscaled', color_layout=ct.colorlayout.RGB)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=compute_precision(ct, args.precision),
        skip_model_load=True)
    converted.author = 'SPAN authors; IIVE Core ML conversion'
    converted.license = 'Apache-2.0; see vendor/span/LICENSE.txt'
    converted.short_description = 'Experimental SPAN x2 / 48 features / SDR RGB8'
    converted.user_defined_metadata['iive.contract'] = 'span-x2-rgb8-sdr-v1'
    converted.user_defined_metadata['iive.source_sha256'] = SHA256
    converted.user_defined_metadata['iive.precision'] = args.precision
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = tempfile.TemporaryDirectory(prefix='span-export-', dir=args.output.parent)
    staged = Path(temporary.name) / 'model.mlpackage'
    converted.save(str(staged))
    # Small models receive a true Core ML vs PyTorch image-I/O parity check.
    # Large exports leave parity null; do not label them verified implicitly.
    parity = None
    if args.width * args.height <= 256 * 256:
        model = ct.models.MLModel(str(staged), compute_units=ct.ComputeUnit.CPU_ONLY)
        cases = {}
        for name, pixels in parity_cases(args.width,args.height,args.parity_image).items():
            with torch.inference_mode():
                reference = wrapper(torch.from_numpy(pixels.copy()).permute(2,0,1)[None].float())[0].permute(1,2,0).numpy()
            image = model.predict({'image':Image.fromarray(pixels)})['upscaled']
            actual = np.asarray(image.convert('RGB')).astype(np.float32)
            difference = np.abs(actual-reference)
            finite = bool(np.isfinite(actual).all() and np.isfinite(reference).all())
            case = {'finite':finite,'mae_code_values':float(difference.mean()) if finite else None,
                    'max_code_values':float(difference.max()) if finite else None,
                    'rmse_code_values':float(np.sqrt((difference*difference).mean())) if finite else None,
                    'input_rgb_sha256':hashlib.sha256(pixels.tobytes()).hexdigest()}
            case['passed'] = bool(finite and case['mae_code_values'] <= 1
                                  and case['rmse_code_values'] <= 1 and case['max_code_values'] <= 8)
            cases[name] = case
        parity = {'backend':'Core ML CPU_ONLY; image quantization included',
                  'gate':'Every case: MAE <= 1, RMSE <= 1, maximum <= 8 code values',
                  'cases':cases, 'passed':all(case['passed'] for case in cases.values())}
    # Keep evidence even when publication is refused. This sidecar never claims
    # model validation or successful export simply because conversion completed.
    validation_report = {'torch':torch.__version__,'coremltools':ct.__version__,
        'precision':args.precision,'width':args.width,'height':args.height,
        'checkpoint_sha256':SHA256,'fusion_max_error':error,'coreml_parity':parity,
        'diagnostic_override':args.allow_parity_risk}
    args.output.with_suffix('.validation.json').write_text(json.dumps(validation_report,indent=2,allow_nan=False)+'\n')
    if parity and not parity['passed'] and not args.allow_parity_risk:
        raise ValueError('Core ML image parity failed; see .validation.json. No model published.')
    if parity is None and not args.allow_parity_risk:
        raise ValueError('Large-shape parity not checked; use --allow-parity-risk only for diagnostic exports')
    validation = 'passed_small_parity' if parity and parity['passed'] else 'unvalidated_numeric_risk'
    converted.user_defined_metadata['iive.validation'] = validation
    converted.save(str(staged))
    files = {str(p.relative_to(staged)):hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(staged.rglob('*')) if p.is_file()}
    manifest = {'model':'SPAN x2 ch48 params_ema','status':'experimental; not player integrated',
        'validation':validation,
        'source_commit':'c77a5917759f09e66fbc7124220c5afc5ee221e5','checkpoint_sha256':SHA256,
        'architecture_sha256':hashlib.sha256((ROOT/'vendor/span/span_arch.py').read_bytes()).hexdigest(),
        'conversion_helper_sha256':hashlib.sha256((ROOT/'scripts/span_coreml_model.py').read_bytes()).hexdigest(),
        'torch':torch.__version__,'coremltools':ct.__version__,'width':args.width,'height':args.height,
        'precision':args.precision,'fusion_max_error':error,'coreml_parity':parity,'files_sha256':files,
        'note':'computeUnits is permission, not measured accelerator utilization; large shapes require separate checks'}
    staged.rename(args.output)
    temporary.cleanup()
    args.output.with_suffix('.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(args.output)

if __name__ == '__main__':
    main()

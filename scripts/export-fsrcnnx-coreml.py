#!/usr/bin/env python3
"""FSRCNNX native weights -> Core ML grayscale x2. Experimental, never changes player assets."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HASHES = {8:'97db353764d9e474e649e56a79be42bfedcb0faa7b5026ce00875a9d3fa064fa',
          16:'cbf910c7320d21510414bb66f287b7e50492b0f38d1de94fbd1a79c46fd43247'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tier',type=int,choices=[8,16],default=8)
    parser.add_argument('--width',type=int,default=128)
    parser.add_argument('--height',type=int,default=128)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    if any(n < 8 or n > 1920 or n%2 for n in (args.width,args.height)):
        parser.error('Use even dimensions 8..1920')
    if args.output.suffix != '.mlpackage' or any(p.exists() for p in [args.output,args.output.with_suffix('.json')]):
        parser.error('Use a NEW .mlpackage path')
    import torch
    import numpy as np
    import coremltools as ct
    from PIL import Image
    if torch.__version__.split('+')[0]!='2.7.0' or ct.__version__!='9.0':
        parser.error('Use scripts/setup-span-toolchain.sh: torch 2.7.0 and coremltools 9.0')
    torch.set_num_threads(4)
    source=ROOT/f'native/FSRCNNXMetal/Sources/FSRCNNXMetal/Resources/fsrcnnx{args.tier}.json'
    digest=hashlib.sha256(source.read_bytes()).hexdigest()
    if digest!=HASHES[args.tier]: raise ValueError('Native weight JSON checksum mismatch')
    weights=json.loads(source.read_text())
    if weights['layout']!='HWIO' or weights['subpixelOrder']!='x*2+y' or len(weights['layers'])!=7:
        raise ValueError('Unrecognized FSRCNNX layout')

    class Layer(torch.nn.Module):
        def __init__(self, layer):
            super().__init__()
            ky,kx,ci,co=layer['shape']
            # Match the existing MPSGraph constants (FP16 weights/bias/PReLU).
            def half_constant(values):
                t=torch.tensor(values,dtype=torch.float32)
                if not t.isfinite().all(): raise ValueError('Nonfinite weight')
                t=t.half().float()
                if not t.isfinite().all(): raise ValueError('FP16 weight overflow')
                return t
            self.register_buffer('weight',half_constant(layer['weights']).reshape(ky,kx,ci,co).permute(3,2,0,1).contiguous())
            self.register_buffer('bias',half_constant(layer['bias']))
            self.register_buffer('alpha',half_constant(layer['alpha']).reshape(1,-1,1,1))
            self.radius=ky//2;self.has_alpha=bool(layer['alpha'])
        def forward(self, value, skip=None):
            if self.radius:
                value=torch.nn.functional.pad(value,(self.radius,)*4,mode='replicate')
            value=torch.nn.functional.conv2d(value,self.weight,self.bias)
            if skip is not None: value=value+skip
            if self.has_alpha: value=value.clamp(min=0)+self.alpha*value.clamp(max=0)
            return value

    class Model(torch.nn.Module):
        def __init__(self):
            super().__init__();self.layers=torch.nn.ModuleList([Layer(l) for l in weights['layers']])
        def forward(self, pixels):
            values={'input':pixels/255.0}
            for layer, spec in zip(self.layers,weights['layers']):
                values[spec['name']]=layer(values[spec['input']],values.get(spec['skip']))
            # FSRCNNX uses x*2+y channels, PyTorch uses y*2+x.
            value=values['stage6'][:,[0,2,1,3],:,:]
            return torch.nn.functional.pixel_shuffle(value,2).clamp(0,1)*255.0

    model=Model().eval()
    example=torch.zeros(1,1,args.height,args.width)
    with torch.inference_mode(): traced=torch.jit.trace(model,example)
    converted=ct.convert(traced,convert_to='mlprogram',
        inputs=[ct.ImageType(name='luma',shape=example.shape,color_layout=ct.colorlayout.GRAYSCALE)],
        outputs=[ct.ImageType(name='upscaled',color_layout=ct.colorlayout.GRAYSCALE)],
        compute_precision=ct.precision.FLOAT16,minimum_deployment_target=ct.target.macOS15,skip_model_load=True)
    converted.author='igv; IIVE Core ML conversion'
    converted.license='LGPL-3.0-or-later; Copyright (C) 2017-2021 igv'
    converted.user_defined_metadata.update({'iive.contract':'fsrcnnx-x2-gray8-v1','iive.tier':str(args.tier),
        'iive.weights_sha256':digest,'iive.precision':'fp16','iive.range':'raw 8-bit Y code values; no limited/full-range remap'})
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='fsr-export-',dir=args.output.parent) as temp:
        staged=Path(temp)/'model.mlpackage';converted.save(str(staged))
        parity={}
        # Small exports receive CPU parity checks. Larger shapes remain explicitly
        # unvalidated until the native comparison tool is run at that shape.
        if args.width*args.height<=256*256:
            test_model=ct.models.MLModel(str(staged),compute_units=ct.ComputeUnit.CPU_ONLY)
            h,w=args.height,args.width
            cases={'constant':np.full((h,w),128,dtype=np.uint8),
                   'ramp':np.broadcast_to(np.linspace(0,255,w,dtype=np.uint8),(h,w)).copy(),
                   'noise':np.random.default_rng(25).integers(0,256,(h,w),dtype=np.uint8)}
            edge=np.zeros((h,w),dtype=np.uint8);edge[h//2:,w//2:]=255;cases['edge']=edge
            for name,pixels in cases.items():
                with torch.inference_mode(): ref=model(torch.from_numpy(pixels.copy())[None,None].float())[0,0].numpy()
                actual=np.asarray(test_model.predict({'luma':Image.fromarray(pixels)})['upscaled']).astype(np.float32)
                if actual.shape!=ref.shape: raise ValueError('Grayscale output shape mismatch')
                d=np.abs(actual-ref);finite=bool(np.isfinite(actual).all() and np.isfinite(ref).all())
                parity[name]={'mae':float(d.mean()) if finite else None,'max':float(d.max()) if finite else None,
                              'rmse':float(np.sqrt((d*d).mean())) if finite else None}
                parity[name]['passed']=finite and parity[name]['mae']<=1 and parity[name]['rmse']<=1 and parity[name]['max']<=8
            if not all(p['passed'] for p in parity.values()): raise ValueError(f'Parity failed: {parity}')
        validation='passed_small_cpu_parity' if parity else 'shape_unvalidated'
        converted.user_defined_metadata['iive.validation']=validation
        converted.save(str(staged))
        manifest={'model':f'FSRCNNX{args.tier}','status':'experimental; not player integrated','width':args.width,'height':args.height,
            'torch':torch.__version__,'coremltools':ct.__version__,'weights_json_sha256':digest,'shader_sha256':weights['sha256'],
            'validation':validation,'cpu_parity':parity,'precision':'fp16','subpixel_mapping':'native x*2+y -> pixel_shuffle [0,2,1,3]',
            'files_sha256':{str(p.relative_to(staged)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(staged.rglob('*')) if p.is_file()},
            'note':'CPU image-I/O parity only; native MPSGraph/Neural Engine and large shapes require separate checks.'}
        staged.rename(args.output)
    args.output.with_suffix('.json').write_text(json.dumps(manifest,indent=2,allow_nan=False)+'\n')
    print(args.output)

if __name__=='__main__':main()

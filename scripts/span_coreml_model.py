"""Shared audited SPAN construction for conversion and layer diagnostics."""
import copy
import hashlib
from pathlib import Path
import sys
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'vendor/span'))
from span_arch import SPAN, Conv3XC

CHECKPOINT_SHA256 = '561fd5cf419a23d4de1231ce258180f61aee4aa8caa1aaaa783769c7301847bc'

def load_fused(checkpoint):
    if hashlib.sha256(Path(checkpoint).read_bytes()).hexdigest() != CHECKPOINT_SHA256:
        raise ValueError('Unrecognized checkpoint checksum')
    original = SPAN(3, 3, feature_channels=48, upscale=2).eval()
    state = torch.load(checkpoint, map_location='cpu', weights_only=True)['params_ema']
    if any(not torch.isfinite(v).all() for v in state.values()):
        raise ValueError('Nonfinite weights')
    original.load_state_dict(state, strict=True)
    fused = copy.deepcopy(original)
    def visit(parent):
        for name, child in list(parent.named_children()):
            if isinstance(child, Conv3XC):
                child.update_params()
                setattr(parent, name, copy.deepcopy(child.eval_conv))
            else:
                visit(child)
    visit(fused)
    generator = torch.Generator().manual_seed(24)
    with torch.inference_mode():
        test = torch.rand(1, 3, 17, 19, generator=generator)
        error = (original(test)-fused(test)).abs().max().item()
    if error > 1e-5:
        raise ValueError(f'Convolution fusion mismatch: {error}')
    return fused, error

class ImageModel(torch.nn.Module):
    def __init__(self, network):
        super().__init__(); self.network = network
    def forward(self, pixels):
        # The official output is already RGB [0,1], despite its internal 255 range.
        return torch.clamp(self.network(pixels/255.0), 0, 1)*255.0

def compute_precision(ct, name):
    if name == 'fp32':
        return ct.precision.FLOAT32
    if name == 'fp16':
        return ct.precision.FLOAT16
    if name == 'mixed-attention':
        # Convolutions may use FP16; preserve cancellation-sensitive attention,
        # residual arithmetic and nonlinearities in FP32. Still requires parity.
        return ct.transform.FP16ComputePrecision(
            op_selector=lambda op: op.op_type in {'conv', 'concat', 'reshape', 'transpose', 'depth_to_space'})
    raise ValueError('Unknown precision profile')

def check_toolchain(torch, ct):
    if torch.__version__.split('+')[0] != '2.7.0' or ct.__version__ != '9.0':
        raise ValueError('Use the pinned torch 2.7.0 / coremltools 9.0 conversion environment; see native/SPANCoreML/requirements-conversion.txt')

def parity_cases(width, height, image_path=None):
    import numpy as np
    from PIL import Image
    cases = {'constant':np.full((height,width,3),128,dtype=np.uint8)}
    ramp = np.broadcast_to(np.linspace(0,255,width,dtype=np.uint8)[None,:,None],(height,width,3)).copy()
    cases['ramp'] = ramp
    cases['noise'] = np.random.default_rng(24).integers(0,256,(height,width,3),dtype=np.uint8)
    if image_path:
        with Image.open(image_path) as image:
            if image.size != (width,height) or image.mode != 'RGB':
                raise ValueError('Parity image must be RGB8 at the exact input dimensions')
            cases['real_image'] = np.asarray(image).copy()
    return cases

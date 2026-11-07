#!/usr/bin/env python3
"""Create a small, reproducible SDR SR reference/input pair; never changes source media."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--time', type=float, default=60)
    parser.add_argument('--crop', type=int, default=256)
    parser.add_argument('--assume-bt709-sdr', action='store_true', required=True,
                        help='Explicit test-copy color assumption; do not use HDR sources')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.source.is_file() or not math.isfinite(args.time) or args.time < 0 or not 16 <= args.crop <= 2048 or args.crop % 4:
        parser.error('Need local media, finite time >= 0, crop 16..2048 divisible by 4')
    if args.output.exists():
        parser.error('Use a NEW output directory')
    from PIL import Image, ImageCms
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        parser.error('FFmpeg is required')
    args.output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='span-fixture-') as directory:
        frame = Path(directory)/'frame.png'
        filters = f'crop={args.crop}:{args.crop},colorspace=iall=bt709:all=bt709:trc=iec61966-2-1:format=yuv444p,format=rgb24'
        subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-ss',str(args.time),'-i',str(args.source),
                        '-frames:v','1','-vf',filters,'-n',str(frame)],check=True)
        with Image.open(frame) as decoded:
            image = decoded.convert('RGB')
        icc = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
        image.save(args.output/'reference.png',icc_profile=icc)
        image.resize((args.crop//2,args.crop//2),Image.Resampling.BICUBIC).save(args.output/'input.png',icc_profile=icc)
    def digest(path):
        with path.open('rb') as file:
            return hashlib.file_digest(file,'sha256').hexdigest()
    manifest = {'source_sha256':digest(args.source),'time_s':args.time,'center_crop':args.crop,
        'color_assumption':'BT.709 SDR source, explicitly converted to sRGB on a NEW test copy; not HDR validation',
        'degradation':'Pillow bicubic downsample 2x; not a video compression/noise benchmark',
        'ffmpeg_filters':filters,'ffmpeg':subprocess.check_output([ffmpeg,'-version'],text=True).splitlines()[0],
        'pixel_rgb_sha256':{name:hashlib.sha256(Image.open(args.output/name).convert('RGB').tobytes()).hexdigest()
                            for name in ('reference.png','input.png')},
        'files_sha256':{name:digest(args.output/name) for name in ('reference.png','input.png')}}
    (args.output/'fixture.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(args.output)

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Strict importer for the two pinned igv shaders. Every operation must be recognized.
GLSL mat4 is column-major: coefficient index input_channel*4+output_channel.
Merges independent four-channel passes into seven NHWC/HWIO convolution stages.
"""
from pathlib import Path
import hashlib, json, re
ROOT = Path(__file__).resolve().parents[1]
NUM = r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?'
def values(s, n):
    result = [float(v) for v in s.split(',')]
    assert len(result) == n
    return result

def export(tier):
    path = ROOT / f'plugin/shaders/FSRCNNX_x2_{tier}-0-4-1.glsl'
    source = path.read_text()
    blocks = source.split('//!HOOK LUMA')[1:]
    parsed = []
    for b in blocks[:-1]:
        desc = re.search(r'//!DESC (.+)', b)[1]
        save = re.search(r'//!SAVE (\w+)', b)[1]
        binds = re.findall(r'//!BIND (\w+)', b)
        body = re.search(r'vec4 hook\(\)\s*\{(.*?)\}', b, re.S)[1]
        bias = None; alpha = None; skip = None; terms = []
        for line in body.strip().splitlines():
            line = line.strip()
            m = re.fullmatch(r'vec4 res = vec4\(([^)]+)\);', line)
            if m: bias = values(m[1], 4); continue
            m = re.fullmatch(r'res \+= vec4\(([^)]+)\) \* float\(LUMA_texOff\(vec2\((-?\d+),(-?\d+)\)\)\);', line)
            if m: terms.append(('LUMA', int(m[2]), int(m[3]), values(m[1], 4))); continue
            m = re.fullmatch(r'res \+= mat4(?:x4)?\(([^)]+)\) \* (\w+)_texOff\(vec2\((-?\d+),(-?\d+)\)\);', line)
            if m: terms.append((m[2], int(m[3]), int(m[4]), values(m[1],16))); continue
            m = re.fullmatch(r'res \+= mat4(?:x4)?\(([^)]+)\) \* (\w+)_texOff\(0\);', line)
            if m: terms.append((m[2], 0, 0, values(m[1],16))); continue
            m = re.fullmatch(r'res \+= (\w+)_texOff\(0\);', line)
            if m: assert skip is None; skip = m[1]; continue
            m = re.fullmatch(r'res = max\(res, vec4\(0.0\)\) \+ vec4\(([^)]+)\) \* min\(res, vec4\(0.0\)\);', line)
            if m: alpha = values(m[1],4); continue
            if line in ('return res;', 'return vec4(res);'): continue
            raise ValueError(f'Unsupported statement: {desc}: {line}')
        assert bias is not None and terms
        parsed.append(dict(desc=desc,save=save,binds=binds,bias=bias,alpha=alpha,skip=skip,terms=terms))
    # The final pass is pixel shuffle in x-major subpixel order, not the usual y-major order.
    final = re.search(r'vec4 hook\(\)\s*\{(.*?)\}', blocks[-1], re.S)[1]
    assert re.sub(r'\s+', '', final) == 'vec2fcoord=fract(SUBCONV1_pos*SUBCONV1_size);vec2base=SUBCONV1_pos+(vec2(0.5)-fcoord)*SUBCONV1_pt;ivec2index=ivec2(fcoord*vec2(2));vec4res=SUBCONV1_tex(base);returnvec4(res[index.x*2+index.y],0,0,1);'
    groups = tier//4
    assert len(parsed) == groups*6+1
    layers = []; available = {'LUMA': ('input',0,1)}
    for stage in range(7):
        passes = parsed[stage*groups:(stage+1)*groups] if stage < 6 else parsed[-1:]
        inputs = list(dict.fromkeys(t[0] for t in passes[0]['terms']))
        # All conv passes in a stage must consume the same complete ordered feature groups.
        assert all(list(dict.fromkeys(t[0] for t in p['terms'])) == inputs for p in passes)
        refs = [available[i] for i in inputs]
        assert len(set(r[0] for r in refs)) == 1
        cin = sum(r[2] for r in refs); cout = len(passes)*4
        assert [r[1] for r in refs] == list(range(0,cin,refs[0][2]))
        k = 5 if stage == 0 else 1 if stage == 5 else 3; radius = k//2
        weights = [0.0]*(k*k*cin*cout); seen=set(); bias=[]; alpha=[]
        for group,p in enumerate(passes):
            bias += p['bias']
            if p['alpha'] is not None: alpha += p['alpha']
            for name,x,y,vals in p['terms']:
                _,offset,channels = available[name]
                assert -radius<=x<=radius and -radius<=y<=radius
                assert (group,name,x,y) not in seen;seen.add((group,name,x,y))
                for ic in range(channels):
                    for oc in range(4):
                        index=(((y+radius)*k+x+radius)*cin+offset+ic)*cout+group*4+oc
                        weights[index]=vals[ic*4+oc]
        assert len(seen)==len(passes)*len(inputs)*k*k
        assert not alpha or len(alpha)==cout
        skip=None
        if stage==5:
            assert [p['skip'] for p in passes] == [f'FEATURE{i+1}' for i in range(groups)]
            skip='stage0'
        else: assert all(p['skip'] is None for p in passes)
        layers.append(dict(name=f'stage{stage}',input=refs[0][0],shape=[k,k,cin,cout],weights=weights,bias=bias,alpha=alpha,skip=skip))
        for i,p in enumerate(passes): available[p['save']] = (f'stage{stage}',i*4,4)
    data=dict(license='LGPL-3.0-or-later',copyright='Copyright (C) 2017-2021 igv',format=1,tier=tier,source=path.name,sha256=hashlib.sha256(source.encode()).hexdigest(),layout='HWIO',subpixelOrder='x*2+y',layers=layers)
    out=ROOT/f'native/FSRCNNXMetal/Sources/FSRCNNXMetal/Resources/fsrcnnx{tier}.json'
    text=json.dumps(data,separators=(',',':'))+'\n'
    if not out.exists() or out.read_text()!=text:out.write_text(text)
    print(f'{path.name}: {len(layers)} stages, {sum(len(x["weights"]) for x in layers)} trained weights')
if __name__=='__main__':
    for tier in (8,16): export(tier)

#!/usr/bin/env python3
"""Apply our build-time filter to a dedicated pinned mpv checkout only."""
import pathlib, subprocess, shutil, sys
root=pathlib.Path(__file__).resolve().parents[1]
src=pathlib.Path(sys.argv[1]).resolve()
expected='88eb9f2e73945d8bc9c133a2f67babaa9af34680'
head=subprocess.check_output(['git','-C',str(src),'rev-parse','HEAD'],text=True).strip()
if head!=expected: raise SystemExit('Unsupported mpv revision; use '+expected)
def replace(path,old,new):
 p=src/path;text=p.read_text()
 if new in text:return
 if text.count(old)!=1:raise SystemExit('Unexpected upstream source: '+str(p))
 p.write_text(text.replace(old,new))
shutil.copy2(root/'native/mpv-filter/vf_iive_rife.c',src/'video/filter/vf_iive_rife.c')
shutil.copy2(root/'native/RIFEBackend/include/IIVERIFE.h',src/'video/filter/IIVERIFE.h')
replace(pathlib.Path('filters/user_filters.c'),'    &vf_format,','    &vf_format,\n    &vf_iive_rife,')
replace(pathlib.Path('filters/user_filters.h'),'extern const struct mp_user_filter_entry vf_format;','extern const struct mp_user_filter_entry vf_format;\nextern const struct mp_user_filter_entry vf_iive_rife;')
replace(pathlib.Path('meson.build'),"    'video/filter/vf_format.c',","    'video/filter/vf_format.c',\n    'video/filter/vf_iive_rife.c',")
library=root/'native/RIFEBackend/.build/release'
# Meson string literals: refuse path characters we cannot safely represent.
if "'" in str(library) or '\n' in str(library):raise SystemExit('Unsupported path quoting')
replace(pathlib.Path('meson.build'),"cc = meson.get_compiler('c')", "cc = meson.get_compiler('c')\n"+
 "dependencies += [cc.find_library('IIVERIFE', dirs: '"+str(library)+"'), dependency('appleframeworks', modules: ['CoreVideo', 'CoreFoundation'])]\n"+
 "add_project_link_arguments('-Wl,-rpath,"+str(library)+"', language: 'c')")
print('Prepared dedicated mpv checkout:',src)

# Minimal no-Cocoa build still needs CFString helpers used by CoreAudio.
replace(pathlib.Path('meson.build'), "    main_fn_source = files('osdep/main-fn-mac.c')\nendif", "    main_fn_source = files('osdep/main-fn-mac.c')\nendif\nif darwin and not features['cocoa']\n    sources += files('osdep/utils-mac.c')\nendif")
# The pinned upstream revision passes an AudioChannelLayout to ChannelMap (SInt32[]).
# Use the public AudioChannelLayout property on the input scope instead.
replace(pathlib.Path('audio/out/ao_coreaudio.c'), "kAudioOutputUnitProperty_ChannelMap,\n                               kAudioUnitScope_Global, 0, layout, layout_size", "kAudioUnitProperty_AudioChannelLayout,\n                               kAudioUnitScope_Input, 0, layout, layout_size")

shutil.copy2(root/'native/mpv-filter/vf_iive_apple.c',src/'video/filter/vf_iive_apple.c')
shutil.copy2(root/'native/AppleBackend/IIVEApple.h',src/'video/filter/IIVEApple.h')
replace(pathlib.Path('filters/user_filters.c'),'    &vf_iive_rife,','    &vf_iive_rife,\n    &vf_iive_apple,')
replace(pathlib.Path('filters/user_filters.h'),'extern const struct mp_user_filter_entry vf_iive_rife;','extern const struct mp_user_filter_entry vf_iive_rife;\nextern const struct mp_user_filter_entry vf_iive_apple;')
replace(pathlib.Path('meson.build'),"    'video/filter/vf_iive_rife.c',","    'video/filter/vf_iive_rife.c',\n    'video/filter/vf_iive_apple.c',")
apple=root/'build/apple'
anchor="add_project_link_arguments('-Wl,-rpath,"+str(library)+"', language: 'c')"
replace(pathlib.Path('meson.build'),anchor,anchor+"\n"+
 "dependencies += [cc.find_library('IIVEApple', dirs: '"+str(apple)+"')]\n"+
 "add_project_link_arguments('-Wl,-rpath,"+str(apple)+"', language: 'c')")

shutil.copy2(root/'native/FSRCNNXMetal/include/IIVEFSR.h',src/'video/filter/IIVEFSR.h')
replace(pathlib.Path('filters/user_filters.c'),'    &vf_iive_apple,','    &vf_iive_apple,\n    &vf_iive_fsrcnnx,')
replace(pathlib.Path('filters/user_filters.h'),'extern const struct mp_user_filter_entry vf_iive_apple;','extern const struct mp_user_filter_entry vf_iive_apple;\nextern const struct mp_user_filter_entry vf_iive_fsrcnnx;')
fsr=root/'native/FSRCNNXMetal/.build/release'
fsr_link="dependencies += [cc.find_library('IIVEFSR', dirs: '"+str(fsr)+"')]\n"+"add_project_link_arguments('-Wl,-rpath,"+str(fsr)+"', language: 'c')"
fsr_anchor="add_project_link_arguments('-Wl,-rpath,"+str(apple)+"', language: 'c')"
replace(pathlib.Path('meson.build'),fsr_anchor,fsr_anchor+"\n"+fsr_link)

# Shared, reference-counted CVPixelBuffer ownership for native filter chaining.
for name in ('iive_surface.h','iive_surface.c'):
 shutil.copy2(root/'native/mpv-filter'/name,src/'video/filter'/name)
replace(pathlib.Path('meson.build'),"    'video/filter/vf_iive_apple.c',","    'video/filter/vf_iive_apple.c',\n    'video/filter/iive_surface.c',")

# libmpv plain-GL is hosted by our NSOpenGLView with a current CGL context.
# Upstream couples VT/GL discovery to its own Cocoa window frontend; allow
# the same existing mapper for this macOS embedding without building that UI.
replace(pathlib.Path('meson.build'),
    "    features['gl-cocoa'] or features['ios-gl'],\n    error_message: 'gl-cocoa nor ios-gl could be found!',",
    "    features['gl-cocoa'] or features['ios-gl'] or (darwin and plain_gl.allowed()),\n    error_message: 'A platform GL context is required for VideoToolbox!',")

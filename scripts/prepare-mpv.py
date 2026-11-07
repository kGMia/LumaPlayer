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
shutil.copy2(root/'native/mpv-filter/iive_queue_budget.h',src/'video/filter/iive_queue_budget.h')
shutil.copy2(root/'native/mpv-filter/iive_preroll.h',src/'video/filter/iive_preroll.h')
# Decoder-owned, per-frame hint. Only ordinary forward hr-seeks with decoder
# dropping allowed can mark frames. Backstep uses the separate hint below;
# neither hint changes mpv's seek/discard PTS.
replace(pathlib.Path('video/mp_image.h'), '    double nominal_fps;',
    '    double nominal_fps;\n    bool iive_preroll; // safely before enhancement context at an hr-seek target')
replace(pathlib.Path('video/mp_image.c'), '    dst->nominal_fps = src->nominal_fps;',
    '    dst->nominal_fps = src->nominal_fps;\n    dst->iive_preroll = src->iive_preroll;')
replace(pathlib.Path('filters/f_decoder_wrapper.c'), '#include "video/csputils.h"',
    '#include "video/csputils.h"\n#include "video/filter/iive_preroll.h"')
if 'mpi->iive_preroll =' not in (src/'filters/f_decoder_wrapper.c').read_text():
 replace(pathlib.Path('filters/f_decoder_wrapper.c'), '        // Stop hr-seek logic.', '''        // A retained reference frame may still precede the exact seek target.
        // Skip only expensive IIVE enhancement, leaving decoding and final mpv
        // frame selection untouched. Reset the hint on EVERY decoder output.
        mpi->iive_preroll = p->play_dir > 0 && p->opts->correct_pts &&
            p->has_broken_packet_pts <= 0 && p->start_pts != MP_NOPTS_VALUE &&
            mpi->pts != MP_NOPTS_VALUE &&
            iive_preroll_before_context(mpi->pts, p->start_pts);

        // Stop hr-seek logic.''')
# Very-exact backward steps must retain every decoded reference frame. Keep a
# separate enhancement-only target: NEVER pass it to decoder frame dropping.
# RIFE advances its original clock through discarded intervals and rebases the
# adjacent encoder before the target. SR still processes exact-seek candidates.
replace(pathlib.Path('video/mp_image.h'),
    '    bool iive_preroll; // safely before enhancement context at an hr-seek target',
    '    bool iive_preroll; // safely before enhancement context at an hr-seek target\n    bool iive_backstep_preroll; // interpolation-only; preserve exact seek clock')
replace(pathlib.Path('video/mp_image.c'),
    '    dst->iive_preroll = src->iive_preroll;',
    '    dst->iive_preroll = src->iive_preroll;\n    dst->iive_backstep_preroll = src->iive_backstep_preroll;')
replace(pathlib.Path('filters/f_decoder_wrapper.h'),
    'void mp_decoder_wrapper_set_start_pts(struct mp_decoder_wrapper *d, double pts);',
    'void mp_decoder_wrapper_set_start_pts(struct mp_decoder_wrapper *d, double pts);\nvoid mp_decoder_wrapper_set_iive_backstep_target(struct mp_decoder_wrapper *d, double pts);')
replace(pathlib.Path('filters/f_decoder_wrapper.c'), '    double start_pts;',
    '    double start_pts;\n    double iive_backstep_target;')
replace(pathlib.Path('filters/f_decoder_wrapper.c'), '    p->first_packet_pdts = MP_NOPTS_VALUE;',
    '    p->first_packet_pdts = MP_NOPTS_VALUE;\n    p->iive_backstep_target = MP_NOPTS_VALUE;')
replace(pathlib.Path('filters/f_decoder_wrapper.c'), '        // Stop hr-seek logic.', '''        mpi->iive_backstep_preroll = p->play_dir > 0 && p->opts->correct_pts &&
            p->has_broken_packet_pts <= 0 && p->iive_backstep_target != MP_NOPTS_VALUE &&
            mpi->pts != MP_NOPTS_VALUE &&
            iive_preroll_before_context(mpi->pts, p->iive_backstep_target);
        if (mpi->pts == MP_NOPTS_VALUE || mpi->pts >= p->iive_backstep_target)
            p->iive_backstep_target = MP_NOPTS_VALUE;

        // Stop hr-seek logic.''')
replace(pathlib.Path('filters/f_decoder_wrapper.c'),
    'static bool is_new_segment(struct priv *p, struct mp_frame frame)', '''void mp_decoder_wrapper_set_iive_backstep_target(struct mp_decoder_wrapper *d, double pts)
{
    struct priv *p = d->f->priv;
    if (p->is_group) {
        for (int i = 0; i < p->num_children; i++)
            mp_decoder_wrapper_set_iive_backstep_target(p->children[i], pts);
        return;
    }
    p->iive_backstep_target = pts;
}

static bool is_new_segment(struct priv *p, struct mp_frame frame)''')
replace(pathlib.Path('player/playloop.c'),
    '            if (dec && hrseek_framedrop)',
    '            if (dec && mpctx->hrseek_backstep)\n                mp_decoder_wrapper_set_iive_backstep_target(dec, mpctx->hrseek_pts);\n            if (dec && hrseek_framedrop)')
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
for name in ('iive_surface.h','iive_surface.c','iive_latency.h'):
 shutil.copy2(root/'native/mpv-filter'/name,src/'video/filter'/name)
replace(pathlib.Path('meson.build'),"    'video/filter/vf_iive_apple.c',","    'video/filter/vf_iive_apple.c',\n    'video/filter/iive_surface.c',")

# libmpv plain-GL is hosted by our NSOpenGLView with a current CGL context.
# Upstream couples VT/GL discovery to its own Cocoa window frontend; allow
# the same existing mapper for this macOS embedding without building that UI.
replace(pathlib.Path('meson.build'),
    "    features['gl-cocoa'] or features['ios-gl'],\n    error_message: 'gl-cocoa nor ios-gl could be found!',",
    "    features['gl-cocoa'] or features['ios-gl'] or (darwin and plain_gl.allowed()),\n    error_message: 'A platform GL context is required for VideoToolbox!',")

# Read-only PCM side branch for SpeechAnalyzer; never alters playback audio.
shutil.copy2(root/'native/mpv-filter/af_iive_captions.c',src/'audio/filter/af_iive_captions.c')
replace(pathlib.Path('filters/user_filters.c'),'    &af_format,','    &af_format,\n    &af_iive_captions,')
replace(pathlib.Path('filters/user_filters.h'),'extern const struct mp_user_filter_entry af_format;','extern const struct mp_user_filter_entry af_format;\nextern const struct mp_user_filter_entry af_iive_captions;')
replace(pathlib.Path('meson.build'),"    'audio/filter/af_format.c',","    'audio/filter/af_format.c',\n    'audio/filter/af_iive_captions.c',")

# Dolby Vision RPU decoding in the existing libmpv GL color-conversion pass.
# Reuse libplacebo's maintained shader generator instead of duplicating DV math.
shutil.copy2(root/'native/mpv-filter/iive_dovi.h', src/'video/out/gpu/iive_dovi.h')
replace(pathlib.Path('video/out/gpu/shader_cache.h'),
    'void gl_sc_uniform_vec3(struct gl_shader_cache *sc, char *name, float f[3]);',
    'void gl_sc_uniform_vec3(struct gl_shader_cache *sc, char *name, float f[3]);\nvoid gl_sc_uniform_vec4(struct gl_shader_cache *sc, char *name, float f[4]);')
replace(pathlib.Path('video/out/gpu/shader_cache.c'), 'static void transpose2x2(float r[2 * 2])', '''void gl_sc_uniform_vec4(struct gl_shader_cache *sc, char *name, float f[4])
{
    struct sc_uniform *u = find_uniform(sc, bstr0(name));
    u->input.type = RA_VARTYPE_FLOAT;
    u->input.dim_v = 4;
    u->glsl_type = "vec4";
    update_uniform_params(sc, u);
    memcpy(u->v.f, f, 4 * sizeof(float));
}

static void transpose2x2(float r[2 * 2])''')
replace(pathlib.Path('video/out/gpu/video.c'), '#include "error_diffusion.h"', '#include "error_diffusion.h"\n#include "iive_dovi.h"')
replace(pathlib.Path('video/out/gpu/video.c'), '    struct gl_shader_cache *sc;', '    struct gl_shader_cache *sc;\n    pl_shader iive_dovi_shader;')
replace(pathlib.Path('video/out/gpu/video.c'), '    gl_sc_destroy(p->sc);', '    pl_shader_free(&p->iive_dovi_shader);\n    gl_sc_destroy(p->sc);')
replace(pathlib.Path('video/out/gpu/video.c'),
    '    // Conversion to RGB. For RGB itself, this still applies e.g. brightness', '''    // Read metadata from THIS frame, not cached format parameters. RPU may
    // change every frame without a format reconfiguration (including after seek).
    struct mp_image *frame = p->image.mpi;
    bool dovi = frame && frame->params.repr.sys == PL_COLOR_SYSTEM_DOLBYVISION &&
                frame->params.repr.dovi && !frame->params.no_dovi;
    if (dovi && iive_dovi_decode(sc, &p->iive_dovi_shader, p->ra->glsl_version,
                                 frame->params.repr, &cparams)) {
        p->image_params.color = frame->params.color;
        pass_describe(p, "IIVE Dolby Vision RPU mapping (SDR output)");
        goto iive_color_converted;
    }

    // Conversion to RGB. For RGB itself, this still applies e.g. brightness''')
replace(pathlib.Path('video/out/gpu/video.c'),
    '    p->components = 3;\n    if (!p->has_alpha)', 'iive_color_converted:\n    p->components = 3;\n    if (!p->has_alpha)')
# Refresh dynamic HDR values before each color pass, including fallback frames.
# Avoid retaining the previous frame's mapped color after an RPU discontinuity.
replace(pathlib.Path('video/out/gpu/video.c'),
    '    struct mp_csp_params cparams = MP_CSP_PARAMS_DEFAULTS;\n    cparams.gray = p->is_gray;', '''    if (p->image.mpi) {
        struct mp_image_params current = p->image.mpi->params;
        mp_image_params_restore_dovi_mapping(&current);
        p->image_params.color = current.color;
    }
    struct mp_csp_params cparams = MP_CSP_PARAMS_DEFAULTS;
    cparams.gray = p->is_gray;''')

# Load glUniform4f in GL function table for Dolby Vision vec4 RPU uniforms.
replace(pathlib.Path('video/out/opengl/common.c'),
    '            DEF_FN(Uniform3f),',
    '            DEF_FN(Uniform3f),\n            DEF_FN(Uniform4f),')

# Opt-in decoder API wall-time trace; pinned-source edits remain idempotent.
for directory in ['video/filter', 'video/decode']:
    for header in ['iive_profile.h', 'iive_latency.h']:
        shutil.copy2(root/'native/mpv-filter'/header, src/directory/header)
replace(pathlib.Path('video/decode/vd_lavc.c'), '#include "common/msg.h"',
        '#include "common/msg.h"\n#include "iive_profile.h"')
replace(pathlib.Path('video/decode/vd_lavc.c'),
        'int ret = avcodec_send_packet(avctx, pkt ? ctx->avpkt : NULL);',
        'int ret = IIVE_PROFILE_DECODE(vd, "send", avcodec_send_packet(avctx, pkt ? ctx->avpkt : NULL));')
replace(pathlib.Path('video/decode/vd_lavc.c'),
        'int ret = avcodec_receive_frame(avctx, ctx->pic);',
        'int ret = IIVE_PROFILE_DECODE(vd, "receive", avcodec_receive_frame(avctx, ctx->pic));')

# VideoToolbox frames already carry an AVHWFramesContext. Reuse FFmpeg's
# maintained Metal YADIF instead of downloading every decoded field for bwdif.
# Limit selection to the two plane layouts handled by our renderer/enhancers.
# Missing filter / Metal initialization failure falls through to upstream bwdif.
replace(pathlib.Path('filters/f_auto_filters.c'),
    '    int prev_imgfmt;\n    bool interlaced_frame;', '    int prev_imgfmt;\n    int prev_hw_subfmt;\n    int configured_deint, configured_parity;\n    bool interlaced_frame;')
replace(pathlib.Path('filters/f_auto_filters.c'),
    'if (img->imgfmt != p->prev_imgfmt) {',
    'if (img->imgfmt != p->prev_imgfmt || img->params.hw_subfmt != p->prev_hw_subfmt) {')
replace(pathlib.Path('filters/f_auto_filters.c'),
    '        p->prev_imgfmt = img->imgfmt;',
    '        p->prev_imgfmt = img->imgfmt;\n        p->prev_hw_subfmt = img->params.hw_subfmt;')
replace(pathlib.Path('filters/f_auto_filters.c'),
    '    } else if (img->imgfmt == IMGFMT_CUDA) {',
    '''    } else if (img->imgfmt == IMGFMT_VIDEOTOOLBOX && img->hwctx &&
               (img->params.hw_subfmt == IMGFMT_NV12 ||
                img->params.hw_subfmt == IMGFMT_P010)) {
        char *args[] = {"mode", "send_field",
                       "deint", opts->deinterlace == 1 ? "all" : "interlaced",
                       "parity", field_parity, NULL};
        p->sub.filter = mp_create_user_filter(f, MP_OUTPUT_CHAIN_VIDEO,
                                              "yadif_videotoolbox", args);
        if (p->sub.filter)
            MP_VERBOSE(f, "IIVE deinterlace: VideoToolbox / Metal YADIF\\n");
    } else if (img->imgfmt == IMGFMT_CUDA) {''')

# On -> Auto must also rebuild the native deinterlacer: its deint/parity
# options are captured when the child filter is created. Drain before replacing.
replace(pathlib.Path('filters/f_auto_filters.c'),
    '    } else if (p->sub.filter && !filter_needed) {',
    '''    } else if (p->sub.filter && (!filter_needed ||
               p->configured_deint != opts->deinterlace ||
               p->configured_parity != opts->field_parity)) {''')
replace(pathlib.Path('filters/f_auto_filters.c'),
    '    mp_assert(!p->sub.filter);\n\n    char *field_parity;',
    '''    mp_assert(!p->sub.filter);
    p->configured_deint = opts->deinterlace;
    p->configured_parity = opts->field_parity;

    char *field_parity;''')

# Independent secondary subtitle color (--secondary-sub-color) with UPDATE_OSD
# and pixel-exact bottom-of-upper to top-of-lower bilingual subtitle spacing (--sub-stack-gap).
replace(pathlib.Path('options/options.h'),
    '    int ass_style_override[2];\n};',
    '    int ass_style_override[2];\n    struct m_color secondary_sub_color;\n};')
replace(pathlib.Path('options/options.h'),
    '    int osd_shaper;\n};',
    '    int osd_shaper;\n    float sub_stack_gap;\n};')
replace(pathlib.Path('options/options.c'),
    '        {"secondary-sub-visibility", OPT_BOOL(sub_visibility[1])},',
    '        {"secondary-sub-visibility", OPT_BOOL(sub_visibility[1])},\n        {"secondary-sub-color", OPT_COLOR(secondary_sub_color)},')
replace(pathlib.Path('options/options.c'),
    '        .ass_style_override[1] = ASS_STYLE_OVERRIDE_STRIP,\n    },',
    '        .ass_style_override[1] = ASS_STYLE_OVERRIDE_STRIP,\n        .secondary_sub_color = {255, 255, 255, 255},\n    },')
replace(pathlib.Path('options/options.c'),
    '        {"osd-shaper", OPT_CHOICE(osd_shaper, {"simple", 0}, {"complex", 1})},',
    '        {"osd-shaper", OPT_CHOICE(osd_shaper, {"simple", 0}, {"complex", 1})},\n        {"sub-stack-gap", OPT_FLOAT(sub_stack_gap), M_RANGE(-100.0, 200.0)},')
replace(pathlib.Path('options/options.c'),
    '        .osd_shaper = 1,\n    },',
    '        .osd_shaper = 1,\n        .sub_stack_gap = -100.0f,\n    },')
replace(pathlib.Path('sub/osd.c'),
    '''    double force_video_pts = atomic_load(&osd->force_video_pts);''',
    '''    m_config_cache_update(osd->opts_cache);
    double force_video_pts = atomic_load(&osd->force_video_pts);''')
replace(pathlib.Path('sub/osd.c'),
    '''        list->change_id += obj->vo_change_id;

        talloc_free(imgs);
    }''',
    '''        list->change_id += obj->vo_change_id;

        talloc_free(imgs);
    }

    if (osd->opts->sub_stack_gap > -99.0f) {
        struct sub_bitmaps *sub1 = NULL, *sub2 = NULL;
        for (int i = 0; i < list->num_items; i++) {
            if (list->items[i]->render_index == OSDTYPE_SUB) sub1 = list->items[i];
            else if (list->items[i]->render_index == OSDTYPE_SUB2) sub2 = list->items[i];
        }
        if (sub1 && sub2 && sub1->num_parts > 0 && sub2->num_parts > 0) {
            int sub1_top = INT_MAX, sub1_bottom = INT_MIN;
            for (int i = 0; i < sub1->num_parts; i++) {
                sub1_top = MPMIN(sub1_top, sub1->parts[i].y);
                sub1_bottom = MPMAX(sub1_bottom, sub1->parts[i].y + sub1->parts[i].dh);
            }
            int sub2_top = INT_MAX;
            for (int i = 0; i < sub2->num_parts; i++) {
                sub2_top = MPMIN(sub2_top, sub2->parts[i].y);
            }
            int gap_px = lrint(osd->opts->sub_stack_gap * (double)MPMAX(res.h, 1) / 720.0);
            int dy = (sub2_top - gap_px) - sub1_bottom;
            if (sub1_top + dy < res.mt) dy = res.mt - sub1_top;
            if (dy != 0) {
                for (int i = 0; i < sub1->num_parts; i++)
                    sub1->parts[i].y += dy;
                sub1->change_id += 1;
                list->change_id += 1;
            }
        }
    }''')
replace(pathlib.Path('sub/sd_ass.c'),
    '''    ASS_Style style = {0};
    mp_ass_set_style(&style, MP_ASS_FONT_PLAYRESY, opts->sub_style);
    ass_set_selective_style_override(priv, &style);
    free(style.FontName);
    if (converted && track->default_style < track->n_styles) {
        mp_ass_set_style(track->styles + track->default_style,
                         track->PlayResY, opts->sub_style);
    }''',
    '''    ASS_Style style = {0};
    mp_ass_set_style(&style, MP_ASS_FONT_PLAYRESY, opts->sub_style);
    if (sd->order == 1 && shared_opts->secondary_sub_color.a) {
        style.PrimaryColour = style.SecondaryColour = MP_ASS_COLOR(shared_opts->secondary_sub_color);
    }
    ass_set_selective_style_override(priv, &style);
    free(style.FontName);
    if (converted && track->default_style < track->n_styles) {
        mp_ass_set_style(track->styles + track->default_style,
                         track->PlayResY, opts->sub_style);
        if (sd->order == 1 && shared_opts->secondary_sub_color.a) {
            track->styles[track->default_style].PrimaryColour =
            track->styles[track->default_style].SecondaryColour =
                MP_ASS_COLOR(shared_opts->secondary_sub_color);
        }
    }''')

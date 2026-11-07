// SPDX-License-Identifier: GPL-3.0-or-later
// libplacebo generates the Dolby Vision math; this adapter only binds its
// variables to mpv's existing GL shader cache. No frame readback or CPU pixels.
#include <libplacebo/shaders/colorspace.h>
#include "shader_cache.h"

static bool iive_dovi_decode(struct gl_shader_cache *sc, pl_shader *shader,
                             int glsl_version, struct pl_color_repr repr,
                             const struct mp_csp_params *eq)
{
    struct pl_shader_params params = {
        .id = 77, .glsl = {.version = glsl_version}, .dynamic_constants = true,
    };
    if (!*shader) *shader = pl_shader_alloc(NULL, &params);
    if (!*shader) return false;
    pl_shader_reset(*shader, &params);
    // pass_read_video already normalizes the integer storage bits to [0,1].
    repr.bits = (struct pl_bit_encoding){0};
    struct pl_color_adjustment adjustment = pl_color_adjustment_neutral;
    adjustment.brightness = eq->brightness;
    adjustment.contrast = eq->contrast;
    adjustment.hue = eq->hue;
    adjustment.saturation = eq->saturation;
    pl_shader_decode_color(*shader, &repr, &adjustment);
    const struct pl_shader_res *res = pl_shader_finalize(*shader);
    if (!res || res->input != PL_SHADER_SIG_COLOR || res->output != PL_SHADER_SIG_COLOR ||
        res->num_descriptors || res->num_vertex_attribs || res->num_constants ||
        res->compute_group_size[0]) return false;

    // Validate the whole interface before modifying the mpv shader. Unexpected
    // libplacebo versions/formats fail closed to the original base-layer path.
    int floats = 0;
    for (int i = 0; i < res->num_variables; i++) {
        struct pl_var v = res->variables[i].var;
        if (v.type != PL_VAR_FLOAT || v.dim_a < 1 || v.dim_a > 64 ||
            v.dim_v < 1 || v.dim_v > 4 ||
            (v.dim_m != 1 && !(v.dim_v == 3 && v.dim_m == 3))) return false;
        int count = v.dim_a * v.dim_v * v.dim_m;
        floats += count;
        if (floats > 2048) return false;
        const float *data = res->variables[i].data;
        for (int j = 0; j < count; j++) if (!isfinite(data[j])) return false;
    }
    for (int i = 0; i < res->num_variables; i++) {
        struct pl_var v = res->variables[i].var;
        const char *type = pl_var_glsl_type_name(v);
        const float *data = res->variables[i].data;
        if (v.dim_a > 1) gl_sc_haddf(sc, "%s %s[%d];\n", type, v.name, v.dim_a);
        for (int a = 0; a < v.dim_a; a++) {
            char name[128];
            snprintf(name, sizeof(name), "%s%s%d", v.name, "_iive_", a);
            // Keep the shader source constant when only RPU coefficients change.
            gl_sc_uniform_dynamic(sc);
            float *value = (float *)(data + a * v.dim_v * v.dim_m);
            if (v.dim_m == 3) gl_sc_uniform_mat3(sc, name, false, value);
            else switch (v.dim_v) {
                case 1: gl_sc_uniform_f(sc, name, value[0]); break;
                case 2: gl_sc_uniform_vec2(sc, name, value); break;
                case 3: gl_sc_uniform_vec3(sc, name, value); break;
                case 4: gl_sc_uniform_vec4(sc, name, value); break;
            }
            if (v.dim_a > 1) gl_sc_addf(sc, "%s[%d] = %s;\n", v.name, a, name);
            else gl_sc_haddf(sc, "#define %s %s\n", v.name, name);
        }
    }
    gl_sc_hadd(sc, res->glsl);
    gl_sc_addf(sc, "color = %s(color);\n", res->name);
    return true;
}

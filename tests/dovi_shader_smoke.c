// SPDX-License-Identifier: GPL-3.0-or-later
// CPU-only interface smoke. Synthetic metadata is NOT a video/color reference.
// clang -I/opt/homebrew/include tests/dovi_shader_smoke.c -L/opt/homebrew/lib -lplacebo -o build/checks/dovi-contract
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <libplacebo/shaders/colorspace.h>

static const struct pl_shader_res *generate(pl_shader shader, struct pl_dovi_metadata *d) {
    pl_shader_reset(shader, pl_shader_params(.id=77, .glsl={.version=150}, .dynamic_constants=true));
    struct pl_color_repr repr = {.sys=PL_COLOR_SYSTEM_DOLBYVISION, .levels=PL_COLOR_LEVELS_FULL, .dovi=d};
    pl_shader_decode_color(shader, &repr, NULL);
    const struct pl_shader_res *r=pl_shader_finalize(shader);
    assert(r && r->input==PL_SHADER_SIG_COLOR && r->output==PL_SHADER_SIG_COLOR);
    assert(!r->num_constants && !r->num_descriptors && !r->num_vertex_attribs);
    int arrays=0, values=0;
    for(int i=0;i<r->num_variables;i++) {
        struct pl_var v=r->variables[i].var;
        assert(v.type==PL_VAR_FLOAT && v.dim_a>0 && v.dim_a<=64);
        assert(v.dim_v>=1 && v.dim_v<=4 && (v.dim_m==1 || (v.dim_m==3 && v.dim_v==3)));
        // The adapter binds tightly packed host values, not GPU std140 layout.
        size_t size=v.dim_v*v.dim_m*v.dim_a*sizeof(float);
        assert(pl_var_host_layout(0,&v).size==size);
        arrays+=v.dim_a>1; values+=size/sizeof(float);
    }
    assert(values<=2048);
    printf("GLSL150 contract: %d variables, %d arrays, %d float values\n",r->num_variables, arrays, values);
    return r;
}
int main(void) {
    struct pl_dovi_metadata d={.nonlinear={.m={{1,0,0},{0,1,0},{0,0,1}}}, .linear={.m={{1,0,0},{0,1,0},{0,0,1}}}};
    pl_shader shader=pl_shader_alloc(NULL, NULL);
    for(int mode=0;mode<2;mode++) {
        for(int c=0;c<3;c++) {
            d.comp[c].num_pivots=9;
            for(int p=0;p<9;p++)d.comp[c].pivots[p]=p/8.f;
            for(int p=0;p<8;p++) {
                d.comp[c].method[p]=mode && p%2;
                d.comp[c].poly_coeffs[p][1]=1;
                d.comp[c].mmr_order[p]=3;
                d.comp[c].mmr_coeffs[p][0][c]=1;
            }
        }
        const struct pl_shader_res *r=generate(shader,&d);
        char *before=strdup(r->glsl);
        d.comp[0].poly_coeffs[0][0]+=0.001f;
        r=generate(shader,&d);
        assert(!strcmp(before,r->glsl)); // coefficient-only updates must not recompile
        free(before);
    }
    pl_shader_free(&shader);
    puts("PASS: polynomial/MMR binding contract and stable shader source; GPU pixels not tested");
}

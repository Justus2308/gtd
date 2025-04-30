#pragma sokol @vs vs
#pragma sokol @glsl_options flip_vert_y
#pragma sokol @glsl_options fixup_clipspace

layout(binding=0) uniform vs_params {
    mat4 mvp;
};

layout(location=0) in vec3 in_pos;
layout(location=1) in vec2 in_uv;
layout(location=2) in vec4 in_color;

out vec2 uv;
out vec4 color;

void main() {
    gl_Position = mvp * vec4(in_pos, 1.0);
    uv = in_uv;
    color = in_color;
}
#pragma sokol @end

#pragma sokol @fs fs

layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

in vec2 uv;
in vec4 color;

out vec4 out_color;

void main() {
    out_color = texture(sampler2D(tex, smp), uv);
    out_color *= color;
}
#pragma sokol @end

#pragma sokol @program shader vs fs


#pragma sokol @cs cs_trackpos

layout(binding=0) readonly buffer cs_ssbo_in {
    float pos_rel_in[];
};
layout(binding=1) buffer cs_ssbo_out {
    vec2 pos_abs_out[];
};

const int TRACK_POINT_COUNT = 1000;
layout(binding=0) uniform cs_params {
    vec2 track[TRACK_POINT_COUNT];
};
layout(binding=1) uniform int pos_count;

layout(local_size_x=64, local_size_y=1, local_size_z=1) in;

void main() {
    const uint idx = gl_GlobalInvocationID.x;
    if (idx >= pos_count) {
        return;
    }

    float pos_rel = pos_rel_in[idx];
    float track_point_count_fp = float(TRACK_POINT_COUNT);
    float track_progress = pos_rel * track_point_count_fp;
    float track_progress_local = track_progress - floor(track_progress);
    int track_lo = int(floor(track_progress));
    int track_hi = int(ceil(track_progress));
    vec2 pos_abs = mix(track[track_lo], track[track_hi], track_progress_local);
    pos_abs_out[idx] = pos_abs;
}
#pragma sokol @end

#pragma sokol @program trackpos cs_trackpos

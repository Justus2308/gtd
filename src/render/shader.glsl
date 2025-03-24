@header const linalg = @import("geo").linalg

@ctype vec2 linalg.v2f32.V
@ctype vec3 linalg.v3f32.V
@ctype vec4 linalg.v4f32.V
@ctype mat2 linalg.m2f32.M
@ctype mat4 linalg.m4f32.M

// 'bytes' layout:
// x: int, texture index/slot

@vs vs_default
@glsl_options flip_vert_y

in vec3 in_pos;
in vec4 in_color;
in vec2 in_uv;
in vec2 in_uv_offset;
in vec2 in_bytes;

out vec4 color;
out vec2 uv;
out vec2 bytes;

void main() {
    gl_Position = vec4(in_pos, 1.0);
    color = in_color;
    uv = in_uv + in_uv_offset;
}

@end

@fs fs_default

layout(binding=0) uniform texture2D tex_atlas;
layout(binding=1) uniform texture2D tex_default;
layout(binding=2) uniform texture2D tex_font;
layout(binding=0) uniform sampler smp;

in vec4 color;
in vec2 uv;
in vec2 bytes;

out vec4 out_color;

void main() {
    int tex_index = int(bytes.x);

    if (tex_index == 0) {
        out_color = texture(sampler2D(tex_atlas, smp), uv);
    } else if (tex_index == 1) {
        out_color = texture(sampler2D(tex_default, smp), uv);
    } else if (tex_index == 2) {
        out_color.rgb = vec3(1.0);
        out_color.a = texture(sampler2D(tex_font, smp), uv).r;
    }
    out_color *= color;
}
@end

@program default vs_default fs_default


@vs vs_inst
@glsl_options flip_vert_y

in vec2 in_pos;
in vec2 in_pos_offset;
in vec2 in_scale;
in vec4 in_color;
in vec2 in_uv;

out vec4 color;
out vec2 uv;

void main() {
    gl_Position = vec4(((in_pos + in_pos_offset) * in_scale), 0.5, 1.0);
    color = in_color;
    uv = in_uv;
}
@end

@fs fs_inst

layout(binding=0) uniform texture2D tex_atlas;
layout(binding=0) uniform sampler smp;

in vec4 color;
in vec2 uv;

out vec4 out_color;

void main() {
    out_color = texture(sampler2D(tex_atlas, smp), uv);
    out_color *= color;
}

@end

@program inst vs_inst fs_inst

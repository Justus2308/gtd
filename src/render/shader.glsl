@header const linalg = @import("geo").linalg

@ctype vec2 linalg.v2f32.V
@ctype vec3 linalg.v3f32.V
@ctype vec4 linalg.v4f32.V
@ctype mat2 linalg.m2f32.M
@ctype mat4 linalg.m4f32.M


@vs vs_default
@glsl_options flip_vert_y

layout(binding=0) uniform vs_params {
    mat4 mvp;
};

in vec3 in_pos;
in vec2 in_uv;
in vec4 in_color;
in vec4 in_extra;

out vec2 uv;
out vec4 color;
out vec4 extra;

void main() {
    gl_Position = mvp * vec4(in_pos, 1.0);
    gl_Position = vec4(in_pos.xy, 0.5, 1.0);
    uv = in_uv;
    color = in_color;
    extra = in_extra;
}
@end

@fs fs_default

layout(binding=0) uniform sampler smp;
layout(binding=0) uniform texture2DArray tex_array;
layout(binding=1) uniform texture2D tex_quads;

in vec2 uv;
in vec4 color;
in vec4 extra;

out vec4 out_color;

void main() {
    // if (extra.x > 0) {
    //     vec3 uvw = vec3(uv, extra.x);
    //     if (extra.y > 0) {
    //         // is_text
    //         out_color.a = texture(sampler2DArray(tex_array, smp), uvw).r;
    //     } else {
    //         // tex_index
    //         out_color = texture(sampler2DArray(tex_array, smp), uvw);
    //     }
    // } else if (extra.z > 0) {
    //     // is_quads
    //     out_color = texture(sampler2D(tex_quads, smp), uv);
    // } else {
    //     // default
    //     out_color = vec4(1.0);
    // }
    // out_color *= color;

    out_color = texture(sampler2D(tex_quads, smp), uv);
    out_color *= color;
}
@end

@program default vs_default fs_default


// Quad shader optimized for simplicity.
// Can only draw sprites from texture atlas.
// Renders to offscreen target.

@vs vs_quad
@glsl_options flip_vert_y
@glsl_options fixup_clipspace

in vec2 in_pos;
in vec2 in_uv;
in vec4 in_color;

out vec2 uv;
out vec4 color;

void main() {
    gl_Position = vec4(in_pos, 0.5, 1.0);
    uv = in_uv;
    color = in_color;
}
@end

@fs fs_quad

layout(binding=0) uniform sampler smp;
layout(binding=2) uniform texture2D tex_atlas;

in vec2 uv;
in vec4 color;

out vec4 out_color;

void main() {
    // out_color = texture(sampler2D(tex_atlas, smp), uv);
    // out_color *= color;
    out_color = color;
}
@end

@program quad vs_quad fs_quad

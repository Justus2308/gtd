@header const linalg = @import("geo").linalg

@ctype vec2 linalg.v2f32.V
@ctype vec3 linalg.v3f32.V
@ctype vec4 linalg.v4f32.V
@ctype mat4 linalg.m4f32.M

@vs vs_offscreen
@glsl_options flip_vert_y

in vec2 in_pos;
in vec4 in_color;
in vec2 in_uv;
in vec4 in_data;

out vec4 color;
out vec2 uv;
out vec4 data;

void main() {
    gl_Position = vec4(in_pos, 0.5, 1.0);
    color = in_color;
    uv = in_uv;
    data = in_data;
}
@end


@fs fs_offscreen

layout(binding=0) uniform texture2D bg;
layout(binding=1) uniform texture2D tex;
layout(binding=1) uniform sampler smp;

in vec4 color;
in vec2 uv;
in vec4 data;

out vec4 frag_color;

void main() {
    frag_color = texture(sampler2D(tex, smp), uv);
}
@end


@program offscreen vs_offscreen fs_offscreen


@vs vs_postproc

void main() {
    
}
@end

@fs fs_postproc

void main() {
    
}
@end

@program postproc vs_postproc fs_postproc


@vs vs_display

void main() {
    
}
@end

@fs fs_display

void main() {
    
}
@end

@program display vs_display fs_display


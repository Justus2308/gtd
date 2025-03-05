// @ctype vec2 @Vector(2, f32)
// @ctype vec4 @Vector(4, f32)
// @ctype mat4 @Vector(4*4, f32)

@vs vs
in vec2 position;
in vec4 color0;
in vec2 uv0;
in vec4 bytes0;

out vec4 color;
out vec2 uv;
out vec4 bytes;

void main() {
    
}
@end


@fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler default_sampler;

in vec4 color;
in vec2 uv;
in vec4 bytes;

out vec4 color_out;

void main() {
    
}
@end

@program quad vs fs


const std = @import("std");
const stdx = @import("stdx");
const build_options = @import("options");
const common = @import("backend/common.zig");

const assert = std.debug.assert;

// TODO move to instance
pub var shaders = struct {
    graphics: struct {
        default: Shader,
    },
    compute: struct {
        trackpos: Shader,
    },
};

pub const Impl = switch (build_options.render_backend) {
    .sokol => @import("backend/sokol.zig"),
};

pub const init = Impl.init;

pub const Shader = Impl.Shader;
pub const Pipeline = Impl.Pipeline;
pub const Image = Impl.Image;
pub const Sampler = Impl.Sampler;
pub const Buffer = Impl.Buffer;

pub const Mesh = common.Mesh;
pub const Index = common.Index;
pub const Cull = common.Cull;
pub const Winding = common.Winding;

pub const max_attr_count = Impl.max_attr_count;

pub fn createTexture(width: u32, height: u32, pixels: []const u8) Image {
    assert(pixels.len == (width * height));
    return Impl.createTexture(width, height, pixels);
}
pub fn destroyTexture(image: Image) void {
    Impl.destroyTexture(image);
}

pub const PipelineKind = common.PipelineKind;
pub const PipelineOptions = common.PipelineOptions;

pub fn createPipeline(
    comptime kind: PipelineKind,
    shader: Shader,
    options: PipelineOptions(kind),
) Pipeline {
    Impl.createPipeline(kind, shader, options);
}
pub fn destroyPipeline(pipeline: Pipeline) void {
    Impl.destroyPipeline(pipeline);
}

pub const SamplerOptions = common.SamplerOptions;

pub fn createSampler(options: SamplerOptions) Sampler {
    return Impl.createSampler(options);
}
pub fn destroySampler(sampler: Sampler) void {
    Impl.destroySampler(sampler);
}

pub const ShaderContext = common.ShaderContext;

pub const BufferKind = common.BufferKind;
pub const BufferContent = common.BufferContent;

pub fn createBuffer(kind: BufferKind, content: BufferContent) Buffer {
    return Impl.createBuffer(kind, content);
}
pub fn destroyBuffer(buffer: Buffer) void {
    Impl.destroyBuffer(buffer);
}

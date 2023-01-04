
struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

struct SpriteData {
    mat_model: mat4x4<f32>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<uniform> shared_uniforms: SharedUniforms;
@group(0) @binding(1) var<uniform> data: SpriteData;
@group(0) @binding(2) var image: texture_2d<f32>;
@group(0) @binding(3) var image_sampler: sampler;

@vertex fn vs_main(
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
) -> VertexOut {
    var mvp: mat4x4<f32> = shared_uniforms.mat_projection * data.mat_model;
    var output: VertexOut;
    output.position_clip = mvp * vec4<f32>(position.xy, 0.0, 1.0);
    output.uv = uv;
    return output;
}

@fragment fn fs_main(
    @location(0) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    return textureSample(image, image_sampler, uv) * data.color;
}
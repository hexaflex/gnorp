
struct VertexInput {
    @builtin(instance_index) instance_index : u32,
    @builtin(vertex_index) vertex_index : u32,
}

struct VertexOutput {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) uv : vec2<f32>,
    @location(1) color: vec4<f32>,
}

struct FragmentInput {
    @location(0) uv : vec2<f32>,
    @location(1) color: vec4<f32>,
}

struct BatchUniforms {
    mat_model: mat4x4<f32>,
    color: vec4<f32>,
}

struct SpriteData {
    mat_model: mat4x4<f32>,
    uv: array<vec2<f32>, 4>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<uniform> shared_uniforms: SharedUniforms;
@group(0) @binding(1) var<uniform> batch_uniforms: BatchUniforms;
@group(0) @binding(2) var<storage> sprites : array<SpriteData, SPRITE_CAPACITY>;
@group(0) @binding(3) var image: texture_2d<f32>;
@group(0) @binding(4) var image_sampler: sampler;

@vertex fn vs_main(input: VertexInput) -> VertexOutput {
    var vertices = array<vec4<f32>, 4>(
        vec4<f32>(0.0, 1.0, 0.0, 1.0),
        vec4<f32>(1.0, 1.0, 0.0, 1.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0),
        vec4<f32>(1.0, 0.0, 0.0, 1.0),
    );

    var sprite = sprites[input.instance_index];
    var mvp: mat4x4<f32> =
        shared_uniforms.mat_projection * 
        batch_uniforms.mat_model *
        sprite.mat_model;

    var output : VertexOutput;
    output.position_clip = mvp * vertices[input.vertex_index];
    output.uv = sprite.uv[input.vertex_index];
    output.color = sprite.color;
    return output;
}

@fragment fn fs_main(input: FragmentInput) -> @location(0) vec4<f32> {
    return textureSample(image, image_sampler, input.uv) * input.color * batch_uniforms.color;
}
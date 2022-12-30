
struct LocalUniforms {
    mat_model: mat4x4<f32>,
    color: vec4<f32>,
    grid_width: u32,
    tile_width: u32,
    tile_height: u32,
    selected_tile: u32,
}

struct Tile {
    uv: array<vec2<f32>, 4>,
    color: vec4<f32>,
}

struct VertexIn {
    @builtin(instance_index) instance_index: u32,
    @builtin(vertex_index) vertex_index: u32,
}

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
}

struct FragmentIn {
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
}

@group(0) @binding(0) var<uniform> shared_uniforms: SharedUniforms;
@group(0) @binding(1) var<uniform> local_uniforms: LocalUniforms;
@group(0) @binding(2) var<storage, read> tiles: array<Tile, TILE_CAPACITY>;
@group(0) @binding(3) var image: texture_2d<f32>;
@group(0) @binding(4) var image_sampler: sampler;

@vertex fn vs_main(input: VertexIn) -> VertexOut {
    var gw = local_uniforms.grid_width;
    var tw = local_uniforms.tile_width;
    var th = local_uniforms.tile_height;
    var ftw = f32(tw);
    var fth = f32(th);
    var tx = f32((input.instance_index % gw) * tw);
    var ty = f32((input.instance_index / gw) * th);

    var vertices = array<vec4<f32>, 4>(
        vec4<f32>(tx,       ty + fth, 0.0, 1.0),
        vec4<f32>(tx + ftw, ty + fth, 0.0, 1.0),
        vec4<f32>(tx,       ty,       0.0, 1.0),
        vec4<f32>(tx + ftw, ty,       0.0, 1.0),
    );

    // var ux = tiles[input.instance_index].uv.x;
    // var uy = tiles[input.instance_index].uv.y;
    // var uv = array<vec2<f32>, 4>(
    //     vec2<f32>(ux,       uy),
    //     vec2<f32>(ux + ftw, uy),
    //     vec2<f32>(ux,       uy + fth),
    //     vec2<f32>(ux + ftw, uy + fth),
    // );

    var mvp: mat4x4<f32> = shared_uniforms.mat_projection * local_uniforms.mat_model;
    var output: VertexOut;
    output.position_clip = mvp * vertices[input.vertex_index];
    output.uv = tiles[input.instance_index].uv[input.vertex_index];
    // output.uv = uv[input.vertex_index];
    output.color = tiles[input.instance_index].color;
    return output;
}

@fragment fn fs_main(input: FragmentIn) -> @location(0) vec4<f32> {
    var tex = textureSample(image, image_sampler, input.uv);
    return tex * local_uniforms.color * input.color;
}
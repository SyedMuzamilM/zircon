#include <metal_stdlib>
using namespace metal;

// This layout matches renderer.zig's Instance exactly: five 16-byte groups.
struct Instance {
    float4 rect, clip, color, uv;
    float radius, mode;
    float2 padding;
};
struct Vertex {
    float4 position [[position]];
    float2 point, local;
    float4 rect, clip, color, uv;
    float radius, mode;
};

vertex Vertex vertex_main(uint vertex_index [[vertex_id]], uint index [[instance_id]],
                          device const Instance *items [[buffer(0)]],
                          constant float2 &size [[buffer(1)]]) {
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    Instance item = items[index];
    Vertex out;
    out.local = corners[vertex_index];
    out.point = item.rect.xy + out.local * item.rect.zw;
    out.position = float4(out.point.x / size.x * 2 - 1,
                          1 - out.point.y / size.y * 2, 0, 1);
    out.rect = item.rect;
    out.clip = item.clip;
    out.color = item.color;
    out.uv = item.uv;
    out.radius = item.radius;
    out.mode = item.mode;
    return out;
}

fragment float4 fragment_main(Vertex in [[stage_in]],
                             texture2d<float> atlas [[texture(0)]]) {
    if (in.point.x < in.clip.x || in.point.y < in.clip.y ||
        in.point.x >= in.clip.x + in.clip.z ||
        in.point.y >= in.clip.y + in.clip.w) discard_fragment();
    float coverage = 1;
    if (in.mode > 0.5) {
        constexpr sampler glyph_sampler(coord::normalized, address::clamp_to_edge,
                                 filter::linear);
        coverage = atlas.sample(glyph_sampler, in.uv.xy + in.local * in.uv.zw).r;
    } else if (in.radius > 0) {
        float radius = min(in.radius, min(in.rect.z, in.rect.w) * 0.5);
        float2 q = abs((in.local - 0.5) * in.rect.zw) -
                   (in.rect.zw * 0.5 - radius);
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        coverage = 1 - smoothstep(-fwidth(distance) * 0.5,
                                  fwidth(distance) * 0.5, distance);
    }
    float alpha = in.color.a * coverage;
    return float4(in.color.rgb * alpha, alpha);
}

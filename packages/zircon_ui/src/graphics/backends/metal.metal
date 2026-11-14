#include <metal_stdlib>
using namespace metal;

// This layout matches renderer.zig's Instance exactly.
struct Instance {
    float4 rect, clip, color, uv;
    float radius, mode;
    float2 transform_scale;
    float2 transform_translate;
    float rotation;
    float padding;
    float4 gradient_color;
    float2 gradient_start;
    float2 gradient_end;
};
struct Vertex {
    float4 position [[position]];
    float2 point, local;
    float4 rect, clip, color, uv;
    float radius, mode;
    float4 gradient_color;
    float2 gradient_start, gradient_end;
    float transform_opacity;
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
    float2 centered = (out.local - 0.5) * item.rect.zw;
    centered *= item.transform_scale;
    float sine = sin(item.rotation);
    float cosine = cos(item.rotation);
    float2 rotated = float2(centered.x * cosine - centered.y * sine,
                            centered.x * sine + centered.y * cosine);
    out.point = item.rect.xy + item.rect.zw * 0.5 + rotated + item.transform_translate;
    out.position = float4(out.point.x / size.x * 2 - 1,
                          1 - out.point.y / size.y * 2, 0, 1);
    out.rect = item.rect;
    out.clip = item.clip;
    out.color = item.color;
    out.uv = item.uv;
    out.radius = item.radius;
    out.mode = item.mode;
    out.gradient_color = item.gradient_color;
    out.gradient_start = item.gradient_start;
    out.gradient_end = item.gradient_end;
    out.transform_opacity = item.padding;
    return out;
}

fragment float4 fragment_main(Vertex in [[stage_in]],
                             texture2d<float> atlas [[texture(0)]]) {
    if (in.point.x < in.clip.x || in.point.y < in.clip.y ||
        in.point.x >= in.clip.x + in.clip.z ||
        in.point.y >= in.clip.y + in.clip.w) discard_fragment();
    float coverage = 1;
    if (in.mode > 3.5) {
        float2 delta = in.gradient_end - in.gradient_start;
        float t = clamp(dot(in.point - in.gradient_start, delta) / max(dot(delta, delta), 0.00001), 0.0, 1.0);
        float4 color = mix(in.color, in.gradient_color, t);
        float radius = min(in.radius, min(in.rect.z, in.rect.w) * 0.5);
        float2 q = abs((in.local - 0.5) * in.rect.zw) - (in.rect.zw * 0.5 - radius);
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        float aa = max(fwidth(distance), 0.001);
        float coverage = 1 - smoothstep(-aa * 0.5, aa * 0.5, distance);
        return float4(color.rgb * color.a * in.transform_opacity * coverage, color.a * in.transform_opacity * coverage);
    } else if (in.mode > 2.5) {
        float2 start = in.uv.xy;
        float2 delta = in.uv.zw - start;
        float t = clamp(dot(in.point - start, delta) / max(dot(delta, delta), 0.00001), 0.0, 1.0);
        float distance = length(in.point - start - t * delta) - in.radius;
        float aa = max(fwidth(distance), 0.001);
        coverage = 1 - smoothstep(-aa * 0.5, aa * 0.5, distance);
    } else if (in.mode > 1.5) {
        constexpr sampler image_sampler(coord::normalized, address::clamp_to_edge,
                                        filter::linear);
        float4 sample = atlas.sample(image_sampler, in.uv.xy + in.local * in.uv.zw);
        // Image assets are already premultiplied. Opacity scales both their
        // color and alpha, matching the pipeline's premultiplied blending.
        return float4(sample.rgb * in.color.rgb * in.color.a * in.transform_opacity,
                      sample.a * in.color.a * in.transform_opacity);
    } else if (in.mode > 0.5) {
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
    float alpha = in.color.a * in.transform_opacity * coverage;
    return float4(in.color.rgb * alpha, alpha);
}

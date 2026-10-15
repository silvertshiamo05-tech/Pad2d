// Metal port of the Inochi2D 0.8 part/composite/mask shaders
// (shaders/basic/*.frag, Copyright © 2020 Inochi2D Project, BSD 2-Clause),
// with all blend modes done through framebuffer fetch.
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct PartParams {
    float4 tintOpacity;   // rgb = multiply tint, a = opacity
    float4 screen;        // rgb = screen tint
    int4 mode;            // x = blend mode, y = 1 for legacy (core) blending
    float4 extra;         // x = mask threshold
};

vertex VertexOut meshVertex(VertexIn in [[stage_in]], constant float4x4 &mvp [[buffer(1)]]) {
    VertexOut out;
    out.position = mvp * float4(in.position, 0, 1);
    out.uv = in.uv;
    return out;
}

// Full-screen triangle for stencil clears and composite blits.
vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0, 1);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// MARK: Blending

// KHR_blend_equation_advanced separable functions on unpremultiplied colour.
static float3 advancedF(int mode, float3 cs, float3 cd) {
    switch (mode) {
    case 1: return cs * cd;                                          // multiply
    case 2: return cs + cd - cs * cd;                                // screen
    case 3: return select(1.0 - 2.0 * (1.0 - cs) * (1.0 - cd), 2.0 * cs * cd, cd <= 0.5); // overlay
    case 4: return min(cs, cd);                                      // darken
    case 5: return max(cs, cd);                                      // lighten
    case 6: {                                                        // colour dodge
        float3 r = min(1.0, cd / max(1.0 - cs, 1e-6));
        r = select(r, float3(1.0), cs >= 1.0);
        return select(r, float3(0.0), cd <= 0.0);
    }
    case 9: {                                                        // colour burn
        float3 r = 1.0 - min(1.0, (1.0 - cd) / max(cs, 1e-6));
        r = select(r, float3(0.0), cs <= 0.0);
        return select(r, float3(1.0), cd >= 1.0);
    }
    case 10: return select(1.0 - 2.0 * (1.0 - cs) * (1.0 - cd), 2.0 * cs * cd, cs <= 0.5); // hard light
    case 11: {                                                       // soft light
        float3 d = select(sqrt(cd), ((16.0 * cd - 12.0) * cd + 4.0) * cd, cd <= 0.25);
        return select(cd + (2.0 * cs - 1.0) * (d - cd), cd - (1.0 - 2.0 * cs) * cd * (1.0 - cd), cs <= 0.5);
    }
    case 12: return abs(cs - cd);                                    // difference
    case 13: return cs + cd - 2.0 * cs * cd;                         // exclusion
    default: return cs;
    }
}

static bool isAdvanced(int mode) {
    return (mode >= 1 && mode <= 6) || (mode >= 9 && mode <= 13);
}

// Both colours are premultiplied. Mirrors inSetBlendModeLegacy / KHR advanced blending.
static float4 inochiBlend(float4 s, float4 d, int mode, bool legacy) {
    if (!legacy && isAdvanced(mode)) {
        float3 cs = s.a > 0 ? s.rgb / s.a : float3(0);
        float3 cd = d.a > 0 ? d.rgb / d.a : float3(0);
        float3 rgb = advancedF(mode, cs, cd) * s.a * d.a + s.rgb * (1.0 - d.a) + d.rgb * (1.0 - s.a);
        return float4(rgb, s.a + d.a * (1.0 - s.a));
    }
    switch (mode) {
    case 1:  return s * d + d * (1.0 - s.a);                                   // multiply
    case 2:  return s + d * (1.0 - s);                                         // screen
    case 5:  return max(s, d);                                                 // lighten (GL_MAX)
    case 6:  return s * d + d;                                                 // colour dodge
    case 7:  return float4(s.rgb + d.rgb * (1.0 - s.rgb), s.a + d.a * (1.0 - s.a)); // linear dodge
    case 8:  return float4(s.rgb + d.rgb, s.a + d.a * (1.0 - s.a));            // add (glow)
    case 13: return float4(s.rgb * (1.0 - d.rgb) + d.rgb * (1.0 - s.rgb), s.a + d.a); // exclusion
    case 14: return float4(max(d.rgb - s.rgb * (1.0 - d.rgb), 0.0), s.a * (1.0 - d.a) + d.a); // subtract
    case 15: return float4(s.rgb * (1.0 - d.rgb) + d.rgb * (1.0 - s.a), s.a * (1.0 - d.a) + d.a * (1.0 - s.a)); // inverse
    case 16: return d * s.a;                                                   // destination in
    case 17: return s * d.a + d * (1.0 - s.a);                                 // clip to lower
    case 18: return d * (1.0 - s.a);                                           // slice from lower
    default: return s + d * (1.0 - s.a);                                       // normal
    }
}

static float4 inochiColor(float4 tex, constant PartParams &p) {
    // basic-stage1.frag: screen then multiply, then opacity.
    float3 screenOut = 1.0 - (1.0 - tex.rgb) * (1.0 - p.screen.rgb * tex.a);
    return float4(screenOut * p.tintOpacity.rgb, tex.a) * p.tintOpacity.a;
}

// MARK: Fragments

fragment float4 partFragment(VertexOut in [[stage_in]],
                             float4 dst [[color(0)]],
                             texture2d<float> albedo [[texture(0)]],
                             sampler smp [[sampler(0)]],
                             constant PartParams &p [[buffer(0)]]) {
    float4 src = inochiColor(albedo.sample(smp, in.uv), p);
    return inochiBlend(src, dst, p.mode.x, p.mode.y != 0);
}

fragment float4 maskFragment(VertexOut in [[stage_in]],
                             texture2d<float> albedo [[texture(0)]],
                             sampler smp [[sampler(0)]],
                             constant PartParams &p [[buffer(0)]]) {
    if (albedo.sample(smp, in.uv).a <= p.extra.x) discard_fragment();
    return float4(1);
}

fragment float4 stencilClearFragment(VertexOut in [[stage_in]]) {
    return float4(0);
}

// composite.frag, blended with legacy blending like Composite.drawSelf.
fragment float4 compositeFragment(VertexOut in [[stage_in]],
                                  float4 dst [[color(0)]],
                                  texture2d<float> layer [[texture(0)]],
                                  constant PartParams &p [[buffer(0)]]) {
    float4 tex = layer.read(uint2(in.position.xy));
    return inochiBlend(inochiColor(tex, p), dst, p.mode.x, true);
}

// Background (checkerboard or solid colour), composited *under* the puppet.
fragment float4 backgroundFragment(VertexOut in [[stage_in]],
                                   float4 dst [[color(0)]],
                                   constant float4 *colors [[buffer(0)]]) {
    float4 a = colors[0], b = colors[1];
    float size = colors[2].x;
    int2 cell = int2(floor(in.position.xy / size));
    float4 bg = ((cell.x + cell.y) & 1) ? b : a;
    return dst + bg * (1.0 - dst.a);
}

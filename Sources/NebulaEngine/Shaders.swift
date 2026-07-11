/// The Metal shader chain (design §5), compiled at runtime from source so the
/// engine needs no `.metallib` build rule. The SAME kernels are used for the
/// interactive preview and the tiled export — that identity is *why* "preview ==
/// export" holds by construction.
///
/// Two passes over textures:
///   1. `processNebula` — denoise blend, black point, GHS-family stretch,
///      midtone saturation → the finished starless nebula.
///   2. `finish` — local contrast (unsharp) on the nebula, then screen the
///      stretched star layer back in.
///
/// The `Uniforms` layout must match `EngineParamsGPU` on the Swift side.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// ---- fullscreen blit: draw the rgba32Float result into the drawable ---------
struct BlitOut { float4 pos [[position]]; float2 uv; };
struct BlitUniforms { float divider; float compare; };

vertex BlitOut blitVertex(uint vid [[vertex_id]]) {
    // Single oversized triangle covering the viewport.
    float2 p = float2((vid == 2) ? 3.0 : -1.0, (vid == 1) ? 3.0 : -1.0);
    BlitOut o;
    o.pos = float4(p, 0.0, 1.0);
    o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);   // flip Y
    return o;
}

fragment float4 blitFragment(BlitOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             texture2d<float> before [[texture(1)]],
                             constant BlitUniforms& b [[buffer(0)]]) {
    // Trilinear: when the image is fit into a smaller window the hardware picks
    // coarser mips, area-averaging so faint 1-pixel stars survive (dim, not
    // gone) instead of aliasing away between texels.
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 col = tex.sample(s, in.uv).rgb;
    if (b.compare > 0.5) {
        // Left of the divider shows the raw stack ("before").
        if (in.uv.x < b.divider) col = before.sample(s, in.uv).rgb;
        if (fabs(in.uv.x - b.divider) < 0.0015) col = float3(1.0);   // divider line
    }
    return float4(col, 1.0);
}

// "Before": the master with only the auto base stretch — the raw stack made
// visible, for the before/after divider.
kernel void stretchBefore(texture2d<float, access::read>  master [[texture(0)]],
                          texture2d<float, access::write> outTex [[texture(1)]],
                          constant Uniforms&              u      [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float3 c = master.read(gid).rgb;
    float3 shadow  = float3(u.shadow0, u.shadow1, u.shadow2);
    float3 midtone = float3(u.midtone0, u.midtone1, u.midtone2);
    c = clamp((c - shadow) / max(1.0 - shadow, 1e-4), 0.0, 1.0);
    c = float3(mtfPivot(c.r, midtone.r), mtfPivot(c.g, midtone.g), mtfPivot(c.b, midtone.b));
    outTex.write(float4(c, 1.0), gid);
}

struct Uniforms {
    float denoiseBlend;
    float blackPoint;
    float glowD;
    float contrastSP;
    float detailStrength;
    float saturation;
    float starWeight;
    float starD;
    // Auto base stretch (linear -> display), computed per channel from image
    // statistics on the CPU — the same idea as Siril autostretch. The sliders
    // above modulate on top of this sane baseline ("Import -> instant Auto").
    float shadow0; float shadow1; float shadow2;    // per-channel black point
    float midtone0; float midtone1; float midtone2; // per-channel MTF midtone
    // Dedicated star-layer stretch (much stronger lift than the nebula, tuned to
    // star flux) so faint field stars survive separation + denoise.
    float starShadow0; float starShadow1; float starShadow2;
    float starMidtone0; float starMidtone1; float starMidtone2;
};

// asinh glow stretch: lifts faint signal, D = strength (0 => identity).
static inline float glowStretch(float x, float D) {
    x = clamp(x, 0.0, 1.0);
    if (D < 1e-4) return x;
    return asinh(D * x) / asinh(D);
}

// Midtones transfer (contrast pivot around SP). Same closed form as the bake's
// finishing stretch, so the look family is consistent end to end.
static inline float mtfPivot(float x, float SP) {
    x = clamp(x, 0.0, 1.0);
    float m = clamp(SP, 0.01, 0.99);
    float d = (2.0 * m - 1.0) * x - m;
    if (fabs(d) < 1e-6) return x;
    return clamp(((m - 1.0) * x) / d, 0.0, 1.0);
}

static inline float3 stretchRGB(float3 c, float D, float SP) {
    return float3(mtfPivot(glowStretch(c.r, D), SP),
                  mtfPivot(glowStretch(c.g, D), SP),
                  mtfPivot(glowStretch(c.b, D), SP));
}

kernel void processNebula(texture2d<float, access::read>  master   [[texture(0)]],
                          texture2d<float, access::read>  denoised [[texture(1)]],
                          texture2d<float, access::read>  starless [[texture(2)]],
                          texture2d<float, access::write> outNeb   [[texture(3)]],
                          constant Uniforms&              u        [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outNeb.get_width() || gid.y >= outNeb.get_height()) return;

    float3 sl = starless.read(gid).rgb;

    // Denoise (interactive, native): an edge-preserving bilateral smooth of the
    // starless nebula, blended by the slider. Stars are already separated out,
    // so this only smooths background/nebula noise; the intensity-similarity
    // weight preserves galaxy structure and star-forming knots. This is the
    // real control — the bake's GraXpert denoise layer was a near no-op here.
    float db = clamp(u.denoiseBlend, 0.0, 1.0);
    float3 neb = sl;
    if (db > 0.001) {
        const int R = 2;
        int W = int(starless.get_width()), H = int(starless.get_height());
        float inv2s2 = 1.0 / (2.0 * 0.008 * 0.008);   // intensity similarity
        float3 acc = 0.0; float wsum = 0.0;
        for (int dy = -R; dy <= R; ++dy) {
            for (int dx = -R; dx <= R; ++dx) {
                uint2 p = uint2(clamp(int(gid.x) + dx, 0, W - 1),
                                clamp(int(gid.y) + dy, 0, H - 1));
                float3 s = starless.read(p).rgb;
                float3 diff = s - sl;
                float w = exp(-dot(diff, diff) * inv2s2)      // range weight
                        * exp(-float(dx*dx + dy*dy) / 8.0);   // spatial weight
                acc += s * w; wsum += w;
            }
        }
        neb = mix(sl, acc / max(wsum, 1e-6), db);
    }

    // Auto base stretch: per-channel black point + MTF midtone (linear->display).
    float3 shadow  = float3(u.shadow0, u.shadow1, u.shadow2);
    float3 midtone = float3(u.midtone0, u.midtone1, u.midtone2);
    neb = clamp((neb - shadow) / max(1.0 - shadow, 1e-4), 0.0, 1.0);
    neb = float3(mtfPivot(neb.r, midtone.r),
                 mtfPivot(neb.g, midtone.g),
                 mtfPivot(neb.b, midtone.b));

    // Extra black point from the Background slider, on the now-display-range data.
    float bp = clamp(u.blackPoint, 0.0, 0.95);
    neb = max(neb - bp, 0.0) / max(1.0 - bp, 1e-3);

    // GHS-family slider stretch on top of the auto base (glow + contrast pivot).
    neb = stretchRGB(neb, u.glowD, u.contrastSP);

    // Midtone saturation, luminance-weighted so the background stays neutral.
    float lum = dot(neb, float3(0.2126, 0.7152, 0.0722));
    float w = smoothstep(0.03, 0.35, lum);              // shadows stay grey
    float sat = mix(1.0, u.saturation, w);
    neb = clamp(lum + (neb - lum) * sat, 0.0, 1.0);

    outNeb.write(float4(neb, 1.0), gid);
}

kernel void finish(texture2d<float, access::read>  nebula [[texture(0)]],
                   texture2d<float, access::read>  stars  [[texture(1)]],
                   texture2d<float, access::write> outTex [[texture(2)]],
                   constant Uniforms&              u      [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    uint W = outTex.get_width(), H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) return;

    float3 neb = nebula.read(gid).rgb;

    // Local contrast: unsharp mask on the nebula luminance (starless only, so
    // stars can't ring). Box blur over a small radius, inline.
    const int R = 4;
    float3 acc = 0.0; float n = 0.0;
    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            int x = clamp(int(gid.x) + dx, 0, int(W) - 1);
            int y = clamp(int(gid.y) + dy, 0, int(H) - 1);
            acc += nebula.read(uint2(x, y)).rgb; n += 1.0;
        }
    }
    float3 blur = acc / n;
    neb = clamp(neb + (neb - blur) * u.detailStrength, 0.0, 1.0);

    // Stars: lift the linear star layer with its OWN strong stretch (tuned to
    // star flux) so faint field stars appear, then their glow stretch (apparent
    // size) and weight, screened in so bright cores add without clipping.
    float3 sShadow  = float3(u.starShadow0, u.starShadow1, u.starShadow2);
    float3 sMidtone = float3(u.starMidtone0, u.starMidtone1, u.starMidtone2);
    float3 st = stars.read(gid).rgb;
    st = clamp((st - sShadow) / max(1.0 - sShadow, 1e-4), 0.0, 1.0);
    st = float3(mtfPivot(st.r, sMidtone.r),
                mtfPivot(st.g, sMidtone.g),
                mtfPivot(st.b, sMidtone.b));
    // starD (Star Size) adds glow/bloom to make stars larger; starWeight scales
    // their presence in the screen.
    float3 stStr = float3(glowStretch(st.r, u.starD),
                          glowStretch(st.g, u.starD),
                          glowStretch(st.b, u.starD)) * clamp(u.starWeight, 0.0, 2.0);
    float3 outc = 1.0 - (1.0 - neb) * (1.0 - clamp(stStr, 0.0, 1.0));

    outTex.write(float4(clamp(outc, 0.0, 1.0), 1.0), gid);
}
""";

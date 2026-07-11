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

    float3 m  = master.read(gid).rgb;
    float3 d  = denoised.read(gid).rgb;
    float3 sl = starless.read(gid).rgb;

    // Denoise as a *blend*, never a destructive bake. A denoised starless is
    // reconstructed from the layers: denoised - (master - starless).
    float3 denoisedStarless = max(d - (m - sl), 0.0);
    float3 neb = mix(sl, denoisedStarless, clamp(u.denoiseBlend, 0.0, 1.0));

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

    // Stars: lift the linear star layer with the same auto base stretch so faint
    // field stars appear, then their own glow stretch (apparent size) and weight,
    // screened back in so bright cores add without clipping.
    float3 shadow  = float3(u.shadow0, u.shadow1, u.shadow2);
    float3 midtone = float3(u.midtone0, u.midtone1, u.midtone2);
    float3 st = stars.read(gid).rgb;
    st = clamp((st - shadow) / max(1.0 - shadow, 1e-4), 0.0, 1.0);
    st = float3(mtfPivot(st.r, midtone.r),
                mtfPivot(st.g, midtone.g),
                mtfPivot(st.b, midtone.b));
    float3 stStr = float3(glowStretch(st.r, u.starD),
                          glowStretch(st.g, u.starD),
                          glowStretch(st.b, u.starD)) * clamp(u.starWeight, 0.0, 2.0);
    float3 outc = 1.0 - (1.0 - neb) * (1.0 - clamp(stStr, 0.0, 1.0));

    outTex.write(float4(clamp(outc, 0.0, 1.0), 1.0), gid);
}
""";

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
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
struct BlitUniforms { float divider; float compare; float clipping; };

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
    if (b.clipping > 0.5) {
        float peak = max(col.r, max(col.g, col.b));
        float low = min(col.r, min(col.g, col.b));
        if (peak >= 0.995) col = mix(col, float3(1.0, 0.12, 0.08), 0.82);
        else if (low <= 0.002) col = mix(col, float3(0.08, 0.38, 1.0), 0.72);
    }
    return float4(col, 1.0);
}

struct Uniforms {
    float denoiseBlend;
    float smoothStrength;
    float correctionBlend;
    float blackPoint;
    float glowD;
    float contrastSP;
    float detailStrength;
    float structureStrength;
    float saturation;
    float vibrance;
    float tint;
    float starWeight;
    float starD;
    float starShrink;
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

static inline float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Apply a scalar tone change without independently bending R/G/B. This keeps
// calibrated star and nebula hues stable through the stretch.
static inline float3 withLuminance(float3 c, float oldLum, float newLum) {
    if (oldLum < 1e-7) return float3(newLum);
    return max(c * (newLum / oldLum), 0.0);
}

static inline float contrastCurve(float x, float amount) {
    x = clamp(x, 0.0, 1.0);
    float a = pow(max(x, 1e-6), amount);
    float b = pow(max(1.0 - x, 1e-6), amount);
    return a / max(a + b, 1e-6);
}

// Compress the brightest channel as a unit rather than clipping channels one
// by one. A gentle shoulder retains core structure and avoids false star hues.
static inline float3 protectHighlights(float3 c) {
    c = max(c, 0.0);
    float peak = max(c.r, max(c.g, c.b));
    if (peak <= 0.82) return c;
    float mapped = 0.82 + 0.18 * (1.0 - exp(-(peak - 0.82) / 0.18));
    return c * (min(mapped, 1.0) / max(peak, 1e-6));
}

kernel void processNebula(texture2d<float, access::read>  master   [[texture(0)]],
                          texture2d<float, access::read>  corrected [[texture(1)]],
                          texture2d<float, access::read>  denoised [[texture(2)]],
                          texture2d<float, access::read>  starless [[texture(3)]],
                          texture2d<float, access::write> outNeb   [[texture(4)]],
                          constant Uniforms&              u        [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outNeb.get_width() || gid.y >= outNeb.get_height()) return;

    float3 rawMaster = master.read(gid).rgb;
    float cb = clamp(u.correctionBlend / 0.8, 0.0, 1.0);
    float3 correctedLayer = corrected.read(gid).rgb;
    float3 correctedMaster = mix(rawMaster, correctedLayer, cb);
    // The starless/denoised layers were baked FROM the corrected master, so
    // carry only their delta relative to it. The Background slider then fades
    // just the gradient correction — Stars and Denoise stay fully functional
    // at Background=0 instead of being faded out with the correction.
    float3 sl = max(correctedMaster + (starless.read(gid).rgb - correctedLayer), 0.0);
    float3 starFlux = max(correctedMaster - sl, 0.0);

    // Blend the actual baked AI result. Subtracting the same star flux yields a
    // denoised starless layer without adding another on-disk layer. With the
    // classical no-model separator this also works; with an old/no separation
    // bake starFlux is zero and this becomes master <-> denoised as expected.
    float db = clamp(u.denoiseBlend, 0.0, 1.0);
    float3 correctedDenoised = max(correctedMaster + (denoised.read(gid).rgb - correctedLayer), 0.0);
    float3 cleanNeb = max(correctedDenoised - starFlux, 0.0);
    // Star presence is a LINEAR fade of the actual star flux: at Stars=100 the
    // pixels reconstruct the master exactly (sl + starFlux == correctedMaster
    // by construction), and dialling down only dims the real stars. No path
    // switch, no re-synthesised star layer — separation imperfections cannot
    // blur the image. The separately-stretched star layer is used only for
    // Star Size bloom in the finish pass.
    //
    // Star Size below neutral tightens stars instead: a greyscale erosion
    // (per-channel min over a disc) of the star flux in LINEAR space. The
    // display stretch is what balloons a star's faint halo skirt, so eroding
    // the linear flux before the stretch pulls the rendered diameter in
    // without touching the core or anything star-free (flux is zero there).
    float3 presenceFlux = starFlux;
    float3 baseDelta = 0.0;
    float shrink = clamp(u.starShrink, 0.0, 1.0);
    if (shrink > 1e-3) {
        // Separation (especially the classical mask) captures only a star's
        // inner disc; the outer halo tail stays baked into the STARLESS layer.
        // Eroding the flux alone would shrink the core and leave that tail as
        // a bright ring ("donut") — most visible over nebulosity. So erode the
        // starless base by the same element too, but only inside a mask
        // dilated from bright flux: halo tails shrink with their star while
        // star-free nebula stays bit-identical.
        float3 e1 = starFlux, e2 = starFlux, e3 = starFlux;
        float3 s1 = sl, s2 = sl, s3v = sl;
        float dil = luminance(starFlux);
        int W = int(outNeb.get_width()), H = int(outNeb.get_height());
        for (int dy = -3; dy <= 3; ++dy) {
            for (int dx = -3; dx <= 3; ++dx) {
                int r2 = dx*dx + dy*dy;
                if (r2 == 0 || r2 > 9) continue;
                uint2 q = uint2(clamp(int(gid.x) + dx, 0, W - 1),
                                clamp(int(gid.y) + dy, 0, H - 1));
                // Mirror of the flux computation above, at the neighbour.
                float3 ncl = corrected.read(q).rgb;
                float3 ncm = mix(master.read(q).rgb, ncl, cb);
                float3 nsl = max(ncm + (starless.read(q).rgb - ncl), 0.0);
                float3 nflux = max(ncm - nsl, 0.0);
                if (r2 <= 2) { e1 = min(e1, nflux); s1 = min(s1, nsl); }
                if (r2 <= 5) { e2 = min(e2, nflux); s2 = min(s2, nsl); }
                e3 = min(e3, nflux); s3v = min(s3v, nsl);
                dil = max(dil, luminance(nflux));
            }
        }
        // Morphological interpolation: shrink sweeps the erosion radius 0→3 px
        // continuously, so the slider never steps.
        float s3 = shrink * 3.0;
        presenceFlux = s3 < 1.0 ? mix(starFlux, e1, s3)
                     : s3 < 2.0 ? mix(e1, e2, s3 - 1.0)
                                : mix(e2, e3, s3 - 2.0);
        float3 slTight = s3 < 1.0 ? mix(sl, s1, s3)
                       : s3 < 2.0 ? mix(s1, s2, s3 - 1.0)
                                  : mix(s2, s3v, s3 - 2.0);
        // Only meaningful star cores get their surroundings eroded: the mask
        // needs bright flux within the disc (halo rings hug bright stars), so
        // faint field stars and clean nebula never pay the cost.
        float ring = smoothstep(0.02, 0.12, dil) * shrink;
        baseDelta = (slTight - sl) * ring;   // ≤ 0 by construction
    }
    float3 neb = max(mix(sl, cleanNeb, db) + baseDelta, 0.0)
               + presenceFlux * clamp(u.starWeight, 0.0, 1.0);

    // Auto base stretch: per-channel black point + MTF midtone (linear->display).
    float3 shadow = float3(u.shadow0, u.shadow1, u.shadow2);
    float3 midtone = float3(u.midtone0, u.midtone1, u.midtone2);
    neb = max((neb - shadow) / max(1.0 - shadow, 1e-4), 0.0);
    neb = float3(mtfPivot(neb.r, midtone.r), mtfPivot(neb.g, midtone.g),
                 mtfPivot(neb.b, midtone.b));
    float lum = luminance(neb);

    // Extra black point from the Background slider, on the now-display-range data.
    float bp = clamp(u.blackPoint, -0.05, 0.08);
    lum = luminance(neb);
    float bgLum = bp >= 0.0 ? max(lum - bp, 0.0) / max(1.0 - bp, 1e-3)
                            : lum + (-bp) * (1.0 - lum);
    neb = withLuminance(neb, lum, bgLum);

    // GHS-family slider stretch on top of the auto base (glow + contrast pivot).
    lum = luminance(neb);
    float shaped = glowStretch(lum, u.glowD);
    float preContrast = shaped;
    shaped = contrastCurve(shaped, u.contrastSP);
    neb = withLuminance(neb, lum, shaped);

    // Colour is three independent controls, all luminance-weighted so the
    // background stays neutral (no colour lifted out of noise). The weight uses
    // the PRE-contrast tone as well: a strong contrast curve darkens the nebula
    // body, and weighting on the darkened value alone would drain its colour
    // exactly when the user asks for punch.
    lum = luminance(neb);
    float w = smoothstep(0.015, 0.18, max(lum, preContrast));

    // Saturation: a uniform chroma scale toward/away from grey.
    float satF = mix(1.0, u.saturation, w);
    neb = max(lum + (neb - lum) * satF, 0.0);

    // Vibrance: a chroma-protected boost applied on top. Already-colourful pixels
    // take less of it, so pale nebulosity enriches without pushing saturated
    // cores into clipped neon; below 1 it gently drains the most saturated first.
    lum = luminance(neb);
    float vibF = mix(1.0, u.vibrance, w);
    {
        float mx = max(neb.r, max(neb.g, neb.b));
        float mn = min(neb.r, min(neb.g, neb.b));
        float chroma = (mx - mn) / max(mx, 1e-4);
        float protect = 1.0 - 0.75 * smoothstep(0.45, 0.95, chroma);
        vibF = 1.0 + (vibF - 1.0) * protect;
    }
    lum = luminance(neb);
    neb = max(lum + (neb - lum) * vibF, 0.0);

    // Tint: green↔magenta balance. Neutral (0.5) keeps a moderate SCNR-style green
    // suppression — broadband deep sky has no lone-green emitters, so green above
    // both red and blue is a stacking/gradient cast; cyan (OIII, green+blue)
    // survives via the blue channel. Toward magenta (tint<0.5) suppresses green
    // harder; toward green (tint>0.5) restores and then adds green.
    float tg = (u.tint - 0.5) * 2.0;                    // -1 magenta .. +1 green
    float scnr = clamp(0.7 - tg, 0.0, 1.0);
    neb.g = mix(neb.g, min(neb.g, max(neb.r, neb.b)), scnr);
    if (tg > 0.0) neb.g = neb.g * (1.0 + tg * 0.35);
    neb = protectHighlights(neb);

    outNeb.write(float4(neb, 1.0), gid);
}

kernel void finish(texture2d<float, access::sample> nebula [[texture(0)]],
                   texture2d<float, access::read>  stars  [[texture(1)]],
                   texture2d<float, access::write> outTex [[texture(2)]],
                   constant Uniforms&              u      [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    uint W = outTex.get_width(), H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) return;

    float3 neb = nebula.read(gid).rgb;
    float centreLum = luminance(neb);

    // One 9x9 gather feeds two consumers: the box blurs for local contrast and
    // an edge-preserving bilateral for Denoise. Stars ride in this image
    // (linear presence), so the smoothing is faded on compact bright peaks
    // below — star profiles survive full Denoise.
    const int R = 4;
    float3 acc = 0.0; float n = 0.0;
    float3 fineAcc = 0.0; float fineN = 0.0;
    float3 bilAcc = 0.0; float bilW = 0.0;
    // Range tolerance grows with strength: light denoise only merges near-equal
    // pixels; full denoise smooths visible grain but still respects real edges.
    float sigR = 0.015 + 0.10 * clamp(u.smoothStrength, 0.0, 1.0);
    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            int x = clamp(int(gid.x) + dx, 0, int(W) - 1);
            int y = clamp(int(gid.y) + dy, 0, int(H) - 1);
            float3 nb = nebula.read(uint2(x, y)).rgb;
            acc += nb; n += 1.0;
            if (abs(dx) <= 1 && abs(dy) <= 1) { fineAcc += nb; fineN += 1.0; }
            float dl = luminance(nb) - centreLum;
            float wgt = exp(-float(dx*dx + dy*dy) / 12.5)          // spatial σ≈2.5
                      * exp(-(dl*dl) / (2.0 * sigR * sigR));       // range
            bilAcc += nb * wgt; bilW += wgt;
        }
    }
    float3 blur = acc / n, fineBlur = fineAcc / fineN;
    if (u.smoothStrength > 1e-3) {
        // Compactness test: a star's 3x3 mean stands well above its 9x9 mean;
        // smooth nebulosity doesn't. Fade the smoothing out on such peaks so
        // Denoise cleans the background without eroding stars.
        float peakiness = luminance(fineBlur) - luminance(blur);
        float starGuard = 1.0 - smoothstep(0.01, 0.06, peakiness);
        neb = mix(neb, bilAcc / max(bilW, 1e-5),
                  clamp(u.smoothStrength, 0.0, 1.0) * starGuard);
    }
    float lum = luminance(neb), blurLum = luminance(blur), fineLum = luminance(fineBlur);
    // Two spatial bands give Detail useful reach without forcing one halo-prone
    // radius. Clamp the recovered signal so noise spikes and ringing cannot run
    // away at the end of the slider.
    float recovered = 0.65 * (lum - fineLum) + 0.35 * (lum - blurLum);
    recovered = clamp(recovered, -0.08, 0.08);
    // Large-scale structure "pop": local contrast against coarse mip levels of
    // the nebula — tens of pixels of blur that the small box gathers can't reach.
    // Two mip taps give a mid- and large-scale band so structure swells at more
    // than one size; the wide clamp lets it carry real depth while still bounding
    // runaway gain. Applied chroma-preserving (via withLuminance) on the starless
    // nebula only, so it deepens structure without shifting hue or bloating stars.
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    constexpr sampler mip(coord::normalized, address::clamp_to_edge,
                          filter::linear, mip_filter::linear);
    float midLum   = luminance(nebula.sample(mip, uv, level(3.5)).rgb);
    float largeLum = luminance(nebula.sample(mip, uv, level(5.5)).rgb);
    float structure = 0.55 * (lum - midLum) + 0.45 * (lum - largeLum);
    structure = clamp(structure, -0.22, 0.22);
    float detailedLum = max(lum + recovered * u.detailStrength
                                 + structure * u.structureStrength, 0.0);
    neb = protectHighlights(withLuminance(neb, lum, detailedLum));

    // Star Size bloom ONLY: star presence is already in the image linearly.
    // The Star Size slider screens in the separately-stretched star layer
    // (lifted so faint stars glow) — at zero the layer contributes nothing and
    // the natural stellar profiles pass through untouched.
    float bloom = clamp(u.starD / 1.2, 0.0, 1.0) * clamp(u.starWeight, 0.0, 1.0);
    float3 outc = neb;
    if (bloom > 1e-4) {
        float3 st = stars.read(gid).rgb;
        float sShadow = u.starShadow0, sMidtone = u.starMidtone0;
        st = max((st - sShadow) / max(1.0 - sShadow, 1e-4), 0.0);
        float starLum = luminance(st);
        st = withLuminance(st, starLum, mtfPivot(starLum, sMidtone));
        // The midtone operation changed luminance. All subsequent operations must
        // use that new value; using the stale linear luminance massively amplified
        // and clipped stars.
        starLum = luminance(st);
        // starD (Star Size) adds glow/bloom to make stars larger.
        float liftedStarLum = glowStretch(starLum, u.starD);
        float3 stStr = withLuminance(st, starLum, liftedStarLum);
        // Saturated Bayer cores have unreliable hue. Fade only the brightest star
        // chroma toward white, retaining genuine colour in ordinary field stars.
        float brightStarSat = 1.0 - 0.82 * smoothstep(0.52, 0.94, liftedStarLum);
        stStr = liftedStarLum + (stStr - liftedStarLum) * brightStarSat;
        stStr *= bloom;
        outc = 1.0 - (1.0 - neb) * (1.0 - protectHighlights(stStr));
    }

    outTex.write(float4(clamp(protectHighlights(outc), 0.0, 1.0), 1.0), gid);
}

// "Before": the master with only the auto base stretch — the raw stack made
// visible, for the before/after divider. Defined last so Uniforms/mtfPivot
// (above) are in scope.
kernel void stretchBefore(texture2d<float, access::read>  master [[texture(0)]],
                          texture2d<float, access::write> outTex [[texture(1)]],
                          constant Uniforms&              u      [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float3 c = master.read(gid).rgb;
    float3 shadow = float3(u.shadow0, u.shadow1, u.shadow2);
    float3 midtone = float3(u.midtone0, u.midtone1, u.midtone2);
    c = max((c - shadow) / max(1.0 - shadow, 1e-4), 0.0);
    c = float3(mtfPivot(c.r, midtone.r), mtfPivot(c.g, midtone.g),
               mtfPivot(c.b, midtone.b));
    c = protectHighlights(c);
    outTex.write(float4(clamp(c, 0.0, 1.0), 1.0), gid);
}
""";

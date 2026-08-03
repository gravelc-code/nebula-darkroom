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
    float warmth;
    float shadowNeutralize;
    float starWeight;
    float starD;
    float starShrink;
    // The sky level the base stretch achieved for this image, measured on the
    // CPU. The Background black point is a fraction of it and every
    // sky-relative threshold below is derived from it.
    float autoSky;
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
// Used only for the Star Size bloom lift; the nebula tone curve is the GHS below.
static inline float glowStretch(float x, float D) {
    x = clamp(x, 0.0, 1.0);
    if (D < 1e-4) return x;
    return asinh(D * x) / asinh(D);
}

// The published Generalised Hyperbolic Stretch (ghsastro.co.uk; Siril ght.c),
// hyperbolic branch (b > 0), LP = 0, C1-continuous, f(0)=0, f(1)=1. Evaluated
// on the above-sky signal so the sky pedestal is invariant by construction.
// Mirrored on the CPU as `GHS.stretch` in NebulaCore — keep the maths in sync.
static inline float ghsT(float x, float D, float B) {
    return 1.0 - pow(1.0 + D * B * x, -1.0 / B);
}
static inline float ghsTd(float x, float D, float B) {
    return D * pow(1.0 + D * B * x, -(1.0 + B) / B);
}
static inline float ghsStretch(float t, float D, float B, float SP, float HP) {
    t = clamp(t, 0.0, 1.0);
    if (D < 1e-4) return t;
    float q0 = -ghsT(SP, D, B);
    float q1 = ghsT(HP - SP, D, B) + ghsTd(HP - SP, D, B) * (1.0 - HP);
    float q  = 1.0 / max(q1 - q0, 1e-6);
    float Ti = t < SP ? -ghsT(SP - t, D, B)
             : t < HP ? ghsT(t - SP, D, B)
                      : ghsT(HP - SP, D, B) + ghsTd(HP - SP, D, B) * (t - HP);
    return clamp((Ti - q0) * q, 0.0, 1.0);
}

// Midtones transfer (contrast pivot around SP). Same closed form as the bake's
// finishing stretch, so the look family is consistent end to end.
static inline float mtfPivot(float x, float SP) {
    x = clamp(x, 0.0, 1.0);
    // Linear deep-sky data needs midtones of ~1e-3 to reach the target
    // background; a 0.01 floor here silently capped the whole auto stretch.
    float m = clamp(SP, 1.0e-4, 0.9999);
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

// Bring an out-of-range pixel back as a unit rather than clipping channels one
// by one (independent clipping skews star hues). In range it is the identity —
// the stretch curves own the highlight shoulder, and star cores reach white.
static inline float3 protectHighlights(float3 c) {
    c = max(c, 0.0);
    float peak = max(c.r, max(c.g, c.b));
    if (peak <= 1.0) return c;
    return c / peak;
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
    float cb = clamp(u.correctionBlend, 0.0, 1.0);
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
    // How star-dominated this pixel is, judged in linear space before any
    // stretch — used to whiten clipped star cores without touching nebula.
    float starness = luminance(presenceFlux)
                   / max(luminance(sl) + luminance(presenceFlux), 1e-6);

    // Auto base stretch: per-channel black point + MTF midtone (linear->display).
    float3 shadow = float3(u.shadow0, u.shadow1, u.shadow2);
    float3 midtone = float3(u.midtone0, u.midtone1, u.midtone2);
    neb = max((neb - shadow) / max(1.0 - shadow, 1e-4), 0.0);
    neb = float3(mtfPivot(neb.r, midtone.r), mtfPivot(neb.g, midtone.g),
                 mtfPivot(neb.b, midtone.b));

    // Background: subtract a FRACTION of this image's own sky level, so the
    // slider means the same thing whether the base stretch left the sky at
    // 0.12 or, on a high-dynamic-range target, far darker.
    float sky = clamp(u.autoSky, 0.0, 0.6);
    float bp = clamp(u.blackPoint, 0.0, 0.95) * sky;
    float lum = luminance(neb);
    float bgLum = max(lum - bp, 0.0) / max(1.0 - bp, 1e-3);
    neb = withLuminance(neb, lum, bgLum);
    // Where the sky now sits — the anchor for the tone curve and colour gates.
    float f = clamp((sky - bp) / max(1.0 - bp, 1e-3), 0.0, 0.5);

    // Published GHS on the above-sky signal, linked on luminance and applied
    // colour-preserving. Glow = strength (D), Contrast = symmetry point (where
    // the stretch concentrates: low = lift everything faint, high = punchy
    // midtones over dark sky). The sky floor itself never moves.
    lum = luminance(neb);
    float shaped = lum;
    if (lum > f) {
        float t = (lum - f) / max(1.0 - f, 1e-4);
        shaped = f + (1.0 - f) * ghsStretch(t, u.glowD, 2.5, u.contrastSP, 0.90);
    }
    float preContrast = shaped;
    neb = withLuminance(neb, lum, shaped);

    // Colour is four independent controls (Saturation, Vibrance, Tint, Warmth),
    // all weighted against the sky floor so the background stays neutral — no
    // colour is lifted out of noise. The weight uses the PRE-stretch tone as
    // well, so a curve that darkens the nebula body can't drain its colour
    // exactly when the user asks for punch.
    lum = luminance(neb);
    float w = smoothstep(f * 0.5, f + 0.12, max(lum, preContrast));

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

    // Saturated Bayer star cores carry unreliable hue: fade bright,
    // star-dominated pixels toward white (the reference look — white cores,
    // coloured halos). The starness gate keeps bright nebulosity untouched.
    float corePeak = max(neb.r, max(neb.g, neb.b));
    float coreW = smoothstep(0.75, 0.92, corePeak) * smoothstep(0.35, 0.75, starness);
    neb = mix(neb, float3(corePeak), 0.85 * coreW);

    // Tint: green↔magenta balance. Neutral (0.5) keeps only a light finishing
    // SCNR (the reference-tool convention — calibrated data shouldn't need
    // more), using Siril's average-neutral estimator with lightness preserved
    // so real teals/OIII shift hue slightly rather than darken. Toward magenta
    // the suppression strengthens to a full SCNR; toward green it releases and
    // then adds green.
    float tg = (u.tint - 0.5) * 2.0;                    // -1 magenta .. +1 green
    float scnr = clamp(0.25 - tg * 0.75, 0.0, 1.0);
    if (scnr > 0.0) {
        float preL = luminance(neb);
        float m = 0.5 * (neb.r + neb.b);                // average neutral
        neb.g = mix(neb.g, min(neb.g, m), scnr);
        neb = withLuminance(neb, luminance(neb), preL); // preserve lightness
    }
    if (tg > 0.0) neb.g = neb.g * (1.0 + tg * 0.35);

    // Warmth: the second white-balance axis (blue↔amber). Warm lifts red and
    // trims blue; cool the reverse. A trim, not a wash — the calibrated colour
    // should already be close.
    float wm = (u.warmth - 0.5) * 2.0;                  // -1 cool .. +1 warm
    neb.r = max(neb.r * (1.0 + wm * 0.15), 0.0);
    neb.b = max(neb.b * (1.0 - wm * 0.15), 0.0);

    // Shadow neutralisation: colour at or below the sky floor is noise, so fade
    // its chroma toward neutral grey. Anchored on the analytic sky floor —
    // faint nebulosity above the sky keeps its colour.
    float nlum = luminance(neb);
    float sw = clamp(((f + 0.05) - nlum) / 0.10, 0.0, 1.0) * clamp(u.shadowNeutralize, 0.0, 1.0);
    neb = mix(neb, float3(nlum), sw);

    outNeb.write(float4(max(neb, 0.0), 1.0), gid);
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
    neb = withLuminance(neb, lum, detailedLum);

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
        stStr = clamp(stStr * bloom, 0.0, 1.0);
        outc = 1.0 - (1.0 - min(neb, 1.0)) * (1.0 - stStr);
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
    outTex.write(float4(clamp(c, 0.0, 1.0), 1.0), gid);
}
""";

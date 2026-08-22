// The moving backdrops, one GPU pass each.
//
// Every function here is a SwiftUI `colorEffect`: it is handed a pixel, ignores the
// colour that was there, and returns what the backdrop looks like at that point. The
// picture is therefore resolution-independent and costs the same at 6K as in a 40-point
// Settings tile — which is the whole reason these are shaders rather than video.
//
// The argument list is a contract with MotionBackdropView.swift, in this order:
//     size      pixel size of the view, for aspect correction
//     time      seconds, already multiplied by the style's own speed
//     intensity 0…1 — the user's slider. Amplitude and contrast, never speed.
//     energy    0…1 — live voice level. A small, deliberate nudge; the backdrop must
//               never compete with the orb for attention.
//     c0…c3     the style's palette, dark to bright.
//
// Compiled into Contents/Resources/default.metallib by build.sh. If the Metal toolchain
// is missing the app falls back to the painted Canvas version and nothing here is used.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - Noise basis

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

/// Value noise with a smoothstep interpolant — cheap, and smooth enough that four
/// octaves of it read as cloud rather than as static.
static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p, int octaves) {
    float sum = 0.0, amp = 0.5;
    float2 q = p;
    for (int i = 0; i < octaves; i++) {
        sum += amp * vnoise(q);
        q = q * 2.02 + float2(37.1, 11.7);   // offset each octave so they cannot align
        amp *= 0.5;
    }
    return sum;
}

/// Four stops, dark to bright, walked with a single 0…1 number.
static half4 ramp(float t, half4 c0, half4 c1, half4 c2, half4 c3) {
    t = clamp(t, 0.0, 1.0);
    if (t < 0.3333) return mix(c0, c1, half(t / 0.3333));
    if (t < 0.6666) return mix(c1, c2, half((t - 0.3333) / 0.3333));
    return mix(c2, c3, half((t - 0.6666) / 0.3334));
}

/// Unit coordinates with x stretched by the aspect ratio, so a circle is a circle and a
/// wave does not change wavelength when the window is resized.
static float2 aspectUV(float2 pos, float2 size) {
    float2 uv = pos / max(size, float2(1.0));
    uv.x *= size.x / max(size.y, 1.0);
    return uv;
}

/// A star.
///
/// The obvious version of this — hash a normalised coordinate, threshold it, done — was
/// wrong in two ways that only showed up on screen: the cells are unit-sized, so every
/// star came out as a *square* several pixels across, and there were hundreds of them.
/// So the grid is measured in points, each star is a round falloff about a jittered
/// centre inside its own cell, and the twinkle is keyed to the cell's hash rather than to
/// position, which is what makes a field shimmer instead of flicker.
static float star(float2 pos, float cellSize, float rarity, float time) {
    float2 g = pos / cellSize;
    float2 id = floor(g);
    float h = hash21(id);
    if (h < rarity) return 0.0;
    float2 jitter = (float2(hash21(id + 3.7), hash21(id + 9.1)) - 0.5) * 0.55;
    float d = length(fract(g) - 0.5 - jitter);
    float core = smoothstep(0.13, 0.0, d);
    float brightness = (h - rarity) / max(1.0 - rarity, 0.001);
    float twinkle = 0.55 + 0.45 * sin(time * 1.4 + h * 60.0);
    return core * brightness * twinkle;
}

// MARK: - Ocean

// Swell moving toward the viewer. The vertical squeeze is a cheap fake perspective:
// wavelength shortens toward the top of the frame, so the same four sine bands read as
// near and far water instead of as stripes.
[[ stitchable ]] half4 motion_ocean(float2 pos, half4 color, float2 size,
                                    float time, float intensity, float energy,
                                    half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 uv = pos / max(size, float2(1.0));
    float depth = pow(clamp(uv.y, 0.0, 1.0), 0.6);       // 0 at the horizon, 1 underfoot
    float amp = 0.45 + intensity * 0.75;

    // Crests run *across* the frame and the rows of them bunch up toward the horizon.
    //
    // The version before this one drove each sine mostly from x, with y as a small term,
    // and the result was a set of long vertical meanders — closer to a contour map of a
    // hillside than to water, which is exactly what it was reported as. Swell coming
    // toward you is rows: the phase has to be dominated by y, and the row count has to
    // fall with depth so the near waves are large and the far ones are a fine corrugation.
    //
    // Written as the *integral* of the row density rather than as `y × density(y)`. The
    // obvious form multiplies by a density that is itself falling, so the true local
    // frequency is `density + y·density′` — which goes to nearly zero at the bottom of
    // the frame and leaves the near water as one featureless wash. Integrating a density
    // that runs 30 rows per height at the horizon down to 6 underfoot gives the crest
    // spacing actually asked for at every depth.
    // Near water travels faster than far water. This is the parallax that makes the
    // surface read as a plane running away from you rather than as a flat pattern.
    float travel = time * (0.55 + 0.75 * depth);
    // Enough wander that no crest is a straight line, applied to the phase rather than to
    // the colour, so the crests bend as a surface does instead of shimmering in place.
    float wander = (fbm(float2(uv.x * 1.7, uv.y * 2.6 - time * 0.06), 3) - 0.5) * 4.0 * amp
                 + sin(uv.x * 3.1 + time * 0.42) * 1.15 * amp
                 + sin(uv.x * 7.3 - time * 0.29) * 0.42 * amp;

    float phase = (30.0 - 12.0 * uv.y) * uv.y + travel + wander;
    float h = sin(phase) * 0.60
            + sin(phase * 2.13 + 1.7) * 0.26
            + sin(phase * 4.31 + 4.2) * 0.10;
    h *= amp;

    // The light sits in a band up near the horizon, not underfoot.
    //
    // Brightness rising with depth is the intuitive way round and it was wrong twice
    // over: water is darkest where it is closest to you, and the bottom of this window is
    // where the buttons and the second line of the header are — a pale milky wash there
    // made both of them nearly unreadable. Putting the bright end in the upper third
    // gives back the ordinary picture of water running away toward a lit horizon, and
    // leaves the two edges the chrome uses dark.
    float band = exp(-pow((uv.y - 0.32) * 2.5, 2.0));

    // The near half needs the wave height to carry more of the colour than the far half
    // does, or it flattens into one broad wash of teal — far water is texture, near water
    // is shape. The cosine is the surface's slope: it darkens the face turning away and
    // lifts the one turning up, which is the whole of why a row of sines reads as
    // something with volume rather than as a gradient with ripples drawn on it.
    float slope = cos(phase) * amp;
    float t = clamp(0.14 + band * 0.50
                    + h * (0.18 + 0.30 * depth)
                    + slope * 0.10 * depth
                    + energy * 0.04, 0.0, 1.0);
    half4 col = ramp(t, c0, c1, c2, c3);

    // Foam on the crest only, and only on the near waves — where a breaking crest would
    // be big enough to see. It reads now because the water under it is dark.
    float crest = smoothstep(0.30, 0.72, h) * pow(depth, 1.5);
    col = mix(col, c3, half(crest * (0.22 + intensity * 0.30)));

    // Glitter, in a path down the middle of the water, brightest where the light is.
    //
    // Broken up by noise rather than being a pure sine of x: a sine tracked the wave
    // height it was added to, so instead of sparkling it drew a pale line along every
    // iso-height — the contour lines that made this look like a map. Sparse, high-powered
    // noise has no such structure to follow.
    float path = exp(-pow((uv.x - 0.5) * 2.2, 2.0));
    float speck = fbm(float2(uv.x * 90.0, uv.y * 130.0 - time * 1.4), 2);
    float glint = pow(smoothstep(0.62, 0.95, speck), 3.0) * smoothstep(0.0, 0.4, h);
    col += c3 * half(glint * path * band * 0.55 * (0.6 + energy));
    return col;
}

// MARK: - Clouds

// Domain-warped fbm: the noise is sampled at coordinates that are themselves noise, which
// is what turns fog into something with edges and volume.
[[ stitchable ]] half4 motion_clouds(float2 pos, half4 color, float2 size,
                                     float time, float intensity, float energy,
                                     half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 uv = aspectUV(pos, size);
    float2 drift = float2(time * 0.06, time * 0.012);

    float2 q = float2(fbm(uv * 2.2 + drift, 4),
                      fbm(uv * 2.2 + drift + float2(5.2, 1.3), 4));
    float2 r = float2(fbm(uv * 2.2 + q * 1.6 + float2(1.7, 9.2) + drift * 1.4, 4),
                      fbm(uv * 2.2 + q * 1.6 + float2(8.3, 2.8) + drift * 1.1, 4));
    float d = fbm(uv * 2.2 + r * 1.9, 5);

    // Sky darkens upward whatever the cloud does, so the frame has a top.
    float sky = clamp(pos.y / max(size.y, 1.0), 0.0, 1.0);
    float t = clamp(sky * 0.35 + d * (0.55 + intensity * 0.6) + energy * 0.04, 0.0, 1.0);
    half4 col = ramp(t, c0, c1, c2, c3);

    // A break in the cloud, lit from behind.
    float light = smoothstep(0.55, 0.95, d + r.x * 0.3);
    col = mix(col, c3, half(light * 0.22 * (0.4 + intensity)));
    return col;
}

// MARK: - Aurora

// Three curtains at different heights, each a noise-displaced band, added rather than
// blended so the overlaps go bright the way real ones do.
[[ stitchable ]] half4 motion_aurora(float2 pos, half4 color, float2 size,
                                     float time, float intensity, float energy,
                                     half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 uv = pos / max(size, float2(1.0));
    half4 col = mix(c0, c1, half(pow(clamp(1.0 - uv.y, 0.0, 1.0), 2.5) * 0.4));

    // Curtains hang, they do not lie down.
    //
    // The first version drew them as horizontal bands whose centre wandered with x, which
    // is roughly how an aurora is described and completely wrong on a 16:9 window: one
    // curtain sweeps most of the frame's height, and adding the vertical striations every
    // aurora has then cut all three into a field of disconnected green dashes. Hanging
    // them from the top instead — a centre that wanders with *y*, striations running the
    // same way — is both what the sky does and what survives being this wide.
    float amp = 0.6 + intensity * 0.7;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float sway = (fbm(float2(uv.y * 1.8 + fi * 4.3, time * 0.10 + fi), 4) - 0.5);
        float centre = 0.24 + fi * 0.27 + sin(time * 0.11 + fi * 2.1) * 0.05 + sway * 0.34 * amp;
        float halfWidth = 0.045 + 0.028 * (0.5 + 0.5 * sin(time * 0.17 + fi * 1.7)) + intensity * 0.02;

        float dx = (uv.x - centre) / halfWidth;
        float band = exp(-dx * dx);
        // Brightest where it comes down out of the dark, gone before the floor.
        float hang = smoothstep(-0.02, 0.22, uv.y) * smoothstep(0.92, 0.20, uv.y);
        // Striations along the fall of the curtain, soft enough not to alias.
        float striae = 0.6 + 0.4 * sin(uv.x * 70.0 + fbm(float2(uv.x * 14.0, time * 0.22), 3) * 9.0);
        // And slow brightness pulses down its length.
        float pulse = 0.55 + 0.6 * fbm(float2(uv.y * 2.6 - time * 0.3, fi * 3.0), 3);

        half4 tint = (i == 1) ? c3 : c2;
        col += tint * half(band * hang * striae * pulse * (0.75 + intensity * 0.55)
                           * (1.0 + energy * 0.3));
    }

    // Stars, thinning out toward the horizon where the curtains are.
    col += half4(half3(star(pos, 22.0, 0.982, time) * pow(1.0 - uv.y, 1.5) * 0.85), 0.0h);
    return col;
}

// MARK: - Fluid

// Ink in water: two warp passes, then the palette walked by the result. No structure at
// all — this is the one to pick when you want colour and nothing to look at.
[[ stitchable ]] half4 motion_fluid(float2 pos, half4 color, float2 size,
                                    float time, float intensity, float energy,
                                    half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 uv = aspectUV(pos, size) * 1.6;

    float2 w1 = float2(fbm(uv + float2(0.0, time * 0.10), 4),
                       fbm(uv + float2(3.4, -time * 0.08), 4));
    float2 w2 = float2(fbm(uv + w1 * (1.4 + intensity) + float2(time * 0.05, 2.1), 4),
                       fbm(uv + w1 * (1.4 + intensity) + float2(-1.9, time * 0.07), 4));

    float v = fbm(uv + w2 * (2.0 + intensity * 1.5), 4);
    float t = clamp(v * 1.35 + (w2.x - 0.5) * 0.4 + energy * 0.06, 0.0, 1.0);
    half4 col = ramp(t, c0, c1, c2, c3);

    // A slow bloom that breathes with the voice, off-centre so it never reads as a
    // vignette around the orb.
    float2 p = pos / max(size, float2(1.0)) - float2(0.68, 0.30);
    p.x *= size.x / max(size.y, 1.0);
    float bloom = exp(-dot(p, p) * 2.6);
    col += c3 * half(bloom * (0.06 + energy * 0.12));
    return col;
}

// MARK: - Silk

// Caustics. Layered sines of a warped coordinate, raised to a high power so only the
// crossings survive — that is what makes light-through-water look like threads.
[[ stitchable ]] half4 motion_silk(float2 pos, half4 color, float2 size,
                                   float time, float intensity, float energy,
                                   half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 uv = aspectUV(pos, size);
    half4 col = mix(c0, c1, half(clamp(uv.y * 0.9, 0.0, 1.0)));

    // The warp has to stay small. At the amplitude the first version used it swamped the
    // grid it was distorting, and the result was smoke — pretty, but the same picture as
    // Clouds with a different palette.
    float2 warp = float2(fbm(uv * 2.4 + float2(time * 0.06, 0.0), 4),
                         fbm(uv * 2.4 + float2(0.0, time * 0.045) + 4.3, 4)) - 0.5;
    float2 q = uv * 7.5 + warp * (2.2 + intensity * 2.2);

    // Caustics are the *zero crossings*, not the peaks: `1 - |sin|` raised high leaves a
    // thin bright thread where the wavefronts cancel, which is what light through moving
    // water actually draws on the bottom of a pool.
    float threads = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float a = 0.6 + fi * 1.05;
        float2 dir = float2(cos(a), sin(a));
        float v = abs(sin(dot(q, dir) * (1.0 + fi * 0.45) + time * (0.45 + fi * 0.22)));
        threads += pow(1.0 - v, 22.0 - fi * 5.0);
    }
    threads = clamp(threads * (0.5 + intensity * 0.7), 0.0, 1.4);

    // Kept faint on purpose. At full strength these are a bright, hard, evenly spaced
    // net — a striking picture, and an impossible one to read a transcript on top of.
    // Caustics on a pool floor are mostly dark anyway; the light is the exception.
    col = mix(col, c2, half(clamp(threads * 0.24, 0.0, 1.0)));
    col += c3 * half(pow(clamp(threads, 0.0, 1.0), 2.6) * (0.20 + energy * 0.12));
    // A slow wash of light across the whole surface, so the dark between threads is not
    // flat black.
    float wash = fbm(uv * 1.6 + float2(time * 0.04, time * 0.03), 3);
    col += c2 * half(wash * 0.10);
    return col;
}

// MARK: - Nebula

// The slowest of the six. Rotating fbm for the gas, a second sharper octave set for the
// bright core, and a fixed star field that twinkles on its own hash rather than on time,
// so it shimmers instead of flickering.
[[ stitchable ]] half4 motion_nebula(float2 pos, half4 color, float2 size,
                                     float time, float intensity, float energy,
                                     half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 uv = aspectUV(pos, size) - float2(0.5 * size.x / max(size.y, 1.0), 0.5);

    float a = time * 0.012;
    float2x2 rot = float2x2(cos(a), -sin(a), sin(a), cos(a));
    float2 q = rot * uv * 2.4;

    float gas = fbm(q + float2(time * 0.02, -time * 0.015), 5);
    float core = fbm(q * 2.7 + float2(-time * 0.03, time * 0.02), 4);

    // Deliberately dark. The first pass put the bright end of the palette across most of
    // the window, and a voice transcript in 11-point grey does not survive being written
    // on hot pink — the vignette and the gamma below are contrast for the text, not
    // decoration. What is left is a dark frame with colour in the middle of it.
    float t = gas * (0.75 + intensity * 0.45) + core * 0.22 - 0.14 - dot(uv, uv) * 0.75;
    t = pow(clamp(t, 0.0, 1.0), 1.5);
    half4 col = ramp(t, c0, c1, c2, c3);

    // A brighter knot where the gas is densest — rare, so it stays an event.
    float knot = smoothstep(0.74, 1.0, gas + core * 0.4);
    col += c3 * half(knot * (0.10 + intensity * 0.12 + energy * 0.08));

    col += half4(half3(star(pos, 17.0, 0.977, time) * 0.9), 0.0h);
    return col;
}

// MARK: - Rain

/// One layer of falling streaks.
///
/// Columns rather than a grid: a streak has to be able to run past a cell boundary
/// without vanishing at it, so the vertical coordinate scrolls continuously and only the
/// *horizontal* division is quantised. Each column gets its own speed and offset from its
/// hash, which is what stops the whole sheet falling in lockstep.
static float rainColumns(float2 uv, float cols, float speed, float time, float sharp) {
    float x = uv.x * cols;
    float id = floor(x);
    float h = hash21(float2(id, 17.0));
    float across = fract(x) - 0.5;
    // A streak is much taller than it is wide, so the falloff across it is steep.
    float w = exp(-across * across * sharp);

    // Several drops down each column, scrolling. `fract` of a continuously falling number
    // wraps, and the shape below is zero at *both* ends of its cell, so the wrap is where
    // one drop has already gone and the next has not yet arrived — no pop.
    float y = uv.y + time * speed * (0.55 + 0.9 * h) + h * 13.0;
    float cell = fract(y * (1.6 + 2.4 * h));
    float body = smoothstep(0.0, 0.10, cell) * pow(1.0 - cell, 5.0);
    return w * body * (0.45 + 0.55 * h);
}

// Rain down a dark window. Three sheets at different depths — the far one fine and slow,
// the near one sparse and fast — over a dim glow that stands in for whatever is behind
// the glass. The glow sits in the upper middle for the same reason Ocean's does: the top
// and bottom of this window are where the header and the buttons are.
[[ stitchable ]] half4 motion_rain(float2 pos, half4 color, float2 size,
                                   float time, float intensity, float energy,
                                   half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 uv = pos / max(size, float2(1.0));
    float2 auv = aspectUV(pos, size);
    float amp = 0.45 + intensity * 0.8;

    // The window: dark almost everywhere, with one soft cool light well inside the
    // frame. Both falloffs are steep, and the haze is *multiplied* by the glow rather
    // than added to it — the first pass added it, and a noise floor across the whole
    // window lifted the corners into the same mid-slate as the middle, which is exactly
    // the wash the header and the buttons have to be legible against.
    float glow = exp(-pow((uv.y - 0.38) * 3.0, 2.0)) * exp(-pow((uv.x - 0.5) * 2.0, 2.0));
    float haze = fbm(auv * 1.7 + float2(time * 0.03, time * 0.018), 4);
    float t = clamp(0.045 + glow * (0.32 + haze * 0.22) + energy * 0.04, 0.0, 1.0);
    half4 col = ramp(t, c0, c1, c2, c3);

    // Condensation: big soft blobs on the glass itself, which is what keeps the streaks
    // from reading as a screensaver of falling lines. Only where there is light behind
    // them to catch — beading on black glass is invisible, and painting it anyway is
    // what turned the dark half of the frame grey.
    float beads = fbm(auv * 9.0 + float2(0.0, time * 0.02), 3);
    col = mix(col, c2, half(smoothstep(0.58, 0.88, beads) * 0.20 * (0.15 + glow)));

    float far  = rainColumns(auv, 150.0, 0.85, time, 620.0);
    float mid  = rainColumns(auv * 1.13 + 7.7, 78.0, 1.35, time, 380.0);
    float near = rainColumns(auv * 0.77 + 3.1, 34.0, 2.10, time, 190.0);

    // The far sheet is texture and the near one is the picture, so they are weighted very
    // differently — an even mix reads as static.
    float sheet = far * 0.30 + mid * 0.55 + near * 0.95;
    sheet *= amp * (0.85 + energy * 0.3);

    // Streaks are *lit* water on dark glass: they take the top of the palette where the
    // glow is behind them and stay dim where it is not.
    col += c3 * half(clamp(sheet, 0.0, 1.6) * (0.16 + glow * 0.34));
    col += c2 * half(clamp(sheet, 0.0, 1.6) * 0.10);
    return col;
}

// MARK: - Embers

// Sparks lifting off something warm. The only style here whose motion goes *up*, and the
// only warm-dark palette — between them that is most of why it does not look like any of
// the others with the colours changed.
//
// The cells scroll rather than the sparks: a spark keeps one cell, and the cell drifts up
// the frame, so nothing is ever re-hashed mid-flight. Being re-hashed is what makes a
// naive particle field flicker rather than rise.
[[ stitchable ]] half4 motion_embers(float2 pos, half4 color, float2 size,
                                     float time, float intensity, float energy,
                                     half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 uv = pos / max(size, float2(1.0));
    float2 auv = aspectUV(pos, size);
    float amp = 0.5 + intensity * 0.8;

    // The heat below: a low glow whose centre is off the bottom edge, so what is in the
    // frame is the *top* of it. Narrow, and dimmer than the first pass — an ember field
    // is mostly dark with sparks in it, and a broad orange wash across two thirds of the
    // window is a fire, which is a thing you look at instead of the person you are
    // talking to.
    float heat = exp(-pow((uv.y - 1.12) * 2.6, 2.0));
    float breathe = 0.85 + 0.15 * sin(time * 0.23) + energy * 0.25;
    float smoke = fbm(auv * 2.1 + float2(time * 0.02, -time * 0.05), 4);
    float t = clamp(heat * 0.42 * breathe + smoke * 0.09 - dot(auv - 0.5, auv - 0.5) * 0.10,
                    0.0, 1.0);
    half4 col = ramp(t, c0, c1, c2, c3);

    // Three sizes of spark, each its own layer so the field has depth rather than one
    // uniform scatter.
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float cols = 26.0 - fi * 7.0;
        float rows = 15.0 - fi * 4.0;
        float rise = 0.16 + fi * 0.10;

        float2 g = float2(auv.x * cols + fi * 5.3, uv.y * rows + time * rise + fi * 3.1);
        float2 id = floor(g);
        float h = hash21(id + fi * 31.0);
        if (h < 0.935 - fi * 0.025) continue;        // sparse: a spark is an event

        float2 f = fract(g) - 0.5;
        // Sparks wander sideways on the way up, each on its own.
        f.x += sin(time * (0.5 + h * 0.9) + h * 40.0) * 0.30 * amp;

        float d = length(f * float2(1.0, 0.85));
        float core = smoothstep(0.34, 0.02, d);
        // Alive low in the frame, out well before the top — the whole idea is that they
        // burn out, and it doubles as the fade that hides a cell leaving the frame.
        float life = smoothstep(0.06, 0.42, uv.y) * smoothstep(1.05, 0.62, uv.y);
        float flick = 0.6 + 0.4 * sin(time * (2.1 + h * 3.0) + h * 60.0);

        half4 tint = (h > 0.985) ? c3 : c2;
        col += tint * half(core * life * flick * (0.42 + intensity * 0.4) * (1.0 + energy * 0.35));
    }
    return col;
}

// MARK: - Prism

// One slow band of split light. The dispersion is real rather than painted on: the palette
// is sampled at three slightly different points and the red, green and blue of the result
// are taken from different ones, which is what a prism does to a beam and what no amount
// of blending two tints can imitate.
[[ stitchable ]] half4 motion_prism(float2 pos, half4 color, float2 size,
                                    float time, float intensity, float energy,
                                    half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 uv = aspectUV(pos, size);
    float2 centred = uv - float2(0.5 * size.x / max(size.y, 1.0), 0.5);

    // The angle drifts, very slightly. A fixed diagonal is the difference between light
    // through a window and a graphic of light through a window.
    float a = 0.62 + sin(time * 0.035) * 0.10;
    float2 dir = float2(cos(a), sin(a));

    // Position along the beam, warped just enough that the edges are not ruled lines.
    //
    // The frequency is the number that matters here and it is bounded on both sides.
    // At 1.15 a 16:9 window holds two full bands and the picture is a striped graphic
    // rather than a beam; at 0.42 `p` does not complete a single cycle across the frame,
    // `fract` never wraps, and what is left is one soft blob with no edges at all. Just
    // under one cycle is the answer: one band crossing the window, the next off the edge.
    float p = dot(uv, dir) * 0.80
            - time * 0.055
            + (fbm(uv * 1.3 + float2(time * 0.02, 0.0), 4) - 0.5) * 0.35 * (0.6 + intensity);

    // The band, plus a much fainter companion — what actually comes through a bevelled
    // edge. Steep enough to have sides: a beam is defined by where it stops.
    float band = exp(-pow((fract(p) - 0.52) * 4.6, 2.0)) * 0.9
               + exp(-pow((fract(p * 0.5 + 0.3) - 0.5) * 7.0, 2.0)) * 0.22;
    band *= 0.45 + intensity * 0.60;

    // Deliberately dark, and heavily vignetted. This is the one style whose whole subject
    // is a bright thing, so everything that is not the beam has to be nearly black or the
    // beam is not bright — it is just the lightest part of a light picture.
    float base = 0.035 + fbm(uv * 1.8 - float2(0.0, time * 0.015), 3) * 0.09;
    float t = clamp(base + band * 0.58 + energy * 0.05 - dot(centred, centred) * 0.55, 0.0, 1.0);

    // Dispersion: the same ramp, three places along it, one channel taken from each.
    // Wide enough to actually see. The three channels come from three points on the
    // palette, so the split only reads at all if those points are far enough apart to be
    // different colours — at a fiftieth of the ramp they are the same colour twice.
    float split = (0.030 + intensity * 0.065) * clamp(band, 0.0, 1.2);
    half4 lo = ramp(t - split, c0, c1, c2, c3);
    half4 mid = ramp(t, c0, c1, c2, c3);
    half4 hi = ramp(t + split, c0, c1, c2, c3);
    half4 col = half4(lo.r, mid.g, hi.b, 1.0h);

    // The bright core of the beam, kept narrow so the band stays something light falls
    // through rather than a stripe of paint.
    col += c3 * half(pow(clamp(band, 0.0, 1.0), 3.0) * (0.22 + energy * 0.10));
    return col;
}

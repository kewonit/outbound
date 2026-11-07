// FROZEN COPY: this file is the shader as Outbound v1.0 shipped it. The app never loads it; only ShaderTests
// compiles it, to compare the real shaders in Sources/Outbound/Shaders against what people first got.
//
// It is older than those shaders and drifts from them by design. Don't fix, tidy or improve it here. When a
// change to the look is meant, copy the current shader over this file and put this note back at the top.

// Clouds and their shadows, at a quarter of the screen's resolution. Cloud space repeats every
// `cloudPeriod` metres so it can drift forever without losing float precision.

constant float cloudPeriod = 16384.0;
constant float cloudCell = 256.0;

// MARK: - Cumulus

// Round domes crowded together, as cumulus heads are: the height of the tallest over `p`, 1 on the crown of a big one and
// 0 only in the odd gap. `cell` divides the cloud period, so they repeat with it.
inline float domes(float2 p, float cell, uint seed) {
    int period = int(cloudPeriod / cell);
    float2 g = p / cell;
    int2 n = int2(floor(g));
    float top = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            int2 c = n + int2(i, j);
            int2 cw = ((c % period) + period) % period;
            float2 h = hash22(cw, seed);
            float size = hash21(cw, seed + 1u);
            // Kept near the middle of its cell, as a dome reaching past the cells looked at would be cut off square.
            float2 to = float2(c) + 0.5 + (h - 0.5) * 0.7 - g;
            float r = 0.6 + 0.5 * size;
            float dome = (0.55 + 0.45 * size) * sqrt(max(1.0 - dot(to, to) / (r * r), 0.0));
            // Merged rather than cut one by the other, so the folds between them are soft, not cracks.
            float blend = saturate(0.5 + 0.5 * (dome - top) / 0.16);
            top = mix(top, dome, blend) + 0.16 * blend * (1.0 - blend);
        }
    }
    return top;
}

// A little warp keeps the domes off any grid.
inline float2 cumulusWarped(float2 at) {
    return at + 45.0 * (float2(vnoiseP(at / 128.0, 128, 311u), vnoiseP(at / 128.0, 128, 312u)) - 0.5);
}

// The tops of cumulus, 0 in its deepest folds and about 1 on its crowns: small domes riding on bigger ones. `big` is the
// biggest size on its own, 0 to 1, for the shade the big forms throw.
inline float cumulusTops(float2 at, thread float &big) {
    float2 q = cumulusWarped(at);
    big = domes(q, 64.0, 321u);
    return 0.5 * big + 0.32 * domes(q, 32.0, 322u) + 0.18 * domes(q, 16.0, 323u);
}

// Fair-weather cumulus: the clouds stand where puffs cluster in some cells, which sets how big each is; their surface is
// the crowded domes the band is made of, so the sky reads as one. Returns how much cloud, the surface the shading
// follows, and the tops for how bright. `detail` leaves out all but the biggest domes, enough for a shadow.
inline float3 cloudField(float2 p, float cover, bool detail) {
    int period = int(cloudPeriod / cloudCell);
    float2 n = floor(p / cloudCell);
    float body = -1.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            int2 c = int2(n) + int2(i, j);
            int2 cw = ((c % period) + period) % period;
            if (hash21(cw, 301u) > cover) continue;
            float size = 0.55 + 0.9 * hash21(cw, 304u);
            float2 center = (float2(c) + 0.3 + 0.4 * hash22(cw, 302u)) * cloudCell;
            int puffs = 3 + int(hash21(cw, 303u) * 4.0);
            float stretch = 1.0 + hash21(cw, 305u) * 0.8;
            for (int k = 0; k < 7; k++) {
                if (k >= puffs) break;
                float2 h = hash22(cw * 7 + int2(k, k * 3), 306u);
                float2 offset = (h - 0.5) * float2(80.0 * stretch, 46.0) * size;
                float r = (17.0 + 20.0 * hash21(cw * 5 + int2(k, 1), 307u)) * size;
                body = max(body, 1.0 - length(p - center - offset) / r);
            }
        }
    }
    if (body <= -0.6) return float3(0.0, body, 0.0);
    float big;
    float tops = detail ? cumulusTops(p, big) : domes(cumulusWarped(p), 64.0, 321u);
    float level = tops + body * 1.6 - 0.35;
    return float3(smoothstep(0.0, 0.08, level), tops + body * 0.5, tops);
}

fragment float4 clouds(VertexOut in [[stage_in]], constant CloudParams &params [[buffer(0)]]) {
    float2 pixel = float2(in.position.x, params.view.x - in.position.y);
    float2 p = params.origin.xy + pixel * params.origin.z;
    float cover = params.origin.w;
    float3 d = cloudField(p, cover, true);
    // Lit from the sun's side of each dome, close to, and a little brighter on the crowns, as the band is.
    float shade = 1.0;
    if (d.x > 0.0) {
        float towards = cloudField(p + params.offsets.xy * 0.15, cover, true).y;
        shade = saturate((0.74 + 3.0 * (d.y - towards)) * mix(0.84, 1.06, smoothstep(0.2, 0.8, d.z)));
    }
    float shadow = cloudField(p + params.offsets.zw, cover, false).x;
    return float4(d.x, shade, shadow, 1.0);
}

// MARK: - The band over a join

// One place stops and the next begins along a line, and a thin band of cloud lies over it, a small barrier between them.
// It belongs to the land, so it comes and goes at the land's pace, and is painted once into a texture of its own that
// slides with the land. `at` below is metres across the world and metres above the join. It is made of the same
// cumulus as the rest of the sky.

constant float bankDepth = 60.0;
constant float bankBays = 16.0;
constant float bankWander = 16.0;

// Noise seldom strays far from its middle, so it is stretched, or an edge comes out nearly straight, like the hem of a
// curtain.
inline float bankBay(float2 at, uint seed) {
    float wander = 0.65 * vnoiseP(at / 128.0, 128, seed) + 0.35 * vnoiseP(at / 64.0, 256, seed + 1u);
    return bankBays * clamp((wander - 0.5) * 4.0, -1.0, 1.0);
}

// How deep into the band a point is, as a level to add to its tops: from 0.58 up it is solid whatever the tops are doing,
// so the join itself is always well under cloud, and from -0.66 down it is clear. Its two edges wander apart and together,
// and the whole band wanders across the join, so it is never a rope of one width. World.bankReach is how far out it shows.
inline float bankReach(float2 at, float halfLength) {
    float y = at.y - bankWander * clamp((vnoiseP(float2(at.x / 512.0, 0.5), 32, 335u) - 0.5) * 4.0, -1.0, 1.0);
    return (halfLength - abs(y) + bankBay(at, y > 0.0 ? 334u : 331u)) / bankDepth;
}

// How much cloud there is at each point, its shade, and how much of its shadow falls there.
fragment float4 bank(VertexOut in [[stage_in]], constant CloudParams &params [[buffer(0)]]) {
    float2 pixel = float2(in.position.x, params.view.x - in.position.y);
    float2 at = params.origin.xy + pixel * params.origin.z;
    float halfLength = params.origin.w;
    float reach = bankReach(at, halfLength);
    float cloud = 0.0, shade = 1.0, falling = 0.0;
    if (reach > -0.66) {
        float big, unused;
        float tops = cumulusTops(at, big);
        cloud = smoothstep(0.0, 0.08, tops + reach - 0.5);
        if (cloud > 0.0) {
            // Lit from the sun's side of each dome, close to, and shaded by the big forms between it and the sun.
            float towards = cumulusTops(at + params.offsets.xy * 0.15, unused);
            float standing = domes(cumulusWarped(at + params.offsets.xy * 0.8), 64.0, 321u) - big;
            shade = 0.74 + 3.0 * (tops - towards) - 1.2 * max(standing, 0.0);
            shade = saturate(shade * mix(0.84, 1.06, smoothstep(0.2, 0.8, tops)));
        }
    }
    // Its shadow is its own shape, thrown across the land as any cloud's is.
    float2 fall = at + params.offsets.zw;
    float fallReach = bankReach(fall, halfLength);
    if (fallReach > -0.66) {
        float unused;
        falling = smoothstep(0.0, 0.2, cumulusTops(fall, unused) + fallReach - 0.5);
    }
    return float4(cloud, shade, falling, 1.0);
}

// Clouds and their shadows, at a quarter of the screen's resolution. Cloud space repeats every
// `cloudPeriod` metres so it can drift forever without losing float precision.

constant float cloudPeriod = 16384.0;
constant float cloudCell = 256.0;

// Fair-weather cumulus: a few puffs clustered in some cells, with lumpy edges. Returns the density and
// the underlying puff field, which falls off smoothly from each puff's middle and is what gets shaded.
inline float2 cloudField(float2 p, float cover, int octaves) {
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
    if (body <= -0.6) return float2(0.0, body);
    // Lumpy cauliflower edges from a little periodic noise.
    float sum = 0.0, amp = 0.5, norm = 0.0, scale = 1.0;
    for (int i = 0; i < octaves; i++) {
        sum += amp * vnoiseP(p / 32.0 * scale, int(cloudPeriod / 32.0 * scale), 210u + uint(i));
        norm += amp;
        amp *= 0.5;
        scale *= 2.0;
    }
    float edge = body + (sum / norm - 0.5) * 0.55;
    return float2(smoothstep(0.0, 0.18, edge), edge);
}

// MARK: - The bank over a join

// One place stops and the next begins along a line, and a thin bank of cloud lies over it, a small barrier between them.
// It belongs to the land, so it comes and goes at the land's pace, and everything about it is fixed in place: `bank` below is metres
// across the world and metres above the join.

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

// The tops of the bank, 0 in its deepest folds and about 1 on its crowns: small domes riding on bigger ones. `big` is the
// biggest size on its own, 0 to 1, for the shade the big forms throw.
inline float2 deckWarped(float2 bank) {
    return bank + 45.0 * (float2(vnoiseP(bank / 128.0, 128, 311u), vnoiseP(bank / 128.0, 128, 312u)) - 0.5);
}

inline float deckTops(float2 bank, thread float &big) {
    float2 q = deckWarped(bank);
    big = domes(q, 64.0, 321u);
    return 0.62 * big + 0.26 * domes(q, 32.0, 322u) + 0.12 * domes(q, 16.0, 323u);
}

// How deep into the bank a point is, as a level to add to its tops. From 0.65 up it is solid whatever the tops are doing,
// and from -0.66 down it is clear. Its two edges wander in bays and headlands, and however far they wander in, the join
// itself stays well under solid cloud. World.bankReach is how far out it can be seen.
constant float deckDepth = 50.0;
constant float deckBays = 28.0;

// Noise seldom strays far from its middle, so it is stretched, or an edge comes out nearly straight, like the hem of a
// curtain.
inline float deckBay(float2 bank, uint seed) {
    float wander = 0.65 * vnoiseP(bank / 128.0, 128, seed) + 0.35 * vnoiseP(bank / 64.0, 256, seed + 1u);
    return deckBays * clamp((wander - 0.5) * 4.0, -1.0, 1.0);
}

inline float deckReach(float2 bank, float half_) {
    return (half_ - abs(bank.y) + deckBay(bank, bank.y > 0.0 ? 334u : 331u)) / deckDepth;
}

fragment float4 clouds(VertexOut in [[stage_in]], constant CloudParams &params [[buffer(0)]]) {
    float2 pixel = float2(in.position.x, params.view.x - in.position.y);
    float2 p = params.origin.xy + pixel * params.origin.z;
    float cover = params.origin.w;

    // A bank of cloud, painted over whatever else is in the sky.
    float alpha = 0.0, bankShade = 1.0, falling = 0.0;
    if (params.deck.x > 0.0) {
        float2 bank = params.deck.zy + pixel * params.origin.z;
        float reach = deckReach(bank, params.deck.x);
        // A thin veil runs out from under its edges.
        float grain = vnoiseP(bank / 32.0, 512, 341u) * 0.65 + vnoiseP(bank / 16.0, 1024, 342u) * 0.35;
        float veil = smoothstep(-0.66, 0.4, reach) * smoothstep(0.25, 0.75, grain) * 0.5;
        float solid = 0.0;
        if (reach > -0.66) {
            float big, unused;
            float tops = deckTops(bank, big);
            solid = smoothstep(0.0, 0.15, tops + reach - 0.5);
            if (solid > 0.0) {
                // Lit from the sun's side of each dome, close to, and shaded by the big forms between it and the sun.
                float towards = deckTops(bank + params.offsets.xy * 0.15, unused);
                float standing = domes(deckWarped(bank + params.offsets.xy * 0.8), 64.0, 321u) - big;
                bankShade = 0.72 + 2.4 * (tops - towards) - 0.75 * max(standing, 0.0);
                bankShade = saturate(bankShade * mix(0.78, 1.06, smoothstep(0.25, 0.85, tops)));
            }
        }
        alpha = solid + veil * (1.0 - solid);
        // Solid, nothing behind it can be seen, and most of what it costs is saved.
        if (alpha >= 1.0) return float4(1.0, bankShade, 1.0, 0.0);
        falling = smoothstep(-0.66, 0.5, deckReach(bank + params.offsets.zw * 0.6, params.deck.x));
    }

    float2 d = cloudField(p, cover, 4);
    // One extra sample towards the sun. Where the cloud thickens that way, this side faces away
    // from the light and falls into blue-grey shade; where it thins, the edge is sunlit.
    float shade = 1.0;
    if (d.x > 0.0) {
        float towards = cloudField(p + params.offsets.xy, cover, 3).y;
        shade = saturate(0.78 + 0.75 * (d.y - towards));
    }
    float shadow = cloudField(p + params.offsets.zw, cover, 2).x;
    if (params.deck.x <= 0.0) return float4(d.x, shade, shadow, 1.0);

    float all = d.x + alpha * (1.0 - d.x);
    // Fading out with the cloud itself where there is next to none of it, so it never jumps.
    float share = alpha / max(all, 0.02);
    // Alpha stays whole for plain cloud, so everything that doesn't know about the bank reads as it always has.
    return float4(all, mix(shade, bankShade, share), max(shadow, falling), 1.0 - share);
}

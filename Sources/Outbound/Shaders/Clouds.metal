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

// MARK: - The bank a crossing goes under

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

// The tops of the bank, 0 in its deepest folds and about 1 on its crowns: small domes riding on bigger ones. Each size
// slides a little faster than the one under it, so the surface turns over slowly as it goes rather than passing like a
// printed sheet. `big` is the biggest size on its own, 0 to 1, for the shade the big forms throw.
inline float2 deckWarped(float2 p, float flow) {
    float2 q = p + float2(0.0, flow);
    return q + 90.0 * (float2(vnoiseP(q / 256.0, 64, 311u), vnoiseP(q / 256.0, 64, 312u)) - 0.5);
}

inline float deckTops(float2 p, float flow, thread float &big) {
    float2 q = deckWarped(p, flow);
    big = domes(q, 128.0, 321u);
    return 0.62 * big + 0.26 * domes(q + float2(0.0, flow * 0.1), 64.0, 322u)
                      + 0.12 * domes(q + float2(0.0, flow * 0.2), 32.0, 323u);
}

// How deep into the bank a point is, as a level to add to its tops. From 0.65 up it is solid whatever the tops are doing,
// and from -0.65 down it is clear. It comes in as a front with long bays in it, down the height of the whole desktop so
// every display sees one bank, and goes by parting: first where a slower noise is low, so holes open before anything
// else, and the top of the desktop a little ahead of the bottom.
constant float deckDepth = 150.0;
constant float deckBays = 90.0;

inline float deckReach(float2 p, float row, constant CloudParams &params) {
    float height = params.deck.w;
    float beyond = deckBays + deckDepth * 0.66;
    float front = mix(height + beyond, -beyond, params.deck.x);
    float bay = vnoiseP(p / 256.0, 64, 331u) * 2.0 - 1.0;
    float coming = (row + bay * deckBays - front) / deckDepth;
    float hole = saturate((vnoiseP(p / 128.0, 128, 332u) * 0.6 + vnoiseP(p / 256.0, 64, 333u) * 0.4 - 0.25) * 2.0);
    float going = 1.76 - params.deck.y * 3.52 + (hole - 0.5) * 1.6 + (0.5 - row / height) * 0.6;
    return min(coming, going);
}

fragment float4 clouds(VertexOut in [[stage_in]], constant CloudParams &params [[buffer(0)]]) {
    float2 pixel = float2(in.position.x, params.view.x - in.position.y);
    float2 p = params.origin.xy + pixel * params.origin.z;
    float cover = params.origin.w;

    // A crossing's bank, painted over whatever else is in the sky.
    float alpha = 0.0, bankShade = 1.0, falling = 0.0;
    if (params.deck.x > 0.0) {
        float row = params.deck.z + pixel.y * params.origin.z;
        float reach = deckReach(p, row, params);
        // A thin veil runs ahead of the bank and lingers after it, sliding at its own speed, lower down.
        float there = smoothstep(0.0, 0.12, params.deck.x) * (1.0 - smoothstep(0.82, 1.0, params.deck.y));
        float2 low = p + float2(0.0, params.flow.y);
        float grain = vnoiseP(low / 64.0, 256, 341u) * 0.65 + vnoiseP(low / 32.0, 512, 342u) * 0.35;
        float veil = smoothstep(-1.5, 0.4, reach) * smoothstep(0.25, 0.75, grain) * 0.55 * there;
        float bank = 0.0;
        if (reach > -0.65) {
            float big, unused;
            float tops = deckTops(p, params.flow.x, big);
            bank = smoothstep(0.0, 0.15, tops + reach - 0.5);
            if (bank > 0.0) {
                // Lit from the sun's side of each dome, close to, and shaded by the big forms between it and the sun.
                float towards = deckTops(p + params.offsets.xy * 0.3, params.flow.x, unused);
                float standing = domes(deckWarped(p + params.offsets.xy * 1.6, params.flow.x), 128.0, 321u) - big;
                bankShade = 0.72 + 2.4 * (tops - towards) - 0.75 * max(standing, 0.0);
                bankShade = saturate(bankShade * mix(0.78, 1.06, smoothstep(0.25, 0.85, tops)));
            }
        }
        alpha = bank + veil * (1.0 - bank);
        // Solid, nothing behind it can be seen, and most of what a closed sky costs is saved.
        if (alpha >= 1.0) return float4(1.0, bankShade, there, 0.0);
        float2 shadowAt = p + params.offsets.zw * 2.0;
        falling = smoothstep(-1.3, 0.5, deckReach(shadowAt, row + params.offsets.w * 2.0, params)) * there;
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

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

fragment float4 clouds(VertexOut in [[stage_in]], constant CloudParams &params [[buffer(0)]]) {
    float2 pixel = float2(in.position.x, params.view.x - in.position.y);
    float2 p = params.origin.xy + pixel * params.origin.z;
    float cover = params.origin.w;
    float2 d = cloudField(p, cover, 4);
    // One extra sample towards the sun. Where the cloud thickens that way, this side faces away
    // from the light and falls into blue-grey shade; where it thins, the edge is sunlit.
    float shade = 1.0;
    if (d.x > 0.0) {
        float towards = cloudField(p + params.offsets.xy, cover, 3).y;
        shade = saturate(0.78 + 0.75 * (d.y - towards));
    }
    float shadow = cloudField(p + params.offsets.zw, cover, 2).x;
    return float4(d.x, shade, shadow, 1.0);
}

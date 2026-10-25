// The only full-resolution pass that runs every frame: the cached ground plus everything that moves.

inline float3 animal(float3 c, float2 local, constant Biome &b, constant Scene &scene, float4 mask, uint seed,
                     float mpp) {
    int kind = int(b.f.w);
    float herds = b.g.x;
    if (kind == noAnimal || herds <= 0.0 || mask.w < 0.02) return c;
    // Herds wander as a whole, so nobody pops in or out at their edges.
    float t = scene.time.y;
    float2 drift = float2(18.0 * sin(t * 6.283 * 3.0 / 7200.0 + float(seed % 7u)),
                          14.0 * sin(t * 6.283 * 2.0 / 7200.0 + 1.7));
    float2 hp = local - drift;
    float spacing = kind == zebra || kind == wildebeest ? 9.0 : 10.0;
    float2 g = floor(hp / spacing);
    int2 cell = int2(g);
    float2 cellCenter = (g + 0.5) * spacing;
    float herd = smoothstep(1.0 - herds * 0.7, 1.08 - herds * 0.5, vnoise(cellCenter / 110.0, seed + 120u));
    float h = hash21(cell, seed + 121u);
    if (h > herd * 0.42) return c;

    // Graze, then take a few steps somewhere else.
    float period = 9.0 + 7.0 * hash21(cell, seed + 122u);
    float phase = t / period + h * 13.0;
    float strides = floor(phase) + smoothstep(0.75, 1.0, fract(phase));
    float2 jitter = (hash22(cell, seed + 123u) - 0.5) * spacing * 0.5;
    float2 walk = float2(sin(strides * 1.7 + h * 40.0), cos(strides * 1.3 + h * 17.0)) * 1.6;
    float2 center = cellCenter + jitter + walk;
    float heading = hash21(cell, seed + 124u) * 6.283 + 0.6 * sin(strides * 0.9 + h * 9.0);

    float2 d = rotate(hp - center, -heading);
    // Drawn larger than life so they read from this height, as in a painted map.
    float len = (kind == sheep ? 1.2 : kind == zebra ? 1.45 : 1.6) * 1.6;
    float wid = (kind == sheep ? 0.75 : 0.62) * 1.6;
    // Only draw where the ground says animals belong.
    if (mask.w < 0.5) return c;
    float2 shadowOff = rotate(-scene.sun.xy * scene.sun.z * 1.1, -heading);
    float body = length(d / float2(len, wid)) - 1.0;
    float head = length((d - float2(len * 1.05, 0.0)) / float2(0.7, 0.5)) - 1.0;
    float shadowBody = length((d - shadowOff) / float2(len, wid)) - 1.0;
    float px = mpp;
    c = shade(c, fill(min(shadowBody, head), px * 0.9) * 0.7, scene);
    float3 coat = b.animalColor.rgb * (0.85 + 0.3 * hash21(cell, seed + 125u));
    if (kind == zebra) {
        float band = step(0.5, fract(d.x * 1.0 + 0.3 * d.y));
        coat = mix(float3(0.96, 0.95, 0.92), float3(0.12, 0.12, 0.14), band * 0.9);
    }
    float a = fill(min(body * len, head * 0.5), px * 0.6);
    return mix(c, coat, a);
}

inline float3 cars(float3 c, float2 world, constant Biome &b, constant Scene &scene, float mpp) {
    float density = b.g.y;
    if (density <= 0.0) return c;
    float wander = b.d.w;
    float rx = roadX(world.y, scene, wander);
    float width = b.e.x;
    if (abs(world.x - rx) > width) return c;
    float3 result = c;
    for (int lane = 0; lane < 2; lane++) {
        float dir = lane == 0 ? 1.0 : -1.0;
        float slot = 150.0;
        float phase = lane == 0 ? scene.time.z : -scene.time.z;
        float i = floor(world.y / slot - phase);
        float pick = hash11(int(i) * 2 + lane, 140u);
        if (pick > min(density * 1.6, 0.75)) continue;
        float y = (i + phase + 0.5) * slot;
        float s = riverSlope(y, scene, wander);
        float angle = atan(s);
        float2 center = float2(roadX(y, scene, wander) - dir * width * 0.22, y);
        float2 d = rotate(world - center, angle);
        float2 size = float2(1.05, 2.3);
        float2 shadowOff = rotate(-scene.sun.xy * scene.sun.z * 1.3, angle);
        result = shade(result, fill(sdBox(d - shadowOff, size) - 0.3, mpp) * 0.75, scene);
        float k = hash11(int(i) * 2 + lane, 141u);
        float3 paint = k < 0.3 ? float3(0.95, 0.95, 0.93) : k < 0.45 ? float3(0.82, 0.18, 0.16)
                     : k < 0.6 ? float3(0.20, 0.34, 0.62) : k < 0.75 ? float3(0.16, 0.16, 0.18)
                     : k < 0.88 ? float3(0.70, 0.71, 0.72) : float3(0.93, 0.74, 0.18);
        float body = sdBox(d, size) - 0.3;
        float roof = sdBox(d - float2(0.0, -0.15 * dir), size * float2(0.75, 0.45)) - 0.2;
        result = mix(result, paint, fill(body, mpp * 0.7));
        result = mix(result, paint * 0.75 + 0.12, fill(roof, mpp * 0.7));
    }
    return result;
}

// A small white bird, seen from above, drawn as a few soft shapes.
inline float birdShape(float2 p, float spread, float bank) {
    // Wings shorten on the side the bird banks towards.
    float side = p.x < 0.0 ? 1.0 - bank * 0.3 : 1.0 + bank * 0.3;
    // From above a wingbeat only shortens the span a little.
    float span = (0.8 + 0.2 * spread) * side;
    float2 w = float2(abs(p.x) / span, p.y);
    float sweep = w.x * w.x * 0.12;
    // Broad at the shoulder, tapering to pointed tips, swept back like a gull's.
    float chord = mix(0.15, 0.025, smoothstep(0.0, 1.0, w.x));
    float wing = sdBox(float2(w.x - 0.5, w.y + sweep - 0.03 + chord * 0.3), float2(0.5, chord)) * span;
    float body = (length(p / float2(0.085, 0.32)) - 1.0) * 0.085;
    float head = length(p - float2(0.0, 0.3)) - 0.065;
    float tail = sdBox(p - float2(0.0, -0.3), float2(0.06 + 0.45 * max(-p.y - 0.26, 0.0), 0.07));
    return min(min(min(wing, body), head), tail);
}

fragment float4 composite(VertexOut in [[stage_in]],
                          constant CompositeParams &params [[buffer(0)]],
                          constant Scene &scene [[buffer(1)]],
                          texture2d<float> groundColor [[texture(0)]],
                          texture2d<float> groundMask [[texture(1)]],
                          texture2d<float> cloudTexture [[texture(2)]],
                          sampler wrap [[sampler(0)]],
                          sampler clampSampler [[sampler(1)]]) {
    float2 size = params.view.xy;
    float2 pixel = float2(in.position.x, size.y - in.position.y);
    float mpp = params.view.z;
    float2 world = params.world.xy + pixel * mpp;

    float2 texel = params.cache.xy + pixel * params.view.w;
    float2 uv = texel / params.cache.zw;
    float3 c = groundColor.sample(wrap, uv).rgb;
    float4 mask = groundMask.sample(wrap, uv);

    float t = scene.time.x;

    // Which leg's animals and cars are on this patch.
    bool inB = world.y > scene.morph.x + scene.morph.y * 0.5;
    constant Leg &leg = inB ? scene.legB : scene.legA;
    float2 local = float2(world.x, world.y - leg.info.x);

    // Gusts roll across tall crops in long soft bands.
    float2 gp = (params.world.zw + pixel * mpp) / float2(160.0, 55.0);
    float gust = vnoiseP(gp, 1024, 150u);
    c *= 1.0 + mask.y * 0.09 * (gust - 0.45);

    c = animal(c, local, leg.biome, scene, mask, uint(leg.info.y), mpp);
    c = cars(c, world, leg.biome, scene, mpp);

    float2 cloudUV = in.position.xy / size;
    float4 cloud = cloudTexture.sample(clampSampler, cloudUV);

    // Water mirrors the sky: clouds overhead brighten it, and the sun glints off ripples.
    float water = mask.x;
    c = mix(c, c + float3(0.16, 0.17, 0.2), water * cloud.x * 0.8);
    float2 gcell = floor(world / 2.4);
    float gh = hash21(int2(gcell), 160u);
    float2 gpos = (gcell + 0.2 + 0.6 * hash22(int2(gcell), 161u)) * 2.4;
    float sparkle = fill(length(world - gpos) - 0.22, mpp * 1.2);
    float glint = pow(saturate(sin(t * (1.2 + gh * 1.8) + gh * 40.0)), 16.0) * step(0.9, gh) * sparkle;
    c = mix(c, float3(1.0, 1.0, 0.97), glint * smoothstep(0.85, 1.0, water) * 0.8 * (1.0 - cloud.z));

    // Cloud shadow, then the bird's shadow, then clouds, then the bird above it all.
    c = shade(c, smoothstep(0.05, 0.8, cloud.z) * 0.62, scene);

    float birdVisible = params.wings.w;
    float2 birdPx = params.bird.xy;
    float scale = params.wings.z;
    if (birdVisible > 0.0) {
        float2 shadowPx = birdPx - scene.sun.xy * scene.sun.z * params.wings.y / mpp;
        float2 q = rotate(pixel - shadowPx, -params.bird.z) / scale;
        float sb = birdShape(q, params.wings.x, params.bird.w);
        c = shade(c, fill(sb, 0.9 / scale) * 0.55 * birdVisible, scene);
    }

    float3 cloudColor = mix(float3(0.66, 0.72, 0.86), float3(1.0, 1.0, 0.99), smoothstep(0.1, 0.95, cloud.y));
    float cloudAlpha = smoothstep(0.02, 0.6, cloud.x);
    c = mix(c, cloudColor, cloudAlpha);

    if (birdVisible > 0.0) {
        float2 q = rotate(pixel - birdPx, -params.bird.z) / scale;
        float sb = birdShape(q, params.wings.x, params.bird.w);
        float underside = saturate(0.5 - q.y * 0.6 + params.bird.w * q.x * 0.5);
        float3 feathers = mix(float3(0.99, 0.99, 0.98), float3(0.78, 0.81, 0.87), underside * 0.6);
        float through = birdVisible * (1.0 - 0.6 * smoothstep(0.3, 0.9, cloud.x));
        // A faint darker rim keeps the white bird readable over pale ground and cloud.
        c = mix(c, c * 0.72, fill(sb - 0.025, 0.9 / scale) * 0.45 * through);
        c = mix(c, feathers, fill(sb, 0.8 / scale) * through);
    }

    // Paper: a fixed grain that does not scroll with the paint, and a soft dry-brush edge.
    float grain = vnoise(in.position.xy / 1.7, 170u) * 0.6 + hash21(int2(in.position.xy), 171u) * 0.4;
    float fibres = vnoise(in.position.xy * float2(1.0 / 9.0, 1.0 / 1.4), 172u);
    c *= 1.0 + params.finish.x * (0.05 * (grain - 0.5) + 0.03 * (fibres - 0.5));
    float2 edgeDist = min(in.position.xy, size - in.position.xy);
    float edge = min(edgeDist.x, edgeDist.y) / max(size.x, size.y);
    float bristles = vnoise(in.position.xy / float2(3.0, 40.0), 173u) * 0.5 + vnoise(in.position.xy / float2(40.0, 3.0), 174u) * 0.5;
    float vignette = 1.0 - smoothstep(0.0, 0.006 + 0.012 * bristles, edge);
    c = mix(c, float3(0.97, 0.95, 0.91), vignette * params.finish.y);

    // Light for the time of day. At night colour drains towards a cool moonlit blue but the shapes
    // keep their values, so it still reads as the same painting.
    float night = scene.time.w;
    float3 lit = c * scene.light.rgb * scene.light.w;
    float3 moonlit = mix(float3(luma(c)), c, 0.4) * float3(0.46, 0.54, 0.78) * 0.78 + float3(0.015, 0.02, 0.045);
    moonlit += water * float3(0.05, 0.06, 0.08) * (1.0 - cloudAlpha);
    c = mix(lit, moonlit, night);

    return float4(saturate(c), 1.0);
}

// Every frame, in one render pass that stays in tile memory until the very end:
//   1. viewGround: the cached ground plus crop gusts, water glints and cars, with the night's light written
//      to a second target that never leaves the tile.
//   2. animalVertex/animalFragment: herds as small instanced sprites, so they only cost the pixels they cover.
//   3. sky: cloud shadow, clouds, the bird, paper and the light of the hour, reading the frame back in place.

struct ViewOut {
    float4 color [[color(0)]];
    // Light that falls on the scene after dark, added once the night grade is done.
    float4 light [[color(1)]];
};

struct SkyOut {
    float4 color [[color(0)]];
};

// Value noise from a small random lattice texture: one fetch, smoothed between lattice points.
inline float latticeNoise(texture2d<float> noise, sampler wrap, float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    f = f * f * (3.0 - 2.0 * f);
    return noise.sample(wrap, (i + f + 0.5) / 256.0).r;
}

struct Mask {
    float water;
    float sway;
    bool road;
    bool herd;
};

// The ground's alpha byte; see packGround.
inline Mask unpack(float alpha) {
    uint packed = uint(alpha * 255.0 + 0.5);
    Mask out;
    out.water = float(packed >> 6) / 3.0;
    out.sway = float((packed >> 2) & 15u) / 15.0;
    out.road = (packed & 2u) != 0u;
    out.herd = (packed & 1u) != 0u;
    return out;
}

// The cache texel under a world point, wrapped into the ring.
inline uint2 cacheTexel(float2 world, constant CompositeParams &params) {
    float2 texel = params.cache.xy + (world - params.world.xy) / params.view.z * params.view.w;
    float2 wrapped = texel - floor(texel / params.cache.zw) * params.cache.zw;
    return uint2(min(wrapped, params.cache.zw - 1.0));
}

// Each lit house keeps its own evening: lights come on through dusk, most go out between ten and half past one,
// a few burn all night, and some come on again before dawn.
inline float houseOn(float id, float hour, float sunset) {
    float hh = hour < 12.0 ? hour + 24.0 : hour;
    float h1 = fract(id * 7.31), h2 = fract(id * 13.17), h3 = fract(id * 23.71);
    float on = sunset + mix(-0.25, 1.5, h1);
    float off = h2 > 0.94 ? 40.0 : 21.8 + 3.6 * h2 * h2;
    float wake = 29.0 + 1.6 * h3;
    float evening = smoothstep(on, on + 0.002, hh) * (1.0 - smoothstep(off, off + 0.002, hh));
    float morning = step(0.72, h3) * smoothstep(wake, wake + 0.002, hh);
    return max(evening, morning);
}

inline float3 cars(float3 c, float2 world, constant Biome &b, constant Scene &scene, float mpp,
                   thread float3 &light) {
    float density = b.g.y;
    if (density <= 0.0) return c;
    float wander = b.d.w;
    float width = b.e.x;
    float night = scene.time.w;
    bool keepLeft = b.h.x > 0.5;
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
        float2 axis = normalize(float2(1.0, s));
        // Northbound traffic keeps to its side of the road: the west side where traffic keeps left.
        float side = keepLeft ? -dir : dir;
        float2 center = float2(roadX(y, scene, wander) + side * width * 0.22, y);
        float2 rel = world - center;
        float2 d = float2(dot(rel, float2(axis.x, -axis.y)), dot(rel, float2(axis.y, axis.x)));
        float2 size = float2(1.05, 2.3);
        float2 shadowOff = -scene.sun.xy * scene.sun.z * 1.3;
        float2 shadowD = float2(dot(rel - shadowOff, float2(axis.x, -axis.y)), dot(rel - shadowOff, float2(axis.y, axis.x)));
        result = shade(result, fill(sdBox(shadowD, size) - 0.3, mpp) * 0.75, scene);
        float k = hash11(int(i) * 2 + lane, 141u);
        float3 paint = k < 0.3 ? float3(0.95, 0.95, 0.93) : k < 0.45 ? float3(0.82, 0.18, 0.16)
                     : k < 0.6 ? float3(0.20, 0.34, 0.62) : k < 0.75 ? float3(0.16, 0.16, 0.18)
                     : k < 0.88 ? float3(0.70, 0.71, 0.72) : float3(0.93, 0.74, 0.18);
        float body = sdBox(d, size) - 0.3;
        float roof = sdBox(d - float2(0.0, -0.15 * dir), size * float2(0.75, 0.45)) - 0.2;
        result = mix(result, paint, fill(body, mpp * 0.7));
        result = mix(result, paint * 0.75 + 0.12, fill(roof, mpp * 0.7));

        if (night > 0.01) {
            // From straight above, headlights only show where they land: a soft wedge on the tarmac, reaching
            // further on the kerb side, hot dots at the front corners and red ones at the back.
            float fwd = d.y * dir - 2.6;
            float lat = d.x * dir;
            float kerb = keepLeft ? -lat : lat;
            float halfW = 0.95 + fwd * (kerb > 0.0 ? 0.24 : 0.17);
            float wedge = fill(abs(lat) - halfW, 0.5 + fwd * 0.08) * smoothstep(-0.3, 1.2, fwd);
            float reach = exp(-max(fwd, 0.0) / (kerb > 0.0 ? 10.0 : 7.5));
            float3 beam = k < 0.6 ? float3(1.0, 0.93, 0.84) : float3(1.0, 0.80, 0.58);
            light += (c * 0.8 + 0.12) * beam * wedge * reach * 0.45;
            float2 lamp = float2(abs(d.x) - 0.72, fwd + 0.15);
            light += beam * (1.0 / (1.0 + dot(lamp, lamp) / 0.05)) * 0.9;
            float2 tail = float2(abs(d.x) - 0.78, d.y * dir + 2.65);
            light += float3(1.0, 0.10, 0.06) * (1.0 / (1.0 + dot(tail, tail) / 0.03)) * 0.8;
        }
    }
    return result;
}

fragment ViewOut viewGround(VertexOut in [[stage_in]],
                            constant CompositeParams &params [[buffer(0)]],
                            constant Scene &scene [[buffer(1)]],
                            texture2d<float> groundColor [[texture(0)]],
                            texture2d<float> groundNight [[texture(1)]],
                            texture2d<float> cloudTexture [[texture(2)]],
                            texture2d<float> noise [[texture(4)]],
                            sampler wrap [[sampler(0)]],
                            sampler clampSampler [[sampler(1)]]) {
    float2 size = params.view.xy;
    float2 pixel = float2(in.position.x, size.y - in.position.y);
    float mpp = params.view.z;
    float2 world = params.world.xy + pixel * mpp;

    float2 texel = params.cache.xy + pixel * params.view.w;
    float3 c = groundColor.sample(wrap, texel / params.cache.zw).rgb;
    float2 wrapped = texel - floor(texel / params.cache.zw) * params.cache.zw;
    uint2 nearest = uint2(min(wrapped, params.cache.zw - 1.0));
    Mask mask = unpack(groundColor.read(nearest).a);
    float water = mask.water;
    float3 light = 0.0;

    // Gusts roll across tall crops in long soft bands.
    if (mask.sway > 0.01) {
        float2 gp = (params.world.zw + pixel * mpp) / float2(160.0, 55.0);
        c *= 1.0 + mask.sway * 0.09 * (latticeNoise(noise, wrap, gp) - 0.45);
    }

    bool inB = world.y > scene.morph.x + scene.morph.y * 0.5;
    constant Leg &leg = inB ? scene.legB : scene.legA;
    if (mask.road) c = cars(c, world, leg.biome, scene, mpp, light);

    // Water mirrors the sky: clouds overhead brighten it, and the sun glints off ripples.
    if (water > 0.01) {
        float2 cloudPx = (params.clouds.xy + pixel * mpp) / params.clouds.z;
        float2 cloudSize = float2(cloudTexture.get_width(), cloudTexture.get_height());
        float overhead = cloudTexture.sample(clampSampler, float2(cloudPx.x, cloudSize.y - cloudPx.y) / cloudSize).x;
        c = mix(c, c + float3(0.16, 0.17, 0.2), water * overhead * 0.8);
        if (water > 0.99) {
            float2 gcell = floor(world / 2.4);
            float gh = hash21(int2(gcell), 160u);
            if (gh > 0.9) {
                float2 gpos = (gcell + 0.2 + 0.6 * hash22(int2(gcell), 161u)) * 2.4;
                float sparkle = fill(length(world - gpos) - 0.22, mpp * 1.2);
                float wave = saturate(sin(scene.time.x * (1.2 + gh * 1.8) + gh * 40.0));
                wave *= wave; wave *= wave; wave *= wave; wave *= wave;
                c = mix(c, float3(1.0, 1.0, 0.97), wave * sparkle * 0.8 * (1.0 - overhead));
            }
        }
    }

    // After dark, baked lamplight comes on house by house; the ground it falls on shows its day colour, warmed.
    float night = scene.time.w;
    float2 lamp = night > 0.0 ? groundNight.read(nearest).rg : 0.0;
    if (lamp.x > 0.004) {
        float id = lamp.y;
        float on = id > 0.99 ? smoothstep(0.1, 0.35, night) : houseOn(id, scene.clock.x, scene.clock.y);
        float3 tint = id > 0.99 ? leg.biome.lamp.rgb : float3(1.0, 0.68, 0.35);
        // About one lit house in ten has a television on in the evening: cool and restless.
        float hour = scene.clock.x < 12.0 ? scene.clock.x + 24.0 : scene.clock.x;
        if (id < 0.99 && fract(id * 41.3) > 0.9 && hour > 20.5 && hour < 23.6) {
            tint = float3(0.62, 0.72, 1.0) * (0.75 + 0.25 * sin(scene.time.x * 3.1 + id * 90.0));
        }
        float pool = lamp.x * on;
        // Lit ground shows its own colour warmed, over a little of the lamp's own colour so it never turns olive.
        light += (c * 0.85 + 0.18) * tint * pool;
        light += float3(1.0, 0.95, 0.85) * smoothstep(0.9, 1.0, pool) * 0.6;
    }

    ViewOut out;
    out.color = float4(c, 1.0);
    out.light = float4(light, 1.0);
    return out;
}

// MARK: - Herds as instanced sprites

struct AnimalParams {
    float4 grid;   // first cell x, y, cells across, cell spacing
    float4 leg;    // leg start (y relative to the reference), lowest and highest world y this batch draws, unused
    float4 drift;  // herd drift x, y, unused, unused
};

struct AnimalOut {
    float4 position [[position]];
    float2 offset;             // metres from the animal, in its own frame
    float2 shadow;             // metres from where its shadow falls, in its own frame
    float4 coat [[flat]];      // rgb and kind
    float2 extent [[flat]];    // half length, half width
};

vertex AnimalOut animalVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant AnimalParams &p [[buffer(0)]],
                              constant Leg &leg [[buffer(1)]],
                              constant Scene &scene [[buffer(2)]],
                              constant CompositeParams &params [[buffer(3)]],
                              texture2d<float> groundColor [[texture(0)]]) {
    AnimalOut out;
    out.position = float4(2.0, 2.0, 0.0, 1.0);
    out.offset = 0.0;
    out.shadow = 0.0;
    out.coat = 0.0;
    out.extent = 1.0;
    constant Biome &b = leg.biome;
    uint seed = uint(leg.info.y);
    int kind = int(b.f.w);
    float herds = b.g.x;
    int across = int(p.grid.z);
    float spacing = p.grid.w;
    int2 cell = int2(p.grid.xy) + int2(int(iid) % across, int(iid) / across);
    float2 cellCenter = (float2(cell) + 0.5) * spacing;

    // Herds are decided in a frame that drifts slowly, so they wander as a whole.
    float herd = smoothstep(1.0 - herds * 0.7, 1.08 - herds * 0.5, vnoise(cellCenter / 110.0, seed + 120u));
    float h = hash21(cell, seed + 121u);
    if (h > herd * 0.42) return out;

    // Graze, then take a few steps somewhere else.
    float t = scene.time.y;
    float period = 9.0 + 7.0 * hash21(cell, seed + 122u);
    float phase = t / period + h * 13.0;
    float strides = floor(phase) + smoothstep(0.75, 1.0, fract(phase));
    float2 jitter = (hash22(cell, seed + 123u) - 0.5) * spacing * 0.5;
    float2 walk = float2(sin(strides * 1.7 + h * 40.0), cos(strides * 1.3 + h * 17.0)) * 1.6;
    float2 local = cellCenter + jitter + walk + p.drift.xy;
    float2 world = float2(local.x, local.y + p.leg.x);
    if (world.y < p.leg.y || world.y >= p.leg.z) return out;
    // Only where the ground says animals belong.
    if (!unpack(groundColor.read(cacheTexel(world, params)).a).herd) return out;

    float heading = hash21(cell, seed + 124u) * 6.283 + 0.6 * sin(strides * 0.9 + h * 9.0);
    // Drawn larger than life so they read from this height, as in a painted map.
    float len = (kind == sheep ? 1.2 : kind == zebra ? 1.45 : kind == gazelle ? 0.9 : 1.6) * 1.6;
    float wid = (kind == sheep ? 0.75 : kind == gazelle ? 0.42 : 0.62) * 1.6;
    float2 shadowOff = -scene.sun.xy * scene.sun.z * 1.1;
    float reach = len * 1.35 + length(shadowOff) + params.view.z * 2.0;

    float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0) * reach;
    float2 pixel = (world + corner - params.world.xy) / params.view.z;
    out.position = float4(pixel / params.view.xy * 2.0 - 1.0, 0.0, 1.0);
    out.offset = rotate(corner, -heading);
    out.shadow = rotate(corner - shadowOff, -heading);
    float3 coat = b.animalColor.rgb * (0.85 + 0.3 * hash21(cell, seed + 125u));
    out.coat = float4(coat, float(kind));
    out.extent = float2(len, wid);
    return out;
}

fragment SkyOut animalFragment(AnimalOut in [[stage_in]], float4 below [[color(0)]],
                               constant CompositeParams &params [[buffer(0)]],
                               constant Scene &scene [[buffer(1)]]) {
    float len = in.extent.x, wid = in.extent.y;
    float px = params.view.z;
    float2 d = in.offset;
    bool isGazelle = in.coat.w == float(gazelle);
    float body = length(d / float2(len, wid)) - 1.0;
    float head = length((d - float2(len * 1.05, 0.0)) / (float2(0.7, 0.5) * (isGazelle ? 0.6 : 1.0))) - 1.0;
    float shadowBody = length(in.shadow / float2(len, wid)) - 1.0;
    float3 c = shade(below.rgb, fill(shadowBody, px * 0.9) * 0.7, scene);
    float3 coat = in.coat.rgb;
    if (in.coat.w == float(zebra)) {
        float band = step(0.5, fract(d.x * 1.0 + 0.3 * d.y));
        coat = mix(float3(0.96, 0.95, 0.92), float3(0.12, 0.12, 0.14), band * 0.9);
    } else if (isGazelle) {
        // Thomson's gazelles: tan backs, a dark side stripe, pale bellies.
        coat = mix(coat, float3(0.18, 0.13, 0.10), fill(abs(abs(d.y) - wid * 0.62) - wid * 0.12, 0.05) * 0.7);
    }
    float a = fill(min(body * len, head * 0.5), px * 0.6);
    SkyOut out;
    out.color = float4(mix(c, coat, a), 1.0);
    return out;
}

// MARK: - Sky

inline float taperedSegment(float2 p, float2 a, float2 b, float ra, float rb) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h) - mix(ra, rb, h);
}

// A gull seen from above, facing +y, wingtips at x = ±1. Each wing is an inner arm that reaches slightly
// forward to the wrist and a hand that sweeps back to a fine point.
inline float birdShape(float2 p, float spread, float bank) {
    // Wings shorten on the side the bird banks towards; a wingbeat only shortens the span a little.
    float side = p.x < 0.0 ? 1.0 - bank * 0.3 : 1.0 + bank * 0.3;
    float span = (0.82 + 0.18 * spread) * side;
    float2 q = float2(abs(p.x) / span, p.y);
    float wrist = 0.08 + 0.07 * (1.0 - spread);
    float inner = taperedSegment(q, float2(0.03, 0.02), float2(0.5, wrist), 0.12, 0.085);
    float hand = taperedSegment(q, float2(0.5, wrist), float2(1.0, -0.1), 0.085, 0.01);
    float wing = min(inner, hand) * span;
    float body = (length(p / float2(0.078, 0.31)) - 1.0) * 0.078;
    float head = length(p - float2(0.0, 0.27)) - 0.06;
    float tail = sdBox(p - float2(0.0, -0.31), float2(0.05 + 0.3 * max(-p.y - 0.27, 0.0), 0.06));
    return smin(smin(body, head, 0.06), min(wing, tail), 0.05);
}

// Paper grain and the dry-brush edge never move, so they are painted once per size at half resolution.
fragment float4 paper(VertexOut in [[stage_in]], constant float4 &params [[buffer(0)]]) {
    float2 size = params.xy;
    float2 p = in.position.xy / params.z;
    float grain = vnoise(p / 1.7, 170u) * 0.6 + vnoise(p / 0.9, 171u) * 0.4;
    float fibres = vnoise(p * float2(1.0 / 9.0, 1.0 / 1.4), 172u);
    float2 edgeDist = min(p, size - p);
    float edge = min(edgeDist.x, edgeDist.y) / max(size.x, size.y);
    float bristles = vnoise(p / float2(3.0, 40.0), 173u) * 0.5 + vnoise(p / float2(40.0, 3.0), 174u) * 0.5;
    float vignette = 1.0 - smoothstep(0.0, 0.006 + 0.012 * bristles, edge);
    return float4(saturate(0.5 + 0.05 * (grain - 0.5) + 0.03 * (fibres - 0.5)), vignette, 0.0, 1.0);
}

fragment SkyOut sky(VertexOut in [[stage_in]],
                    float4 below [[color(0)]],
                    float4 lamplight [[color(1)]],
                    constant CompositeParams &params [[buffer(0)]],
                    constant Scene &scene [[buffer(1)]],
                    texture2d<float> cloudTexture [[texture(2)]],
                    texture2d<float> paperTexture [[texture(3)]],
                    sampler clampSampler [[sampler(1)]]) {
    float2 size = params.view.xy;
    float2 pixel = float2(in.position.x, size.y - in.position.y);
    float mpp = params.view.z;
    float3 c = below.rgb;

    // Clouds were painted a while ago with a margin; slide them by how far they have drifted since.
    float2 cloudTexSize = float2(cloudTexture.get_width(), cloudTexture.get_height());
    float2 cloudPx = (params.clouds.xy + pixel * mpp) / params.clouds.z;
    float4 cloud = cloudTexture.sample(clampSampler, float2(cloudPx.x, cloudTexSize.y - cloudPx.y) / cloudTexSize);

    // Cloud shadow, then the bird's shadow, then clouds, then the bird above it all.
    c = shade(c, smoothstep(0.05, 0.8, cloud.z) * 0.62, scene);

    float birdVisible = params.wings.w;
    float2 birdPx = params.bird.xy;
    float scale = params.wings.z;
    if (birdVisible > 0.0) {
        float2 shadowPx = birdPx - scene.sun.xy * scene.sun.z * params.wings.y / mpp;
        float2 offset = pixel - shadowPx;
        if (dot(offset, offset) < scale * scale * 1.6) {
            float2 q = rotate(offset, -params.bird.z) / scale;
            c = shade(c, fill(birdShape(q, params.wings.x, params.bird.w), 0.9 / scale) * 0.55 * birdVisible, scene);
        }
    }

    float cloudAlpha = smoothstep(0.02, 0.6, cloud.x);
    if (cloudAlpha > 0.0) {
        float3 cloudColor = mix(float3(0.66, 0.72, 0.86), float3(1.0, 1.0, 0.99), smoothstep(0.1, 0.95, cloud.y));
        c = mix(c, cloudColor, cloudAlpha);
    }

    if (birdVisible > 0.0) {
        float2 offset = pixel - birdPx;
        if (dot(offset, offset) < scale * scale * 1.6) {
            float2 q = rotate(offset, -params.bird.z) / scale;
            float sb = birdShape(q, params.wings.x, params.bird.w);
            float underside = saturate(0.5 - q.y * 0.6 + params.bird.w * q.x * 0.5);
            float3 feathers = mix(float3(0.99, 0.99, 0.98), float3(0.78, 0.81, 0.87), underside * 0.6);
            // Dark wingtips, as gulls have.
            feathers = mix(feathers, float3(0.24, 0.25, 0.28), smoothstep(0.8, 0.9, abs(q.x)) * 0.85);
            float through = birdVisible * (1.0 - 0.6 * smoothstep(0.3, 0.9, cloud.x));
            // A faint darker rim keeps the white bird readable over pale ground and cloud.
            c = mix(c, c * 0.72, fill(sb - 0.025, 0.9 / scale) * 0.45 * through);
            c = mix(c, feathers, fill(sb, 0.8 / scale) * through);
        }
    }

    // Paper grain that does not scroll with the paint, and a soft dry-brush edge.
    float2 paper = paperTexture.sample(clampSampler, in.position.xy / size).rg;
    c *= 1.0 + params.finish.x * (paper.x - 0.5);
    c = mix(c, float3(0.97, 0.95, 0.91), paper.y * params.finish.y);

    // Light for the time of day. At night colour drains towards a cool moonlit blue but the shapes keep their
    // values, so it still reads as the same painting; lamplight then comes through, except under low cloud.
    float night = scene.time.w;
    float3 lit = c * scene.light.rgb * scene.light.w;
    if (night > 0.0) {
        float3 moonlit = mix(float3(luma(c)), c, 0.4) * float3(0.44, 0.54, 0.76) * 0.78 + float3(0.015, 0.02, 0.045);
        // Clouds hold far less moonlight than their daytime white suggests.
        moonlit *= 1.0 - 0.42 * cloudAlpha;
        c = mix(lit, moonlit, night);
        c += lamplight.rgb * night * (1.0 - 0.85 * cloudAlpha);
    } else {
        c = lit;
    }

    SkyOut out;
    out.color = float4(saturate(c), 1.0);
    return out;
}

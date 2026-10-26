// FROZEN COPY: this file is the shader as Outbound v1.0 shipped it. The app never loads it; only ShaderTests
// compiles it, to compare the real shaders in Sources/Outbound/Shaders against what people first got.
//
// It is older than those shaders and drifts from them by design. Don't fix, tidy or improve it here. When a
// change to the look is meant, copy the current shader over this file and put this note back at the top.

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

// One street lamp's light on the ground. `value` is the baked pool below 0.8 and the glowing head above it;
// `lamp` tells lamps apart, 0 to 1. Photocells switch lamps on a few at a time through dusk. Older sodium
// lamps glow a dim pinkish red for their first minutes before reaching their orange, newer LED lamps come
// on at once in the place's own white. Now and then one is failing and stutters. Some villages, as in much
// of rural France, switch their lamps off from midnight until five.
inline float3 streetLight(float3 c, float value, float lamp, float night, float hour, constant Biome &b, float time) {
    float h1 = fract(lamp * 7.13 + 0.31), h2 = fract(lamp * 17.9 + 0.57);
    float start = 0.08 + 0.14 * h1;
    float on = smoothstep(start, start + 0.02, night);
    if (b.k.y > 0.5) on *= 1.0 - step(24.0, hour) * step(hour, 29.0);
    bool sodium = h2 < b.k.x;
    float3 tint = b.lamp.rgb;
    if (sodium) {
        float warm = saturate((night - start) / 0.12);
        tint = mix(float3(0.95, 0.45, 0.32), float3(1.0, 0.6, 0.22), warm);
        on *= mix(0.35, 1.0, warm);
    }
    if (fract(lamp * 31.7) > 0.955) {
        float tick = floor(time * 9.0);
        float burst = step(0.82, fract(sin(floor(time / 6.0) * 12.9898 + lamp * 78.2) * 43758.5));
        on *= 1.0 - burst * step(0.45, fract(sin(tick * 12.9898 + lamp * 4.1) * 43758.5)) * 0.85;
    }
    if (on <= 0.0) return 0.0;
    float pool = min(value, 0.8) / 0.8;
    float glow = saturate((value - 0.8) / 0.2);
    // The lamp's colour wins over the ground's: grass under a lamp reads pale, not lurid green.
    float3 ground = mix(float3(luma(c)), c, 0.45) * 0.85 + 0.2;
    float3 light = ground * tint * (pool * pool * 0.85 + pool * 0.25);
    light += tint * glow * 0.7 + float3(1.0, 0.98, 0.94) * glow * glow * glow * 0.5;
    return light * on;
}

// Cars ride slots along the road, northbound on one side and southbound on the other, each pointing along the road
// and keeping to its lane through the bends. Whose traffic it is and where the road runs are decided where the car
// is, so a car is never cut in two where one place turns into the next.
inline float3 cars(float3 c, float2 world, constant Scene &scene, float mpp, thread float3 &light) {
    float night = scene.time.w;
    constant Biome &a = scene.legA.biome;
    constant Biome &b = scene.legB.biome;
    float3 result = c;
    for (int lane = 0; lane < 2; lane++) {
        float dir = lane == 0 ? 1.0 : -1.0;
        Slot slot = slotAt(world.y, carSlot, dir, scene.time.z, lane == 0 ? scene.traffic.x : scene.traffic.y);
        // A car and its shadow reach a few metres from its slot's middle; most of the road is empty.
        if (abs(world.y - slot.y) > 8.0) continue;
        int id = slot.id * 2 + lane;
        float m = landTurn(slot.y, scene);
        if (hash11(id, 140u) > min(mix(a.g.y, b.g.y, m) * 1.6, 0.75)) continue;
        float2 wander = course(scene, m);
        float width = mix(a.e.x, b.e.x, m);
        // Northbound traffic keeps to its side of the road: the west side where traffic keeps left.
        float keepLeft = mix(a.h.x, b.h.x, smoothstep(0.3, 0.7, m));
        float side = mix(dir, -dir, keepLeft);
        float2 along = normalize(float2(roadSlope(slot.y, scene, wander), 1.0));
        float2 across = float2(along.y, -along.x);
        float2 center = float2(roadX(slot.y, scene, wander), slot.y) + across * side * width * 0.25;
        float2 rel = world - center;
        // Car-local metres: x across to its right, y forward.
        float2 q = float2(dot(rel, across), dot(rel, along)) * dir;
        if (dot(q, q) > 140.0) continue;
        float2 sun = float2(dot(scene.sun.xy, across), dot(scene.sun.xy, along)) * dir;

        // A car stands about 1.5 m tall; its shadow stays attached however low the sun.
        float2 size = float2(0.85, 2.15);
        float2 shadowOff = -sun * min(scene.sun.z, 1.6) * 1.5;
        result = shade(result, fill(sweptBox(q, size, shadowOff) - 0.25, mpp) * 0.7, scene);
        float k = hash11(id, 141u);
        float3 paint = k < 0.3 ? float3(0.95, 0.95, 0.93) : k < 0.45 ? float3(0.82, 0.18, 0.16)
                     : k < 0.6 ? float3(0.20, 0.34, 0.62) : k < 0.75 ? float3(0.16, 0.16, 0.18)
                     : k < 0.88 ? float3(0.70, 0.71, 0.72) : float3(0.93, 0.74, 0.18);
        // From above: bonnet, windscreen, roof, rear window and boot, the sunward edge of the roof catching light.
        float body = sdBox(q, size) - 0.25;
        float cabin = sdBox(q - float2(0.0, -0.1), float2(0.72, 1.2)) - 0.12;
        float roof = sdBox(q - float2(0.0, -0.2), float2(0.64, 0.68)) - 0.1;
        float3 glass = mix(float3(0.10, 0.12, 0.15), float3(0.42, 0.47, 0.55), 0.25 * saturate(0.5 + 0.5 * sun.y));
        float3 top = paint * (0.9 + 0.12 * saturate(dot(normalize(q + 1e-4), sun)));
        result = mix(result, paint * 0.92, fill(body, mpp * 0.7));
        result = mix(result, glass, fill(cabin, mpp * 0.6));
        result = mix(result, top, fill(roof, mpp * 0.6));

        if (night > 0.01) {
            // From straight above, headlights only show where they land: a soft wedge on the tarmac, reaching
            // further on the kerb side, hot dots at the front corners and red ones at the back.
            float fwd = q.y - 2.6;
            float lat = q.x;
            float kerb = keepLeft > 0.5 ? -lat : lat;
            float halfW = 0.95 + fwd * (kerb > 0.0 ? 0.24 : 0.17);
            float wedge = fill(abs(lat) - halfW, 0.5 + fwd * 0.08) * smoothstep(-0.3, 1.2, fwd);
            float reach = exp(-max(fwd, 0.0) / (kerb > 0.0 ? 10.0 : 7.5));
            float3 beam = k < 0.6 ? float3(1.0, 0.93, 0.84) : float3(1.0, 0.80, 0.58);
            light += (c * 0.8 + 0.12) * beam * wedge * reach * 0.45;
            float2 lamp = float2(abs(q.x) - 0.65, fwd + 0.25);
            light += beam * (1.0 / (1.0 + dot(lamp, lamp) / 0.05)) * 0.9;
            float2 tail = float2(abs(q.x) - 0.7, q.y + 2.35);
            light += float3(1.0, 0.10, 0.06) * (1.0 / (1.0 + dot(tail, tail) / 0.03)) * 0.8;
        }
    }
    return result;
}

// MARK: - Trains and boats

// The train as one box per car along the line. `lp` comes back in car-local metres: x across, y along.
inline float trainShape(float2 p, constant Train &tr, thread float2 &lp, thread float &k) {
    float along;
    float d = railSigned(p, tr.rail.xy, tr.rail.z, tr.shape.xyz, along);
    float u = (tr.run.x - along) * tr.run.y;
    float length = tr.run.z;
    float cars = tr.run.w + tr.info.x;
    k = clamp(floor(u / length), 0.0, cars - 1.0);
    lp = float2(d, u - (k + 0.5) * length);
    // Drawn a little wider than life, like the animals, so it reads from this height.
    float round = k == 0.0 ? 1.2 : 0.3;
    float gap = 0.6;
    return sdBox(lp, float2(2.1, length * 0.5 - gap) - round) - round;
}

inline float3 train(float3 c, float2 world, constant Train &tr, constant Scene &scene, float mpp,
                    thread float3 &light) {
    float2 lp, lps;
    float k, ks;
    // Its shadow: is the point towards the sun inside the train? A train stands about 4 m tall.
    float ds = trainShape(world + scene.sun.xy * scene.sun.z * 4.2, tr, lps, ks);
    c = shade(c, fill(ds, 0.5) * 0.8, scene);
    float db = trainShape(world, tr, lp, k);
    bool loco = k < tr.info.x;
    bool freight = tr.info.y > 0.5;
    if (db < 1.0) {
        float3 roof = loco ? tr.locomotive.rgb : tr.roof.rgb;
        if (freight && !loco) {
            // Covered hoppers, each weathered its own way, with a darker hatch strip down the middle.
            float wear = hash11(int(k), 521u);
            roof = mix(tr.body.rgb, tr.stripe.rgb, wear * wear * 0.8);
            roof = mix(roof, roof * 0.72, fill(abs(lp.x) - 0.3, 0.08));
            roof *= 1.0 - 0.18 * fill(abs(fract(lp.y / 3.4) - 0.5) * 3.4 - 0.08, 0.08);
        } else {
            // The livery carries the roof, with a pale roof strip down the middle and the stripe along each side.
            float3 body = loco ? tr.locomotive.rgb : tr.body.rgb;
            roof = mix(body, tr.roof.rgb, fill(abs(lp.x) - 0.7, 0.1) * 0.7);
            roof = mix(roof, tr.stripe.rgb, step(1.65, abs(lp.x)));
            roof *= 0.94 + 0.12 * hash11(int(k), 520u);
            if (!loco && int(k) % 2 == 0) {
                roof = mix(roof, float3(0.22, 0.23, 0.25), fill(abs(sdBox(lp + float2(0.0, tr.run.z * 0.3), float2(0.6, 0.8))) - 0.05, 0.06));
            }
        }
        c = mix(c, roof, fill(db, mpp * 0.7));
    }
    if (scene.time.w > 0.0 && !freight) {
        // Warm windows spill onto the ballast either side; the leading car throws a beam down the line.
        float out = abs(lp.x) - 2.2;
        float bay = step(0.5, fract(lp.y / 1.9 + 0.25));
        light += (c * 0.85 + 0.18) * float3(1.0, 0.83, 0.65) * 0.6 * fill(out - 1.4, 0.8) * smoothstep(-0.2, 0.3, out)
               * exp(-max(out, 0.0) / 0.9) * bay * step(abs(lp.y), tr.run.z * 0.5 - 1.0) * step(tr.info.x, k);
    }
    if (scene.time.w > 0.0) {
        float ahead = -(lp.y + tr.run.z * 0.5) * step(k, 0.0);
        light += float3(1.0, 0.92, 0.8) * 0.45 * fill(abs(lp.x) - 1.2 - ahead * 0.05, 0.6)
               * smoothstep(0.0, 1.0, ahead) * exp(-ahead / 25.0);
    }
    return c;
}

inline float3 boatPaint(float h) {
    return h < 0.3 ? float3(0.94, 0.94, 0.92) : h < 0.5 ? float3(0.78, 0.22, 0.18)
         : h < 0.7 ? float3(0.20, 0.38, 0.62) : h < 0.85 ? float3(0.22, 0.48, 0.32) : float3(0.66, 0.46, 0.28);
}

// Boats ride slots along the river, up and down stream, each with a Kelvin wake: two bright arms at 19.5
// degrees either side of its track, crest lines across them, and churned water straight behind. The wake is laid
// out along the river rather than straight back, so it follows the boat round a bend.
inline float3 boats(float3 c, float2 world, float water, constant Scene &scene, float mpp, float t,
                    thread float3 &light) {
    float3 result = c;
    for (int lane = 0; lane < 2; lane++) {
        float dir = lane == 0 ? 1.0 : -1.0;
        Slot slot = slotAt(world.y, boatSlot, dir, scene.clock.z, lane == 0 ? scene.traffic.z : scene.traffic.w);
        // Along the river is never shorter than along y, so a point this far from the bow is clear of boat and wake.
        float ahead = (slot.y - world.y) * dir;
        if (ahead < -10.0 || ahead > 80.0) continue;
        int id = slot.id * 2 + lane;
        float m = landTurn(slot.y, scene);
        constant Biome &b = m < 0.5 ? scene.legA.biome : scene.legB.biome;
        if (b.h.z <= 0.0 || hash11(id, 600u) > b.h.z * 0.6) continue;
        float2 wander = course(scene, m);
        float width = mix(scene.legA.biome.d.z, scene.legB.biome.d.z, m);
        bool hippos = b.h.w > 1.5;
        float speed = hippos ? 0.0 : 2.0 + 3.0 * hash11(id, 603u);
        float slope = riverSlope(world.y, scene, wander);
        float stretch = sqrt(1.0 + slope * slope);
        // u runs back from the bow along the river, v across it from the boat's line.
        float u = (slot.y - world.y) * dir * stretch;
        float v = (world.x - riverX(world.y, scene, wander)) / stretch - width * (0.1 + 0.15 * hash11(id, 601u)) * dir;
        if (u < -10.0 || u > 80.0) continue;
        float2 along = float2(slope, 1.0) / stretch;
        float2 across = float2(along.y, -along.x);
        float2 sun = float2(dot(scene.sun.xy, across), dot(scene.sun.xy, along)) * dir;
        if (hippos) {
            // A pod of backs in the water, each with slow ripple rings.
            for (int h = 0; h < 4; h++) {
                float2 at = float2((hash11(id * 8 + h, 610u) - 0.5) * 8.0, (hash11(id * 8 + h, 611u) - 0.5) * 14.0);
                float2 q = float2(v, -u) - at;
                float ring = fract(t * 0.18 + hash11(id * 8 + h, 612u));
                result = mix(result, result * 1.15 + 0.05, fill(abs(length(q) - 1.6 - ring * 4.0) - 0.12, 0.15)
                             * (1.0 - ring) * water * 0.6);
                float back = (length(q / float2(0.95, 1.6)) - 1.0) * 0.95;
                result = mix(result, float3(0.42, 0.40, 0.42), fill(back, mpp * 0.7));
            }
            continue;
        }
        float L = 4.0 + 4.0 * hash11(id, 604u), W = L * 0.22;
        if (water > 0.3 && u > 0.0) {
            float fade = exp(-u / 28.0);
            float edge = abs(v) - 0.354 * u;
            float arm = fill(abs(edge) - 0.22 - 0.012 * u, 0.35 + 0.02 * u);
            float feather = smoothstep(0.55, 1.0, 0.5 + 0.5 * sin((u * 0.82 + abs(v) * 0.57) * 6.283 / (0.5 + 0.06 * u)));
            float lambda = 6.283 * speed * speed / 9.81;
            float trans = smoothstep(0.65, 1.0, 0.5 + 0.5 * cos(6.283 * (u + 0.9 * v * v / max(u, 1.0)) / lambda));
            float wash = fill(abs(v) - (W * 0.7 + 0.04 * u), 0.4) * smoothstep(0.0, 2.0, u - L) * exp(-u / 14.0);
            float foam = (arm * (0.5 + 0.5 * feather) + fill(edge, 0.6) * trans * 0.22) * fade + wash * 0.6;
            result *= 1.0 - 0.07 * fill(abs(edge - 0.7) - 0.3, 0.4) * fade;
            result = mix(result, float3(0.93, 0.95, 0.96), saturate(foam) * 0.55 * water);
        }
        // Hull: pointed bow, rounded stern, a little shadow, someone aboard.
        float2 hp = float2(v * dir, -u + L * 0.5);
        float taper = 1.0 + 1.3 * saturate(hp.y / (L * 0.5));
        float2 hs = hp + sun * scene.sun.z * 0.5;
        float hullShadow = (length(float2(hs.x * taper / W, hs.y / (L * 0.5))) - 1.0) * W;
        result = shade(result, fill(hullShadow, 0.3) * 0.6, scene);
        float hull = (length(float2(hp.x * taper / W, hp.y / (L * 0.5))) - 1.0) * W;
        float3 paint = boatPaint(hash11(id, 605u));
        result = mix(result, paint, fill(hull, mpp * 0.6));
        result = mix(result, float3(0.60, 0.42, 0.26), fill(hull + 0.22, mpp * 0.6));
        result = mix(result, float3(0.18, 0.17, 0.2), fill(length(hp - float2(0.0, -L * 0.15)) - 0.32, mpp));
        if (scene.time.w > 0.0) {
            float2 port = hp - float2(-W, L * 0.1), starboard = hp - float2(W, L * 0.1), stern = hp - float2(0.0, -L * 0.5);
            light += float3(1.0, 0.12, 0.08) / (1.0 + dot(port, port) / 0.03);
            light += float3(0.15, 1.0, 0.35) / (1.0 + dot(starboard, starboard) / 0.03);
            light += float3(1.0, 0.95, 0.85) / (1.0 + dot(stern, stern) / 0.04);
        }
    }
    return result;
}

// The ground's colour at a cache texel position. As the ground pans, each pixel lands at a different fraction of a
// texel every frame, and one bilinear tap blurs it by a different amount each time, so fine detail pulses as it
// moves; on a Retina display the pixels are too small to see it. The other filters blur by nearly the same amount
// at any fraction: 1, a box over the pixel's footprint; 2, a cubic B-spline from four bilinear taps; 3, a B-spline
// down the direction of flight only, from two.
inline float3 groundColorAt(texture2d<float> ground, sampler wrap, float2 texel, float2 size, float filter,
                            float footprint) {
    if (filter < 0.5) return ground.sample(wrap, texel / size).rgb;
    if (filter < 1.5) {
        float q = footprint * 0.25;
        return 0.25 * (ground.sample(wrap, (texel + float2(-q, -q)) / size).rgb
                     + ground.sample(wrap, (texel + float2(q, -q)) / size).rgb
                     + ground.sample(wrap, (texel + float2(-q, q)) / size).rgb
                     + ground.sample(wrap, (texel + float2(q, q)) / size).rgb);
    }
    // The B-spline's weights for the four texels either side, folded into two bilinear taps per axis.
    float2 t = texel - 0.5;
    float2 i = floor(t), f = t - i;
    float2 w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
    float2 w1 = (4.0 - 6.0 * f * f + 3.0 * f * f * f) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f * f - 3.0 * f * f * f) / 6.0;
    float2 w3 = f * f * f / 6.0;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 h0 = i - 0.5 + w1 / g0, h1 = i + 1.5 + w3 / g1;
    if (filter < 2.5) {
        return g0.y * (g0.x * ground.sample(wrap, float2(h0.x, h0.y) / size).rgb
                     + g1.x * ground.sample(wrap, float2(h1.x, h0.y) / size).rgb)
             + g1.y * (g0.x * ground.sample(wrap, float2(h0.x, h1.y) / size).rgb
                     + g1.x * ground.sample(wrap, float2(h1.x, h1.y) / size).rgb);
    }
    return g0.y * ground.sample(wrap, float2(texel.x, h0.y) / size).rgb
         + g1.y * ground.sample(wrap, float2(texel.x, h1.y) / size).rgb;
}

fragment ViewOut viewGround(VertexOut in [[stage_in]],
                            constant CompositeParams &params [[buffer(0)]],
                            constant Scene &scene [[buffer(1)]],
                            texture2d<float> groundColor [[texture(0)]],
                            texture2d<float> groundNight [[texture(1)]],
                            texture2d<float> cloudTexture [[texture(2)]],
                            texture2d<float> noise [[texture(4)]],
                            texture2d<float> incomingColor [[texture(5)]],
                            texture2d<float> incomingNight [[texture(6)]],
                            sampler wrap [[sampler(0)]],
                            sampler clampSampler [[sampler(1)]]) {
    float2 size = params.view.xy;
    float2 pixel = float2(in.position.x, size.y - in.position.y);
    float mpp = params.view.z;
    float2 world = params.world.xy + pixel * mpp;

    float2 texel = params.cache.xy + pixel * params.view.w;
    float3 c = groundColorAt(groundColor, wrap, texel, params.cache.zw, params.finish.w, params.view.w);
    float2 wrapped = texel - floor(texel / params.cache.zw) * params.cache.zw;
    uint2 nearest = uint2(min(wrapped, params.cache.zw - 1.0));
    // While a Fly To sweeps, the new place is painted into a cache of its own and blended in here, with a darker
    // tide line where the two paints meet.
    float turned = sweepBlend(world, scene);
    if (turned > 0.0) {
        float3 next = groundColorAt(incomingColor, wrap, texel, params.cache.zw, params.finish.w, params.view.w);
        c = mix(c, next, turned) * (1.0 - 0.12 * (1.0 - abs(turned * 2.0 - 1.0)));
    }
    texture2d<float> landColor = turned > 0.5 ? incomingColor : groundColor;
    texture2d<float> landNight = turned > 0.5 ? incomingNight : groundNight;
    Mask mask = unpack(landColor.read(nearest).a);
    float water = mask.water;
    float3 light = 0.0;

    // Gusts roll across tall crops in long soft bands.
    if (mask.sway > 0.01) {
        float2 gp = (params.world.zw + pixel * mpp) / float2(160.0, 55.0);
        c *= 1.0 + mask.sway * 0.09 * (latticeNoise(noise, wrap, gp) - 0.45);
    }

    constant Leg &leg = landTurn(world.y, scene) > 0.5 ? scene.legB : scene.legA;
    if (mask.road) c = cars(c, world, scene, mpp, light);
    if (water > 0.99) c = boats(c, world, water, scene, mpp, scene.time.x, light);
    if (scene.train.rail.w > 0.0) {
        float along;
        if (abs(railSigned(world, scene.train.rail.xy, scene.train.rail.z, scene.train.shape.xyz, along)) < 9.0 + 4.2 * scene.sun.z) {
            c = train(c, world, scene.train, scene, mpp, light);
        }
    }

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
    float2 lamp = night > 0.0 ? landNight.read(nearest).rg : 0.0;
    // Smoothed ground gets smoothed lamplight too, or the pools step a whole texel at a time; the lamp's id stays
    // the nearest texel's.
    if (night > 0.0 && params.finish.w > 0.5) lamp.x = landNight.sample(wrap, texel / params.cache.zw).r;
    if (lamp.x > 0.004) {
        float id = lamp.y;
        float hour = scene.clock.x < 12.0 ? scene.clock.x + 24.0 : scene.clock.x;
        if (id > 0.895) {
            light += streetLight(c, lamp.x, (id - 0.9) * 10.0, night, hour, leg.biome, scene.time.x);
        } else {
            float on = houseOn(id, scene.clock.x, scene.clock.y);
            float3 tint = float3(1.0, 0.68, 0.35);
            // About one lit house in ten has a television on in the evening: cool and restless.
            if (fract(id * 41.3) > 0.9 && hour > 20.5 && hour < 23.6) {
                tint = float3(0.62, 0.72, 1.0) * (0.75 + 0.25 * sin(scene.time.x * 3.1 + id * 90.0));
            }
            float pool = lamp.x * on;
            // Lit ground shows its own colour warmed, over a little of the lamp's own colour so it never turns olive.
            light += (mix(float3(luma(c)), c, 0.65) * 0.85 + 0.22) * tint * pool * 1.35;
            light += float3(1.0, 0.95, 0.85) * smoothstep(0.9, 1.0, pool) * 0.6;
        }
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
    float4 patches [[flat]];   // patch colour and whether there are any, then a seed in the alpha's fraction
};

vertex AnimalOut animalVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant AnimalParams &p [[buffer(0)]],
                              constant Leg &leg [[buffer(1)]],
                              constant Scene &scene [[buffer(2)]],
                              constant CompositeParams &params [[buffer(3)]],
                              texture2d<float> groundColor [[texture(0)]],
                              texture2d<float> incomingColor [[texture(1)]]) {
    AnimalOut out;
    out.position = float4(2.0, 2.0, 0.0, 1.0);
    out.offset = 0.0;
    out.shadow = 0.0;
    out.coat = 0.0;
    out.extent = 1.0;
    out.patches = 0.0;
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
    // Only where the ground says animals belong, in whichever painting it has turned to during a Fly To.
    texture2d<float> land = sweepBlend(world, scene) > 0.5 ? incomingColor : groundColor;
    if (!unpack(land.read(cacheTexel(world, params)).a).herd) return out;

    float heading = hash21(cell, seed + 124u) * 6.283 + 0.6 * sin(strides * 0.9 + h * 9.0);
    // Drawn larger than life so they read from this height, as in a painted map.
    float len = (kind == sheep ? 1.2 : kind == zebra ? 1.45 : kind == gazelle ? 0.9 : 1.6) * 1.6;
    float wid = (kind == sheep ? 0.75 : kind == gazelle ? 0.42 : 0.62) * 1.6;
    float2 shadowOff = -scene.sun.xy * scene.sun.z * 1.1;
    // A quad just big enough for the animal, its head and its shadow, so herds cost as few pixels as possible.
    float2 heading2 = float2(cos(heading), sin(heading));
    float2 centre = world + heading2 * len * 0.25 + shadowOff * 0.5;
    float reach = len * 1.3 + length(shadowOff) * 0.5 + params.view.z * 2.0;
    float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0) * reach;
    corner += centre - world;
    float2 pixel = (world + corner - params.world.xy) / params.view.z;
    out.position = float4(pixel / params.view.xy * 2.0 - 1.0, 0.0, 1.0);
    out.offset = rotate(corner, -heading);
    out.shadow = rotate(corner - shadowOff, -heading);
    float3 coat = b.animalColor.rgb * (0.85 + 0.3 * hash21(cell, seed + 125u));
    out.coat = float4(coat, float(kind));
    out.extent = float2(len, wid);
    out.patches = float4(b.animalPatches.rgb, b.animalPatches.w > 0.5 ? 1.0 + h : 0.0);
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
    } else if (in.patches.w > 0.5) {
        // Patched coats, each animal its own: Normande brown on white, Hereford white faces on red.
        float seed = fract(in.patches.w) * 50.0;
        float patch = smoothstep(0.48, 0.56, vnoise(d * 1.1 + seed, 130u));
        coat = mix(coat, in.patches.rgb, patch);
        coat = mix(coat, float3(0.93, 0.91, 0.87), fill(length(d - float2(len * 1.05, 0.0)) - 0.55, 0.1) * step(in.patches.r, 0.7));
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

// MARK: - Flocks

// The nearest bird of the flock to `pixel`, as a signed distance in pixels. Skeins find their bird in O(1):
// which arm, then which slot along it. Loose groups and circling birds are few enough to check each.
inline float flockDistance(float2 pixel, constant CompositeParams &p, float t, thread float2 &q, thread float &spread) {
    int formation = int(p.flockShape.x);
    int n = int(p.flockShape.y);
    float size = p.flockShape.z;
    if (formation == 2) {
        float best = 1e9;
        float radius = size * 11.0;
        for (int i = 0; i < 8; i++) {
            if (i >= n) break;
            float a = p.flock.z * (0.8 + 0.3 * hash11(i, 702u)) + float(i) * 6.283 / float(n);
            float r = radius * (0.75 + 0.5 * hash11(i, 703u));
            float2 rel = rotate(pixel - p.flock.xy - float2(cos(a), sin(a)) * r, -a);
            float d = birdShape(rel / size, 1.0, 0.6) * size;
            if (d < best) { best = d; q = rel / size; spread = 1.0; }
        }
        return best;
    }
    float2 rel = rotate(pixel - p.flock.xy, -(p.flock.z - M_PI_F * 0.5));
    if (formation == 1) {
        float best = 1e9;
        for (int i = 0; i < 8; i++) {
            if (i >= n) break;
            float h = hash11(i, 704u);
            float2 at = (hash22(int2(i, 3), 705u) - 0.5) * size * float2(16.0, 12.0)
                      + float2(sin(t * 0.6 + h * 9.0), cos(t * 0.45 + h * 4.0)) * size * 1.2;
            float flap = 0.5 + 0.5 * sin(t * 4.0 + h * 6.283);
            float d = birdShape((rel - at) / size, flap, 0.0) * size;
            if (d < best) { best = d; q = (rel - at) / size; spread = flap; }
        }
        return best;
    }
    // A skein: two arms 18 degrees either side of the leader, a little ragged, a wingbeat travelling back.
    float spacing = size * 3.4;
    float side = rel.x < 0.0 ? -1.0 : 1.0;
    float2 arm = float2(side * sin(0.32), -cos(0.32));
    float perArm = side < 0.0 ? ceil(float(n - 1) * 0.55) : floor(float(n - 1) * 0.45);
    float j = clamp(round(dot(rel, arm) / spacing), 0.0, perArm);
    float h = hash11(int(j * side) + 64, 700u);
    float2 at = arm * j * spacing + float2(sin(t * 0.7 + h * 6.0), cos(t * 0.5 + h * 9.0)) * spacing * 0.14;
    spread = 0.5 + 0.5 * sin(t * 5.5 - j * 0.8 + h * 6.0);
    q = (rel - at) / size;
    return birdShape(q, spread, 0.0) * size;
}

// How far from the leader any bird of the flock can be, in pixels: only pixels this close do any work.
inline float flockReach(constant CompositeParams &p) {
    int formation = int(p.flockShape.x);
    float n = p.flockShape.y;
    float size = p.flockShape.z;
    if (formation == 2) return size * 16.0;
    if (formation == 1) return size * 11.0;
    return size * (3.4 * ceil((n - 1.0) * 0.55) * 1.15 + 2.5);
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

    // A flock: soft shadows far below for high birds, crisp ones for low egrets, then the birds themselves.
    if (params.flock.w > 0.0) {
        float t = params.flockLook.w;
        float reach = flockReach(params);
        float2 q;
        float spread;
        float2 shadowPx = params.flock.xy - scene.sun.xy * scene.sun.z * params.flockShape.w;
        if (length(pixel - shadowPx) < reach) {
            float altitude = params.flockShape.w * mpp;
            float d = flockDistance(pixel - (shadowPx - params.flock.xy), params, t, q, spread);
            float blur = 0.8 + altitude * 0.0093 / mpp;
            c = shade(c, fill(d, blur) * mix(0.45, 0.12, saturate(altitude / 150.0)), scene);
        }
        if (length(pixel - params.flock.xy) < reach) {
            float d = flockDistance(pixel, params, t, q, spread);
            float3 plumage = params.flockLook.rgb * (0.9 + 0.2 * saturate(0.5 - q.y));
            c = mix(c, plumage, fill(d, 0.7));
        }
    }

    float cloudAlpha = smoothstep(0.02, 0.6, cloud.x);
    if (cloudAlpha > 0.0) {
        float3 cloudColor = mix(float3(0.66, 0.72, 0.86), float3(1.0, 1.0, 0.99), smoothstep(0.1, 0.95, cloud.y));
        c = mix(c, cloudColor, cloudAlpha);
    }

    // Live, the bird has its own layer above the wallpaper; stills and exports draw it here.
    if (birdVisible > 0.0 && params.finish.z > 0.5) {
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

// MARK: - The bird's own layer

// The gull alone on a transparent square, lit for the time of day, for the small layer that follows the cursor.
fragment float4 birdSprite(VertexOut in [[stage_in]],
                           constant CompositeParams &params [[buffer(0)]],
                           constant Scene &scene [[buffer(1)]]) {
    float2 pixel = float2(in.position.x, params.view.y - in.position.y);
    float scale = params.wings.z;
    float2 q = rotate(pixel - params.bird.xy, -params.bird.z) / scale;
    float sb = birdShape(q, params.wings.x, params.bird.w);
    float underside = saturate(0.5 - q.y * 0.6 + params.bird.w * q.x * 0.5);
    float3 c = mix(float3(0.99, 0.99, 0.98), float3(0.78, 0.81, 0.87), underside * 0.6);
    c = mix(c, float3(0.24, 0.25, 0.28), smoothstep(0.8, 0.9, abs(q.x)) * 0.85);
    float body = fill(sb, 0.8 / scale);
    float rim = fill(sb - 0.025, 0.9 / scale) * 0.32;
    float alpha = max(body, rim);
    c = mix(float3(0.0), c, body / max(alpha, 1e-4));
    float night = scene.time.w;
    float3 lit = c * scene.light.rgb * scene.light.w;
    float3 moonlit = mix(float3(luma(c)), c, 0.4) * float3(0.44, 0.54, 0.76) * 0.78 + float3(0.015, 0.02, 0.045);
    c = mix(lit, moonlit, night);
    return float4(saturate(c) * alpha, alpha);
}

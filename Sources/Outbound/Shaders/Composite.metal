// Every frame, in one render pass that stays in tile memory until the very end:
//   1. viewGround: the cached ground plus crop gusts, water glints and cars, with the night's light written
//      to a second target that never leaves the tile.
//   2. animalVertex/animalFragment: herds as small instanced sprites, so they only cost the pixels they cover.
//   3. sky: cloud shadow, clouds, the bird, paper and the light of the hour, reading the frame back in place.

// The ground and sky draws are compiled more than once, each copy holding only the parts some frames need. A part a
// frame never reaches still slows every pixel just by being in the shader, as the more a shader holds the fewer pixels
// the GPU works on at a time: with all of them in, a daytime frame with no train, flock or band of cloud in it took over
// a third longer. Every copy paints the same picture.
//
// The copies are made with function constants, from a second library compiled with OUTBOUND_LEAN. The library every
// other shader comes from must have none: with even one in it Metal compiles all its shaders another way, and the
// ground's, so compiled, now and then painted a block of eight texels by four without a tree or its shadow, about once
// in two hundred paintings of a screen.
#ifdef OUTBOUND_LEAN
// Lamps, headlights and lit windows, which only show after dark.
constant bool withDark [[function_constant(0)]];
constant bool withTrain [[function_constant(1)]];
// The new place blended in during a Fly To.
constant bool withSweep [[function_constant(2)]];
// The gull and its shadow.
constant bool withBird [[function_constant(3)]];
constant bool withFlock [[function_constant(4)]];
// The band of cloud between two places.
constant bool withBand [[function_constant(5)]];
#else
constant bool withDark = true;
constant bool withTrain = true;
constant bool withSweep = true;
constant bool withBird = true;
constant bool withFlock = true;
constant bool withBand = true;
#endif

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
// on at once in the place's own white. Every lamp shines steadily; none flickers. Some villages, as in much
// of rural France, switch their lamps off from midnight until five.
inline float3 streetLight(float3 c, float value, float lamp, float night, float hour, constant Biome &b) {
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
    if (on <= 0.0) return 0.0;
    float pool = min(value, 0.8) / 0.8;
    float glow = saturate((value - 0.8) / 0.2);
    // The lamp's colour wins over the ground's: grass under a lamp reads pale, not lurid green.
    float3 ground = mix(float3(luma(c)), c, 0.45) * 0.85 + 0.2;
    float3 light = ground * tint * (pool * pool * 0.85 + pool * 0.25);
    light += tint * glow * 0.7 + float3(1.0, 0.98, 0.94) * glow * glow * glow * 0.5;
    return light * on;
}

// Ground lit by one low-beam headlamp, 0.65 m up, at `p` metres from it (x to the car's right, y ahead), with the kerb
// on side `kerb` (1 right, -1 left). Built the way a European low beam is: a flat cut-off 0.57 degrees below the
// horizon on the oncoming side that rises past the kerb-side kink, a hot spot just under it towards the kerb, a
// broad spread, and next to nothing steeply down, which the bumper hides. What reaches the road falls off with the
// cube of distance, so from above the pool begins a couple of metres ahead, is brightest at four to six, and tails
// off over forty, longer on the kerb side. 1 is about the brightest a single lamp lights the road.
inline float lowBeam(float2 p, float kerb) {
    if (p.y <= 0.0) return 0.0;
    const float h = 0.65;
    float r = length(p);
    float down = atan2(h, r) * 57.29578;
    float across = atan2(p.x, p.y) * 57.29578 * kerb;
    float cutoff = mix(0.57, -0.5, smoothstep(0.0, 4.0, across));
    float shown = smoothstep(cutoff - 0.25, cutoff + 0.25, down) * smoothstep(24.0, 6.0, down);
    float hot = 0.85 * exp(-pow((down - 1.4) / 1.3, 2.0)) * exp(-pow((across - 2.0) / 7.0, 2.0));
    float spread = 0.35 * exp(-(down - 1.0) / 4.0) * exp(-pow(across / (across > 0.0 ? 28.0 : 20.0), 2.0));
    float d2 = r * r + h * h;
    return (hot + spread) * shown * h / (d2 * sqrt(d2)) / 0.00042;
}

// How much of a car with chance `h` is on the road where the land has turned `m`, 0 to 1. Places differ in how busy
// their roads are, so as a Fly To sweeps by the road can get too quiet for a car, or busy enough. It goes or comes over a
// short way rather than in one frame. Where the two places agree there is nothing to fade: all or nothing.
inline float carPresence(float h, float m, float busyA, float busyB) {
    float busy = min(mix(busyA, busyB, m) * 1.6, 0.75);
    float soft = abs(busyB - busyA) * 1.6 * 0.06 * smoothstep(0.0, 0.06, min(m, 1.0 - m));
    return soft > 1e-5 ? saturate((busy - h) / soft + 0.5) : (h > busy ? 0.0 : 1.0);
}

// How much direct sun reaches this pixel: none in a cloud's shade, where the light is all from the sky and nothing casts a
// shadow of its own.
inline float directSun(float2 pixel, constant CompositeParams &params, texture2d<float> clouds, texture2d<float> band,
                       sampler s) {
    float2 size = float2(clouds.get_width(), clouds.get_height());
    float2 at = (params.clouds.xy + pixel * params.view.z) / params.clouds.z;
    float shadow = clouds.sample(s, float2(at.x, size.y - at.y) / size).z;
    if (params.bank.w > 0.0) {
        float2 bandSize = float2(band.get_width(), band.get_height());
        float2 bandAt = (params.bank.xy + pixel * params.view.z) / params.bank.z;
        shadow = max(shadow, band.sample(s, float2(bandAt.x, bandSize.y - bandAt.y) / bandSize).z);
    }
    return 1.0 - smoothstep(0.05, 0.8, shadow);
}

// How far a car is ahead of its slot's middle at time `t` (wrapping hourly): up to 30 m either way, over two to five
// minutes, so it speeds up and slows down by a sixth or so. Periods divide an hour, so nothing jumps when `t` wraps.
inline float carDrift(int id, float t) {
    float reach = 12.0 + 18.0 * hash11(id, 146u);
    float period = 3600.0 / (12.0 + floor(hash11(id, 147u) * 18.0));
    return reach * sin(6.283185 * t / period + 6.283185 * hash11(id, 148u));
}

// Cars ride slots along the road, northbound on one side and southbound on the other, each pointing along the road
// and keeping to its lane through the bends. Whose traffic it is and where the road runs are decided where the car
// is, so a car is never cut in two where one place turns into the next.
inline float3 cars(float3 c, float2 world, constant Scene &scene, float mpp, thread float3 &light, float sunlit = 1.0) {
    float night = withDark ? scene.time.w : 0.0;
    constant Biome &a = scene.legA.biome;
    constant Biome &b = scene.legB.biome;
    float3 result = c;
    for (int lane = 0; lane < 2; lane++) {
        float dir = lane == 0 ? 1.0 : -1.0;
        Slot base = slotAt(world.y, carSlot, dir, scene.time.z, lane == 0 ? scene.traffic.x : scene.traffic.y);
        // Each car gains on its slot and falls back again, never more than a quarter of the way to the next, so
        // gaps open and close and oncoming cars don't all pass at once, but no car ever reaches another. By day a
        // car never leaves its slot's half; after dark the headlights of the car behind can reach into it.
        for (int behind = 0; behind < (night > 0.01 ? 2 : 1); behind++) {
        Slot slot = base;
        slot.y -= dir * carSlot * float(behind);
        slot.id -= int(dir) * behind;
        int id = slot.id * 2 + lane;
        float sway = carDrift(id, scene.time.x);
        slot.y += sway * dir;
        // A car and its shadow reach a few metres from its middle, its headlights some way ahead after dark;
        // most of the road is empty.
        float ahead = (world.y - slot.y) * dir;
        if (ahead < -12.0 || ahead > (night > 0.01 ? 60.0 : 12.0)) continue;
        float m = landTurn(slot.y, scene);
        float present = carPresence(hash11(id, 140u), m, a.g.y, b.g.y);
        // Northbound traffic keeps to its side of the road: the west side where traffic keeps left. Between a place
        // that keeps left and one that keeps right no car can change sides without driving through the oncoming
        // lane, so they all fade out before the change and new ones fade in after it.
        float keepLeft = m < 0.5 ? a.h.x : b.h.x;
        if (a.h.x != b.h.x) present *= smoothstep(0.0, 0.03, abs(m - 0.5));
        if (present <= 0.0) continue;
        float3 carless = result, unlit = light;
        float2 wander = course(scene, m);
        float width = mix(a.e.x, b.e.x, m);
        float side = mix(dir, -dir, keepLeft);
        float2 along = normalize(float2(roadSlope(slot.y, scene, wander), 1.0));
        float2 across = float2(along.y, -along.x);
        float2 center = float2(roadX(slot.y, scene, wander), slot.y) + across * side * width * 0.25;
        float2 rel = world - center;
        // Car-local metres: x across to its right, y forward.
        float2 q = float2(dot(rel, across), dot(rel, along)) * dir;
        float k = hash11(id, 141u), kind = hash11(id, 142u);
        // Mostly cars, some vans, now and then a lorry.
        bool lorry = kind < 0.09, van = !lorry && kind < 0.26;
        float2 size = lorry ? float2(1.02, 4.6) : van ? float2(0.9, 2.5) : float2(0.82, 2.1);
        if (dot(q, q) < 140.0) {
            float2 sun = float2(dot(scene.sun.xy, across), dot(scene.sun.xy, along)) * dir;
            // Its shadow stays attached however low the sun.
            float2 shadowOff = -sun * scene.sun.z * (lorry ? 3.2 : van ? 2.0 : 1.5);
            result = shade(result, fill(sweptBox(q, size, shadowOff) - 0.25, 0.3 + mpp) * 0.62 * sunlit, scene);
            // The colours cars really are: mostly white, grey, silver and black, the rest dark and quiet.
            float3 paint = k < 0.3 ? float3(0.82, 0.82, 0.8) : k < 0.48 ? float3(0.56, 0.57, 0.58)
                         : k < 0.66 ? float3(0.12, 0.12, 0.13) : k < 0.78 ? float3(0.15, 0.21, 0.32)
                         : k < 0.88 ? float3(0.4, 0.12, 0.11) : k < 0.95 ? float3(0.33, 0.3, 0.25) : float3(0.66, 0.57, 0.36);
            if (van) paint = mix(paint, float3(0.84, 0.84, 0.82), 0.6);
            // Narrowing to the nose and tail, rounded over its edges, so the body reads as a shape and not a slab.
            float taper = lorry ? 1.0 : 1.0 - 0.14 * smoothstep(size.y - 1.1, size.y + 0.2, abs(q.y));
            float body = sdBox(float2(q.x / taper, q.y), size) - 0.22;
            float3 skin = paint * (0.74 + 0.26 * smoothstep(0.0, -0.32, body));
            float3 sky = mix(float3(0.08, 0.1, 0.13), float3(0.4, 0.46, 0.54), 0.3 * saturate(0.5 + 0.5 * sun.y));
            result = mix(result, skin, fill(body, mpp * 0.7));
            if (lorry) {
                // A cab, a dark gap, and a long pale box with ribs along it.
                float box = sdBox(q - float2(0.0, -1.0), float2(1.0, 3.45));
                float3 load = mix(float3(0.74, 0.74, 0.72), paint, step(0.6, k)) * (1.0 + 0.05 * sin(q.y * 5.0));
                result = mix(result, load * (0.9 + 0.12 * saturate(sun.x * sign(q.x))), fill(box, mpp * 0.6));
                result = mix(result, sky, fill(sdBox(q - float2(0.0, size.y - 0.3), float2(0.82, 0.2)) - 0.05, mpp * 0.6));
            } else {
                float front = van ? 1.75 : 0.95, back = van ? -2.3 : -1.42;
                float mid = 0.5 * (front + back), length = 0.5 * (front - back);
                float cabin = sdBox(q - float2(0.0, mid), float2(0.7 - 0.05 * saturate(q.y - mid), length)) - 0.12;
                float roof = sdBox(q - float2(0.0, mid - (van ? 0.1 : 0.12)), float2(0.61, length - (van ? 0.28 : 0.5))) - 0.1;
                float3 top = paint * (0.92 + 0.14 * saturate(dot(normalize(q + 1e-4), sun)));
                result = mix(result, mix(sky, sky * 1.5, saturate(q.y - front + 0.7)), fill(cabin, mpp * 0.6));
                result = mix(result, top, fill(roof, mpp * 0.6));
            }
        }

        if (night > 0.01) {
            // From straight above the lamps face away, so a headlight shows as a small glint at the front corner and,
            // mostly, as the light it lays on the road ahead (see lowBeam): soft, a fraction of a street lamp's, and
            // gone by the verge. Newer cars have cool LED lamps, older ones warm halogen. Tail lights are small red
            // glints with a faint red wash on the road behind.
            float kerb = keepLeft > 0.5 ? -1.0 : 1.0;
            float3 beam = k < 0.55 ? float3(0.9, 0.95, 1.0) : float3(1.0, 0.85, 0.64);
            if (q.y > size.y - 0.1) {
                float lit = lowBeam(q - float2(size.x - 0.14, size.y + 0.2), kerb)
                          + lowBeam(q - float2(0.14 - size.x, size.y + 0.2), kerb);
                float pool = lit / (lit + 1.6);
                // The beam crosses the verge and fades out on the grass before the road's edge is reached.
                float s = roadSlope(world.y, scene, wander);
                float fromCentre = abs(world.x - roadX(world.y, scene, wander)) / sqrt(1.0 + s * s);
                pool *= 1.0 - smoothstep(width * 0.5 + 0.3, width * 0.5 + 2.2, fromCentre);
                light += (c * 0.75 + 0.04) * beam * pool * 0.85;
            }
            float2 lens = float2(abs(q.x) - size.x + 0.14, q.y - size.y - 0.2);
            float lensD = dot(lens, lens);
            light += beam * (exp(-lensD / 0.012) * 0.55 + exp(-lensD / 0.25) * 0.08);
            float2 tail = float2(abs(q.x) - size.x + 0.1, q.y + size.y + 0.28);
            float tailD = dot(tail, tail);
            float3 red = float3(1.0, 0.12, 0.06);
            light += red * (exp(-tailD / 0.008) * 0.45 + exp(-tailD / 0.15) * 0.06);
            float behind = -(q.y + size.y + 0.3);
            if (behind > 0.0) light += (c * 0.6 + 0.03) * red * exp(-behind / 1.3) * exp(-q.x * q.x / 0.9) * 0.08;
        }
        result = mix(carless, result, present);
        light = mix(unlit, light, present);
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
    // A real width, 3.1 m. Units with no locomotive have a cab at each end.
    bool cab = k == 0.0 || (tr.info.x < 0.5 && k == cars - 1.0);
    float round = cab ? 1.0 : 0.3;
    float gap = 0.6;
    return sdBox(lp, float2(1.55, length * 0.5 - gap) - round) - round;
}

inline float3 train(float3 c, float2 world, constant Train &tr, constant Scene &scene, float mpp,
                    thread float3 &light, float sunlit = 1.0) {
    float2 lp, lps;
    float k, ks;
    // Its shadow: is the point towards the sun inside the train? A train stands about 4 m tall.
    float ds = trainShape(world + scene.sun.xy * scene.sun.z * 4.2, tr, lps, ks);
    c = shade(c, fill(ds, 0.5) * 0.8 * sunlit, scene);
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
            roof = mix(body, tr.roof.rgb, fill(abs(lp.x) - 0.52, 0.1) * 0.7);
            roof = mix(roof, tr.stripe.rgb, step(1.22, abs(lp.x)));
            roof *= 0.94 + 0.12 * hash11(int(k), 520u);
            if (!loco && int(k) % 2 == 0) {
                roof = mix(roof, float3(0.22, 0.23, 0.25), fill(abs(sdBox(lp + float2(0.0, tr.run.z * 0.3), float2(0.6, 0.8))) - 0.05, 0.06));
            }
        }
        c = mix(c, roof, fill(db, mpp * 0.7));
    }
    if (withDark && scene.time.w > 0.0 && !freight) {
        // Warm windows spill onto the ballast either side; the leading car throws a beam down the line.
        float out = abs(lp.x) - 1.65;
        float bay = step(0.5, fract(lp.y / 1.9 + 0.25));
        light += (c * 0.85 + 0.18) * float3(1.0, 0.83, 0.65) * 0.6 * fill(out - 1.4, 0.8) * smoothstep(-0.2, 0.3, out)
               * exp(-max(out, 0.0) / 0.9) * bay * step(abs(lp.y), tr.run.z * 0.5 - 1.0) * step(tr.info.x, k);
    }
    if (withDark && scene.time.w > 0.0) {
        float ahead = -(lp.y + tr.run.z * 0.5) * step(k, 0.0);
        light += float3(1.0, 0.92, 0.8) * 0.45 * fill(abs(lp.x) - 0.9 - ahead * 0.05, 0.6)
               * smoothstep(0.0, 1.0, ahead) * exp(-ahead / 25.0);
    }
    return c;
}

// Hull colours: white and pale grey plastic, navy, red, green, and varnished wood.
inline float3 boatPaint(float h) {
    return h < 0.35 ? float3(0.9, 0.9, 0.88) : h < 0.5 ? float3(0.16, 0.22, 0.33) : h < 0.62 ? float3(0.58, 0.19, 0.16)
         : h < 0.74 ? float3(0.19, 0.32, 0.25) : h < 0.86 ? float3(0.6, 0.65, 0.68) : float3(0.55, 0.37, 0.21);
}

// How far the river can stray from the valley's middle, scene.road.x, in either place: the most its wander and its
// bends can add up to (the sums of their waves' weights in riverShape and riverBends).
inline float riverReach(constant Scene &scene) {
    constant Biome &a = scene.legA.biome;
    constant Biome &b = scene.legB.biome;
    return 1.36 * max(abs(a.d.w), abs(b.d.w)) + 1.25 * max(max(a.k.z, b.k.z), 0.0);
}

// A boat and its wake reach no further than this from the point on the river it is abreast of: 80 m back along it,
// the wake's arms 33 m out at their widest, and the boat up to a quarter of the river's width off its middle.
inline float boatReach(float width) {
    return 113.0 + 0.25 * width;
}

// The outline of a small open boat seen from above, as a distance in metres, negative inside. `q` runs across the
// boat and along it, with the stem at +L/2, and `B` is its beam. The sides run straight, draw in over the front half
// to a pointed stem, and narrow a little aft to a square transom.
inline float boatOutline(float2 q, float L, float B) {
    float reach = L * 0.5;
    float s = q.y / reach;
    float t = saturate((s + 0.1) / 1.1), a = saturate((-0.1 - s) / 0.9);
    float width = B * 0.5 * (1.0 - t * t) * (1.0 - 0.12 * a * a);
    float slope = B * 0.5 * (2.0 * t / 1.1 + 0.24 * a / 0.9) / reach;
    return max((abs(q.x) - width) / sqrt(1.0 + slope * slope), abs(q.y) - reach);
}

// Someone sitting in a boat, seen from above: shoulders in a coat, and a head of dark or fair hair.
inline float3 boater(float3 c, float2 p, float h, float mpp) {
    float3 coat = h < 0.25 ? float3(0.17, 0.21, 0.31) : h < 0.45 ? float3(0.62, 0.2, 0.15)
                : h < 0.6 ? float3(0.83, 0.68, 0.22) : h < 0.8 ? float3(0.36, 0.39, 0.27) : float3(0.82, 0.82, 0.8);
    c = mix(c, coat, fill((length(p / float2(0.25, 0.16)) - 1.0) * 0.16, mpp * 0.6));
    float3 hair = fract(h * 7.3) < 0.6 ? float3(0.16, 0.12, 0.09) : float3(0.47, 0.37, 0.25);
    return mix(c, hair, fill(length(p - float2(0.0, 0.03)) - 0.1, mpp * 0.6));
}

// Boats ride slots along the river, up and down stream, each with a Kelvin wake: two arms at 19.5 degrees either
// side of its track and churned, then smoothed, water straight behind. The wake is laid out along the river rather
// than straight back, so it follows the boat round a bend.
inline float3 boats(float3 c, float2 world, float water, constant Scene &scene, float mpp, float t,
                    thread float3 &light, float sunlit = 1.0) {
    float3 result = c;
    for (int lane = 0; lane < 2; lane++) {
        float dir = lane == 0 ? 1.0 : -1.0;
        // Hippos keep to their pools; boats go up and down at their own speeds.
        bool still = (landTurn(world.y, scene) < 0.5 ? scene.legA : scene.legB).biome.h.w > 1.5;
        Slot slot = still ? slotAt(world.y, boatSlot, 1.0, 0.0, -scene.water.y)
                          : slotAt(world.y, boatSlot, dir, lane == 0 ? scene.clock.z : scene.water.x,
                                   lane == 0 ? scene.traffic.z : scene.traffic.w);
        if (still) slot.y += 3.0 * sin(t / 37.0 + float(slot.id + lane) * 1.7);
        // Along the river is never shorter than along y, so a point this far from the bow is clear of boat and wake.
        float ahead = (slot.y - world.y) * dir;
        if (ahead < -10.0 || ahead > 80.0) continue;
        int id = slot.id * 2 + lane;
        float m = landTurn(slot.y, scene);
        constant Biome &a = scene.legA.biome;
        constant Biome &b = m < 0.5 ? a : scene.legB.biome;
        // Each place has its own boats, so one comes or goes around halfway rather than in a single frame, and hippos
        // and boats, which can't turn into each other, leave a moment's gap.
        float chance = hash11(id, 600u);
        float present = mix(a.h.z > 0.0 && chance <= a.h.z * 0.6 ? 1.0 : 0.0,
                            scene.legB.biome.h.z > 0.0 && chance <= scene.legB.biome.h.z * 0.6 ? 1.0 : 0.0,
                            smoothstep(0.47, 0.53, m));
        if ((a.h.w > 1.5) != (scene.legB.biome.h.w > 1.5)) present *= smoothstep(0.0, 0.03, abs(m - 0.5));
        if (present <= 0.0) continue;
        float3 boatless = result, unlit = light;
        float2 wander = course(scene, m);
        float width = mix(scene.legA.biome.d.z, scene.legB.biome.d.z, m);
        bool hippos = b.h.w > 1.5;
        float riverAt = riverX(slot.y, scene, wander);
        if (abs(world.x - riverAt) > boatReach(width)) continue;
        // How fast it goes through the water, which sets its wake, whichever way the current takes it.
        float speed = hippos ? 0.0 : 1.9;
        float slope = riverSlope(slot.y, scene, wander);
        float stretch = sqrt(1.0 + slope * slope);
        float2 along = float2(slope, 1.0) / stretch;
        float2 across = float2(along.y, -along.x);
        // u runs back from the bow along the boat, v square across it from the boat's line.
        float2 rel = world - float2(riverAt, slot.y);
        float u = -dot(rel, along) * dir;
        // It keeps to its own side of the river, and to the deep water round a bend, away from the bar.
        float bars = mix(scene.legA.biome.l.w, scene.legB.biome.l.w, m);
        float deepSide = -riverTurn(slot.y + clamp(width, 14.0, 44.0), scene, wander, slope) * saturate(width / 12.0);
        float v = dot(rel, across) - width * ((0.1 + 0.15 * hash11(id, 601u)) * dir * (1.0 - 0.6 * abs(deepSide))
                                             + 0.2 * deepSide * min(bars, 1.0));
        if (u < -10.0 || u > 80.0) continue;
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
            result = mix(boatless, result, present);
            continue;
        }
        float L = 4.5 + 3.0 * hash11(id, 604u), B = L * (0.33 + 0.05 * hash11(id, 606u));
        // Across the boat and along it, with the stem at +L/2 and the transom at -L/2.
        float2 q = float2(v * dir, L * 0.5 - u);
        float hull = boatOutline(q, L, B);
        if (water > 0.3 && u > 0.0) {
            // At a walking pace a small boat leaves little behind it. Two soft arms of short crests, slanting out from
            // its track, run back from the bow and are gone within a few lengths. The propeller churns a short trail
            // of foam straight astern, which stays where it is in the water as the boat goes on, and leaves a ribbon of
            // smoothed water that outlasts the rest.
            float reach = 5.0 + 2.6 * speed * speed;
            float edge = abs(v) - 0.354 * u;
            float spread = edge < 0.0 ? 0.5 + 0.05 * u : 0.2 + 0.015 * u;
            float arm = abs(edge) < 3.0 * spread ? exp(-edge * edge / (spread * spread)) : 0.0;
            float crest = 0.5 + 0.5 * cos(6.283 * (0.57 * abs(v) - 0.82 * u) / 1.5);
            float swell = arm * exp(-u / reach) * smoothstep(0.0, 1.5, u) * water;
            result *= 1.0 - 0.06 * swell * (1.0 - crest);
            result = mix(result, float3(0.86, 0.9, 0.93), 0.22 * swell * crest);
            float behind = u - L;
            if (behind > -0.3) {
                float wide = B * 0.22 + 0.06 * max(behind, 0.0);
                float churn = vnoise(float2(v / 0.4 + 17.0 * hash11(id, 608u), (u - speed * t) / 0.8), 609u);
                float foam = exp(-max(behind, 0.0) / (0.6 * L)) * (1.0 - smoothstep(0.55, 1.0, abs(v) / wide))
                           * smoothstep(-0.3, 0.3, behind) * (0.55 + 0.45 * smoothstep(0.35, 0.75, churn));
                result = mix(result, float3(0.9, 0.93, 0.94), foam * 0.5 * water);
                float slick = fill(abs(v) - B * 0.4 - 0.025 * behind, 0.6) * smoothstep(0.0, L, behind)
                            * exp(-behind / (reach * 2.5));
                result = mix(result, result * 1.04 + 0.025, slick * 0.7 * water);
            }
            // The bow pushes a little wave up along each side.
            float bowWave = fill(abs(hull - 0.18) - 0.08, 0.12) * smoothstep(-0.2 * L, 0.35 * L, q.y);
            result = mix(result, float3(0.9, 0.93, 0.94), bowWave * 0.45 * water);
        }
        // Its shadow on the water, from a hull standing about half a metre out of it.
        result = shade(result, fill(boatOutline(q + sun * scene.sun.z * 0.45, L, B) - 0.05, 0.2) * 0.5 * sunlit, scene);
        float k = hash11(id, 605u);
        float3 paint = boatPaint(k);
        bool plastic = k < 0.35 || (k >= 0.74 && k < 0.86);
        bool launch = hash11(id, 607u) < 0.55;
        // The topsides, lit on the sun's side.
        result = mix(result, paint * (0.93 + 0.09 * sign(q.x) * sun.x), fill(hull, mpp * 0.6));
        // Inside the gunwale the cockpit, open to the stern and closed by a foredeck on the launches. The gunwale
        // shades its floor on the side away from the sun.
        float deck = L * (launch ? 0.16 : 0.36);
        float cockpit = max(hull + 0.12, q.y - deck);
        float2 up = sun * scene.sun.z * 0.4;
        float lee = 1.0 - fill(max(boatOutline(q + up, L, B) + 0.12, q.y + up.y - deck), 0.08);
        float3 floorColor = (plastic ? float3(0.66, 0.69, 0.7) : float3(0.42, 0.31, 0.2)) * (1.0 - 0.35 * lee * sunlit);
        result = mix(result, floorColor, fill(cockpit, mpp * 0.6));
        // A seat across the middle, and on the launches a windscreen where the foredeck ends.
        float3 seat = plastic ? paint * 0.97 : float3(0.58, 0.45, 0.3);
        result = mix(result, seat, fill(max(abs(q.y + L * 0.06) - 0.13, cockpit), mpp * 0.6));
        if (launch) {
            result = mix(result, float3(0.24, 0.29, 0.34), fill(max(abs(q.y - deck + 0.05) - 0.07, hull + 0.18), mpp * 0.6));
        }
        // Whoever steers sits in the stern beside the outboard, and now and then someone sits on the seat too.
        float side = hash11(id, 611u) < 0.5 ? -1.0 : 1.0;
        result = boater(result, q - float2(0.17 * side, 0.7 - L * 0.5), hash11(id, 610u), mpp);
        if (hash11(id, 612u) < 0.4) result = boater(result, q - float2(0.0, -L * 0.06), hash11(id, 613u), mpp);
        float motor = sdBox(q - float2(0.0, -L * 0.5 - 0.16), float2(0.13, 0.2)) - 0.06;
        result = mix(result, float3(0.13, 0.13, 0.14), fill(motor, mpp * 0.6));
        result = mix(result, float3(0.3, 0.31, 0.33), fill(motor + 0.07, mpp * 0.5) * 0.6);
        if (withDark && scene.time.w > 0.0) {
            float2 port = q - float2(-B * 0.45, L * 0.2), starboard = q - float2(B * 0.45, L * 0.2), stern = q - float2(0.0, -L * 0.5);
            light += float3(1.0, 0.12, 0.08) / (1.0 + dot(port, port) / 0.03);
            light += float3(0.15, 1.0, 0.35) / (1.0 + dot(starboard, starboard) / 0.03);
            light += float3(1.0, 0.95, 0.85) / (1.0 + dot(stern, stern) / 0.04);
        }
        result = mix(boatless, result, present);
        light = mix(unlit, light, present);
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

// The gusts only drift with the wind, so like the clouds they are painted at a quarter of the screen's resolution with
// a margin and slid along. Red is how much tall crops sway; green is the cats' paws the wind roughens on water, in cells
// that divide the gust space's period, bent by a slower noise so they never show its grid. params: gust-space corner
// (x, y), metres per pixel, the texture's height.
fragment float4 gusts(VertexOut in [[stage_in]], constant float4 &params [[buffer(0)]],
                      texture2d<float> noise [[texture(0)]], sampler wrap [[sampler(0)]]) {
    float2 gust = params.xy + float2(in.position.x, params.w - in.position.y) * params.z;
    float sway = latticeNoise(noise, wrap, gust / float2(55.0, 160.0));
    float2 bent = gust + 30.0 * float2(latticeNoise(noise, wrap, gust / float2(44.0, 53.3333)) - 0.5,
                                       latticeNoise(noise, wrap, gust.yx / float2(53.3333, 44.0) + 31.0) - 0.5);
    float paws = 0.65 * latticeNoise(noise, wrap, bent / float2(27.5, 20.0))
               + 0.35 * latticeNoise(noise, wrap, bent / float2(13.75, 10.0));
    return float4(sway, paws, 0.0, 1.0);
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
                            texture2d<float> bankTexture [[texture(7)]],
                            texture2d<float> gustTexture [[texture(8)]],
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
    float turned = withSweep ? sweepBlend(world, scene) : 0.0;
    if (withSweep && turned > 0.0) {
        float3 next = groundColorAt(incomingColor, wrap, texel, params.cache.zw, params.finish.w, params.view.w);
        c = mix(c, next, turned) * (1.0 - 0.12 * (1.0 - abs(turned * 2.0 - 1.0)));
    }
    texture2d<float> landColor = turned > 0.5 ? incomingColor : groundColor;
    texture2d<float> landNight = turned > 0.5 ? incomingNight : groundNight;
    Mask mask = unpack(landColor.read(nearest).a);
    float water = mask.water;
    float3 light = 0.0;

    // The gusts, from their own texture: how much tall crops sway, and the cats' paws on water. Read for every pixel,
    // though only crops and water use them: asking first which pixels do cost a tenth of a daytime frame.
    float2 gustSize = float2(gustTexture.get_width(), gustTexture.get_height());
    float2 gustPx = (params.gusts.xy + pixel * mpp) / params.gusts.z;
    float2 gusts = gustTexture.sample(clampSampler, float2(gustPx.x, gustSize.y - gustPx.y) / gustSize).rg;
    // Gusts roll across tall crops in long soft bands, lying across the wind. Nothing else sways, so nothing else changes.
    c *= 1.0 + mask.sway * 0.09 * (gusts.x - 0.45);

    constant Leg &leg = landTurn(world.y, scene) > 0.5 ? scene.legB : scene.legA;
    // Only what moves casts a shadow here, so only its pixels ask how much sun gets through the clouds.
    if (mask.road) c = cars(c, world, scene, mpp, light, directSun(pixel, params, cloudTexture, bankTexture, clampSampler));
    // Lakes and paddies away from the river have no boats to look for.
    float riverRoom = riverReach(scene);
    if (water > 0.99
        && abs(world.x - scene.road.x) < riverRoom + boatReach(max(scene.legA.biome.d.z, scene.legB.biome.d.z))) {
        c = boats(c, world, water, scene, mpp, scene.time.x, light,
                  directSun(pixel, params, cloudTexture, bankTexture, clampSampler));
    }
    if (withTrain && scene.train.rail.w > 0.0) {
        float along;
        if (abs(railSigned(world, scene.train.rail.xy, scene.train.rail.z, scene.train.shape.xyz, along)) < 9.0 + 4.2 * scene.sun.z) {
            // Where two places meet a train goes no further than its line does, and over other places it isn't drawn.
            float turn = landTurn(world.y, scene);
            float side = scene.train.info.z;
            float shown = side > 2.5 ? 0.0 : side < 0.5 || scene.morph.z >= 0.0 ? 1.0 : side < 1.5 ? 1.0 - turn : turn;
            if (shown > 0.0) {
                float3 lit = light;
                float3 passing = train(c, world, scene.train, scene, mpp, lit,
                                       directSun(pixel, params, cloudTexture, bankTexture, clampSampler));
                c = mix(c, passing, shown);
                light = mix(light, lit, shown);
            }
        }
    }

    // Water holds the sky: clouds overhead brighten it, and so does the wind, which roughens it in soft cats' paws that
    // drift across with the gusts. On a river the current draws faint threads along it, sliding slowly downstream.
    if (water > 0.01) {
        float2 cloudPx = (params.clouds.xy + pixel * mpp) / params.clouds.z;
        float2 cloudSize = float2(cloudTexture.get_width(), cloudTexture.get_height());
        float overhead = cloudTexture.sample(clampSampler, float2(cloudPx.x, cloudSize.y - cloudPx.y) / cloudSize).x;
        c = mix(c, c + float3(0.16, 0.17, 0.2), water * overhead * 0.8);
        c = mix(c, float3(0.66, 0.74, 0.8), water * smoothstep(0.5, 0.8, gusts.y) * 0.12);
        // The mask can't tell a river from a lake, so only what lies between the river's banks gets a current. Its
        // threads follow the current, not the middle of the river: they crowd to the outside of each bend, and run
        // twice as fast down the deep water there as over the shallows.
        if (water > 0.9 && abs(world.x - scene.road.x) < riverRoom + max(scene.legA.biome.d.z, scene.legB.biome.d.z)) {
            float turned = landTurn(world.y, scene);
            float width = riverWidth(scene, turned);
            float bars = mix(scene.legA.biome.l.w, scene.legB.biome.l.w, turned);
            Channel ch = channelAt(world, scene, course(scene, turned), width, bars, false);
            float current = smoothstep(0.9, 1.0, water) * smoothstep(0.15, 0.6, ch.depth) * step(abs(ch.t), 1.0);
            if (current > 0.0) {
                float lane = (ch.t + 0.4 * ch.bend * (1.0 - ch.t * ch.t)) * ch.edge / 7.0;
                float slow = latticeNoise(noise, wrap, float2(lane, (world.y + scene.clock.w) / 64.0));
                float quick = latticeNoise(noise, wrap, float2(lane + 0.37, (world.y + 2.0 * scene.clock.w) / 64.0));
                c *= 1.0 + 0.08 * current * (mix(slow, quick, smoothstep(0.9, 1.7, ch.depth)) - 0.5);
            }
        }
    }

    // After dark, baked lamplight comes on house by house; the ground it falls on shows its day colour, warmed.
    float night = withDark ? scene.time.w : 0.0;
    float2 lamp = 0.0;
    if (withDark && night > 0.0) lamp = landNight.read(nearest).rg;
    // Smoothed ground gets smoothed lamplight too, or the pools step a whole texel at a time; the lamp's id stays
    // the nearest texel's.
    if (withDark && night > 0.0 && params.finish.w > 0.5) lamp.x = landNight.sample(wrap, texel / params.cache.zw).r;
    if (withDark && lamp.x > 0.004) {
        float id = lamp.y;
        float hour = scene.clock.x < 12.0 ? scene.clock.x + 24.0 : scene.clock.x;
        if (id > 0.895) {
            light += streetLight(c, lamp.x, (id - 0.9) * 10.0, night, hour, leg.biome);
        } else {
            float on = houseOn(id, scene.clock.x, scene.clock.y);
            float3 tint = float3(1.0, 0.68, 0.35);
            // About one lit house in ten has a television on in the evening: a cool, steady glow.
            if (fract(id * 41.3) > 0.9 && hour > 20.5 && hour < 23.6) {
                tint = float3(0.62, 0.72, 1.0) * 0.85;
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
    float2 jitter = (hash22(cell, seed + 123u) - 0.5) * spacing * 0.3;
    float2 walk = float2(sin(strides * 1.7 + h * 40.0), cos(strides * 1.3 + h * 17.0)) * 1.2;
    // It faces the way it last walked, turning as it steps.
    float2 step = float2(1.7 * cos(strides * 1.7 + h * 40.0), -1.3 * sin(strides * 1.3 + h * 17.0));
    float heading = atan2(step.y, step.x);
    // A little bigger than life, so they read from this height without outgrowing the cars.
    float len = (kind == sheep ? 0.7 : kind == zebra ? 1.0 : kind == gazelle ? 0.55 : 1.05) * 1.2;
    float wid = (kind == sheep ? 0.45 : kind == gazelle ? 0.28 : 0.42) * 1.2;
    float2 local = cellCenter + jitter + walk + p.drift.xy;
    float2 world = float2(local.x, local.y + p.leg.x);
    if (world.y < p.leg.y || world.y >= p.leg.z) return out;
    // Only where the ground says animals belong, nose to tail, in whichever painting it has turned to during a Fly To.
    // Where its next steps would take it off, it stays where it was grazing.
    texture2d<float> land = sweepBlend(world, scene) > 0.5 ? incomingColor : groundColor;
    float2 reach2 = float2(cos(heading), sin(heading)) * len * 1.6;
    bool fits = unpack(land.read(cacheTexel(world, params)).a).herd
             && unpack(land.read(cacheTexel(world + reach2, params)).a).herd
             && unpack(land.read(cacheTexel(world - reach2 * 0.7, params)).a).herd;
    if (!fits) {
        local = cellCenter + jitter + p.drift.xy;
        world = float2(local.x, local.y + p.leg.x);
        if (world.y < p.leg.y || world.y >= p.leg.z) return out;
        if (!unpack(land.read(cacheTexel(world, params)).a).herd
            || !unpack(land.read(cacheTexel(world + reach2, params)).a).herd
            || !unpack(land.read(cacheTexel(world - reach2 * 0.7, params)).a).herd) return out;
    }
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
    // Which way and how far its shadow falls, in its own frame; the fragment sweeps the body along it.
    out.shadow = rotate(shadowOff, -heading);
    float3 coat = b.animalColor.rgb * (0.85 + 0.3 * hash21(cell, seed + 125u));
    out.coat = float4(coat, float(kind));
    out.extent = float2(len, wid);
    out.patches = float4(b.animalPatches.rgb, b.animalPatches.w > 0.5 ? 1.0 + h : 0.0);
    return out;
}

fragment SkyOut animalFragment(AnimalOut in [[stage_in]], float4 below [[color(0)]],
                               constant CompositeParams &params [[buffer(0)]],
                               constant Scene &scene [[buffer(1)]],
                               texture2d<float> cloudTexture [[texture(2)]],
                               texture2d<float> bankTexture [[texture(7)]],
                               sampler clampSampler [[sampler(1)]]) {
    float len = in.extent.x, wid = in.extent.y;
    float px = params.view.z;
    float2 d = in.offset;
    bool isGazelle = in.coat.w == float(gazelle);
    // From above an animal is a barrel, as wide at the shoulder as at the hip, with a narrower head held out before it.
    float body = length(float2(max(abs(d.x) - (len - wid), 0.0), d.y)) - wid;
    float2 skull = float2(0.5, 0.3) * (isGazelle ? 0.6 : 1.0);
    float head = (length((d - float2(len + skull.x * 0.55, 0.0)) / skull) - 1.0) * skull.y;
    // Swept from the body out along the shadow, so it stays attached however low the sun.
    float2 scaled = d / float2(len, wid), cast = in.shadow / float2(len, wid);
    float along = saturate(dot(scaled, cast) / max(dot(cast, cast), 1e-4));
    float shadowBody = length(scaled - cast * along) - 1.0;
    float sunlit = directSun(float2(in.position.x, params.view.y - in.position.y), params, cloudTexture, bankTexture,
                             clampSampler);
    float3 c = shade(below.rgb, fill(shadowBody, px * 0.9) * 0.7 * sunlit, scene);
    float3 coat = in.coat.rgb;
    if (in.coat.w == float(zebra)) {
        float band = step(0.5, fract(d.x * 1.0 + 0.3 * d.y));
        coat = mix(float3(0.96, 0.95, 0.92), float3(0.12, 0.12, 0.14), band * 0.9);
    } else if (in.patches.w > 0.5) {
        // Patched coats, each animal its own: Normande brown on white, Hereford white faces on red.
        float seed = fract(in.patches.w) * 50.0;
        float patch = smoothstep(0.48, 0.56, vnoise(d * 1.1 + seed, 130u));
        coat = mix(coat, in.patches.rgb, patch);
        coat = mix(coat, float3(0.93, 0.91, 0.87), fill(length(d - float2(len + 0.28, 0.0)) - 0.5, 0.1) * step(in.patches.r, 0.7));
    } else if (isGazelle) {
        // Thomson's gazelles: tan backs, a dark side stripe, pale bellies.
        coat = mix(coat, float3(0.18, 0.13, 0.10), fill(abs(abs(d.y) - wid * 0.62) - wid * 0.12, 0.05) * 0.7);
    }
    float a = fill(smin(body, head, 0.25), px * 0.6);
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

// How far a wing reaches: it shortens on the side the bird banks towards, and folds in on the upstroke.
inline float wingReach(float x, float spread, float bank) {
    return (0.76 + 0.24 * spread) * (x < 0.0 ? 1.0 + bank * 0.22 : 1.0 - bank * 0.22);
}

// The front and back edges of a wing at `x` along it, 0 at the shoulder and 1 at the tip. The front reaches forward to
// the wrist and sweeps back; the back runs nearly straight out, then curves in to meet it at a fine point.
inline float2 wingEdges(float x, float fold) {
    float wrist = 0.135 + 0.07 * fold;
    float tip = -0.15 - 0.16 * fold;
    float inner = saturate(x / 0.46);
    float front = x < 0.46 ? mix(0.05, wrist, inner * (2.0 - inner)) : mix(wrist, tip, pow((x - 0.46) / 0.54, 1.5));
    float back = x < 0.5 ? mix(-0.125, -0.07 + 0.05 * fold, x / 0.5)
                         : mix(-0.07 + 0.05 * fold, tip, pow((x - 0.5) / 0.5, 2.2));
    return float2(front, back);
}

// A gull seen from above, facing +y, wingtips at x = ±1: long wings with a wrist and a pointed hand, feather tips showing
// along the back of each, a body narrowing into the head and bill, and a short fan of a tail. No two sides quite match,
// and in a turn the head looks into it and the tail twists to steer.
inline float birdShape(float2 p, float spread, float bank) {
    float span = wingReach(p.x, spread, bank);
    float x = abs(p.x) / span;
    float side = p.x < 0.0 ? 1.3 : 0.0;
    float2 edge = wingEdges(x, 1.0 - spread);
    edge.y += (0.006 + 0.008 * smoothstep(0.45, 0.7, x)) * abs(sin(x * 25.0 + side)) * smoothstep(0.1, 0.25, x);
    edge.x += 0.004 * sin(x * 13.0 + side * 2.0);
    float wing = max(max(p.y - edge.x, edge.y - p.y), x - 1.0) * 0.85 * span;
    float body = taperedSegment(p, float2(0.0, 0.11), float2(0.0, -0.2), 0.108, 0.06);
    float look = bank * 0.05;
    float head = taperedSegment(p, float2(0.0, 0.2), float2(look * 0.8, 0.3), 0.066, 0.05);
    float bill = taperedSegment(p, float2(look, 0.335), float2(look * 1.5, 0.4), 0.022, 0.006);
    float2 r = rotate(p - float2(0.0, -0.2), bank * 0.3);
    float2 fan = float2(abs(r.x), r.y);
    float middle = taperedSegment(fan, float2(0.0, 0.0), float2(0.0, -0.135), 0.042, 0.03);
    float outer = taperedSegment(fan, float2(0.016, 0.0), float2(0.06, -0.118), 0.036, 0.026);
    float tail = smin(middle, outer, 0.012);
    return smin(smin(smin(smin(body, head, 0.07), tail, 0.04), bill, 0.02), wing, 0.07);
}

// The gull's colours from above, painted rather than filled: white all over, the white of the wings only just shaded
// where the flight feathers lie under the coverts and along the shoulder, and dark tips with a small white mirror each.
// `sun` is towards the sun in the bird's own frame, so it is lit like the ground.
inline float3 gullColour(float2 p, float spread, float bank, float2 sun) {
    float x = abs(p.x) / wingReach(p.x, spread, bank);
    float2 edge = wingEdges(x, 1.0 - spread);
    float depth = saturate((p.y - edge.y) / max(edge.x - edge.y, 0.02));
    // A slow unevenness in the wash, different on each side.
    float wash = sin(p.x * 11.0 + p.y * 17.0 + 1.0) * sin(p.x * 23.0 - p.y * 9.0);
    float wing = smoothstep(0.08, 0.2, x);
    // Each flight feather a little different from the next, and the coverts a shade paler over them.
    float feather = sin(x * 25.0 + depth * 1.6) * sin(x * 9.0 + 2.1);
    float coverts = smoothstep(0.34, 0.6, depth + wash * 0.06 + sin(x * 31.0) * 0.07);
    float3 c = mix(float3(0.98, 0.97, 0.95), float3(0.89, 0.9, 0.92) * (1.0 + 0.025 * feather), wing * (1.0 - coverts));
    c *= 1.0 + 0.012 * wash;
    float dark = smoothstep(0.76, 0.86, x + (depth - 0.5) * 0.09 + wash * 0.012);
    float mirror = 1.0 - smoothstep(0.012, 0.034, length(float2(x - 0.92, p.y - mix(edge.x, edge.y, 0.5))));
    c = mix(c, float3(0.16, 0.155, 0.17), dark * (1.0 - 0.85 * mirror));
    c = mix(c, float3(0.88, 0.68, 0.24), smoothstep(0.325, 0.35, p.y));
    // Rounded down the body and tilted along the wings, so the side towards the sun is the lit one, as on the ground;
    // the shaded side goes cool. In a turn the raised wing catches a little more of it.
    float tilt = clamp(-p.x * 8.0, -1.0, 1.0) * (bank * 0.5 + 0.18);
    float round = saturate(1.0 - x * 5.0) * dot(float2(p.x * 7.0, 0.0), sun);
    float light = round * 0.06 + tilt * sun.x * 0.06;
    return min(c * (1.0 + light), float3(1.0)) + float3(-0.012, -0.006, 0.012) * saturate(-light * 12.0);
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
            float d = birdShape(rel / size, 1.0, -0.6) * size;
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
            float flap = 0.5 + 0.5 * sin(t * 13.0 + h * 6.283);
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
    spread = 0.5 + 0.5 * sin(t * 15.0 - j * 0.8 + h * 6.0);
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
                    texture2d<float> bankTexture [[texture(7)]],
                    sampler clampSampler [[sampler(1)]]) {
    float2 size = params.view.xy;
    float2 pixel = float2(in.position.x, size.y - in.position.y);
    float mpp = params.view.z;
    float3 c = below.rgb;

    // Clouds were painted a while ago with a margin; slide them by how far they have drifted since.
    float2 cloudTexSize = float2(cloudTexture.get_width(), cloudTexture.get_height());
    float2 cloudPx = (params.clouds.xy + pixel * mpp) / params.clouds.z;
    float4 cloud = cloudTexture.sample(clampSampler, float2(cloudPx.x, cloudTexSize.y - cloudPx.y) / cloudTexSize);

    // The band between two places, which moves with the land rather than the sky.
    float4 band = 0.0;
    if (withBand && params.bank.w > 0.0) {
        float2 bandSize = float2(bankTexture.get_width(), bankTexture.get_height());
        float2 bandPx = (params.bank.xy + pixel * mpp) / params.bank.z;
        band = bankTexture.sample(clampSampler, float2(bandPx.x, bandSize.y - bandPx.y) / bandSize);
    }

    // Cloud shadow, then the bird's shadow, then clouds, then the bird above it all.
    float sunlit = 1.0 - smoothstep(0.05, 0.8, max(cloud.z, band.z));
    c = shade(c, (1.0 - sunlit) * 0.62, scene);

    float birdVisible = withBird ? params.wings.w : 0.0;
    float2 birdPx = params.bird.xy;
    float scale = params.wings.z;
    if (withBird && birdVisible > 0.0) {
        float2 shadowPx = birdPx - scene.sun.xy * scene.sun.z * params.wings.y / mpp;
        float2 offset = pixel - shadowPx;
        if (dot(offset, offset) < scale * scale * 1.6) {
            float2 q = rotate(offset, -params.bird.z) / scale;
            // Soft, as a shadow is from that high up, and none where a cloud already shades the ground.
            c = shade(c, fill(birdShape(q, params.wings.x, params.bird.w), 0.05) * 0.45 * birdVisible * sunlit, scene);
        }
    }

    // A flock: soft shadows far below for high birds, crisp ones for low egrets, then the birds themselves.
    if (withFlock && params.flock.w > 0.0) {
        float t = params.flockLook.w;
        float reach = flockReach(params);
        float2 q;
        float spread;
        float2 shadowPx = params.flock.xy - scene.sun.xy * scene.sun.z * params.flockShape.w;
        if (length(pixel - shadowPx) < reach) {
            float altitude = params.flockShape.w * mpp;
            float d = flockDistance(pixel - (shadowPx - params.flock.xy), params, t, q, spread);
            // Blurred by how far the light travels from bird to ground, which is further the lower the sun.
            float blur = 0.8 + altitude * sqrt(1.0 + scene.sun.z * scene.sun.z) * 0.0093 / mpp;
            c = shade(c, fill(d, blur) * mix(0.45, 0.12, saturate(altitude / 150.0)) * params.flock.w * sunlit, scene);
        }
        if (length(pixel - params.flock.xy) < reach) {
            float d = flockDistance(pixel, params, t, q, spread);
            float3 plumage = params.flockLook.rgb * (0.9 + 0.2 * saturate(0.5 - q.y));
            c = mix(c, plumage, fill(d, 0.7) * params.flock.w);
        }
    }

    float cloudAlpha = smoothstep(0.02, 0.6, cloud.x);
    if (cloudAlpha > 0.0) {
        float3 cloudColor = mix(float3(0.66, 0.72, 0.86), float3(1.0, 1.0, 0.99), smoothstep(0.1, 0.95, cloud.y));
        c = mix(c, cloudColor, cloudAlpha);
    }

    // The band lies over all that, and the gull flies above it, its shadow close beneath it.
    float bank = withBand ? smoothstep(0.02, 0.6, band.x) : 0.0;
    if (withBand && bank > 0.0) {
        c = mix(c, mix(float3(0.66, 0.72, 0.86), float3(1.0, 1.0, 0.99), smoothstep(0.1, 0.95, band.y)), bank);
        if (withBird && birdVisible > 0.0) {
            float2 offset = pixel - (birdPx - scene.sun.xy * params.wings.y * 0.35 / mpp);
            if (dot(offset, offset) < scale * scale * 1.6) {
                float2 q = rotate(offset, -params.bird.z) / scale;
                c = shade(c, fill(birdShape(q, params.wings.x, params.bird.w), 0.05) * 0.6 * bank, scene);
            }
        }
        cloudAlpha += bank * (1.0 - cloudAlpha);
    }

    // Live, the bird has its own layer above the wallpaper; stills and exports draw it here.
    if (withBird && birdVisible > 0.0 && params.finish.z > 0.5) {
        float2 offset = pixel - birdPx;
        if (dot(offset, offset) < scale * scale * 1.6) {
            float2 q = rotate(offset, -params.bird.z) / scale;
            float sb = birdShape(q, params.wings.x, params.bird.w);
            float through = birdVisible * (1.0 - 0.6 * smoothstep(0.3, 0.9, cloud.x) * (1.0 - bank));
            // A breath of shade round it keeps the white of the bird apart from pale ground and cloud.
            c = mix(c, c * 0.8, fill(sb - 0.014, 1.6 / scale) * 0.3 * through);
            c = mix(c, gullColour(q, params.wings.x, params.bird.w, rotate(scene.sun.xy, -params.bird.z)),
                    fill(sb, 1.1 / scale) * through);
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
        // Clouds hold far less moonlight than their daytime white suggests, though the band seen from above still stands
        // paler than the land, or it would be a curtain drawn over it.
        moonlit *= 1.0 - mix(0.24, 0.16, bank) * cloudAlpha;
        c = mix(lit, moonlit, night);
        c += lamplight.rgb * night * (1.0 - mix(0.85, 1.0, bank) * cloudAlpha);
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
    float3 c = gullColour(q, params.wings.x, params.bird.w, rotate(scene.sun.xy, -params.bird.z));
    float body = fill(sb, 1.1 / scale);
    float rim = fill(sb - 0.014, 1.6 / scale) * 0.09;
    float alpha = max(body, rim);
    c = mix(float3(0.0), c, body / max(alpha, 1e-4));
    float night = scene.time.w;
    float3 lit = c * scene.light.rgb * scene.light.w;
    float3 moonlit = mix(float3(luma(c)), c, 0.4) * float3(0.44, 0.54, 0.76) * 0.78 + float3(0.015, 0.02, 0.045);
    c = mix(lit, moonlit, night);
    return float4(saturate(c) * alpha, alpha);
}

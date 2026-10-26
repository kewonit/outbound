#include <metal_stdlib>
using namespace metal;

// Mirrors ShaderTypes.swift. Every field is a float4.

struct Biome {
    float4 ground, groundDark, crop0, crop1, crop2, crop3, hedge, water, shallows, sand, road, canopy,
           canopyLight, rock, snow, animalColor;
    float4 a; // layout, fieldSize, hedgeWidth, warp
    float4 b; // fallow, patchiness, strokes, sway
    float4 c; // flooded, trees, treeSize, hedgeTrees
    float4 d; // orchards, petals, riverWidth, riverWander
    float4 e; // roadWidth, paved, ponds, houses
    float4 f; // rocks, snowCover, frozen, animal
    float4 g; // herds, cars, clumping, treeLines
    float4 h; // drives left, street lights, boats, boat kind
    float4 lamp;
    float4 roof0, roof1, roof2, animalPatches;
    float4 i; // villages, road trees, flat roofs, levees
    float4 j; // landmark A, density, landmark B, density
    float4 k; // sodium lamps, lamps off late, river bends, pond size
    float4 blossom, blossomLight; // orchard trees in flower; blossom.w is 1 when only orchards flower
    float4 l; // evergreen gardens
};

struct Leg {
    Biome biome;
    float4 info;      // start, seed, index
    float4 rail;      // origin (leg-local), angle, present
    float4 railShape; // wiggle amplitude, wavelength, phase, electrified
};

struct Train {
    float4 rail;   // origin (relative to the reference), angle, active
    float4 shape;  // wiggle amplitude, wavelength, phase
    float4 run;    // nose along the rail, direction, car length, cars
    float4 info;   // locomotives, kind
    float4 body, stripe, roof, locomotive;
};

struct Scene {
    float4 river;  // phases
    float4 road;   // riverX, roadOffset, roadPhase, crossPhase
    float4 sun;    // toward sun xy, shadow per metre, elevation
    float4 light;  // rgb, strength
    float4 morph;  // boundary, length, sweep (-1 flying), sweep wave
    float4 time;   // seconds (wraps hourly), seconds (wraps every two hours), car phase, night
    float4 clock;  // local hour, sunset hour, boat phase
    float4 traffic; // car cycles north and south, boat cycles up and down stream (see carSlot)
    float4 bends;  // phases of the river's own bends
    Train train;
    Leg legA;
    Leg legB;
};

struct GroundParams {
    float4 origin; // tex xy, world xy
    float4 texel;  // metres per texel
};

struct CloudParams {
    float4 origin;  // cloud space xy, metres per pixel, cover
    float4 offsets; // light xy, shadow xy
    float4 view;    // height px
};

struct CompositeParams {
    float4 view;   // w, h, metres per pixel, texels per pixel
    float4 world;  // x, y of bottom-left
    float4 cache;  // origin texel xy, size wh
    float4 bird;   // px xy, heading, bank
    float4 wings;  // spread, altitude, scale px, visible
    float4 finish; // grain, vignette, bird drawn here, ground filter (see groundColorAt)
    float4 clouds; // cloud-space offset of the view from the cloud texture's corner (xy), metres per cloud pixel
    float4 flock;      // leader px xy, heading, visible
    float4 flockShape; // formation, birds, half wingspan px, shadow px per unit shadow length
    float4 flockLook;  // rgb, seconds aloft
};

enum Layout { layoutGrassland = 0, layoutPaddies = 1, layoutFields = 2, layoutStripes = 3, layoutPivots = 4, layoutTaiga = 5 };
enum Landmark { markNone = 0, markKopje = 1, markWaterPoint = 2, markGrove = 3, markFarmstead = 4, markTubeWell = 5, markKiln = 6,
                markGlasshouse = 7, markWindmill = 8, markFeedlot = 9, markBurn = 10, markLake = 11, markCorral = 12 };
enum Animal { noAnimal = 0, cattle = 1, zebra = 2, wildebeest = 3, sheep = 4, reindeer = 5, gazelle = 6 };

struct VertexOut {
    float4 position [[position]];
};

// One triangle that covers the whole target.
vertex VertexOut fullscreen(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// MARK: - Hashing and noise

inline uint hashu(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

inline float hash21(int2 p, uint seed) {
    uint h = hashu(uint(p.x) * 0x8da6b343U ^ hashu(uint(p.y) * 0xd8163841U ^ seed * 0xcb1ab31fU));
    return float(h) * (1.0 / 4294967296.0);
}

inline float2 hash22(int2 p, uint seed) {
    return float2(hash21(p, seed), hash21(p, seed ^ 0x9e3779b9U));
}

inline float hash11(int p, uint seed) {
    return float(hashu(uint(p) * 0x27d4eb2dU ^ seed * 0x165667b1U)) * (1.0 / 4294967296.0);
}

// Value noise in 0...1 with quintic smoothing.
inline float vnoise(float2 p, uint seed) {
    float2 i = floor(p);
    float2 f = p - i;
    int2 c = int2(i);
    float a = hash21(c, seed);
    float b = hash21(c + int2(1, 0), seed);
    float d = hash21(c + int2(0, 1), seed);
    float e = hash21(c + int2(1, 1), seed);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

// Value noise that repeats every `period` cells, for clouds that drift forever without float drift.
inline float vnoiseP(float2 p, int period, uint seed) {
    float2 i = floor(p);
    float2 f = p - i;
    int2 c = int2(i);
    int2 c0 = ((c % period) + period) % period;
    int2 c1 = ((c + 1) % period + period) % period;
    float a = hash21(c0, seed);
    float b = hash21(int2(c1.x, c0.y), seed);
    float d = hash21(int2(c0.x, c1.y), seed);
    float e = hash21(c1, seed);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

// Positions are measured from a reference that moves north in steps of 2048 m. Patterns laid along the river and
// road are painted in those coordinates, so their lattice repeats a whole number of times in 2048 m: rows painted
// before and after a step then agree, with no seam across the river. `cell` is the lattice spacing in metres.
constant float referenceStep = 2048.0;

inline float alongNoise(float2 p, float2 cell, uint seed) {
    int period = max(int(round(referenceStep / cell.y)), 1);
    float2 q = float2(p.x / cell.x, p.y * float(period) / referenceStep);
    float2 i = floor(q);
    float2 f = q - i;
    int x = int(i.x);
    int y0 = ((int(i.y) % period) + period) % period;
    int y1 = (y0 + 1) % period;
    float a = hash21(int2(x, y0), seed);
    float b = hash21(int2(x + 1, y0), seed);
    float d = hash21(int2(x, y1), seed);
    float e = hash21(int2(x + 1, y1), seed);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

// Distance along y that repeats evenly in 2048 m, for dashes and slots near `spacing` long.
inline float alongSpacing(float spacing) {
    return referenceStep / max(round(referenceStep / spacing), 1.0);
}

constant float2x2 octave = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));

inline float fbm(float2 p, int octaves, uint seed) {
    float sum = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amp * vnoise(p, seed + uint(i) * 101u);
        norm += amp;
        amp *= 0.5;
        p = octave * p;
    }
    return sum / norm;
}

// How far the land at `world` (metres, relative to the scene's reference) has turned into the next place while a
// Fly To sweeps over it: 0 still the old place, 1 the new. The new place spreads in organic patches, like wet paint
// creeping across the sheet. This is the ground shader's own blend, so the frame pass can mix an old painting with a
// new one exactly where the ground would have.
// How far the land at world y has turned from leg A into leg B, 0 to 1: smoothly over the morph while flying, and
// behind the sweep's front during a Fly To.
inline float landTurn(float y, constant Scene &scene) {
    float boundary = scene.morph.x;
    if (y < boundary) return 0.0;
    if (scene.morph.z < 0.0) return smoothstep(boundary, boundary + scene.morph.y, y);
    return saturate((scene.morph.z * (scene.morph.w + 400.0) - (y - boundary)) / 400.0);
}

inline float sweepBlend(float2 world, constant Scene &scene) {
    if (scene.morph.z < 0.0) return 0.0;
    float m = landTurn(world.y, scene);
    if (m <= 0.0) return 0.0;
    float2 localB = float2(world.x, world.y - scene.legB.info.x);
    float threshold = 0.08 + 0.84 * fbm(localB / 85.0, 3, 77u);
    return smoothstep(threshold - 0.05, threshold + 0.05, m);
}

// MARK: - Shapes

inline float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

inline float sdBox(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// A box and the shadow it casts `offset` away, as one shape: the box swept along the offset, so however low the sun
// the shadow stays joined to what casts it.
inline float sweptBox(float2 p, float2 size, float2 offset) {
    float t = saturate(dot(p, offset) / max(dot(offset, offset), 1e-4));
    return min(min(sdBox(p, size), sdBox(p - offset, size)), sdBox(p - offset * t, size));
}

inline float2 rotate(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// A railway line: `along` runs in the line's direction, the result is the signed distance across it.
inline float railSigned(float2 p, float2 origin, float angle, float3 shape, thread float &along) {
    float2 q = rotate(p - origin, -angle);
    float w = q.x / shape.y + shape.z;
    float slope = shape.x / shape.y * cos(w);
    along = q.x;
    return (q.y - shape.x * sin(w)) * rsqrt(1.0 + slope * slope);
}

// Soft coverage of a signed distance, `w` metres wide.
inline float fill(float d, float w) {
    return 1.0 - smoothstep(-w, w, d);
}

inline float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

// Watercolour pigment density (Bousseau et al. 2006): darkens or lightens like more or less paint.
inline float3 pigment(float3 c, float t, float strength) {
    float d = 1.0 + strength * (t - 0.5);
    return clamp(c - (c - c * c) * (d - 1.0), 0.0, 1.0);
}

// MARK: - River and road, shared by every pass so they meet up exactly

constant float4 riverWaves = float4(1530.0, 640.0, 3900.0, 271.0);

inline float riverShape(float y, float4 phases) {
    float4 s = sin(y / riverWaves + phases);
    return 0.62 * s.x + 0.24 * s.y + 0.45 * s.z + 0.05 * s.w;
}

// `wander` is the place's course: how far the valley swings (x) and how deeply the river bends within it (y).

// The valley the river and the road share: long, gentle swings.
inline float valleyX(float y, constant Scene &scene, float wander) {
    return scene.road.x + wander * riverShape(y, scene.river);
}

inline float valleySlope(float y, constant Scene &scene, float wander) {
    float4 c = cos(y / riverWaves + scene.river) / riverWaves;
    return wander * (0.62 * c.x + 0.24 * c.y + 0.45 * c.z + 0.05 * c.w);
}

constant float roadWave = 2100.0;
// The river's own bends, about 380 to 950 m from one to the next.
constant float3 bendWaves = float3(95.0, 61.0, 151.0);

// Where the road crosses from one side of the valley to the other, -1 to 1, and how fast it does, per metre.
inline float2 roadSwap(float y, constant Scene &scene) {
    float a = y / roadWave + scene.road.z;
    float t = tanh(3.0 * sin(a));
    return float2(t, (1.0 - t * t) * 3.0 * cos(a) / roadWave);
}

// The bends the river makes within the valley, and their slope. The road doesn't follow them, so they straighten
// out where the road crosses, as rivers are trained to under a bridge, and the road never meets the river twice.
inline float2 riverBends(float y, constant Scene &scene, float bend) {
    if (bend <= 0.0) return 0.0;
    float3 a = y / bendWaves + scene.bends.xyz;
    float3 w = float3(0.55, 0.3, 0.4);
    float shape = dot(w, sin(a));
    float dshape = dot(w, cos(a) / bendWaves);
    float2 swap = roadSwap(y, scene);
    float u = saturate((abs(swap.x) - 0.08) / 0.47);
    float damp = u * u * (3.0 - 2.0 * u);
    float ddamp = 6.0 * u * (1.0 - u) / 0.47 * sign(swap.x) * swap.y;
    return bend * float2(shape * damp, dshape * damp + shape * ddamp);
}

inline float riverX(float y, constant Scene &scene, float2 wander) {
    return valleyX(y, scene, wander.x) + riverBends(y, scene, wander.y).x;
}

inline float riverSlope(float y, constant Scene &scene, float2 wander) {
    return valleySlope(y, scene, wander.x) + riverBends(y, scene, wander.y).y;
}

// The road keeps to one side of the river and swaps sides now and then, which is where bridges go.
inline float roadX(float y, constant Scene &scene, float2 wander) {
    return valleyX(y, scene, wander.x) + scene.road.y * roadSwap(y, scene).x;
}

inline float roadSlope(float y, constant Scene &scene, float2 wander) {
    return valleySlope(y, scene, wander.x) + scene.road.y * roadSwap(y, scene).y;
}

// The place's course where the land has turned `m` of the way from leg A to leg B.
inline float2 course(constant Scene &scene, float m) {
    return mix(float2(scene.legA.biome.d.w, scene.legA.biome.k.z), float2(scene.legB.biome.d.w, scene.legB.biome.k.z), m);
}

// MARK: - Traffic

// Cars and boats ride slots that move along the road or river. Each slot is a whole fraction of 2048 m, so a car
// keeps its slot when the reference steps on, and the slot's number counts on with the cycle rather than wrapping,
// so a car is the same car for as long as it is in view.
constant float carSlot = 128.0;
constant float boatSlot = 512.0;

struct Slot {
    float y;  // where the slot's middle is now
    int id;   // the same for the life of the car or boat in it
};

// The slot under world y for traffic heading north (`dir` 1) or south (-1). `phase` is the fraction of a slot
// travelled, and `cycle` the slots passed, both northwards.
inline Slot slotAt(float y, float spacing, float dir, float phase, float cycle) {
    float f = dir > 0.0 ? phase : fract(1.0 - phase);
    float i = floor(y / spacing - f);
    Slot s;
    s.y = (i + f + 0.5) * spacing;
    s.id = int(i) - int(cycle);
    return s;
}

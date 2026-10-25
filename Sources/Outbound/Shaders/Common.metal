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
};

struct Leg {
    Biome biome;
    float4 info; // start, seed, index
};

struct Scene {
    float4 river;  // phases
    float4 road;   // riverX, roadOffset, roadPhase, crossPhase
    float4 sun;    // toward sun xy, shadow per metre, elevation
    float4 light;  // rgb, strength
    float4 morph;  // boundary, length, sweep (-1 flying), sweep wave
    float4 time;   // seconds (wraps hourly), seconds (wraps every two hours), car phase, night
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
    float4 finish; // grain, vignette, debug
};

enum Layout { layoutGrassland = 0, layoutPaddies = 1, layoutFields = 2, layoutStripes = 3, layoutPivots = 4 };
enum Animal { noAnimal = 0, cattle = 1, zebra = 2, wildebeest = 3, sheep = 4, reindeer = 5 };

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

// MARK: - Shapes

inline float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

inline float sdBox(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

inline float2 rotate(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
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

inline float riverX(float y, constant Scene &scene, float wander) {
    return scene.road.x + wander * riverShape(y, scene.river);
}

inline float riverSlope(float y, constant Scene &scene, float wander) {
    float4 c = cos(y / riverWaves + scene.river) / riverWaves;
    return wander * (0.62 * c.x + 0.24 * c.y + 0.45 * c.z + 0.05 * c.w);
}

constant float roadWave = 2100.0;

// The road keeps to one side of the river and swaps sides now and then, which is where bridges go.
inline float roadX(float y, constant Scene &scene, float wander) {
    return riverX(y, scene, wander) + scene.road.y * tanh(3.0 * sin(y / roadWave + scene.road.z));
}

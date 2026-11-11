// FROZEN COPY: this file is the shader as Outbound v1.0 shipped it. The app never loads it; only ShaderTests
// compiles it, to compare the real shaders in Sources/Outbound/Shaders against what people first got.
//
// It is older than those shaders and drifts from them by design. Don't fix, tidy or improve it here. When a
// change to the look is meant, copy the current shader over this file and put this note back at the top.

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
    float4 l; // evergreen gardens, where the river runs (world x), scattered trees' height for their width, river bars
    float4 n; // bank trees
    float4 railLine;  // the leg's railway: origin (leg-local x, y), cos and sin of its angle
    float4 railCurve; // its wiggle: amplitude, 1 / wavelength, phase, then whether there is one
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
    float4 info;   // locomotives, kind, whose line it is near a join (0 either, 1 the old place, 2 the new)
    float4 body, stripe, roof, locomotive;
};

struct Scene {
    float4 river;  // phases
    float4 road;   // riverX, roadOffset, roadPhase, crossPhase
    float4 sun;    // toward sun xy, shadow per metre, elevation
    float4 light;  // rgb, strength
    float4 morph;  // boundary, unused, sweep (-1 flying), sweep wave
    float4 time;   // seconds (wraps hourly), seconds (wraps every two hours), car phase, night
    float4 clock;  // local hour, sunset hour, boat phase, how far the current has carried a river's surface
    float4 traffic; // car cycles north and south, boat cycles up and down stream (see carSlot)
    float4 bends;  // phases of the river's own bends, then how many crossroad spacings the reference has passed
    Train train;
    Leg legA;
    Leg legB;
    float4 water;  // boats' downstream phase, the reference in boat slots for still water, unused, unused
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
    float4 bank;       // offset of the view from the band's texture (xy), metres per band pixel, whether one shows
    float4 gusts;      // gust-space offset of the view from the gust texture's corner (xy), metres per gust pixel
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

// How far the land at world y has turned from leg A into leg B, 0 to 1: at once at the line where they meet while flying,
// under a bank of cloud, and behind the sweep's front during a Fly To.
inline float landTurn(float y, constant Scene &scene) {
    float boundary = scene.morph.x;
    if (y < boundary) return 0.0;
    if (scene.morph.z < 0.0) return 1.0;
    return saturate((scene.morph.z * (scene.morph.w + 400.0) - (y - boundary)) / 400.0);
}

// How far the land must have turned before the new place reaches `world`, 0 to 1: the line its patches spread along.
inline float patchThreshold(float2 world, constant Scene &scene) {
    float2 localB = float2(world.x, world.y - scene.legB.info.x);
    return 0.08 + 0.84 * fbm(localB / 85.0, 3, 77u);
}

// How far the land at `world` (metres, relative to the scene's reference) has turned into the next place while a
// Fly To sweeps over it: 0 still the old place, 1 the new. The new place spreads in organic patches, like wet paint
// creeping across the sheet. This is the ground shader's own blend, so the frame pass can mix an old painting with a
// new one exactly where the ground would have.
inline float sweepBlend(float2 world, constant Scene &scene) {
    if (scene.morph.z < 0.0) return 0.0;
    float m = landTurn(world.y, scene);
    if (m <= 0.0) return 0.0;
    float threshold = patchThreshold(world, scene);
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
// The river's own bends, about 350 to 650 m from one to the next: the first wave sets them, the last draws them
// closer together and further apart, and the second is a small unevenness laid over them.
constant float3 bendWaves = float3(72.0, 61.0, 151.0);
// How far each bend leans downstream, as the third harmonic of its turn. The river flows south.
constant float riverLean = 0.07;

// Where the road crosses from one side of the valley to the other, -1 to 1, and how fast it does, per metre.
inline float2 roadSwap(float y, constant Scene &scene) {
    float a = y / roadWave + scene.road.z;
    // Quickly, so it crosses the river nearly square and a bridge is about as long as the river is wide.
    float t = tanh(8.0 * sin(a));
    return float2(t, (1.0 - t * t) * 8.0 * cos(a) / roadWave);
}

// The bends the river makes within the valley, and their slope: one run of bends rather than waves laid over each
// other, so each is a bend in its own right. They come closer together and further apart as the longest wave has it,
// swell and fade with the valley's own waves, so a tight bend follows a nearly straight reach, and each leans
// downstream and is a little fuller than a sine, as a river's are. The road doesn't follow them, so they straighten
// out where the road crosses, as rivers are trained to under a bridge, and the road never meets the river twice.
// Never further out than 1.25 times `bend`, which riverReach counts on.
inline float2 riverBends(float y, constant Scene &scene, float bend) {
    if (bend <= 0.0) return 0.0;
    float3 a = y / bendWaves + scene.bends.xyz;
    float4 v = y / riverWaves + scene.river;
    float phase = a.x + 0.55 * sin(a.z);
    float dphase = 1.0 / bendWaves.x + 0.55 * cos(a.z) / bendWaves.z;
    float swell = v.w + 1.3 * sin(v.y);
    float strength = 0.74 + 0.26 * sin(swell);
    float dstrength = 0.26 * cos(swell) * (1.0 / riverWaves.w + 1.3 * cos(v.y) / riverWaves.y);
    float turn = sin(phase) + riverLean * cos(3.0 * phase) + 0.035 * sin(3.0 * phase);
    float dturn = (cos(phase) - 3.0 * riverLean * sin(3.0 * phase) + 0.105 * cos(3.0 * phase)) * dphase;
    float shape = strength * turn + 0.1 * sin(a.y);
    float dshape = dstrength * turn + strength * dturn + 0.1 * cos(a.y) / bendWaves.y;
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
// Where there is no river to swap sides of, it runs straight.
inline float roadX(float y, constant Scene &scene, float2 wander) {
    return valleyX(y, scene, wander.x) + scene.road.y * saturate(wander.x / 4.0) * roadSwap(y, scene).x;
}

inline float roadSlope(float y, constant Scene &scene, float2 wander) {
    return valleySlope(y, scene, wander.x) + scene.road.y * saturate(wander.x / 4.0) * roadSwap(y, scene).y;
}

// The place's course where the land has turned `m` of the way from leg A to leg B.
inline float2 course(constant Scene &scene, float m) {
    return mix(float2(scene.legA.biome.d.w, scene.legA.biome.k.z), float2(scene.legB.biome.d.w, scene.legB.biome.k.z), m);
}

// The river's width where the land has turned `m` of the way from leg A to leg B. Between a place with a river and one
// without it keeps its width, and is painted over in patches instead.
inline float riverWidth(constant Scene &scene, float m) {
    float a = scene.legA.biome.d.z, b = scene.legB.biome.d.z;
    return (a < 0.5) != (b < 0.5) ? max(a, b) : mix(a, b, m);
}

// MARK: - The river's channel

// What the river is like across its channel at one point. Water shapes it: the current swings to the outside of each
// bend and cuts that bank back, drops its sand on the inside as a bar, and both happen a little downstream of where
// the bend is tightest. So nothing here is a copy of the centre line moved sideways.
struct Channel {
    float d;      // metres from the centre line, positive towards +x
    float slope;  // the centre line's slope there
    float bend;   // how hard the river turned a little upstream, -1 to 1: positive with the inside of the bend at +x
    float left;   // the top of the bank on the -x side, in metres from the centre line
    float right;  // and on the +x side
    float edge;   // the top of the bank on this point's own side, with its slumps and its small unevenness
    float t;      // across the channel, -1 at the left bank's top to 1 at the right's
    float tilt;   // how the bed lies there: 1 on a straight, more towards a pool, below 0 on a bar that stands dry
    float depth;  // in mean depths: 0 on a bar or a bank, about 1 down the middle of a straight, 2 or 3 in a pool
};

// A bend of this radius or tighter counts as a full one.
constant float bendRadius = 115.0;

// How hard the river turns at y, where its slope is `slope`: its curvature against bendRadius, positive where it turns
// towards +x going north. Worked out from the same waves as valleyX and riverBends, and to be kept in step with them;
// it leaves out how slowly the bends swell and how they straighten for the road, which change it by a few parts in
// a hundred, and is a third of the work of measuring the slope twice.
inline float riverTurn(float y, constant Scene &scene, float2 wander, float slope) {
    float4 v = y / riverWaves + scene.river;
    float4 waves = sin(v);
    float curve = -wander.x * dot(float4(0.62, 0.24, 0.45, 0.05) * waves, 1.0 / (riverWaves * riverWaves));
    if (wander.y > 0.0) {
        float3 a = y / bendWaves + scene.bends.xyz;
        float phase = a.x + 0.55 * sin(a.z);
        float dphase = 1.0 / bendWaves.x + 0.55 * cos(a.z) / bendWaves.z;
        float ddphase = -0.55 * sin(a.z) / (bendWaves.z * bendWaves.z);
        float strength = 0.74 + 0.26 * sin(v.w + 1.3 * waves.y);
        float s1 = sin(phase), c1 = cos(phase), s3 = sin(3.0 * phase), c3 = cos(3.0 * phase);
        float dturn = c1 - 3.0 * riverLean * s3 + 0.105 * c3;
        float ddturn = -s1 - 9.0 * riverLean * c3 - 0.315 * s3;
        float shape = strength * (ddturn * dphase * dphase + dturn * ddphase) - 0.1 * sin(a.y) / (bendWaves.y * bendWaves.y);
        float u = saturate((abs(roadSwap(y, scene).x) - 0.08) / 0.47);
        curve += wander.y * shape * u * u * (3.0 - 2.0 * u);
    }
    float k = 1.0 + slope * slope;
    return clamp(curve / (k * sqrt(k)) * bendRadius, -1.0, 1.0);
}

// For the frame pass, which asks on every frame: how far `p` is across the river from its centre line, and how hard
// the river turned `lag` upstream, with the centre line's slope there. The centre line is riverX exactly; the slope
// leaves out the valley's, which is slight, and the turn is taken from the bends' own wave moved on by `lag`. Near
// enough to send the current the right way, at a third of what channelAt asks of the ground. Keep in step with
// riverBends.
inline float2 riverCurrent(float2 p, constant Scene &scene, float2 wander, float lag, thread float &slope) {
    float4 waves = sin(p.y / riverWaves + scene.river);
    float x = scene.road.x + wander.x * dot(float4(0.62, 0.24, 0.45, 0.05), waves);
    float curve = -wander.x * dot(float4(0.62, 0.24, 0.45, 0.05) * waves, 1.0 / (riverWaves * riverWaves));
    slope = 0.0;
    if (wander.y > 0.0) {
        float3 a = p.y / bendWaves + scene.bends.xyz;
        float phase = a.x + 0.55 * sin(a.z);
        float dphase = 1.0 / bendWaves.x + 0.55 * cos(a.z) / bendWaves.z;
        float strength = 0.74 + 0.26 * sin(p.y / riverWaves.w + scene.river.w + 1.3 * waves.y);
        float u = saturate((abs(roadSwap(p.y, scene).x) - 0.08) / 0.47);
        float reach = wander.y * u * u * (3.0 - 2.0 * u);
        float s1 = sin(phase), c1 = cos(phase);
        float s3 = s1 * (3.0 - 4.0 * s1 * s1), c3 = c1 * (4.0 * c1 * c1 - 3.0);
        x += reach * (strength * (s1 + riverLean * c3 + 0.035 * s3) + 0.1 * sin(a.y));
        slope = reach * strength * (c1 - 3.0 * riverLean * s3 + 0.105 * c3) * dphase;
        float ahead = phase + lag * dphase;
        float sa = sin(ahead), ca = cos(ahead);
        float sa3 = sa * (3.0 - 4.0 * sa * sa), ca3 = ca * (4.0 * ca * ca - 3.0);
        curve += reach * strength * (-sa - 9.0 * riverLean * ca3 - 0.315 * sa3) * dphase * dphase;
    }
    float k = 1.0 + slope * slope;
    return float2((p.x - x) / sqrt(k), clamp(curve / (k * sqrt(k)) * bendRadius, -1.0, 1.0));
}

// The top of one bank (`side` -1 or 1), in metres from the centre line: wider and narrower on its own along the
// river, set back by the bar on the inside of a bend, cut back a little on the outside.
inline float riverBank(float side, float y, float semi, float bend, float bars, bool exact) {
    float inner = saturate(bend * side), outer = saturate(-bend * side);
    float slow = exact ? alongNoise(float2(side * 3.0, y), float2(1.0, 170.0), 12u) - 0.5 : 0.0;
    // A canal's banks are dug straight and stay where they were dug.
    float wild = saturate(bars * 4.0);
    return semi * (1.0 + (0.24 * slow + 0.16 * outer) * wild + 0.55 * bars * inner);
}

// How much further from the river than it used to what stands on the land must keep, for the banks' wandering: the
// most a bank can stand beyond half the river's width, less the 6 m everything already allowed.
inline float riverSpread(float semi, float bars) {
    return max(semi * (0.12 + max(0.55 * bars, 0.16)) - 6.0, 0.0);
}

// `exact` is for the ground, which paints the banks. Without it they are left smooth, which is enough for the frame
// pass to send the current the right way, and costs it far less on every frame.
inline Channel channelAt(float2 p, constant Scene &scene, float2 wander, float width, float bars, bool exact = true) {
    Channel c;
    float semi = width * 0.5;
    // The river flows south, so upstream is north: bars and pools lie about a width below the bend that makes them.
    float lag = clamp(width, 14.0, 44.0);
    float turned = 0.0;
    if (exact) {
        c.slope = riverSlope(p.y, scene, wander);
        c.d = (p.x - riverX(p.y, scene, wander)) / sqrt(1.0 + c.slope * c.slope);
    } else {
        float2 across = riverCurrent(p, scene, wander, lag, c.slope);
        c.d = across.x;
        turned = across.y;
    }
    c.bend = 0.0;
    c.left = semi;
    c.right = semi;
    c.edge = semi;
    c.t = c.d / max(semi, 0.01);
    c.tilt = 1.0;
    c.depth = 0.0;
    if (width < 0.5 || abs(c.d) > (exact ? semi * 2.0 + 60.0 : semi * (1.3 + 0.55 * bars) + 3.0)) return c;
    if (exact) turned = riverTurn(p.y + lag, scene, wander, c.slope);
    c.bend = turned * saturate(width / 12.0);
    c.left = riverBank(-1.0, p.y, semi, c.bend, bars, exact);
    c.right = riverBank(1.0, p.y, semi, c.bend, bars, exact);
    float side = c.d > 0.0 ? 1.0 : -1.0;
    float inner = saturate(c.bend * side), outer = saturate(-c.bend * side);
    // A cut bank falls in a bay at a time, leaving points between the bays; a bar's edge is smooth.
    c.edge = side > 0.0 ? c.right : c.left;
    if (exact) {
        float bays = abs(2.0 * alongNoise(float2(side * 9.0, p.y), float2(1.0, 15.0), 3u) - 1.0);
        bays *= sqrt(bays);
        float uneven = alongNoise(float2(side * 7.0, p.y), float2(1.0, 4.0), 4u) - 0.5;
        float wild = saturate(bars * 4.0);
        c.edge += (1.6 + 0.05 * width) * smoothstep(0.1, 0.5, outer) * bays * wild
                + 0.7 * uneven * (1.0 - 0.7 * smoothstep(0.0, 0.3, inner)) * (0.15 + 0.85 * wild);
    }
    c.t = c.d / c.edge;
    // The bed tilts down towards the outside of the bend, where the bank is steep; inside, it shelves up into the bar.
    c.tilt = 1.0 - (0.9 + 1.7 * bars) * c.bend * c.t;
    // A bar shelves gently into the water; any other bank drops away under it.
    float across = c.t * c.t;
    float wall = across * across * across;
    c.depth = max(c.tilt, 0.0) * max(1.0 - mix(wall, across, smoothstep(0.0, 0.3, inner * bars)), 0.0);
    return c;
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

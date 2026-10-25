// Probes and promises for ShaderTests: small compute kernels that each call a few shader functions over a 64 by 64
// grid of inputs, one float4 per thread. They are compiled after the shaders, joined on the same way the app joins
// its files, so they can call anything there.
//
// Kernels named probe… write what the functions return; the tests compare those answers between the real shaders
// and the copy in Shipped/. Kernels named promise… write how far each thing a function guarantees is from true,
// 0 when it holds; the tests expect 0 everywhere, on both builds.
//
// Every one takes the same bindings, so the tests can run them all the same way: the output at buffer 0, a Scene
// from a real World over one of the places at 1, three views (as the frame pass gets them, one per kind of flock)
// at 2, and the app's own noise lattice and wrapping sampler at texture and sampler 0.

constant uint probeSide = 64;
constant uint probeCount = probeSide * probeSide;

// Thread `id` as a point on the grid, `step` apart, centred on `centre`.
inline float2 probePoint(uint id, float step, float2 centre) {
    return (float2(id % probeSide, id / probeSide) - 31.5) * step + centre;
}

// A number from 0 to 1 for thread `id`, a different one for each `salt`.
inline float probeRandom(uint id, uint salt) {
    return hash11(int(id), 0x51ed27u + salt);
}

// MARK: - Layout

// Sizes and offsets of every struct Swift fills in, in bytes, in the order the tests list them.
kernel void layouts(device uint *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    if (id != 0) return;
    uint i = 0;
    out[i++] = sizeof(Biome);
    out[i++] = sizeof(Leg);
    out[i++] = sizeof(Train);
    out[i++] = sizeof(Scene);
    out[i++] = sizeof(GroundParams);
    out[i++] = sizeof(CloudParams);
    out[i++] = sizeof(CompositeParams);
    out[i++] = sizeof(AnimalParams);
    out[i++] = __builtin_offsetof(Biome, a);
    out[i++] = __builtin_offsetof(Biome, lamp);
    out[i++] = __builtin_offsetof(Biome, roof0);
    out[i++] = __builtin_offsetof(Biome, i);
    out[i++] = __builtin_offsetof(Biome, k);
    out[i++] = __builtin_offsetof(Biome, blossomLight);
    out[i++] = __builtin_offsetof(Leg, info);
    out[i++] = __builtin_offsetof(Leg, railShape);
    out[i++] = __builtin_offsetof(Train, run);
    out[i++] = __builtin_offsetof(Train, locomotive);
    out[i++] = __builtin_offsetof(Scene, time);
    out[i++] = __builtin_offsetof(Scene, clock);
    out[i++] = __builtin_offsetof(Scene, train);
    out[i++] = __builtin_offsetof(Scene, legA);
    out[i++] = __builtin_offsetof(Scene, legB);
    out[i++] = __builtin_offsetof(CloudParams, view);
    out[i++] = __builtin_offsetof(CompositeParams, finish);
    out[i++] = __builtin_offsetof(CompositeParams, flockLook);
    out[i++] = __builtin_offsetof(AnimalParams, drift);
}

// MARK: - Hashing and noise

// hash21, hash22 and hash11 over neighbouring cells, which should land anywhere in 0...1.
kernel void probeHash(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    int2 cell = int2(id % probeSide, id / probeSide) - 32;
    float2 pair = hash22(cell, 7u);
    out[id] = float4(hash21(cell, 7u), pair, hash11(int(id), 7u));
}

// Value noise, the same a hundredth of a cell to the side, and periodic noise here and one period over.
kernel void probeNoise(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 0.173, float2(3.1, -7.4));
    out[id] = float4(vnoise(p, 11u), vnoise(p + float2(0.01, 0.0), 11u),
                     vnoiseP(p, 8, 12u), vnoiseP(p + 8.0, 8, 12u));
}

// Fractal noise: with one octave it is plain value noise, and with more it still stays in 0...1.
kernel void probeFbm(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                     uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 0.37, float2(-12.0, 40.0));
    out[id] = float4(fbm(p, 1, 21u), vnoise(p, 21u), fbm(p, 3, 21u), fbm(p, 6, 21u));
}

// MARK: - Shapes

// The smooth minimum's dip below min(a, b), a box's signed distance, how far a rotation stretches a point
// (never), and soft coverage across an edge.
kernel void probeShapes(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 0.11, float2(0.0));
    float a = probeRandom(id, 1u) * 4.0 - 2.0, b = probeRandom(id, 2u) * 4.0 - 2.0;
    float angle = probeRandom(id, 3u) * 6.2831853;
    out[id] = float4(smin(a, b, 0.5) - min(a, b), sdBox(p, float2(1.5, 0.75)),
                     length(rotate(p, angle)) - length(p), fill(p.x, 0.4));
}

// Distance to a segment: 0 anywhere along it, and a tapered one is thinner at its narrow end.
kernel void probeSegments(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                          uint id [[thread_position_in_grid]]) {
    float2 a = float2(-3.0, 1.0), b = float2(4.0, -2.0);
    float t = probeRandom(id, 13u);
    float2 p = probePoint(id, 0.2, float2(0.0));
    out[id] = float4(segmentDistance(mix(a, b, t), a, b), segmentDistance(p, a, b),
                     taperedSegment(p, a, b, 0.5, 0.1), taperedSegment(mix(a, b, t), a, b, 0.5, 0.1));
}

// A railway's signed distance is 0 on its own centre line, `along` is the way along it, and a point moved off
// the line reads as off it, on the side it was moved to.
kernel void probeRail(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    float x = (float(id) - 2048.0) * 0.9;
    float angle = 0.6;
    float3 shape = float3(14.0, 230.0, 0.8);
    float2 origin = float2(120.0, -40.0);
    float2 onLine = origin + rotate(float2(x, shape.x * sin(x / shape.y + shape.z)), angle);
    float along, alongOff;
    float d = railSigned(onLine, origin, angle, shape, along);
    float off = railSigned(onLine + rotate(float2(0.0, 5.0), angle), origin, angle, shape, alongOff);
    out[id] = float4(d, along - x, off, alongOff - x);
}

// MARK: - Colour

// Watercolour pigment at any density stays in gamut, and at neutral density leaves a colour as it was.
kernel void probePigment(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
    float3 c = float3(probeRandom(id, 4u), probeRandom(id, 5u), probeRandom(id, 6u));
    float3 painted = pigment(c, probeRandom(id, 7u), 1.6);
    float3 neutral = pigment(c, 0.5, 1.6);
    out[id] = float4(min(painted.x, min(painted.y, painted.z)), max(painted.x, max(painted.y, painted.z)),
                     length(neutral - c), luma(painted));
}

// The place's crop colours across the whole range of picks.
kernel void probeCrops(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    float h = float(id) / float(probeCount);
    out[id] = float4(cropColor(scene.legB.biome, h), h);
}

// Roof colours, shaded as much as the pick says, in the scene's daylight.
kernel void probeRoofs(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    float h = float(id) / float(probeCount);
    out[id] = float4(shade(roofColor(scene.legB.biome, h), h, scene), h);
}

// MARK: - Water and roads

// The river and road through the scene: each centre line sits at distance 0 from itself, and the river's slope
// agrees with the curve it describes. The last value is the river's x, for comparing builds.
kernel void probeRiverRoad(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    float y = (float(id) - 2048.0) * 3.7;
    float wander = scene.legB.biome.d.w;
    float x = riverX(y, scene, wander);
    float measured = riverX(y + 0.5, scene, wander) - riverX(y - 0.5, scene, wander);
    out[id] = float4(riverSlope(y, scene, wander) - measured, riverDistance(float2(x, y), scene, wander),
                     roadDistance(float2(roadX(y, scene, wander), y), scene, wander), x);
}

// How far points are from the strip pivots keep clear of, and whether they are clear of the water.
kernel void probeClearance(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    constant Leg &leg = scene.legB;
    float wander = leg.biome.d.w;
    float riverHalf = leg.biome.d.z * 0.5;
    float2 local = probePoint(id, 6.0, float2(scene.road.x, 300.0));
    float2 world = float2(local.x, local.y + leg.info.x);
    out[id] = float4(pivotClearance(local, leg, scene, wander),
                     float(clearOfWater(world, leg.biome, scene, riverHalf, wander, 3.0)),
                     riverPresence(riverHalf), riverDistance(world, scene, wander));
}

// MARK: - Land

// Field layout: the Voronoi cells farms are cut into, the warped space they are laid out in, and the width of
// the hedges between them.
kernel void probeFields(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    constant Biome &b = scene.legB.biome;
    uint seed = uint(scene.legB.info.y);
    float2 p = probePoint(id, 7.0, float2(scene.road.x, 300.0));
    Cells cells = voronoi(p / 60.0, seed);
    out[id] = float4(cells.border, float(cells.cell.x * 7 + cells.cell.y), fieldSpace(p, b, seed).x,
                     hedgeHalfWidth(p, b, seed));
}

// Bare ground between fields.
kernel void probeOpenGround(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                            uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 4.0, float2(scene.road.x - 200.0, 120.0));
    out[id] = float4(openGround(p, scene.legB.biome, uint(scene.legB.info.y)), 1.0);
}

// Where the land probes look: leg B of the scene, a little way into it, across the river and the road.
struct ProbeSpot {
    float2 world;
    float2 local;
    uint seed;
    float wander;
    float riverHalf;
};

inline ProbeSpot probeSpot(uint id, float step, constant Scene &scene) {
    constant Leg &leg = scene.legB;
    ProbeSpot spot;
    spot.world = probePoint(id, step, float2(scene.road.x, leg.info.x + 400.0));
    spot.local = float2(spot.world.x, spot.world.y - leg.info.x);
    spot.seed = uint(leg.info.y);
    spot.wander = leg.biome.d.w;
    spot.riverHalf = leg.biome.d.z < 0.5 ? 0.0 : leg.biome.d.z * 0.5;
    return spot;
}

// The paint the painting helpers are given to paint over.
constant float3 probeBase = float3(0.45, 0.5, 0.35);

// The land of the place in view, as the ground pass paints it before the river, railway and road: its colour
// and water here, and its sway, herds, road and night light in probeLandMasks.
inline Land probeLand(uint id, constant Scene &scene) {
    ProbeSpot spot = probeSpot(id, 5.0, scene);
    return land(spot.world, scene.legB, scene, spot.riverHalf, spot.wander);
}

kernel void probeLandColour(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                            uint id [[thread_position_in_grid]]) {
    Land l = probeLand(id, scene);
    out[id] = float4(l.color, l.water);
}

kernel void probeLandMasks(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    Land l = probeLand(id, scene);
    out[id] = float4(l.sway, l.herd, l.road, l.light);
}

// Each field layout, painted with this place's colours whatever layout the place itself uses, so every layout
// is covered by every palette. Colour, and the one mask each layout is about.
kernel void probeGrassland(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 5.0, scene);
    Land l = grassland(spot.local, scene.legB.biome, spot.seed);
    out[id] = float4(l.color, l.sway);
}

kernel void probeFieldLayout(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                             uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 5.0, scene);
    Land l = fields(spot.local, scene.legB.biome, scene, spot.seed);
    out[id] = float4(l.color, l.sway);
}

kernel void probePaddies(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 5.0, scene);
    Land l = paddies(spot.local, scene.legB.biome, spot.seed);
    out[id] = float4(l.color, l.water);
}

kernel void probeStripes(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 5.0, scene);
    Land l = stripes(spot.local, scene.legB.biome, spot.seed);
    out[id] = float4(l.color, l.sway);
}

kernel void probePivots(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 9.0, scene);
    Land l = pivots(spot.local, scene.legB, scene, spot.seed, spot.wander);
    out[id] = float4(l.color, l.road);
}

kernel void probeTaiga(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 5.0, scene);
    Land l = taiga(spot.local, scene.legB.biome, scene, spot.seed);
    out[id] = float4(l.color, l.forest);
}

// Jittered field edges stay within half the jitter of their cell, and the boats' paint covers its palette.
kernel void probeEdgesAndPaint(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                               uint id [[thread_position_in_grid]]) {
    int k = int(id) - 2048;
    out[id] = float4(boatPaint(probeRandom(id, 14u)), jitteredEdge(k, 0.4, 5u) - float(k));
}

// MARK: - On the land

// One tree seen from above around its trunk, with the shade it casts, and how much it covers.
kernel void probeTree(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    float2 d = probePoint(id, 0.25, float2(0.0));
    float cover = 0.0;
    float3 c = tree(probeBase, d, 4.0, d + 300.0, scene.legB.biome, scene, 17u, cover);
    out[id] = float4(c, cover);
}

// Trees scattered over the land, gathered into groves as the place likes them.
kernel void probeTrees(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 3.0, scene);
    float cover = 0.0;
    float3 c = trees(probeBase, spot.local, spot.world, scene.legB.biome, scene, spot.seed, spot.riverHalf,
                     spot.wander, cover);
    out[id] = float4(c, cover);
}

// One house up close: its roof and shadow, and the light it spills after dark.
kernel void probeHouse(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    float2 d = probePoint(id, 0.5, float2(0.0));
    float cover = 0.0, light = 0.0, lightID = 0.0;
    float3 c = house(probeBase, d, 0.4, float2(4.0, 6.0), 3, scene.legB.biome, scene, 23u, cover, light, lightID);
    out[id] = float4(c, light);
}

// Farms and villages as the place builds them, with their night light.
kernel void probeHouses(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 4.0, scene);
    float cover = 0.0, light = 0.0, lightID = 0.0;
    float3 c = houses(probeBase, spot.local, spot.world, scene.legB.biome, scene, spot.seed, spot.wander, cover,
                      light, lightID);
    out[id] = float4(c, light);
}

// Street lamps along the village roads, and the pools of light they leave.
kernel void probeStreetLamps(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                             uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 4.0, scene);
    float light = 0.0, lightID = 0.0;
    float3 c = streetLamps(probeBase, spot.local, spot.world, scene.legB.biome, scene, spot.seed, spot.wander, light,
                           lightID);
    out[id] = float4(c, light);
}

// A cluster of boulders, and whether a herd would stand there.
kernel void probeBoulders(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                          uint id [[thread_position_in_grid]]) {
    float2 d = probePoint(id, 0.3, float2(0.0));
    float herd = 0.0;
    float3 c = boulders(probeBase, d, 6.0, 5, scene.legB.biome, scene, 29u, herd);
    out[id] = float4(c, herd);
}

// Every kind of landmark, a band of the grid each, at full density.
kernel void probeLandmarks(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 6.0, scene);
    int kind = int(id * 13u / probeCount);
    float herd = 0.0, water = 0.0, cover = 0.0, light = 0.0, lightID = 0.0;
    float3 c = landmark(probeBase, kind, 1.0, spot.local, spot.world, scene.legB.biome, scene, spot.seed, spot.wander,
                        spot.riverHalf, herd, water, cover, light, lightID);
    out[id] = float4(c, water + light);
}

// Ponds, and the water they mark.
kernel void probePonds(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 12.0, scene);
    float water = 0.0;
    float3 c = ponds(probeBase, spot.local, spot.world, scene.legB.biome, scene, spot.seed, spot.wander, water);
    out[id] = float4(c, water);
}

// MARK: - River, road and railway

// The river across its banks, painted for the place in view.
kernel void probeRiver(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 2.0, scene);
    float water = 0.0, herd = 0.0;
    float3 c = river(probeBase, spot.world, scene, scene.legA.biome, scene.legB.biome, 1.0, scene.legB.biome.d.z,
                     spot.wander, water, herd);
    out[id] = float4(c, water);
}

// The road and its verges, and how much of each point is road.
kernel void probeRoad(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    ProbeSpot spot = probeSpot(id, 1.0, scene);
    float y = scene.legB.info.x + 400.0;
    float2 world = probePoint(id, 1.0, float2(roadX(y, scene, spot.wander), y));
    float onRoad = 0.0, water = 0.0, herd = 0.0;
    float3 c = road(probeBase, world, scene, scene.legA.biome, scene.legB.biome, 1.0, spot.riverHalf,
                    spot.wander, onRoad, water, herd);
    out[id] = float4(c, onRoad);
}

// The railway where it passes its origin, when a leg has one, and the same line laid over a road.
kernel void probeRailway(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
    constant Leg &leg = scene.legB;
    float2 onLine = leg.rail.xy + rotate(float2(0.0, leg.railShape.x * sin(leg.railShape.z)), leg.rail.z);
    float2 world = probePoint(id, 0.6, float2(onLine.x, onLine.y + leg.info.x));
    float herd = 0.0, water = 0.0;
    float3 c = railway(probeBase, world, leg, scene, 0.45, leg.biome.d.z * 0.5, leg.biome.d.w, herd, water);
    out[id] = float4(c, luma(railOverRoad(probeBase, world, leg, 1.0, 0.45)));
}

// MARK: - Things that move

// Street lights through an evening: warming up, on, and the odd one failing.
kernel void probeStreetLight(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                             uint id [[thread_position_in_grid]]) {
    float value = float(id % probeSide) / float(probeSide - 1);
    float hour = 17.0 + 10.0 * float(id / probeSide) / float(probeSide - 1);
    float3 c = streetLight(probeBase, value, probeRandom(id, 15u), 1.0, hour, scene.legB.biome, 1800.0);
    out[id] = float4(c, hour);
}

// Cars along the road, and the light of their lamps.
kernel void probeCars(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    float y = scene.legB.info.x + 400.0 + (float(id / 8u) - 256.0) * 1.5;
    float x = roadX(y, scene, scene.legB.biome.d.w) + (float(id % 8u) - 3.5) * 1.2;
    float3 light = float3(0.0);
    float3 c = cars(probeBase, float2(x, y), scene.legB.biome, scene, 0.45, light);
    out[id] = float4(c, light.r + light.g + light.b);
}

// Boats on the river, with their wakes and lights.
kernel void probeBoats(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    float y = scene.legB.info.x + 400.0 + (float(id / 16u) - 128.0) * 3.0;
    float x = riverX(y, scene, scene.legB.biome.d.w) + (float(id % 16u) - 7.5) * 1.5;
    float3 light = float3(0.0);
    float3 c = boats(probeBase, float2(x, y), 1.0, scene.legB.biome, scene, 0.45, scene.time.x, light);
    out[id] = float4(c, light.r + light.g + light.b);
}

// The middle of the passing train, on its rail.
inline float2 probeTrainMiddle(constant Train &tr) {
    float middle = tr.run.x - tr.run.y * 0.5 * tr.run.z * (tr.run.w + tr.info.x);
    float wiggle = tr.shape.x * sin(middle / max(tr.shape.y, 1.0) + tr.shape.z);
    return tr.rail.xy + rotate(float2(middle, wiggle), tr.rail.z);
}

// The train in view, around its middle car, when one is passing.
kernel void probeTrain(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    float2 world = probePoint(id, 1.2, probeTrainMiddle(scene.train));
    float3 light = float3(0.0);
    float3 c = train(probeBase, world, scene.train, scene, 0.45, light);
    out[id] = float4(c, light.r + light.g + light.b);
}

// The train's outline: the distance to its cars, where a point sits on its car, and which car that is.
kernel void probeTrainShape(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                            uint id [[thread_position_in_grid]]) {
    float2 world = probePoint(id, 0.8, probeTrainMiddle(scene.train));
    float2 local = float2(0.0);
    float car = 0.0;
    float d = trainShape(world, scene.train, local, car);
    out[id] = float4(d, local, car);
}

// MARK: - The frame pass

// Value noise read from the lattice, as the frame pass reads it for gusts and glints.
kernel void probeLatticeNoise(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                              texture2d<float> lattice [[texture(0)]], sampler wrap [[sampler(0)]],
                              uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 0.37, float2(5.0, 9.0));
    out[id] = float4(latticeNoise(lattice, wrap, p), latticeNoise(lattice, wrap, p + 256.0),
                     latticeNoise(lattice, wrap, p * 3.1), latticeNoise(lattice, wrap, -p));
}

// The flock as each kind flies it, a third of the grid each: the nearest bird's distance, where the point falls on
// that bird, and its wing spread, over the reach around the leader.
kernel void probeFlock(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                       constant CompositeParams *views [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    constant CompositeParams &view = views[id * 3u / probeCount];
    float2 pixel = probePoint(id, flockReach(view) / 32.0, view.flock.xy);
    float2 q = float2(0.0);
    float spread = 0.0;
    float d = flockDistance(pixel, view, view.flockLook.w, q, spread);
    out[id] = float4(d, q, spread);
}

// The cache texel under points across the view, wrapped into the ring.
kernel void probeCacheTexel(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                            constant CompositeParams *views [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    constant CompositeParams &view = views[0];
    float2 world = view.world.xy + probePoint(id, 11.0, float2(340.0, 220.0));
    uint2 texel = cacheTexel(world, view);
    out[id] = float4(float2(texel), world - view.world.xy);
}

// The ground's alpha byte: what packGround writes, unpack reads back, to the precision the byte holds. The value
// goes through 8 bits on the way, as it does in the cache.
kernel void probePacking(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
    float water = probeRandom(id, 11u), sway = probeRandom(id, 12u);
    bool road = (id & 1u) != 0u, herd = (id & 2u) != 0u;
    Mask m = unpack(round(packGround(water, sway, road, herd) * 255.0) / 255.0);
    out[id] = float4(m.water - round(water * 3.0) / 3.0, m.sway - round(sway * 15.0) / 15.0,
                     float(m.road == road), float(m.herd == herd));
}

// MARK: - After dark

// Which houses are lit with the sun setting at 19:00: at noon, at nine, at half past eleven and at three.
kernel void probeHouseLights(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                             uint id [[thread_position_in_grid]]) {
    float house = probeRandom(id, 9u);
    out[id] = float4(houseOn(house, 12.0, 19.0), houseOn(house, 21.0, 19.0), houseOn(house, 23.5, 19.0),
                     houseOn(house, 3.0, 19.0));
}

// The light around one house: lit windows, porch and yard lamp, the same house under a full roof cover, and a
// wider house. The last value is the distance from the house, so the tests can tell where light should end.
kernel void probeHouseGlow(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    float2 d = probePoint(id, 0.9, float2(0.0));
    out[id] = float4(houseGlow(d, float2(4.0, 6.0), 3, 41u, 0.0), houseGlow(d, float2(4.0, 6.0), 3, 41u, 1.0),
                     houseGlow(d, float2(6.0, 3.0), 8, 41u, 0.0), length(d));
}

// MARK: - Sky

// The gull: mirror images when flying level, one wing shorter when it banks.
kernel void probeBird(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 0.04, float2(0.0));
    float spread = probeRandom(id, 10u);
    out[id] = float4(birdShape(p, spread, 0.0), birdShape(float2(-p.x, p.y), spread, 0.0),
                     birdShape(p, spread, 0.6), birdShape(float2(-p.x, p.y), spread, 0.6));
}

// Clouds: density and puff field here and one cloud period over, where the sky repeats.
kernel void probeClouds(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 23.0, float2(1200.0, -800.0));
    out[id] = float4(cloudField(p, 0.55, 4), cloudField(p + cloudPeriod, 0.55, 4));
}

// MARK: - Promises

// How far `x` is outside lo...hi, and how far it is from 0 beyond `tolerance`; both 0 when all is well.
inline float outside(float x, float lo, float hi) { return max(lo - x, 0.0) + max(x - hi, 0.0); }
inline float beyond(float x, float tolerance) { return max(abs(x) - tolerance, 0.0); }

// Hashes land in 0...1, and hash22 starts with hash21.
kernel void promiseHash(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    int2 cell = int2(id % probeSide, id / probeSide) - 32;
    float h = hash21(cell, 7u);
    float2 pair = hash22(cell, 7u);
    out[id] = float4(outside(h, 0.0, 1.0), outside(pair.y, 0.0, 1.0), outside(hash11(int(id), 7u), 0.0, 1.0),
                     beyond(pair.x - h, 0.0));
}

// Value noise stays in 0...1 and moves little over a hundredth of a cell, periodic noise repeats, and one octave
// of fractal noise is value noise while more octaves still stay in 0...1.
kernel void promiseNoise(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 0.173, float2(3.1, -7.4));
    float n = vnoise(p, 11u);
    out[id] = float4(outside(n, 0.0, 1.0), beyond(n - vnoise(p + float2(0.01, 0.0), 11u), 0.05),
                     beyond(vnoiseP(p, 8, 12u) - vnoiseP(p + 8.0, 8, 12u), 1e-4),
                     beyond(fbm(p, 1, 11u) - n, 1e-6) + outside(fbm(p, 6, 21u), 0.0, 1.0));
}

// The smooth minimum dips below min(a, b) by at most k / 4; a box's distance matches the one worked out the long
// way, to its nearest point outside and its nearest side inside; rotation keeps length; and fill is a half on
// the edge and only falls across it.
kernel void promiseShapes(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                          uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 0.11, float2(0.0));
    float a = probeRandom(id, 1u) * 4.0 - 2.0, b = probeRandom(id, 2u) * 4.0 - 2.0;
    float2 size = float2(1.5, 0.75);
    float box = all(abs(p) <= size) ? -min(size.x - abs(p.x), size.y - abs(p.y)) : length(p - clamp(p, -size, size));
    float turned = length(rotate(p, probeRandom(id, 3u) * 6.2831853));
    out[id] = float4(outside(smin(a, b, 0.5) - min(a, b), -0.125, 0.0), beyond(sdBox(p, size) - box, 1e-4),
                     beyond(turned - length(p), 1e-4 * max(1.0, length(p))),
                     beyond(fill(0.0, 0.4) - 0.5, 1e-6) + max(fill(p.x + 0.01, 0.4) - fill(p.x, 0.4), 0.0));
}

// A segment's distance is 0 along it and matches the distance to its nearest point; a tapered segment is a
// thickened one, so it reads nearer everywhere and inside along its length.
kernel void promiseSegments(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                            uint id [[thread_position_in_grid]]) {
    float2 a = float2(-3.0, 1.0), b = float2(4.0, -2.0);
    float2 p = probePoint(id, 0.2, float2(0.0));
    float2 on = mix(a, b, probeRandom(id, 13u));
    float t = saturate(dot(p - a, b - a) / dot(b - a, b - a));
    float d = segmentDistance(p, a, b);
    out[id] = float4(beyond(segmentDistance(on, a, b), 1e-4), beyond(d - distance(p, mix(a, b, t)), 1e-4),
                     max(taperedSegment(p, a, b, 0.5, 0.1) - d, 0.0), max(taperedSegment(on, a, b, 0.5, 0.1), 0.0));
}

// A railway's distance is 0 on its own centre line and `along` is the way along it; a point moved 5 metres off
// reads as about 5 metres off, on that side, and no further along.
kernel void promiseRail(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    float x = (float(id) - 2048.0) * 0.9;
    float angle = 0.6;
    float3 shape = float3(14.0, 230.0, 0.8);
    float2 origin = float2(120.0, -40.0);
    float2 onLine = origin + rotate(float2(x, shape.x * sin(x / shape.y + shape.z)), angle);
    float along, alongOff;
    float d = railSigned(onLine, origin, angle, shape, along);
    float off = railSigned(onLine + rotate(float2(0.0, 5.0), angle), origin, angle, shape, alongOff);
    out[id] = float4(beyond(d, 5e-3), beyond(along - x, 5e-3), outside(off, 4.9, 5.001), beyond(alongOff - x, 5e-3));
}

// Pigment at any density stays in gamut and at neutral density leaves a colour alone, and the luma of a colour
// in gamut stays in 0...1.
kernel void promisePigment(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    float3 c = float3(probeRandom(id, 4u), probeRandom(id, 5u), probeRandom(id, 6u));
    float3 painted = pigment(c, probeRandom(id, 7u), 1.6);
    out[id] = float4(outside(min(painted.x, min(painted.y, painted.z)), 0.0, 1.0),
                     outside(max(painted.x, max(painted.y, painted.z)), 0.0, 1.0),
                     beyond(length(pigment(c, 0.5, 1.6) - c), 1e-5), outside(luma(painted), 0.0, 1.0));
}

// The river and road through the scene: each centre line sits at distance 0 from itself, the river's slope
// agrees with the curve it describes, and riverX is riverShape laid out from the scene's river.
kernel void promiseCentreLines(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                               uint id [[thread_position_in_grid]]) {
    float y = (float(id) - 2048.0) * 3.7;
    float wander = scene.legB.biome.d.w;
    float x = riverX(y, scene, wander);
    float measured = riverX(y + 0.5, scene, wander) - riverX(y - 0.5, scene, wander);
    out[id] = float4(beyond(riverSlope(y, scene, wander) - measured, 2e-3),
                     beyond(riverDistance(float2(x, y), scene, wander), 1e-2),
                     beyond(roadDistance(float2(roadX(y, scene, wander), y), scene, wander), 1e-2),
                     beyond(x - (scene.road.x + wander * riverShape(y, scene.river)), 1e-3));
}

// The ground's alpha byte keeps water to a third, sway to a fifteenth, and the road and herd bits exactly,
// through the 8 bits the cache stores it in.
kernel void promisePacking(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    float water = probeRandom(id, 11u), sway = probeRandom(id, 12u);
    bool road = (id & 1u) != 0u, herd = (id & 2u) != 0u;
    Mask m = unpack(round(packGround(water, sway, road, herd) * 255.0) / 255.0);
    out[id] = float4(beyond(m.water - round(water * 3.0) / 3.0, 1e-5), beyond(m.sway - round(sway * 15.0) / 15.0, 1e-5),
                     float(m.road != road), float(m.herd != herd));
}

// A house is either lit or not at any hour, and its light is never negative, shows only as a skylight under a
// full roof, and ends well short of 27 metres away.
kernel void promiseHouseLight(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
    float2 d = probePoint(id, 0.9, float2(0.0));
    float open = houseGlow(d, float2(4.0, 6.0), 3, 41u, 0.0), wide = houseGlow(d, float2(6.0, 3.0), 8, 41u, 0.0);
    float far = length(d) > 27.0 ? 1.0 : 0.0;
    float hour = 24.0 * probeRandom(id, 16u);
    out[id] = float4(outside(houseOn(probeRandom(id, 9u), hour, 16.0 + 6.0 * probeRandom(id, 17u)), 0.0, 1.0),
                     max(-open, 0.0) + max(-wide, 0.0), outside(houseGlow(d, float2(4.0, 6.0), 3, 41u, 1.0), 0.0, 0.85),
                     far * (open + wide));
}

// The gull is its own mirror image in level flight, its middle is inside it, and a wingspan away is outside.
kernel void promiseBird(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 0.04, float2(0.0));
    float spread = probeRandom(id, 10u), bank = probeRandom(id, 18u) * 2.0 - 1.0;
    float2 corner = float2(id & 1u ? 1.4 : -1.4, id & 2u ? 1.4 : -1.4);
    out[id] = float4(beyond(birdShape(p, spread, 0.0) - birdShape(float2(-p.x, p.y), spread, 0.0), 1e-5),
                     max(birdShape(float2(0.0, 0.02), spread, bank), 0.0), max(-birdShape(corner, spread, bank), 0.0),
                     0.0);
}

// Clouds repeat one cloud period over, where the sky wraps, and their density stays in 0...1.
kernel void promiseClouds(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                          uint id [[thread_position_in_grid]]) {
    float2 p = probePoint(id, 23.0, float2(1200.0, -800.0));
    float2 here = cloudField(p, 0.55, 4), over = cloudField(p + cloudPeriod, 0.55, 4);
    out[id] = float4(beyond(here.x - over.x, 0.02), beyond(here.y - over.y, 0.02), outside(here.x, 0.0, 1.0), 0.0);
}

// The land's water is a share, its night light is never negative, and every texel it maps the view to is inside
// the cache.
kernel void promiseLand(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                        constant CompositeParams *views [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    Land l = probeLand(id, scene);
    constant CompositeParams &view = views[0];
    uint2 texel = cacheTexel(view.world.xy + probePoint(id, 11.0, float2(340.0, 220.0)), view);
    out[id] = float4(outside(l.water, 0.0, 1.0), max(-l.light, 0.0),
                     outside(float(texel.x), 0.0, view.cache.z - 1.0), outside(float(texel.y), 0.0, view.cache.w - 1.0));
}

// Each kind of flock reaches no further than flockReach says: past it, every bird is further than a wingspan.
kernel void promiseFlock(device float4 *out [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                         constant CompositeParams *views [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    constant CompositeParams &view = views[id * 3u / probeCount];
    float reach = flockReach(view);
    float angle = probeRandom(id, 19u) * 6.2831853;
    float2 pixel = view.flock.xy + float2(cos(angle), sin(angle)) * reach * (1.05 + probeRandom(id, 20u));
    float2 q = float2(0.0);
    float spread = 0.0;
    out[id] = float4(max(-flockDistance(pixel, view, view.flockLook.w, q, spread), 0.0), 0.0, 0.0, 0.0);
}

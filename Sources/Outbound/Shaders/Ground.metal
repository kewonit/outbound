// The ground: painted once into a scrolling cache, a few new rows at a time.

struct GroundOut {
    float4 color [[color(0)]];
    // water, sway, road, herd
    float4 mask [[color(1)]];
};

struct Land {
    float3 color;
    float water;
    float sway;
    float herd;
    float road;
    float forest;
};

inline float3 cropColor(constant Biome &b, float h) {
    return h < 0.25 ? b.crop0.rgb : h < 0.5 ? b.crop1.rgb : h < 0.75 ? b.crop2.rgb : b.crop3.rgb;
}

// Shadows are a cool multiply, never grey.
inline float3 shade(float3 c, float amount) {
    return c * mix(float3(1.0), float3(0.56, 0.62, 0.78), amount);
}

// One tree crown with its shadow. `d` is the offset from the trunk.
inline float3 tree(float3 c, float2 d, float r, float2 local, constant Biome &b, constant Scene &scene, uint seed,
                   thread float &cover) {
    float2 shadowOff = -scene.sun.xy * scene.sun.z * r * 1.7;
    c = shade(c, fill(length(d - shadowOff) - r * 0.95, 0.7) * 0.85);
    float lobes = vnoise(local / (r * 0.55), seed + 44u);
    float dt = length(d) - r * (0.88 + 0.28 * lobes);
    float lit = dot(normalize(d + 1e-4), scene.sun.xy) * 0.5 + 0.5;
    float clumps = vnoise(local / (r * 0.4), seed + 45u);
    float3 crown = mix(b.canopy.rgb, b.canopyLight.rgb, saturate(lit * 0.8 + clumps * 0.35 - 0.12));
    crown *= 0.92 + 0.16 * smoothstep(0.2, 1.0, lit) * clumps;
    crown = mix(crown, b.snow.rgb, b.f.y * 0.55 * smoothstep(0.45, 0.8, clumps));
    float a = fill(dt, 0.45);
    cover = max(cover, a);
    return mix(c, crown, a);
}

// MARK: - Field layouts

struct Cells {
    float border; // distance to the nearest border, in cells
    int2 cell;
};

// Inigo Quilez's exact distance to Voronoi borders, with the second pass smoothed so fields round off.
inline Cells voronoi(float2 x, uint seed) {
    float2 n = floor(x);
    float2 f = x - n;
    int2 ni = int2(n);
    float2 mg = 0.0, mr = 0.0;
    float md = 8.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(i, j);
            float2 o = 0.5 + 0.85 * (hash22(ni + int2(i, j), seed) - 0.5);
            float2 r = g + o - f;
            float d = dot(r, r);
            if (d < md) { md = d; mr = r; mg = g; }
        }
    }
    md = 8.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float2 g = mg + float2(i, j);
            float2 o = 0.5 + 0.85 * (hash22(ni + int2(g), seed) - 0.5);
            float2 r = g + o - f;
            float2 diff = r - mr;
            if (dot(diff, diff) > 1e-5) md = smin(md, dot(0.5 * (mr + r), normalize(diff)), 0.22);
        }
    }
    Cells c;
    c.border = md;
    c.cell = ni + int2(mg);
    return c;
}

inline float2 fieldSpace(float2 p, constant Biome &b, uint seed) {
    float size = b.a.y;
    float2 w = float2(fbm(p / (size * 1.9), 3, seed + 21u), fbm(p / (size * 1.9) + 17.3, 3, seed + 22u)) - 0.5;
    return p / size + b.a.w * 1.15 * w;
}

inline float hedgeHalfWidth(float2 p, constant Biome &b, uint seed) {
    // Lumpy, like a line of tree crowns.
    return b.a.z * 0.5 * (0.65 + 0.7 * vnoise(p / (b.a.z * 1.1 + 2.0), seed + 31u));
}

// Ground with soft patches and long brush strokes.
inline float3 openGround(float2 p, constant Biome &b, uint seed) {
    float big = fbm(p / 150.0, 4, seed + 1u);
    float mid = fbm(p / 38.0, 3, seed + 2u);
    float3 c = mix(b.ground.rgb, b.groundDark.rgb, smoothstep(0.42, 0.78, big) * b.b.y);
    c = mix(c, b.crop1.rgb, smoothstep(0.58, 0.82, vnoise(p / 230.0, seed + 3u)) * 0.55 * b.b.y);
    c = mix(c, b.crop2.rgb, smoothstep(0.55, 0.85, mid) * 0.35);
    float strokes = vnoise(rotate(p, 0.55) * float2(1.0 / 1.4, 1.0 / 8.5), seed + 4u);
    float fine = vnoise(rotate(p, 0.55) * float2(1.0 / 0.6, 1.0 / 3.0), seed + 5u);
    c *= 1.0 + b.b.z * (0.16 * (strokes - 0.5) + 0.08 * (fine - 0.5));
    return c;
}

inline Land grassland(float2 p, constant Biome &b, uint seed) {
    Land l;
    l.color = openGround(p, b, seed);
    l.water = 0.0;
    l.sway = b.b.w * 0.7;
    l.herd = 1.0;
    l.road = 0.0;
    l.forest = 0.0;
    return l;
}

inline Land fields(float2 p, constant Biome &b, constant Scene &scene, uint seed) {
    float size = b.a.y;
    Cells v = voronoi(fieldSpace(p, b, seed), seed);
    float border = v.border * size;
    float hw = hedgeHalfWidth(p, b, seed);

    float h = hash21(v.cell, seed + 5u);
    float fallow = hash21(v.cell, seed + 6u);
    float angle = hash21(v.cell, seed + 7u) * M_PI_F;
    float2 q = rotate(p, angle);

    Land l;
    l.water = b.c.x * step(fallow, 0.5) * 0.6;
    l.road = 0.0;
    l.forest = 0.0;
    if (fallow < b.b.x) {
        l.color = openGround(p, b, seed);
        l.sway = b.b.w * 0.4;
        l.herd = 1.0;
    } else {
        float3 c = cropColor(b, h);
        c *= 0.94 + 0.12 * hash21(v.cell, seed + 8u);
        // Drill rows and brush strokes running along the field.
        float rows = sin(q.x * (2.0 * M_PI_F / 2.6));
        float strokes = vnoise(q * float2(1.0 / 2.6, 1.0 / 20.0), seed + 9u);
        float wash = vnoise(q / 30.0, seed + 16u);
        c *= 1.0 + b.b.z * (0.018 * rows + 0.07 * (strokes - 0.5) + 0.1 * (wash - 0.5));
        // Paint pools a little darker against the hedge.
        c *= 1.0 - 0.13 * (1.0 - smoothstep(0.0, 12.0, border - hw));
        l.color = c;
        l.sway = b.b.w;
        l.herd = 0.0;
    }

    // Orchards: grass under rows of small trees in some fields.
    if (hash21(v.cell, seed + 10u) < b.d.x && fallow >= b.b.x) {
        l.color = openGround(p, b, seed);
        float spacing = 8.5;
        float2 g = floor(q / spacing);
        float trees = 0.0;
        int2 cell = int2(g);
        if (hash21(cell, seed + 11u) < 0.88) {
            float2 local = q - (g + 0.5) * spacing - (hash22(cell, seed + 12u) - 0.5) * 1.6;
            float r = b.c.z * 0.3 * (0.85 + 0.3 * hash21(cell, seed + 13u));
            l.color = tree(l.color, rotate(local, -angle), r, p, b, scene, seed, trees);
        }
        l.sway = b.b.w * 0.3 * (1.0 - trees);
        l.herd = 0.0;
    }

    // Hedge shadow, sampled where the sun would see the hedge from.
    float2 toSun = scene.sun.xy * scene.sun.z * (2.5 + b.a.z * 0.45);
    Cells vs = voronoi(fieldSpace(p + toSun, b, seed), seed);
    float shadowEdge = vs.border * size - hedgeHalfWidth(p + toSun, b, seed);
    l.color = shade(l.color, fill(shadowEdge, 1.2) * 0.8);

    if (border < hw + 1.0) {
        // Soft, rotated noise so the hedge reads as massed crowns rather than a grid, with a few
        // darker clumps where trees stand taller.
        float2 hp = rotate(p, 0.7);
        float crowns = fbm(hp / 7.0, 3, seed + 14u);
        float lit = fbm((hp + rotate(scene.sun.xy, 0.7) * 1.6) / 7.0, 3, seed + 14u) - crowns;
        float clumps = smoothstep(0.55, 0.8, vnoise(p / 16.0, seed + 15u));
        float3 hedge = b.hedge.rgb * (0.92 + 0.2 * (crowns - 0.5) + 2.2 * lit) * (1.0 - 0.16 * clumps);
        l.color = mix(l.color, hedge, fill(border - hw, 0.55));
        l.forest = fill(border - hw, 0.55);
        l.sway = mix(l.sway, 0.15, fill(border - hw, 0.55));
        l.herd = 0.0;
        l.water *= 1.0 - fill(border - hw, 0.55);
    }
    return l;
}

// One plot of the paddy grid: column bounds, row bounds and an id.
inline float jitteredEdge(int k, float jitter, uint seed) {
    return float(k) + (hash11(k, seed) - 0.5) * jitter;
}

inline Land paddies(float2 p, constant Biome &b, uint seed) {
    float w = b.a.y;
    float cx = p.x / w;
    int k = int(floor(cx));
    float e0 = jitteredEdge(k, 0.3, seed);
    float e1 = jitteredEdge(k + 1, 0.3, seed);
    int col = k;
    if (cx < e0) { col = k - 1; e1 = e0; e0 = jitteredEdge(k - 1, 0.3, seed); }
    else if (cx >= e1) { col = k + 1; e0 = e1; e1 = jitteredEdge(k + 2, 0.3, seed); }

    // Columns come in blocks of five that share their cross levees, like a surveyed grid.
    int block = int(floor(float(col) / 5.0));
    int inBlock = col - block * 5;
    float len = w * (1.5 + 0.9 * hash11(block, seed + 1u));
    float ry = (p.y + hash11(block, seed + 2u) * len * 7.0) / len;
    float row = floor(ry);
    float rowDist = min(ry - row, row + 1.0 - ry) * len;
    // Now and then a cross levee is missing and two plots run together.
    if (hash21(int2(col, int(row)), seed + 10u) < 0.18 && ry - row < 0.5) rowDist = 1e3;
    float sideDist = min(cx - e0, e1 - cx) * w;
    float edgeDist = min(sideDist, rowDist);
    int2 plot = int2(col, int(row));

    float h = hash21(plot, seed + 3u);
    float kind = hash21(plot, seed + 4u);
    Land l;
    l.road = 0.0;
    l.herd = 0.0;
    l.forest = 0.0;
    float3 c;
    if (kind < b.b.x) {
        // Ploughed mud.
        c = mix(float3(0.56, 0.45, 0.34), b.groundDark.rgb, 0.2);
        c *= 1.0 + 0.08 * sin(p.y * 2.4) * b.b.z;
        l.water = 0.0;
        l.sway = 0.0;
    } else if (h < 0.5) {
        c = cropColor(b, h);
        c = mix(c, c * 1.08, vnoise(p / 9.0, seed + 11u));
        l.water = b.c.x;
        l.sway = 0.1;
    } else {
        c = cropColor(b, h);
        // Seedlings in rows, picked out as specks.
        float2 g = p / float2(1.15, 1.4);
        float speck = hash21(int2(floor(g)), seed + 5u);
        c *= 1.0 + 0.1 * (speck - 0.5) * (1.0 + b.b.z);
        l.water = b.c.x * 0.25;
        l.sway = b.b.w;
    }
    c *= 0.95 + 0.1 * hash21(plot, seed + 6u);

    float levee = b.a.z * 0.5;
    c = mix(c, b.hedge.rgb * (0.92 + 0.12 * vnoise(p / 1.5, seed + 9u)), fill(edgeDist - levee, 0.3));
    // A thin bright grass line along each levee.
    c = mix(c, mix(b.hedge.rgb, float3(0.55, 0.78, 0.35), 0.55),
            fill(abs(edgeDist - levee - 0.35) - 0.25, 0.2) * (1.0 - b.f.y));
    // Between blocks: a farm track, or now and then an irrigation canal.
    if (inBlock == 0 && cx - e0 < 0.5) {
        float d = (cx - e0) * w;
        bool canal = hash11(block, seed + 7u) < 0.3;
        if (canal) {
            float wet = fill(d - levee - 1.8, 0.3);
            c = mix(c, b.water.rgb, wet);
            l.water = max(l.water, wet);
        } else {
            c = mix(c, b.road.rgb * (1.0 + 0.06 * vnoise(p / 1.2, seed + 8u)), fill(d - 2.8, 0.35));
        }
    }
    l.color = c;
    l.sway *= 1.0 - fill(edgeDist - levee, 0.3);
    l.water *= 1.0 - fill(edgeDist - levee, 0.3);
    return l;
}

inline Land stripes(float2 p, constant Biome &b, uint seed) {
    float w = b.a.y;
    float blockLength = 340.0;
    float by = floor((p.y + 80.0 * hash11(int(floor(p.x / 600.0)), seed)) / blockLength);
    float yIn = fract((p.y + 80.0 * hash11(int(floor(p.x / 600.0)), seed)) / blockLength) * blockLength;
    float shift = hash11(int(by), seed + 1u) * w;
    float sx = (p.x + shift) / w;
    float col = floor(sx);
    float xIn = fract(sx) * w;
    int2 strip = int2(int(col), int(by));
    float h = hash21(strip, seed + 2u);
    Land l;
    l.road = 0.0;
    l.herd = 0.0;
    l.water = 0.0;
    l.forest = 0.0;
    float3 c;
    if (hash21(strip, seed + 3u) < b.b.x) {
        c = mix(b.ground.rgb, b.groundDark.rgb, 0.3 + 0.4 * vnoise(p / 9.0, seed + 4u));
        l.sway = 0.2;
    } else {
        c = cropColor(b, h);
        float rows = sin(p.x * (2.0 * M_PI_F / 1.7));
        c *= 1.0 + 0.05 * rows * b.b.z + 0.08 * (vnoise(p * float2(1.0 / 0.8, 1.0 / 6.0), seed + 5u) - 0.5);
        l.sway = b.b.w;
    }
    // Bare soil between strips; a water ditch every few strips.
    float edge = min(xIn, w - xIn);
    c = mix(c, b.groundDark.rgb * 0.8, fill(edge - b.a.z * 0.3, 0.25));
    bool ditch = hash11(int(col), seed + 6u) < 0.22;
    if (ditch) {
        float d = xIn - 1.4;
        c = mix(c, b.water.rgb, fill(d, 0.3));
        c = mix(c, b.hedge.rgb, fill(abs(d - 1.0) - 0.6, 0.3));
        l.water = fill(d, 0.3);
    }
    // Grass tracks between blocks.
    float yEdge = min(yIn, blockLength - yIn);
    c = mix(c, b.hedge.rgb * (0.9 + 0.15 * vnoise(p / 2.0, seed + 7u)), fill(yEdge - 3.5, 0.4));
    l.color = c;
    return l;
}

inline Land pivots(float2 p, constant Biome &b, constant Scene &scene, uint seed) {
    float s = b.a.y;
    float2 g = floor(p / s);
    float2 center = (g + 0.5) * s;
    float2 r = p - center;
    float radius = s * 0.485;
    int2 cell = int2(g);
    Land l;
    l.road = 0.0;
    l.water = 0.0;
    l.forest = 0.0;
    float3 c = openGround(p, b, seed);
    l.herd = 1.0;
    l.sway = b.b.w * 0.3;
    float d = length(r) - radius;
    if (hash21(cell, seed + 1u) > b.b.x) {
        float angle = atan2(r.y, r.x);
        float split = hash21(cell, seed + 2u);
        float h = hash21(cell, seed + 3u);
        // Some circles are planted in halves or quarters.
        if (split > 0.55) {
            float slices = split > 0.82 ? 4.0 : 2.0;
            float start = hash21(cell, seed + 4u) * 6.283;
            h = fract(h + floor((angle + start) / (6.283 / slices)) * 0.37);
        }
        float3 crop = cropColor(b, h) * (0.95 + 0.1 * hash21(cell, seed + 5u));
        // Wheel tracks of the pivot arm.
        float rings = sin(length(r) * (2.0 * M_PI_F / 54.0));
        crop *= 1.0 - 0.05 * smoothstep(0.85, 1.0, rings);
        crop *= 1.0 + b.b.z * 0.12 * (vnoise(rotate(r, angle) * float2(1.0 / 1.0, 1.0 / 14.0), seed + 6u) - 0.5);
        c = mix(c, crop, fill(d, 1.2));
        l.sway = mix(l.sway, b.b.w, fill(d, 1.2));
        l.herd = 1.0 - fill(d, 1.2);
    }
    // Section roads every mile.
    float mile = s * 2.0;
    float2 m = abs(fract(p / mile + 0.5) - 0.5) * mile;
    float roadD = min(m.x, m.y) - b.e.x * 0.5;
    c = mix(c, b.road.rgb * (0.95 + 0.1 * vnoise(p / 1.5, seed + 7u)), fill(roadD, 0.5));
    l.road = fill(roadD, 0.5);
    l.herd *= 1.0 - l.road;
    l.color = c;
    return l;
}

// MARK: - Things on the land

inline float riverDistance(float2 p, constant Scene &scene, float wander) {
    float cx = riverX(p.y, scene, wander);
    float s = riverSlope(p.y, scene, wander);
    return (p.x - cx) / sqrt(1.0 + s * s);
}

inline float roadDistance(float2 p, constant Scene &scene, float wander) {
    float rx = roadX(p.y, scene, wander);
    float s = riverSlope(p.y, scene, wander);
    float t = tanh(3.0 * sin(p.y / roadWave + scene.road.z));
    s += scene.road.y * (1.0 - t * t) * 3.0 * cos(p.y / roadWave + scene.road.z) / roadWave;
    return (p.x - rx) / sqrt(1.0 + s * s);
}

inline bool clearOfWater(float2 world, constant Biome &b, constant Scene &scene, float riverHalf, float wander,
                         float r) {
    return abs(riverDistance(world, scene, wander)) > riverHalf + r + 5.0
        && abs(roadDistance(world, scene, wander)) > b.e.x * 0.5 + r + 2.0;
}

// Trees scattered, gathered into groves as much as the biome likes. Each tree and its shadow stay
// inside their own cell, so one lookup is enough.
inline float3 trees(float3 c, float2 local, float2 world, constant Biome &b, constant Scene &scene, uint seed,
                    float riverHalf, float wander, thread float &cover) {
    float density = b.c.y;
    float size = b.c.z;
    if (density > 0.0) {
        float spacing = size * 2.6;
        float2 g = floor(local / spacing);
        int2 cell = int2(g);
        float h = hash21(cell, seed + 40u);
        float2 centerLocal = (g + 0.5) * spacing;
        float clumping = b.g.z;
        float clump = smoothstep(0.5, 0.78, vnoise(centerLocal / 240.0, seed + 41u));
        float chance = density * mix(1.0, 0.12 + 3.2 * clump, clumping);
        if (h < chance) {
            float r = size * 0.5 * (0.7 + 0.5 * hash21(cell, seed + 42u));
            float margin = r * 1.9;
            float2 center = g * spacing + margin + hash22(cell, seed + 43u) * max(spacing - 2.0 * margin, 0.0);
            if (clearOfWater(world + (center - local), b, scene, riverHalf, wander, r)) {
                float2 d = local - center;
                // Petals scattered round blossom trees.
                if (b.d.y > 0.0) {
                    float petal = hash21(int2(floor(local / 0.9)), seed + 46u);
                    float near = 1.0 - smoothstep(r, r * 2.6, length(d));
                    c = mix(c, b.canopyLight.rgb * 1.05, step(1.0 - 0.22 * b.d.y * near, petal) * 0.9);
                }
                c = tree(c, d, r, local, b, scene, seed, cover);
            }
        }
    }

    // Windbreaks: straight lines of trees along some survey lines.
    if (b.g.w > 0.0) {
        float lineSpacing = 380.0;
        float k = floor(local.x / lineSpacing);
        float lineX = (k + 0.5) * lineSpacing + (hash11(int(k), seed + 50u) - 0.5) * 140.0;
        if (hash11(int(k), seed + 51u) < b.g.w && abs(local.x - lineX) < 14.0
            && hash21(int2(int(k), int(floor(local.y / 260.0))), seed + 52u) < 0.65) {
            float step = 7.0;
            float j0 = floor(local.y / step);
            for (int i = -1; i <= 1; i++) {
                float j = j0 + float(i);
                float jh = hash11(int(j) * 31 + int(k), seed + 53u);
                float r = size * 0.4 * (0.8 + 0.4 * jh);
                float2 center = float2(lineX + (jh - 0.5) * 1.6, (j + 0.5) * step);
                if (clearOfWater(world + (center - local), b, scene, riverHalf, wander, r)) {
                    c = tree(c, local - center, r, local, b, scene, seed, cover);
                }
            }
        }
    }
    return c;
}

inline float3 houses(float3 c, float2 local, float2 world, constant Biome &b, constant Scene &scene, uint seed,
                     float wander, thread float &cover) {
    if (b.e.w <= 0.0) return c;
    float slot = 85.0;
    float k = floor(local.y / slot);
    float h = hash11(int(k), seed + 60u);
    if (h > b.e.w) return c;
    float side = hash11(int(k), seed + 61u) < 0.5 ? -1.0 : 1.0;
    float yC = (k + 0.3 + 0.4 * hash11(int(k), seed + 62u)) * slot;
    float worldY = world.y + (yC - local.y);
    float rx = roadX(worldY, scene, wander);
    float s = riverSlope(worldY, scene, wander);
    float2 center = float2(rx + side * (b.e.x * 0.5 + 9.0 + 16.0 * hash11(int(k), seed + 63u)), worldY);
    if (abs(riverDistance(center, scene, wander)) < 30.0) return c;
    float angle = atan(s) + (hash11(int(k), seed + 64u) - 0.5) * 0.3;
    float2 d = rotate(world - center, -angle);
    float2 size = float2(4.2, 6.5) * (0.85 + 0.35 * hash11(int(k), seed + 65u));
    float2 shadowOff = rotate(-scene.sun.xy * scene.sun.z * 5.0, -angle);
    c = shade(c, fill(sdBox(d - shadowOff, size), 0.5) * 0.8);
    float roofPick = hash11(int(k), seed + 66u);
    float3 roof = roofPick < 0.35 ? float3(0.80, 0.33, 0.24) : roofPick < 0.6 ? float3(0.68, 0.40, 0.30)
                : roofPick < 0.8 ? float3(0.42, 0.50, 0.62) : float3(0.62, 0.60, 0.58);
    roof = mix(roof, b.snow.rgb, b.f.y * 0.8);
    // Two roof halves catch the light differently.
    float3 roofSide = d.x * scene.sun.x > 0.0 ? roof * 1.08 : roof * 0.78;
    float a = fill(sdBox(d, size), 0.35);
    cover = max(cover, a);
    c = mix(c, roofSide, a);
    // A shed beside it.
    float2 shed = d - float2(size.x + 3.5, -size.y * 0.4);
    c = shade(c, fill(sdBox(shed - shadowOff * 0.6, float2(2.0, 2.6)), 0.4) * 0.7);
    c = mix(c, float3(0.70, 0.66, 0.60), fill(sdBox(shed, float2(2.0, 2.6)), 0.3));
    return c;
}

inline float3 ponds(float3 c, float2 local, float2 world, constant Biome &b, constant Scene &scene, uint seed,
                    float wander, thread float &water) {
    if (b.e.z <= 0.0) return c;
    float spacing = 260.0;
    float2 g = floor(local / spacing);
    int2 cell = int2(g);
    if (hash21(cell, seed + 80u) > b.e.z * 0.55) return c;
    float r = 14.0 + 22.0 * hash21(cell, seed + 81u);
    float2 center = g * spacing + r * 2.0 + hash22(cell, seed + 82u) * (spacing - r * 4.0);
    float2 centerWorld = world + (center - local);
    if (abs(riverDistance(centerWorld, scene, wander)) < 90.0) return c;
    float2 d = local - center;
    float shape = length(d * float2(1.0, 1.25)) / r - 1.0 + 0.45 * (fbm(local / 16.0, 3, seed + 83u) - 0.5);
    float dist = shape * r;
    float3 deep = b.f.z > 0.5 ? mix(b.snow.rgb, b.shallows.rgb, 0.35) : b.water.rgb;
    float3 shallow = b.f.z > 0.5 ? b.snow.rgb : b.shallows.rgb;
    float3 pond = mix(deep, shallow, smoothstep(-r * 0.55, 0.0, dist));
    c = mix(c, b.sand.rgb * 0.95, fill(dist - 2.2, 0.6) * (1.0 - b.f.y * 0.7));
    c = mix(c, pond, fill(dist, 0.5));
    water = max(water, fill(dist, 0.5) * (1.0 - b.f.z));
    return c;
}

inline float3 rocks(float3 c, float2 p, constant Biome &b, constant Scene &scene, uint seed, thread float &herd) {
    if (b.f.x <= 0.0) return c;
    float f = fbm(p / 170.0, 4, seed + 90u);
    float edge = 0.66 - b.f.x * 0.1;
    float a = smoothstep(edge, edge + 0.025, f);
    if (a <= 0.0) return c;
    float fl = fbm((p + scene.sun.xy * 7.0) / 170.0, 4, seed + 90u);
    float lit = saturate(0.5 + (fl - f) * 22.0);
    float3 rock = b.rock.rgb * (0.78 + 0.4 * lit) * (0.92 + 0.12 * vnoise(p / 3.0, seed + 91u));
    rock = mix(rock, b.snow.rgb * (0.86 + 0.16 * lit), b.f.y * 0.75);
    // A darker ring where the rock meets the moss.
    c = mix(c, b.rock.rgb * 0.62, smoothstep(edge - 0.02, edge, f) * (1.0 - a) * 0.8);
    herd *= 1.0 - a;
    return mix(c, rock, a);
}

// MARK: - The whole ground for one leg

inline Land land(float2 world, constant Leg &leg, constant Scene &scene, float riverHalf, float wander) {
    constant Biome &b = leg.biome;
    uint seed = uint(leg.info.y);
    float2 local = float2(world.x, world.y - leg.info.x);
    int layout = int(b.a.x);
    Land l;
    if (layout == layoutPaddies) l = paddies(local, b, seed);
    else if (layout == layoutFields) l = fields(local, b, scene, seed);
    else if (layout == layoutStripes) l = stripes(local, b, seed);
    else if (layout == layoutPivots) l = pivots(local, b, scene, seed);
    else l = grassland(local, b, seed);

    l.color = rocks(l.color, local, b, scene, seed, l.herd);
    float water = l.water;
    l.color = ponds(l.color, local, world, b, scene, seed, wander, water);
    l.herd *= 1.0 - smoothstep(0.0, 0.5, water - l.water);
    l.water = water;
    float cover = 0.0;
    l.color = houses(l.color, local, world, b, scene, seed, wander, cover);
    l.color = trees(l.color, local, world, b, scene, seed, riverHalf, wander, cover);
    l.sway *= 1.0 - cover;
    l.herd *= 1.0 - cover;
    l.water *= 1.0 - cover;

    // Snow settles everywhere except on water and the darkest crowns.
    float snow = b.f.y * (1.0 - cover * 0.7) * (1.0 - l.forest * 0.8) * smoothstep(0.25, 0.6, fbm(local / 40.0, 3, seed + 95u) + 0.35);
    l.color = mix(l.color, b.snow.rgb * (0.94 + 0.06 * vnoise(local / 6.0, seed + 96u)), snow * (1.0 - l.water));

    // A broad wash, like paint laid on unevenly across the sheet.
    l.color *= 1.0 + 0.08 * (fbm(local / 340.0, 3, seed + 99u) - 0.5);

    // Paint finish: pigment turbulence at two scales.
    float t1 = vnoise(local / 60.0, seed + 97u);
    float t2 = vnoise(local / 6.5, seed + 98u);
    l.color = pigment(l.color, t1, 0.32);
    l.color = pigment(l.color, t2, 0.16);
    return l;
}

// MARK: - River and road on top, continuous across legs

inline float3 river(float3 c, float2 p, constant Scene &scene, constant Biome &a, constant Biome &b, float m,
                    float width, float wander, thread float &water, thread float &herd) {
    float d = riverDistance(p, scene, wander);
    float halfWidth = width * 0.5;
    // Banks wobble a little so the river looks painted, not ruled.
    float wobble = (vnoise(float2(p.y / 23.0, d > 0.0 ? 3.0 : 7.0), 3u) - 0.5) * width * 0.16;
    float ad = abs(d) + wobble;
    float bank = halfWidth + 2.5 + width * 0.12;
    if (ad > bank + 2.0) return c;

    float3 deep = mix(a.water.rgb, b.water.rgb, m);
    float3 shallow = mix(a.shallows.rgb, b.shallows.rgb, m);
    float3 sand = mix(a.sand.rgb, b.sand.rgb, m);
    float frozen = mix(a.f.z, b.f.z, m);
    float t = ad / halfWidth;
    float3 w = mix(deep * 0.9, deep, smoothstep(0.1, 0.45, t));
    w = mix(w, mix(deep, shallow, 0.55), smoothstep(0.45, 0.7, t));
    w = mix(w, shallow, smoothstep(0.72, 0.9, t));
    // Long streaks following the current.
    float streak = vnoise(float2(d / 2.2, p.y / 26.0), 5u);
    w *= 1.0 + 0.07 * (streak - 0.5);
    float3 ice = mix(float3(0.86, 0.91, 0.96), float3(0.72, 0.81, 0.90), smoothstep(0.2, 0.9, streak));
    w = mix(w, ice, frozen);

    float3 banks = mix(sand, sand * 0.85, vnoise(p / 3.0, 6u));
    banks = mix(banks, mix(a.snow.rgb, b.snow.rgb, m), mix(a.f.y, b.f.y, m) * 0.8);
    c = mix(c, banks, fill(ad - bank, 0.8));
    c = mix(c, mix(sand, shallow, 0.35), fill(ad - halfWidth - 1.0, 0.4));
    float inWater = fill(ad - halfWidth, 0.45);
    water = max(water, inWater * (1.0 - frozen));
    herd *= 1.0 - fill(ad - bank, 0.8);
    return mix(c, w, inWater);
}

inline float3 road(float3 c, float2 p, constant Scene &scene, constant Biome &a, constant Biome &b, float m,
                   float riverHalf, float wander, thread float &onRoad, thread float &water, thread float &herd) {
    float width = mix(a.e.x, b.e.x, m);
    float paved = mix(a.e.y, b.e.y, m);
    float3 surface = mix(a.road.rgb, b.road.rgb, m);
    float halfWidth = width * 0.5;
    float d = roadDistance(p, scene, wander);

    // A crossroad now and then.
    float spacing = 1450.0;
    float k = floor((p.y + scene.road.w) / spacing);
    float crossY = (k + 0.5) * spacing - scene.road.w + 40.0 * sin(p.x / 380.0 + k);
    float hasCross = step(hash11(int(k), 70u), 0.55);
    float dc = mix(1e6, abs(p.y - crossY) - halfWidth * 0.9, hasCross);

    float dd = min(abs(d) - halfWidth, dc);
    if (dd > 3.0) return c;
    float onRiver = fill(abs(riverDistance(p, scene, wander)) - riverHalf - 3.0, 0.5);
    float2 sunOff = scene.sun.xy * scene.sun.z * 3.0;
    // The bridge deck shades the water under it.
    float shadowD = min(abs(roadDistance(p + sunOff, scene, wander)) - halfWidth, dc);
    c = shade(c, fill(shadowD, 0.8) * onRiver * 0.9);

    float3 r = surface * (0.95 + 0.08 * vnoise(p / 1.8, 71u));
    // Paved roads get a dashed centre line, dirt roads two wheel ruts.
    float along = p.y;
    float dash = step(0.55, fract(along / 7.0)) * fill(abs(d) - 0.18, 0.12) * paved;
    r = mix(r, float3(0.96, 0.95, 0.9), dash * (1.0 - onRiver));
    float ruts = fill(abs(abs(d) - halfWidth * 0.45) - 0.35, 0.25) * (1.0 - paved);
    r *= 1.0 - 0.12 * ruts;
    // Railings on bridges.
    float rail = fill(abs(abs(d) - halfWidth - 0.4) - 0.35, 0.2) * onRiver * step(abs(d), halfWidth + 1.2);
    float3 railColor = float3(0.78, 0.36, 0.22);

    float a2 = fill(dd, 0.5);
    float shoulder = fill(dd - 1.3, 0.7) * (1.0 - a2);
    c = mix(c, c * 0.88, shoulder * (1.0 - onRiver));
    c = mix(c, r, a2);
    c = mix(c, railColor, rail);
    onRoad = max(onRoad, fill(abs(d) - halfWidth, 0.5) * (1.0 - onRiver));
    water *= 1.0 - a2;
    herd *= 1.0 - fill(dd - 1.0, 0.5);
    return c;
}

fragment GroundOut ground(VertexOut in [[stage_in]],
                          constant GroundParams &params [[buffer(0)]],
                          constant Scene &scene [[buffer(1)]]) {
    float texel = params.texel.x;
    float2 world = params.origin.zw + (in.position.xy - params.origin.xy) * texel;

    // How far the land has turned from leg A into leg B here.
    float boundary = scene.morph.x;
    float m = 0.0;
    if (world.y >= boundary) {
        if (scene.morph.z < 0.0) {
            m = smoothstep(boundary, boundary + scene.morph.y, world.y);
        } else {
            float wave = scene.morph.w;
            m = saturate((scene.morph.z * (wave + 400.0) - (world.y - boundary)) / 400.0);
        }
    }
    float2 localB = float2(world.x, world.y - scene.legB.info.x);
    float threshold = 0.1 + 0.8 * (0.7 * vnoise(localB / 75.0, 77u) + 0.3 * hash21(int2(floor(localB / 7.0)), 78u));
    bool useB = m > threshold;

    float wander = mix(scene.legA.biome.d.w, scene.legB.biome.d.w, m);
    float width = mix(scene.legA.biome.d.z, scene.legB.biome.d.z, m);
    float riverHalf = width * 0.5;
    Land l = useB ? land(world, scene.legB, scene, riverHalf, wander) : land(world, scene.legA, scene, riverHalf, wander);

    float onRoad = l.road;
    float water = l.water;
    float herd = l.herd;
    float3 c = river(l.color, world, scene, scene.legA.biome, scene.legB.biome, m, width, wander, water, herd);
    c = road(c, world, scene, scene.legA.biome, scene.legB.biome, m, riverHalf, wander, onRoad, water, herd);

    GroundOut out;
    out.color = float4(saturate(c), 1.0);
    out.mask = float4(saturate(water), saturate(l.sway), saturate(onRoad), saturate(herd));
    return out;
}

// The ground: painted once into a scrolling cache, a few new rows at a time.

struct GroundOut {
    // Paint, with water, sway, road and herd packed into the alpha byte so a daytime frame reads one texture.
    float4 color [[color(0)]];
    // Night light pool and which lamp it belongs to; only read after dark.
    float4 night [[color(1)]];
};

// Alpha byte: water in the top two bits, sway in the next four, then a road bit and a herd bit.
inline float packGround(float water, float sway, bool road, bool herd) {
    uint packed = (uint(saturate(water) * 3.0 + 0.5) << 6) | (uint(saturate(sway) * 15.0 + 0.5) << 2)
                | (road ? 2u : 0u) | (herd ? 1u : 0u);
    return float(packed) / 255.0;
}

struct Land {
    float3 color;
    float water;
    float sway;
    float herd;
    float road;
    float forest;
    /// Light that falls on the ground after dark, and which lamp it comes from (1 for street lamps).
    float light;
    float lightID;
};

inline float3 cropColor(constant Biome &b, float h) {
    return h < 0.25 ? b.crop0.rgb : h < 0.5 ? b.crop1.rgb : h < 0.75 ? b.crop2.rgb : b.crop3.rgb;
}

// Shadows are a cool multiply, never grey, and fade away once the sun is down.
inline float3 shade(float3 c, float amount, constant Scene &scene) {
    float daylight = mix(0.2, 1.0, smoothstep(-0.1, 0.12, scene.sun.w));
    return c * mix(float3(1.0), float3(0.56, 0.62, 0.78), amount * daylight);
}

// One tree crown with its shadow. `d` is the offset from the trunk; `dark` and `light` are the crown's shaded
// and lit colours.
inline float3 tree(float3 c, float2 d, float r, float2 local, constant Biome &b, constant Scene &scene, uint seed,
                   thread float &cover, float3 dark, float3 light) {
    // Capped so the shadow stays inside the tree's cell even when the sun is low.
    float2 shadowOff = -scene.sun.xy * min(scene.sun.z, 0.75) * r * 1.7;
    c = shade(c, fill(length(d - shadowOff) - r * 0.95, 0.7) * 0.85, scene);
    float lobes = vnoise(local / (r * 0.55), seed + 44u);
    float dt = length(d) - r * (0.88 + 0.28 * lobes);
    float lit = dot(normalize(d + 1e-4), scene.sun.xy) * 0.5 + 0.5;
    float clumps = vnoise(local / (r * 0.4), seed + 45u);
    float3 crown = mix(dark, light, saturate(lit * 0.8 + clumps * 0.35 - 0.12));
    crown *= 0.92 + 0.16 * smoothstep(0.2, 1.0, lit) * clumps;
    crown = mix(crown, b.snow.rgb, b.f.y * 0.55 * smoothstep(0.45, 0.8, clumps));
    float a = fill(dt, 0.45);
    cover = max(cover, a);
    return mix(c, crown, a);
}

inline float3 tree(float3 c, float2 d, float r, float2 local, constant Biome &b, constant Scene &scene, uint seed,
                   thread float &cover) {
    return tree(c, d, r, local, b, scene, seed, cover, b.canopy.rgb, b.canopyLight.rgb);
}

inline float segmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)));
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
    // Big fenced paddocks, each grazed a little differently, the fence only a crisp change of tone and a track.
    if (b.a.y > 400.0) {
        float size = b.a.y;
        float2 g = floor(p / size);
        float2 f = fract(p / size) * size;
        l.color *= 0.93 + 0.14 * hash21(int2(g), seed + 50u);
        float fence = min(min(f.x, size - f.x), min(f.y, size - f.y));
        l.color = mix(l.color, l.color * 0.86, fill(fence - 0.4, 0.25));
        l.color = mix(l.color, b.road.rgb * 1.05, fill(abs(f.x - 6.0) - 1.6, 0.5) * step(0.5, hash21(int2(g), seed + 51u)));
    }
    l.water = 0.0;
    l.sway = b.b.w * 0.7;
    l.herd = 1.0;
    l.road = 0.0;
    l.forest = 0.0;
    l.light = 0.0;
    l.lightID = 0.0;
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
    l.light = 0.0;
    l.lightID = 0.0;
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
            // Fallen petals in the grass round trees in flower.
            if (b.d.y > 0.0 && b.blossom.w > 0.5) {
                float petal = hash21(int2(floor(p / 0.9)), seed + 46u);
                float near = 1.0 - smoothstep(r, r * 2.4, length(local));
                l.color = mix(l.color, b.blossomLight.rgb * 1.03, step(1.0 - 0.3 * b.d.y * near, petal) * 0.9);
            }
            l.color = tree(l.color, rotate(local, -angle), r, p, b, scene, seed, trees, b.blossom.rgb, b.blossomLight.rgb);
        }
        l.sway = b.b.w * 0.3 * (1.0 - trees);
        l.herd = 0.0;
    }

    // Hedge shadow, sampled where the sun would see the hedge from.
    float2 toSun = scene.sun.xy * scene.sun.z * (2.5 + b.a.z * 0.45);
    Cells vs = voronoi(fieldSpace(p + toSun, b, seed), seed);
    float shadowEdge = vs.border * size - hedgeHalfWidth(p + toSun, b, seed);
    l.color = shade(l.color, fill(shadowEdge, 1.2) * 0.8, scene);

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
    float len = w * (2.4 + 0.9 * hash11(block, seed + 1u));
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
    l.light = 0.0;
    l.lightID = 0.0;
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
    l.light = 0.0;
    l.lightID = 0.0;
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

// How far a leg-local point is outside the strip a pivot must keep clear of: the main road and the railway.
inline float pivotClearance(float2 p, constant Leg &leg, constant Scene &scene, float wander) {
    float2 world = float2(p.x, p.y + leg.info.x);
    float clear = abs(roadDistance(world, scene, wander)) - leg.biome.e.x * 0.5 - 9.0;
    if (leg.rail.w > 0.5) {
        float along;
        clear = min(clear, abs(railSigned(p, leg.rail.xy, leg.rail.z, leg.railShape.xyz, along)) - 12.0);
    }
    return clear;
}

inline Land pivots(float2 p, constant Leg &leg, constant Scene &scene, uint seed, float wander) {
    constant Biome &b = leg.biome;
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
    l.light = 0.0;
    l.lightID = 0.0;
    float3 c = openGround(p, b, seed);
    l.herd = 1.0;
    l.sway = b.b.w * 0.3;
    float d = length(r) - radius;
    // A circle whose pad would sit on the road or the railway is left out; one they only cross is cut short
    // along them, like the part circles seen from the air.
    float clear = d < 1.5 ? pivotClearance(p, leg, scene, wander) : 1e3;
    if (hash21(cell, seed + 1u) > b.b.x && pivotClearance(center, leg, scene, wander) > 12.0) {
        float planted = smoothstep(0.0, 2.5, clear);
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
        float inCircle = fill(d, 1.2) * planted;
        c = mix(c, crop, inCircle);
        l.sway = mix(l.sway, b.b.w, inCircle);
        l.herd = 1.0 - inCircle;
        // The sprinkler arm reaching from the centre pad, raised on its towers, and its shadow. It turns back
        // before reaching a road or a railway, so it always rests over the crop.
        float2 arm = rotate(float2(1.0, 0.0), hash21(cell, seed + 8u) * 6.283) * radius * 0.98;
        if (min(pivotClearance(center + arm, leg, scene, wander), pivotClearance(center + arm * 0.5, leg, scene, wander)) < 2.0) {
            arm = -arm;
        }
        float armShown = step(2.0, min(pivotClearance(center + arm, leg, scene, wander),
                                       pivotClearance(center + arm * 0.5, leg, scene, wander)));
        float2 lift = scene.sun.xy * scene.sun.z * 3.5;
        c = shade(c, fill(segmentDistance(r + lift, 0.0, arm) - 0.35, 0.3) * 0.55 * armShown, scene);
        c = mix(c, float3(0.72, 0.73, 0.74), fill(segmentDistance(r, 0.0, arm) - 0.3, 0.2) * armShown);
        c = mix(c, float3(0.66, 0.65, 0.62), fill(sdBox(r, float2(3.5)), 0.3));
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

// How much river there is: none in a place without one, narrowing away where such a place begins.
inline float riverPresence(float riverHalf) {
    return smoothstep(0.25, 2.0, riverHalf);
}

inline bool clearOfWater(float2 world, constant Biome &b, constant Scene &scene, float riverHalf, float wander,
                         float r) {
    return (riverHalf <= 0.25 || abs(riverDistance(world, scene, wander)) > riverHalf + r + 5.0)
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
                if (b.d.y > 0.0 && b.blossom.w < 0.5) {
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

    // Avenues: trees planted along both edges of the road for long stretches, with the odd gap.
    if (b.i.y > 0.0) {
        float rx = roadX(world.y, scene, wander);
        float dx = world.x - rx;
        float edge = b.e.x * 0.5 + 3.8;
        int side = dx > 0.0 ? 1 : 0;
        if (abs(abs(dx) - edge) < 8.0
            && hash11(int(floor(local.y / 240.0)) * 2 + side, seed + 56u) < b.i.y
            && (riverHalf <= 0.25 || abs(riverDistance(world, scene, wander)) > riverHalf + 14.0)) {
            float spacing = 8.5;
            float j0 = floor(local.y / spacing);
            for (int i = -1; i <= 1; i++) {
                float j = j0 + float(i);
                float jh = hash11(int(j) * 2 + side, seed + 57u);
                if (jh < 0.12) continue;
                float r = size * 0.36 * (0.85 + 0.3 * jh);
                float2 center = float2(rx + (dx > 0.0 ? 1.0 : -1.0) * edge + (jh - 0.5), world.y + ((j + 0.5) * spacing - local.y));
                c = tree(c, world - center, r, local, b, scene, seed, cover);
            }
        }
    }
    return c;
}

// Light leaving a house after dark, in house-local metres. Windows can't be seen from above, so this is
// what they do to the ground: warm patches outside the long walls, a porch lamp, sometimes a roof window.
inline float houseGlow(float2 d, float2 size, int k, uint seed, float roofCover) {
    float glow = 0.0;
    float out = abs(d.x) - size.x;
    if (out > -0.3 && out < 8.0 && abs(d.y) < size.y + 1.5) {
        float n = max(2.0, floor(size.y * 2.0 / 3.0));
        float v = (d.y + size.y) / (2.0 * size.y) * n;
        float i = clamp(floor(v), 0.0, n - 1.0);
        float lit = step(0.35, hash11(k * 64 + int(i) * 2 + (d.x > 0.0 ? 1 : 0), seed + 400u));
        float across = abs(v - i - 0.5) * (2.0 * size.y / n);
        float spread = 0.5 + 0.45 * max(out, 0.0);
        glow = lit * fill(across - spread, 0.3 + 0.15 * max(out, 0.0)) * exp(-max(out, 0.0) / 2.6)
             * smoothstep(-0.3, 0.2, out) * 0.75;
    }
    float2 porch = float2(size.x * 0.4, size.y + 0.6);
    float r = length(d - porch);
    float hasPorch = step(0.3, hash11(k, seed + 402u));
    float pool = pow(1.0 + r * r / 9.0, -1.5) * (1.0 - smoothstep(6.0, 10.0, r));
    glow = max(glow, pool * 0.6 * hasPorch);
    glow = max(glow, fill(r - 0.25, 0.15) * hasPorch);
    // Half the farms keep a yard lamp on a pole beside the house.
    float2 yard = float2(-size.x - 4.0, -size.y * 0.3);
    float yardLamp = step(0.5, hash11(k, seed + 405u));
    float ry = length(d - yard);
    glow = max(glow, yardLamp * (pow(1.0 + ry * ry / 49.0, -1.5) * (1.0 - smoothstep(10.0, 16.0, ry)) * 0.6
                                 + fill(ry - 0.25, 0.15)));
    glow *= 1.0 - roofCover;
    float skylight = fill(sdBox(d - float2(-size.x * 0.45, size.y * 0.2), float2(0.45, 0.6)), 0.1);
    return max(glow, skylight * 0.85 * step(0.6, hash11(k, seed + 404u)) * roofCover);
}

inline float3 roofColor(constant Biome &b, float pick) {
    return pick < 0.45 ? b.roof0.rgb : pick < 0.8 ? b.roof1.rgb : b.roof2.rgb;
}

// One house: shadow, roof (pitched halves catching the light differently, or flat with a water tank), a shed, and
// after dark the light it spills on the ground. `d` is in house-local metres.
inline float3 house(float3 c, float2 d, float angle, float2 size, int k, constant Biome &b, constant Scene &scene,
                    uint seed, thread float &cover, thread float &light, thread float &lightID) {
    if (dot(d, d) > 600.0) return c;
    float2 shadowOff = rotate(-scene.sun.xy * scene.sun.z * 5.0, -angle);
    c = shade(c, fill(sdBox(d - shadowOff, size), 0.5) * 0.8, scene);
    float3 roof = roofColor(b, hash11(k, seed + 66u)) * (0.92 + 0.16 * hash11(k, seed + 68u));
    roof = mix(roof, b.snow.rgb, b.f.y * 0.8);
    float3 face;
    if (b.i.z > 0.5) {
        // Flat roofs: a parapet rim and a round water tank on top.
        face = roof * (1.0 - 0.12 * fill(abs(sdBox(d, size)) - 0.35, 0.15));
        face = mix(face, hash11(k, seed + 69u) < 0.5 ? float3(0.16, 0.16, 0.18) : float3(0.93, 0.93, 0.9),
                   fill(length(d - size * float2(0.45, 0.5)) - 0.75, 0.15));
    } else {
        face = d.x * rotate(scene.sun.xy, -angle).x > 0.0 ? roof * 1.08 : roof * 0.78;
        face = mix(face, roof * 0.6, fill(abs(d.x) - 0.12, 0.08));
    }
    float a = fill(sdBox(d, size), 0.35);
    cover = max(cover, a);
    c = mix(c, face, a);
    float2 shed = d - float2(size.x + 3.5, -size.y * 0.4);
    c = shade(c, fill(sdBox(shed - shadowOff * 0.6, float2(2.0, 2.6)), 0.4) * 0.7, scene);
    float shedCover = fill(sdBox(shed, float2(2.0, 2.6)), 0.3);
    c = mix(c, float3(0.70, 0.66, 0.60), shedCover);
    float glow = houseGlow(d, size, k, seed, a) * (1.0 - shedCover);
    if (glow > light) {
        light = glow;
        lightID = 0.02 + 0.86 * hash11(k, seed + 403u);
    }
    return c;
}

// Street lamps through villages: poles at a steady spacing, staggered across the road or all down one side,
// each with its head on a short arm over the kerb. By day only the head and the pole's shadow show. After
// dark each lamp throws a pool stretched along the road, brighter on the road than behind the pole, and
// neighbouring pools run together. The night texture keeps the pool below 0.8 and the glowing head above
// it, with lamp ids from 0.9 up so the composite can tell lamps apart.
inline float3 streetLamps(float3 c, float2 local, float2 world, constant Biome &b, constant Scene &scene, uint seed,
                          float wander, thread float &light, thread float &lightID) {
    if (b.h.y <= 0.0 || b.i.x <= 0.0) return c;
    const float spacing = 34.0, height = 7.0;
    float roadHalf = b.e.x * 0.5;
    float j0 = floor(local.y / spacing);
    float pools = 0.0, head = 0.0, strongest = 0.0, chosen = 0.0;
    float2 shadow = -scene.sun.xy * min(scene.sun.z, 2.0) * height;
    for (int dj = -1; dj <= 1; dj++) {
        float j = j0 + float(dj);
        float y = (j + 0.5) * spacing;
        float village = smoothstep(0.62 - b.i.x * 0.22, 0.7 - b.i.x * 0.22, vnoise(float2(y / 1100.0, 0.5), seed + 70u));
        // Lamps run the length of a village, with the odd gap where a pole is missing.
        if (village < 0.5 || hash11(int(j), seed + 67u) > 0.55 + b.h.y * 0.45) continue;
        int stretch = int(floor(y / 520.0));
        float side = hash11(stretch, seed + 68u) < 0.5 ? ((int(j) & 1) == 0 ? 1.0 : -1.0)
                                                      : (hash11(stretch, seed + 69u) < 0.5 ? -1.0 : 1.0);
        float worldY = world.y + (y - local.y);
        float rx = roadX(worldY, scene, wander);
        float slope = (roadX(worldY + 2.0, scene, wander) - roadX(worldY - 2.0, scene, wander)) * 0.25;
        float2 along = normalize(float2(slope, 1.0));
        float2 out = float2(along.y, -along.x) * side;
        float2 base = float2(rx, worldY);
        float2 pole = base + out * (roadHalf + 1.5);
        float2 lamp = base + out * (roadHalf + 0.2);
        float2 q = world - lamp;
        float u = dot(q, along), v = dot(q, out);

        // Day: the pole and arm cast a thin shadow, and the head is a small grey box.
        float poleShadow = segmentDistance(world, pole, pole + shadow);
        float armShadow = segmentDistance(world, pole + shadow, lamp + shadow);
        c = shade(c, fill(min(poleShadow, armShadow) - 0.1, 0.22) * 0.5, scene);
        c = mix(c, float3(0.24, 0.24, 0.26), fill(segmentDistance(world, pole, lamp) - 0.07, 0.15) * 0.6);
        c = mix(c, float3(0.2, 0.2, 0.22), fill(length(world - pole) - 0.16, 0.1));
        float box = sdBox(float2(u, v), float2(0.24, 0.5));
        float3 housing = mix(float3(0.36, 0.37, 0.4), float3(0.55, 0.56, 0.6), saturate(dot(scene.sun.xy, along) * 0.5 + 0.5));
        c = mix(c, housing, fill(box, 0.1));

        // Night: the pool falls on the road ahead of the head, stretched along the road.
        float2 centre = float2(u, v + 1.2);
        float r2 = centre.x * centre.x / 2.9 + centre.y * centre.y;
        float pool = pow(1.0 + r2 / (height * height), -1.5);
        pool *= 1.0 - smoothstep(13.0, 20.0, sqrt(r2) + 2.5 * (vnoise(world / 3.0, seed + 411u) - 0.5));
        pool *= 1.0 - 0.55 * smoothstep(0.0, 6.0, v - 1.0);
        pools += pool;
        if (pool > strongest) {
            strongest = pool;
            chosen = j;
        }
        head = max(head, max(fill(box, 0.1), exp(-dot(q, q) / 0.45) * 0.55));
    }
    float value = head > 0.02 ? 0.8 + 0.2 * head : 0.8 * saturate(pools);
    if (strongest > 0.0 && value > light) {
        light = value;
        lightID = 0.9 + 0.1 * hash11(int(chosen), seed + 412u);
    }
    return c;
}

// Houses along the road: scattered farms in open country, and now and then a village where they crowd in two rows
// with gardens, street lamps and trees.
inline float3 houses(float3 c, float2 local, float2 world, constant Biome &b, constant Scene &scene, uint seed,
                     float wander, thread float &cover, thread float &light, thread float &lightID) {
    if (b.e.w <= 0.0 && b.i.x <= 0.0) return c;
    float rx0 = roadX(world.y, scene, wander);
    float side = world.x > rx0 ? 1.0 : -1.0;
    if (abs(world.x - rx0) > 95.0) return c;
    float slot = 30.0;
    float k0 = floor(local.y / slot);
    for (int dk = -1; dk <= 1; dk++) {
        float k = k0 + float(dk);
        float yC = (k + 0.2 + 0.6 * hash11(int(k), seed + 62u)) * slot;
        float village = smoothstep(0.62 - b.i.x * 0.22, 0.7 - b.i.x * 0.22, vnoise(float2(yC / 1100.0, 0.5), seed + 70u))
                      * step(0.001, b.i.x);
        float worldY = world.y + (yC - local.y);
        float rx = roadX(worldY, scene, wander);
        float s = riverSlope(worldY, scene, wander);
        for (int row = 0; row < 2; row++) {
            int id = (int(k) * 2 + (side > 0.0 ? 1 : 0)) * 2 + row;
            float chance = row == 0 ? mix(b.e.w * 0.33, 0.85, village) : 0.7 * village;
            if (hash11(id, seed + 60u) > chance) continue;
            float out = row == 0 ? b.e.x * 0.5 + 8.0 + 10.0 * hash11(id, seed + 63u) : 36.0 + 16.0 * hash11(id, seed + 63u);
            float2 center = float2(rx + side * out, worldY);
            if (b.d.z > 0.5 && abs(riverDistance(center, scene, wander)) < b.d.z * 0.5 + b.i.w + 16.0) continue;
            float angle = atan(s) + (hash11(id, seed + 64u) - 0.5) * (0.3 + village * 0.2);
            float2 size = float2(4.2, 6.5) * (0.8 + 0.35 * hash11(id, seed + 65u)) * (b.i.z > 0.5 ? 1.15 : 1.0);
            c = house(c, rotate(world - center, -angle), angle, size, id, b, scene, seed, cover, light, lightID);
            // A garden tree behind village houses.
            if (village > 0.3 && hash11(id, seed + 71u) < 0.6) {
                float2 behind = center + float2(side * (size.x + 6.0 + 4.0 * hash11(id, seed + 72u)), (hash11(id, seed + 73u) - 0.5) * 8.0);
                c = tree(c, world - behind, 2.6 + 1.6 * hash11(id, seed + 74u), local, b, scene, seed, cover);
            }
        }
    }
    return streetLamps(c, local, world, b, scene, seed, wander, light, lightID);
}

// MARK: - Landmarks

inline float3 boulders(float3 c, float2 d, float radius, int id, constant Biome &b, constant Scene &scene, uint seed,
                       thread float &herd) {
    // A halo of greener grass round the rocks, then a cluster of granite domes lit from the sun's side.
    c = mix(c, c * float3(0.78, 0.95, 0.72), (1.0 - smoothstep(radius * 0.6, radius * 1.4, length(d))) * 0.5);
    for (int i = 0; i < 7; i++) {
        float2 at = (hash22(int2(id, i), seed + 801u) - 0.5) * radius * 1.1;
        float r = radius * (0.12 + 0.22 * hash11(id * 9 + i, seed + 802u));
        float2 q = d - at;
        c = shade(c, fill(length(q + scene.sun.xy * scene.sun.z * r * 0.6) - r, 1.0) * 0.7, scene);
        float dome = length(q) - r * (1.0 + 0.12 * (vnoise(q / 3.0, seed + 803u) - 0.5));
        float lit = saturate(dot(normalize(q + 1e-4), scene.sun.xy) * 0.5 + 0.5);
        float3 rock = b.rock.rgb * (0.72 + 0.45 * lit) * (0.94 + 0.12 * vnoise(q / 1.5, seed + 804u));
        rock = mix(rock, float3(0.85, 0.66, 0.52), 0.2 * vnoise(q / 4.0, seed + 805u));
        c = mix(c, rock, fill(dome, 0.4));
        herd *= 1.0 - fill(dome - 2.0, 1.0);
    }
    return c;
}

inline float3 landmark(float3 c, int kind, float density, float2 local, float2 world, constant Biome &b,
                       constant Scene &scene, uint seed, float wander, float riverHalf, thread float &herd,
                       thread float &water, thread float &cover, thread float &light, thread float &lightID) {
    if (kind == markNone || density <= 0.0) return c;
    float cell = kind == markTubeWell ? 170.0 : kind == markWindmill ? 700.0 : kind == markKopje ? 420.0
               : kind == markFeedlot || kind == markKiln ? 1500.0 : kind == markCorral ? 1300.0 : 750.0;
    float radius = kind == markTubeWell ? 14.0 : kind == markWindmill ? 22.0 : kind == markKopje ? 55.0
                 : kind == markFeedlot ? 260.0 : kind == markGrove ? 120.0 : kind == markBurn ? 200.0
                 : kind == markLake ? 170.0 : kind == markCorral ? 150.0 : kind == markKiln ? 110.0
                 : kind == markFarmstead ? 70.0 : 90.0;
    uint s = seed + uint(kind) * 131u;
    float2 g = floor(local / cell);
    int2 id2 = int2(g);
    int id = id2.x * 7919 + id2.y;
    if (hash21(id2, s) > density) return c;
    float2 center = g * cell + radius + 10.0 + hash22(id2, s + 1u) * max(cell - 2.0 * radius - 20.0, 0.0);
    if (kind == markFarmstead && int(b.a.x) == layoutPivots) {
        // Farmsteads sit in the dry corners between the circles.
        center = round(center / b.a.y) * b.a.y;
    }
    float2 d = local - center;
    if (dot(d, d) > radius * radius * 1.7) return c;
    float2 centerWorld = world + (center - local);
    if (riverHalf > 0.25 && abs(riverDistance(centerWorld, scene, wander)) < riverHalf + radius * 0.8 + 15.0) return c;
    if (abs(roadDistance(centerWorld, scene, wander)) < b.e.x * 0.5 + radius * 0.8 + 6.0) return c;
    float angle = hash21(id2, s + 2u) * 6.283;
    float2 r = rotate(d, -angle);

    if (kind == markKopje) {
        c = boulders(c, d, radius * (0.6 + 0.5 * hash21(id2, s + 3u)), id, b, scene, s, herd);
        for (int i = 0; i < 3; i++) {
            float2 at = (hash22(int2(id, i + 20), s + 4u) - 0.5) * radius * 1.4;
            c = tree(c, d - at, 4.0 + 3.0 * hash11(id * 3 + i, s + 5u), local, b, scene, seed, cover);
        }
    } else if (kind == markWaterPoint) {
        // Cattle trails fan out from the water, the ground trampled bare round it.
        float len = length(d);
        float bare = 1.0 - smoothstep(22.0, 50.0, len + 8.0 * (vnoise(d / 9.0, s + 6u) - 0.5));
        c = mix(c, float3(0.71, 0.60, 0.42), bare * 0.85);
        float a = atan2(d.y, d.x);
        float n = 9.0;
        float trail = (floor(a / 6.283 * n) + 0.5) * 6.283 / n + (hash11(int(floor(a / 6.283 * n)) + id, s + 7u) - 0.5) * 0.4;
        float across = len * abs(sin(a - trail));
        c = mix(c, float3(0.74, 0.66, 0.5), fill(across - 0.6, 0.4) * smoothstep(30.0, 40.0, len) * (1.0 - smoothstep(80.0, 140.0, len)) * 0.7);
        float tank = len - 9.0;
        c = mix(c, float3(0.6, 0.62, 0.64), fill(abs(tank) - 0.6, 0.2));
        c = mix(c, mix(b.water.rgb, float3(0.23, 0.35, 0.42), 0.5), fill(tank + 0.6, 0.2));
        water = max(water, fill(tank + 0.6, 0.2));
        // The windmill: a slim tower, its rotor, and their long shadow.
        float2 mill = d - float2(13.0, 4.0);
        float2 away = -scene.sun.xy * scene.sun.z * 10.0;
        c = shade(c, fill(segmentDistance(mill, 0.0, away) - 0.18, 0.15) * 0.6, scene);
        c = shade(c, fill(abs(length(mill - away) - 1.4) - 0.12, 0.12) * 0.5, scene);
        c = mix(c, float3(0.55, 0.56, 0.58), fill(length(mill) - 0.7, 0.15));
        herd = max(herd, bare);
    } else if (kind == markGrove) {
        // An estancia in its dark grove: a soft square of eucalyptus round a clearing with the house and sheds.
        float edge = sdBox(r, float2(radius * 0.75)) + 12.0 * (vnoise(r / 14.0, s + 8u) - 0.5);
        float clearing = sdBox(r - float2(radius * 0.15, 0.0), float2(radius * 0.32, radius * 0.24));
        float grove = fill(edge, 2.0) * (1.0 - fill(clearing, 2.0));
        c = shade(c, fill(sdBox(r + rotate(scene.sun.xy, -angle) * scene.sun.z * 12.0, float2(radius * 0.75)), 6.0) * 0.6, scene);
        float crowns = vnoise(r / 4.0, s + 9u) * 0.6 + vnoise(r / 9.0, s + 10u) * 0.4;
        float3 euc = float3(0.24, 0.36, 0.29) * (0.82 + 0.35 * crowns);
        c = mix(c, euc, grove);
        cover = max(cover, grove);
        herd *= 1.0 - fill(edge - 6.0, 2.0);
        c = house(c, rotate(r - float2(radius * 0.18, radius * 0.05), 0.0), angle, float2(5.0, 8.0), id, b, scene, s, cover, light, lightID);
        float2 shed = r - float2(radius * 0.05, -radius * 0.12);
        c = shade(c, fill(sdBox(shed + rotate(scene.sun.xy, -angle) * scene.sun.z * 4.0, float2(9.0, 5.0)), 0.5) * 0.6, scene);
        c = mix(c, float3(0.72, 0.73, 0.74), fill(sdBox(shed, float2(9.0, 5.0)), 0.3));
    } else if (kind == markFarmstead) {
        // House, metal sheds and steel grain bins, sheltered by an L of dark cedar to the north and west.
        float2 q = d;
        float windbreak = max(fill(sdBox(q - float2(-radius * 0.55, 0.0), float2(10.0, radius * 0.6)), 3.0),
                              fill(sdBox(q - float2(0.0, radius * 0.55), float2(radius * 0.6, 10.0)), 3.0));
        windbreak *= smoothstep(0.35, 0.6, vnoise(q / 3.5, s + 11u) + 0.2);
        float2 qs = q + scene.sun.xy * scene.sun.z * 9.0;
        float shadowBreak = max(fill(sdBox(qs - float2(-radius * 0.55, 0.0), float2(10.0, radius * 0.6)), 4.0),
                                fill(sdBox(qs - float2(0.0, radius * 0.55), float2(radius * 0.6, 10.0)), 4.0));
        c = shade(c, shadowBreak * 0.75, scene);
        float3 cedar = float3(0.18, 0.29, 0.20) * (0.85 + 0.3 * vnoise(q / 3.0, s + 12u));
        c = mix(c, cedar, windbreak);
        cover = max(cover, windbreak);
        c = house(c, q - float2(-10.0, 18.0), 0.0, float2(5.0, 7.5), id, b, scene, s, cover, light, lightID);
        for (int i = 0; i < 2; i++) {
            float2 shed = q - float2(14.0 + 8.0 * float(i), -8.0 - 22.0 * float(i));
            c = shade(c, fill(sdBox(shed + scene.sun.xy * scene.sun.z * 5.0, float2(8.0, 15.0)), 0.5) * 0.7, scene);
            c = mix(c, float3(0.80, 0.81, 0.82) * (0.94 + 0.08 * float(i)), fill(sdBox(shed, float2(8.0, 15.0)), 0.3));
        }
        for (int i = 0; i < 4; i++) {
            float2 bin = q - float2(-12.0 + 9.0 * float(i), -32.0);
            float br = 3.8;
            c = shade(c, fill(length(bin + scene.sun.xy * scene.sun.z * 8.0) - br, 0.6) * 0.7, scene);
            float lit = saturate(dot(normalize(bin + 1e-4), scene.sun.xy) * 0.5 + 0.5);
            c = mix(c, float3(0.70, 0.72, 0.74) * (0.8 + 0.35 * lit), fill(length(bin) - br, 0.25));
            c = mix(c, float3(0.9, 0.9, 0.9), fill(length(bin) - 0.6, 0.15));
        }
        herd *= 1.0 - fill(length(q) - radius, 4.0);
    } else if (kind == markTubeWell) {
        // A tiny brick room with a tank beside it and a big shade tree.
        float2 q = r;
        c = shade(c, fill(sdBox(q - float2(0.0, 0.0) + rotate(scene.sun.xy, -angle) * scene.sun.z * 3.0, float2(1.8)), 0.3) * 0.7, scene);
        c = mix(c, float3(0.83, 0.74, 0.62), fill(sdBox(q, float2(1.8)), 0.15));
        c = mix(c, float3(0.42, 0.55, 0.62), fill(sdBox(q - float2(3.4, 0.0), float2(1.2, 1.6)), 0.15));
        c = tree(c, q - float2(-4.0, 3.5), 4.5, local, b, scene, seed, cover);
    } else if (kind == markKiln) {
        // A long oval trench kiln of dusty red-brown, its chimney's long shadow, clay yards and rows of drying bricks.
        float2 q = r;
        float yard = sdBox(q, float2(radius * 0.95, radius * 0.6)) + 6.0 * (vnoise(q / 10.0, s + 13u) - 0.5);
        c = mix(c, float3(0.70, 0.45, 0.33), fill(yard, 3.0) * 0.85);
        float rows = fill(abs(fract(q.y / 4.0) - 0.5) * 4.0 - 0.7, 0.2) * fill(sdBox(q - float2(radius * 0.5, 0.0), float2(radius * 0.35, radius * 0.45)), 0.5);
        c = mix(c, float3(0.80, 0.72, 0.62), rows * 0.8);
        float trench = abs(length(q / float2(1.8, 1.0) - float2(-radius * 0.15, 0.0)) - radius * 0.22);
        c = mix(c, float3(0.50, 0.28, 0.20), fill(trench - 4.0, 0.8));
        float2 stack = q - float2(-radius * 0.15, 0.0);
        float2 away = rotate(-scene.sun.xy, -angle) * scene.sun.z * 35.0;
        c = shade(c, fill(segmentDistance(stack, 0.0, away) - 0.9, 0.5) * 0.65, scene);
        c = mix(c, float3(0.38, 0.22, 0.17), fill(length(stack) - 1.6, 0.2));
        herd *= 1.0 - fill(yard, 3.0);
    } else if (kind == markGlasshouse) {
        // Pale panels in a grid that catch the light in long stripes.
        float2 q = r;
        float2 extent = float2(radius * 0.8, radius * 0.5);
        c = shade(c, fill(sdBox(q + rotate(scene.sun.xy, -angle) * scene.sun.z * 4.0, extent), 0.5) * 0.6, scene);
        float panel = fill(sdBox(q, extent), 0.3);
        float ridge = fill(abs(fract(q.x / 3.2) - 0.5) * 3.2 - 0.12, 0.08);
        float glint = smoothstep(0.65, 1.0, vnoise(float2(q.x / 3.2, q.y / 40.0) + 3.0, s + 14u));
        float3 glass = mix(float3(0.83, 0.87, 0.89), float3(0.97, 0.98, 0.99), glint) * (1.0 - 0.1 * ridge);
        c = mix(c, glass, panel);
        cover = max(cover, panel);
        herd *= 1.0 - panel;
    } else if (kind == markWindmill) {
        // A polder mill: octagonal body, four sails and their shadow.
        float2 q = r;
        float sails = 1e9;
        for (int i = 0; i < 4; i++) {
            float2 arm = rotate(float2(0.0, 1.0), float(i) * 1.5708 + 0.4);
            sails = min(sails, segmentDistance(q, arm * 1.5, arm * 12.0) - 0.9);
        }
        float2 sunR = rotate(scene.sun.xy, -angle) * scene.sun.z;
        float sailShadow = 1e9;
        for (int i = 0; i < 4; i++) {
            float2 arm = rotate(float2(0.0, 1.0), float(i) * 1.5708 + 0.4);
            sailShadow = min(sailShadow, segmentDistance(q + sunR * 16.0, arm * 1.5, arm * 12.0) - 0.9);
        }
        c = shade(c, fill(length(q + sunR * 12.0) - 4.2, 0.5) * 0.7, scene);
        c = shade(c, fill(sailShadow, 0.4) * 0.55, scene);
        float3 body = float3(0.36, 0.30, 0.26);
        c = mix(c, body, fill(length(q) - 4.2, 0.3));
        c = mix(c, float3(0.45, 0.35, 0.28), fill(length(q) - 2.0, 0.3));
        c = mix(c, float3(0.86, 0.84, 0.80), fill(sails, 0.25) * 0.9);
        cover = max(cover, fill(length(q) - 4.2, 0.3));
    } else if (kind == markFeedlot) {
        // Pens in rows, pale feed alleys, white bunk lines and dark cattle crowded along them.
        float2 q = r;
        float block = sdBox(q, float2(radius * 0.9, radius * 0.55));
        if (block < 0.0) {
            float2 pen = float2(fract(q.x / 34.0) * 34.0, fract(q.y / 62.0) * 62.0);
            float3 dirt = float3(0.54, 0.45, 0.35) * (0.9 + 0.2 * vnoise(q / 6.0, s + 15u));
            float alley = fill(min(pen.y, 62.0 - pen.y) - 4.0, 0.5);
            float bunk = fill(abs(pen.y - 4.8) - 0.4, 0.15);
            float fence = fill(min(pen.x, 34.0 - pen.x) - 0.25, 0.1);
            float cattle = step(0.55, hash21(int2(floor(q / float2(1.6, 1.2))), s + 16u)) * fill(abs(pen.y - 7.5) - 2.2, 0.4);
            float3 pens = mix(dirt, float3(0.78, 0.72, 0.6), alley);
            pens = mix(pens, float3(0.93, 0.93, 0.91), bunk);
            pens = mix(pens, dirt * 0.7, fence * 0.6);
            pens = mix(pens, float3(0.17, 0.14, 0.12), cattle * 0.85);
            c = mix(c, pens, fill(block, 2.0));
            herd = 0.0;
        }
    } else if (kind == markBurn) {
        float shape = length(d) / radius - 0.75 + 0.5 * (fbm(d / 60.0, 3, s + 17u) - 0.5);
        float charred = fill(shape, 0.05);
        float greenEdge = fill(abs(shape - 0.04) - 0.04, 0.03);
        c = mix(c, float3(0.24, 0.22, 0.20) * (0.85 + 0.3 * vnoise(d / 5.0, s + 18u)), charred * 0.92);
        c = mix(c, float3(0.6, 0.76, 0.36), greenEdge * 0.55);
        c = mix(c, float3(0.55, 0.53, 0.5), fill(abs(shape) - 0.012, 0.01) * 0.4);
    } else if (kind == markLake) {
        float shape = length(d * float2(1.0, 1.3)) / radius - 0.72 + 0.55 * (fbm(d / 45.0, 3, s + 19u) - 0.5);
        float wet = fill(shape, 0.02);
        float3 deep = b.f.z > 0.5 ? mix(b.snow.rgb, float3(0.72, 0.8, 0.88), 0.4)
                                  : mix(b.water.rgb * 0.72, float3(0.1, 0.17, 0.28), 0.35);
        c = mix(c, b.sand.rgb, fill(shape - 0.05, 0.02) * (1.0 - b.f.y * 0.6));
        c = mix(c, mix(deep, b.shallows.rgb * 0.8, smoothstep(-0.08, 0.0, shape)), wet);
        water = max(water, wet * (1.0 - b.f.z));
        herd *= 1.0 - fill(shape - 0.05, 0.02);
        cover = max(cover, wet);
    } else if (kind == markCorral) {
        // A round reindeer corral with long funnel fences running out into the land.
        float ring = abs(length(d) - 18.0);
        c = mix(c, c * 1.12 + 0.04, fill(length(d) - 18.0, 1.0) * 0.5);
        c = mix(c, float3(0.42, 0.36, 0.30), fill(ring - 0.3, 0.15));
        float2 a1 = rotate(float2(1.0, 0.0), angle), a2 = rotate(float2(1.0, 0.0), angle + 0.7);
        float fence = min(segmentDistance(d, a1 * 18.0, a1 * 150.0), segmentDistance(d, a2 * 18.0, a2 * 150.0));
        c = mix(c, float3(0.42, 0.36, 0.30), fill(fence - 0.25, 0.15));
    }
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
    if (b.d.z > 0.5 && abs(riverDistance(centerWorld, scene, wander)) < 90.0) return c;
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

// Lapland: pine heath on pale reindeer lichen, broken by aapa bogs where long curving strings of peat
// separate dark pools, like fingerprints seen from above.
inline Land taiga(float2 p, constant Biome &b, constant Scene &scene, uint seed) {
    Land l;
    l.road = 0.0;
    l.light = 0.0;
    l.lightID = 0.0;
    float mire = smoothstep(0.56, 0.62, fbm(p / 380.0, 3, seed + 30u));
    float3 heath = mix(b.crop0.rgb, b.crop2.rgb, smoothstep(0.45, 0.75, fbm(p / 26.0, 3, seed + 31u)) * 0.6);
    heath *= 0.95 + 0.1 * vnoise(p / 3.0, seed + 32u);
    float2 w = p + 40.0 * float2(fbm(p / 260.0, 2, seed + 33u), fbm(p / 260.0 + 7.0, 2, seed + 34u));
    float strings = sin((w.x * 0.35 + w.y) / 7.0);
    float pools = smoothstep(0.7, 0.9, -strings) * smoothstep(0.55, 0.72, vnoise(w / float2(22.0, 8.0), seed + 35u));
    float3 sedge = b.crop1.rgb * (0.92 + 0.12 * vnoise(p / 4.0, seed + 36u));
    sedge = mix(sedge, b.crop3.rgb, smoothstep(0.7, 0.95, strings) * 0.8);
    float3 pool = mix(float3(0.24, 0.30, 0.32), mix(b.snow.rgb, float3(0.78, 0.84, 0.9), 0.3), b.f.z);
    sedge = mix(sedge, pool, pools);
    float3 c = mix(heath, sedge, mire);
    l.water = pools * mire * (1.0 - b.f.z);
    float cover = 0.0;
    // Pines on the heath, in two scattered layers so they never line up.
    for (int layer = 0; layer < 2; layer++) {
        float spacing = layer == 0 ? 7.0 : 11.0;
        float2 q = layer == 0 ? p : rotate(p, 0.6);
        float2 g = floor(q / spacing);
        int2 cell = int2(g);
        float h = hash21(cell, seed + 37u + uint(layer));
        float stand = smoothstep(0.3, 0.6, vnoise((g + 0.5) * spacing / 140.0, seed + 38u));
        if (h < b.c.w * (1.0 - mire) * (0.25 + stand)) {
            float r = (layer == 0 ? 2.2 : 3.0) * (0.75 + 0.5 * hash21(cell, seed + 39u));
            float margin = r * 1.7;
            float2 center = g * spacing + margin + hash22(cell, seed + 40u) * max(spacing - 2.0 * margin, 0.0);
            c = tree(c, q - center, r, p, b, scene, seed, cover);
        }
    }
    l.color = c;
    l.forest = (1.0 - mire) * 0.7;
    l.sway = mire * 0.35;
    l.herd = mire > 0.5 && pools < 0.3 ? 1.0 : 0.0;
    return l;
}

inline Land land(float2 world, constant Leg &leg, constant Scene &scene, float riverHalf, float wander) {
    constant Biome &b = leg.biome;
    uint seed = uint(leg.info.y);
    float2 local = float2(world.x, world.y - leg.info.x);
    int layout = int(b.a.x);
    Land l;
    if (layout == layoutPaddies) l = paddies(local, b, seed);
    else if (layout == layoutFields) l = fields(local, b, scene, seed);
    else if (layout == layoutStripes) l = stripes(local, b, seed);
    else if (layout == layoutPivots) l = pivots(local, leg, scene, seed, wander);
    else if (layout == layoutTaiga) l = taiga(local, b, scene, seed);
    else l = grassland(local, b, seed);

    l.color = rocks(l.color, local, b, scene, seed, l.herd);
    float water = l.water;
    l.color = ponds(l.color, local, world, b, scene, seed, wander, water);
    l.herd *= 1.0 - smoothstep(0.0, 0.5, water - l.water);
    l.water = water;
    float cover = 0.0;
    l.color = landmark(l.color, int(b.j.x), b.j.y, local, world, b, scene, seed, wander, riverHalf, l.herd, l.water,
                       cover, l.light, l.lightID);
    l.color = landmark(l.color, int(b.j.z), b.j.w, local, world, b, scene, seed + 17u, wander, riverHalf, l.herd, l.water,
                       cover, l.light, l.lightID);
    l.color = houses(l.color, local, world, b, scene, seed, wander, cover, l.light, l.lightID);
    float roofs = cover;
    l.color = trees(l.color, local, world, b, scene, seed, riverHalf, wander, cover);
    l.light *= 1.0 - 0.75 * saturate(cover - roofs);
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
    if (width < 0.5) return c;
    float d = riverDistance(p, scene, wander);
    float halfWidth = width * 0.5;
    // A narrowing river takes its banks and dykes with it.
    float presence = saturate(width / 12.0);
    // Banks wobble a little so the river looks painted, not ruled.
    float wobble = (vnoise(float2(p.y / 23.0, d > 0.0 ? 3.0 : 7.0), 3u) - 0.5) * width * 0.16;
    float ad = abs(d) + wobble;
    float bank = halfWidth + (2.5 + width * 0.12) * presence;
    float levee = mix(a.i.w, b.i.w, m) * presence;
    if (ad > bank + levee + 3.0) return c;
    if (levee > 0.0) {
        // Grassy dykes either side, with a pale track along the crest.
        float out = ad - bank;
        float3 dyke = mix(c, mix(a.ground.rgb, b.ground.rgb, m) * float3(0.92, 1.08, 0.86), 0.75);
        dyke *= 0.95 + 0.1 * vnoise(p / 3.0, 9u);
        dyke = mix(dyke, mix(a.road.rgb, b.road.rgb, m), fill(abs(out - levee * 0.55) - 1.4, 0.4) * 0.8);
        // Snow lies on the dykes as it does on the fields.
        dyke = mix(dyke, mix(a.snow.rgb, b.snow.rgb, m) * (0.95 + 0.05 * vnoise(p / 5.0, 10u)), mix(a.f.y, b.f.y, m) * 0.9);
        c = mix(c, dyke, fill(out - levee, 1.2) * smoothstep(-1.0, 0.5, out));
        c = shade(c, fill(abs(out - levee - 1.0) - 1.0, 0.8) * 0.35, scene);
        herd *= 1.0 - fill(out - levee, 1.2);
    }

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
    float onRiver = fill(abs(riverDistance(p, scene, wander)) - riverHalf - 3.0, 0.5) * riverPresence(riverHalf);
    float2 sunOff = scene.sun.xy * scene.sun.z * 3.0;
    // The bridge deck shades the water under it.
    float shadowD = min(abs(roadDistance(p + sunOff, scene, wander)) - halfWidth, dc);
    c = shade(c, fill(shadowD, 0.8) * onRiver * 0.9, scene);

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

// MARK: - Railways


// The track bed, painted once: ballast, sleepers drawn wider apart than real ones so they never shimmer
// at this scale, rails, overhead masts with their shadows, and a steel deck where it crosses the river.
inline float3 railway(float3 c, float2 world, constant Leg &leg, constant Scene &scene, float texel,
                      float riverHalf, float wander, thread float &herd, thread float &water) {
    if (leg.rail.w < 0.5) return c;
    float2 local = float2(world.x, world.y - leg.info.x);
    float along;
    float d = railSigned(local, leg.rail.xy, leg.rail.z, leg.railShape.xyz, along);
    float ad = abs(d);
    if (ad > 10.0) return c;
    float fw = max(texel * 0.7, 0.12);
    float onRiver = fill(abs(riverDistance(world, scene, wander)) - riverHalf - 2.5, 0.6) * riverPresence(riverHalf);
    if (onRiver > 0.0) {
        // The deck's shadow on the water.
        float alongS;
        float dS = railSigned(local + scene.sun.xy * scene.sun.z * 6.0, leg.rail.xy, leg.rail.z, leg.railShape.xyz, alongS);
        c = shade(c, fill(abs(dS) - 2.4, 0.5) * onRiver * 0.85, scene);
    }
    float3 ballast = float3(0.58, 0.55, 0.50) * (0.92 + 0.16 * vnoise(local / 0.7, 501u));
    ballast = mix(ballast, leg.biome.snow.rgb * 0.95, leg.biome.f.y * 0.7);
    c = mix(c, c * 0.86, fill(ad - 3.8, 0.9) * (1.0 - onRiver));
    c = mix(c, mix(ballast, float3(0.30, 0.29, 0.31), onRiver), fill(ad - 2.5, 0.35));
    c = mix(c, float3(0.22, 0.22, 0.25), fill(abs(ad - 2.3) - 0.2, fw) * onRiver);
    float tie = abs(fract(along / 1.1) - 0.5) * 1.1;
    float sleeper = fill(tie - 0.17, fw) * fill(ad - 1.35, 0.15);
    c = mix(c, float3(0.36, 0.31, 0.27), sleeper * 0.7);
    c = mix(c, float3(0.80, 0.80, 0.83), fill(abs(ad - 0.72) - 0.06, max(0.08, texel * 0.6)) * 0.85);
    if (leg.railShape.w > 0.5) {
        // A mast every 55 m on one side, its shadow a long thin stroke away from the sun.
        float foot = (floor(along / 55.0) + 0.5) * 55.0;
        float2 lp = float2(along - foot, d - 3.3);
        float2 away = rotate(-scene.sun.xy, -leg.rail.z) * scene.sun.z * 7.0;
        c = shade(c, fill(segmentDistance(lp, 0.0, away) - 0.11, 0.12) * 0.7, scene);
        c = mix(c, float3(0.30, 0.30, 0.33), fill(length(lp) - 0.22, 0.1));
    }
    herd *= 1.0 - fill(ad - 4.5, 0.5);
    water *= 1.0 - fill(ad - 2.6, 0.3);
    return c;
}

// Where the line crosses the road, the road wins but the rails still show across it.
inline float3 railOverRoad(float3 c, float2 world, constant Leg &leg, float onRoad, float texel) {
    if (leg.rail.w < 0.5 || onRoad < 0.01) return c;
    float2 local = float2(world.x, world.y - leg.info.x);
    float along;
    float ad = abs(railSigned(local, leg.rail.xy, leg.rail.z, leg.railShape.xyz, along));
    if (ad > 3.0) return c;
    c = mix(c, c * 0.8, fill(ad - 1.0, 0.2) * onRoad * 0.6);
    return mix(c, float3(0.78, 0.78, 0.80), fill(abs(ad - 0.72) - 0.06, max(0.08, texel * 0.6)) * onRoad);
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
    // The new place spreads in organic patches, like wet paint creeping across the sheet. Inside the
    // soft edge both places are painted and blended; elsewhere only one is.
    float2 localB = float2(world.x, world.y - scene.legB.info.x);
    float threshold = 0.08 + 0.84 * fbm(localB / 85.0, 3, 77u);
    float blend = smoothstep(threshold - 0.05, threshold + 0.05, m);

    float wander = mix(scene.legA.biome.d.w, scene.legB.biome.d.w, m);
    float widthA = scene.legA.biome.d.z, widthB = scene.legB.biome.d.z;
    float width = mix(widthA, widthB, m);
    // Between a place with a river and one without, the river is painted over in the same creeping patches as
    // the land, rather than narrowing to a point in the middle of a field.
    float riverShown = 1.0;
    if ((widthA < 0.5) != (widthB < 0.5)) {
        width = max(widthA, widthB);
        riverShown = widthA >= 0.5 ? 1.0 - blend : blend;
    }
    float riverHalf = width * 0.5;
    float halfA = widthA < 0.5 ? 0.0 : riverHalf, halfB = widthB < 0.5 ? 0.0 : riverHalf;
    Land l;
    if (blend >= 1.0) {
        l = land(world, scene.legB, scene, halfB, wander);
    } else if (blend <= 0.0) {
        l = land(world, scene.legA, scene, halfA, wander);
    } else {
        Land a = land(world, scene.legA, scene, halfA, wander);
        Land b = land(world, scene.legB, scene, halfB, wander);
        l = a;
        l.color = mix(a.color, b.color, blend);
        l.water = mix(a.water, b.water, blend);
        l.sway = mix(a.sway, b.sway, blend);
        l.herd = mix(a.herd, b.herd, blend);
        l.road = mix(a.road, b.road, blend);
        l.light = mix(a.light, b.light, blend);
        l.lightID = blend > 0.5 ? b.lightID : a.lightID;
        // A darker tide line where the two paints meet.
        l.color *= 1.0 - 0.12 * (1.0 - abs(blend * 2.0 - 1.0));
    }

    float onRoad = l.road;
    float water = l.water;
    float herd = l.herd;
    float3 c = river(l.color, world, scene, scene.legA.biome, scene.legB.biome, m, width, wander, water, herd);
    if (riverShown < 1.0) {
        c = mix(l.color, c, riverShown);
        water = mix(l.water, water, riverShown);
        herd = mix(l.herd, herd, riverShown);
    }
    // Bridges only where the river is still painted.
    float crossingHalf = riverShown > 0.5 ? riverHalf : 0.0;
    constant Leg &railLeg = blend > 0.5 ? scene.legB : scene.legA;
    c = railway(c, world, railLeg, scene, texel, crossingHalf, wander, herd, water);
    c = road(c, world, scene, scene.legA.biome, scene.legB.biome, m, crossingHalf, wander, onRoad, water, herd);
    c = railOverRoad(c, world, railLeg, onRoad, texel);

    GroundOut out;
    out.color = float4(saturate(c), packGround(water, l.sway, onRoad > 0.5, herd > 0.5));
    out.night = float4(saturate(l.light * (1.0 - water * 0.8)), l.lightID, 0.0, 0.0);
    return out;
}

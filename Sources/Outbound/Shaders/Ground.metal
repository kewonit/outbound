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
    /// How much is roof or crown, which cars on the road pass under.
    float cover;
};

inline float3 cropColor(constant Biome &b, float h) {
    return h < 0.25 ? b.crop0.rgb : h < 0.5 ? b.crop1.rgb : h < 0.75 ? b.crop2.rgb : b.crop3.rgb;
}

// Fallen petals at `p`: how much of one lies there, where `amount` is how thickly they have fallen, 0 to 1. Each is a
// small soft dab somewhere in its own patch of ground, thickest where most have fallen, with a faint carpet under them.
inline float petals(float2 p, float amount, uint seed) {
    float2 g = p / 0.9;
    int2 cell = int2(floor(g));
    float2 from = g - floor(g) - 0.25 - 0.5 * hash22(cell, seed + 47u);
    float dab = 1.0 - smoothstep(0.1, 0.3, length(from));
    return max(step(1.0 - amount, hash21(cell, seed + 46u)) * dab * 0.9, amount * amount * 0.35);
}

// MARK: - Trees

// Trees near a point are gathered first and painted together, so crowns can overlap with the taller on top, and a
// shadow, cast from the trunk as long as the sun makes it, can fall across a neighbour's cell and onto lower crowns.
enum TreeKind { broadleaf = 0, spruce = 1, pine = 2 };
enum Foliage { leaves = 0, flowers = 1, eucalyptus = 2, conifer = 3, birch = 4, cedar = 5 };

constant int canopySize = 10;

struct Canopy {
    float2 at[canopySize];    // trunks, in leg-local metres
    float4 shape[canopySize]; // crown radius, height, kind and foliage (see treeKind), tone
    int count;
    // The longest shadow any of them casts, so the few cells round a point hold every tree that can shade it.
    float reach;
};

// A tree's kind and its foliage share a number in its shape, as everything in a Canopy costs memory for every thread.
inline int treeKind(float4 shape) {
    return int(shape.z) & 3;
}

inline Canopy canopy(float reach) {
    Canopy k;
    k.count = 0;
    k.reach = reach;
    return k;
}

// Shadows are a cool multiply, never grey, and fade away once the sun is down.
inline float3 shade(float3 c, float amount, constant Scene &scene) {
    float daylight = mix(0.2, 1.0, smoothstep(-0.1, 0.12, scene.sun.w));
    return c * mix(float3(1.0), float3(0.56, 0.62, 0.78), amount * daylight);
}

inline float segmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)));
}

// Shadow per metre of height for this tree: the sun's, cut short so it stays within the canopy's reach.
inline float treeSun(float4 shape, float reach, constant Scene &scene) {
    return min(scene.sun.z, reach / max(shape.y, 1.0));
}

// Half the depth of a crown from its top to its lowest leaves. A tall tree's crown is deeper than it is wide: a broadleaf
// is in leaf over its upper three fifths, a pine over its upper two.
inline float crownDepth(float4 shape) {
    bool flat = treeKind(shape) == pine;
    return max((flat ? 0.55 : 0.95) * shape.x, (flat ? 0.2 : 0.3) * shape.y);
}

// How a tree's shadow covers `q` (from its trunk) on a surface `level` metres up, 0 to 1. A crown throws the shadow of
// all its depth, an ellipse drawn out away from the sun, and the bare trunk under it throws a thin line from the foot of
// the tree to it, so however low the sun a shadow starts where its tree stands. A spruce throws a spike from its base to
// the shadow of its tip.
inline float shadowOf(float2 q, float4 shape, float level, float z, float2 u) {
    float r = shape.x, h = shape.y;
    if (treeKind(shape) == spruce) {
        float tip = (h - level) * z;
        if (tip <= 0.0) return 0.0;
        float2 a = -u * max(0.1 * h - level, 0.0) * z, b = -u * tip;
        float2 pa = q - a, ba = b - a;
        float t = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-4));
        return fill(length(pa - ba * t) - r * 0.9 * (1.0 - t) - 0.08, 0.2 + 0.03 * tip * t);
    }
    float deep = crownDepth(shape);
    float above = h - deep - level;
    if (above + deep <= 0.0) return 0.0;
    float2 across = float2(-u.y, u.x);
    float2 e = float2(r * 0.95, sqrt(r * r + deep * deep * z * z));
    float2 s = q + u * max(above, 0.0) * z;
    float d = (length(float2(dot(s, across), dot(s, u)) / e) - 1.0) * e.x;
    // A crown's shadow is as ragged as the crown, and softer the further it falls.
    d += r * 0.13 * sin(s.x * 2.7 / r + shape.w * 31.0) * sin(s.y * 2.3 / r + shape.w * 17.0);
    float cover = fill(d, 0.4 + 0.05 * max(above, 0.0) * z);
    if (level <= 0.0) {
        float trunk = segmentDistance(q, 0.0, -u * max(above, 0.0) * z);
        cover = max(cover, fill(trunk - 0.1 - 0.012 * h, 0.16) * 0.8);
    }
    return cover;
}

// How far `q` (from the trunk) lies outside the crown's ragged outline, and the crown's height there.
inline float crownAt(float2 q, float4 shape, thread float &height) {
    float r = shape.x, h = shape.y, tone = shape.w;
    float len = length(q);
    float a = atan2(q.y, q.x);
    float t = saturate(len / r);
    if (treeKind(shape) == spruce) {
        // Branches in whorls make a star from above.
        float star = 0.5 + 0.5 * cos(a * 7.0 + tone * 40.0);
        height = h * (1.0 - 0.9 * t);
        return len - r * (0.74 + 0.26 * star * star);
    }
    float vert = treeKind(shape) == pine ? 0.55 : 0.95;
    height = h - vert * r + vert * r * sqrt(1.0 - t * t);
    float lobes = 0.5 * sin(a * 3.0 + tone * 23.0) + 0.35 * sin(a * 5.0 + tone * 61.0) + 0.2 * sin(a * 11.0 + tone * 97.0);
    return len - r * (0.88 + 0.13 * lobes);
}

inline void foliageColours(int foliage, constant Biome &b, thread float3 &dark, thread float3 &light) {
    if (foliage == flowers) { dark = b.blossom.rgb; light = b.blossomLight.rgb; }
    else if (foliage == eucalyptus) { dark = float3(0.20, 0.29, 0.24); light = float3(0.43, 0.52, 0.42); }
    else if (foliage == conifer) { dark = b.canopy.rgb * float3(0.62, 0.68, 0.72); light = b.canopy.rgb * 1.05; }
    else if (foliage == birch) { dark = b.hedge.rgb * 0.7; light = b.hedge.rgb * 1.14; }
    else if (foliage == cedar) { dark = float3(0.12, 0.2, 0.15); light = float3(0.25, 0.36, 0.26); }
    else { dark = b.canopy.rgb; light = b.canopyLight.rgb; }
}

// A crown lit as a dome (a cone for a spruce), broken into clumps that each catch the sun on one side, the shade
// of taller neighbours laid over it, and every tree a little different.
inline float3 crownColour(thread Canopy &k, int i, float2 p, float level, constant Biome &b,
                          constant Scene &scene, uint seed) {
    float4 shape = k.shape[i];
    float2 q = (p - k.at[i]) / shape.x;
    float tone = shape.w;
    uint ts = seed + 300u + uint(tone * 997.0);
    float3 dark, light;
    foliageColours(int(shape.z) >> 2, b, dark, light);
    float2 u = scene.sun.xy;
    float elevation = max(scene.sun.w, 0.15);
    float3 sun = float3(u * cos(elevation), sin(elevation));
    float len = length(q);
    float3 n;
    if (treeKind(shape) == spruce) {
        n = normalize(float3(q / max(len, 1e-3) * 0.85, 0.5));
    } else {
        float vert = treeKind(shape) == pine ? 0.55 : 0.95;
        n = normalize(float3(q, sqrt(saturate(1.0 - len * len)) / vert));
    }
    float lit = dot(n, sun);
    // Turned its own way in every tree, so no two crowns show the noise's lattice lined up.
    float2 cq = rotate(q, tone * 6.283) * (treeKind(shape) == spruce ? 3.2 : 2.3) + tone * 37.0;
    float clump = vnoise(cq, ts);
    float bump = vnoise(cq + u * 0.3, ts) - clump;
    float3 c = mix(dark, light, saturate(0.6 * lit + 0.08 + 2.3 * bump + 0.35 * (clump - 0.5)));
    // Deep gaps between the masses of leaves, and a darker rim on the side away from the sun.
    c *= 0.72 + 0.28 * smoothstep(0.22, 0.56, clump);
    c *= 1.0 - 0.24 * smoothstep(0.6, 1.0, len) * saturate(0.6 - lit);
    // No two trees quite alike: some warmer, some cooler, some older and darker.
    float vary = fract(tone * 7.31);
    c *= 0.84 + 0.32 * tone;
    c = mix(c, c * float3(1.1, 1.05, 0.8), saturate(vary * 2.2 - 1.2));
    c = mix(c, c * float3(0.88, 0.98, 1.04), saturate(0.8 - vary * 2.4));
    c = mix(c, b.snow.rgb * (0.85 + 0.15 * saturate(lit)), b.f.y * 0.6 * smoothstep(0.45, 0.75, clump));

    float shadow = 0.0;
    for (int j = 0; j < k.count; j++) {
        if (j == i) continue;
        shadow = max(shadow, shadowOf(p - k.at[j], k.shape[j], level, treeSun(k.shape[j], k.reach, scene), u));
    }
    return shade(c, shadow * 0.8, scene);
}

// Adds a tree to the canopy if its crown or its shadow reaches p.
inline void plant(thread Canopy &k, float2 p, float2 at, float r, float h, int kind, float tone, int foliage,
                  constant Scene &scene) {
    if (k.count >= canopySize) return;
    float2 q = p - at;
    float len = min(h * scene.sun.z, k.reach);
    // The last places are kept for crowns over p: a crown lost would leave a hole, a shadow lost only a little light.
    if (dot(q, q) > (r * 1.1 + 0.4) * (r * 1.1 + 0.4)
        && (k.count >= canopySize - 3
            || segmentDistance(q, 0.0, -scene.sun.xy * len) > r * (1.0 + 0.85 * scene.sun.z) + 0.5)) return;
    k.at[k.count] = at;
    k.shape[k.count] = float4(r, h, float(kind + foliage * 4), tone);
    k.count++;
}

// Paints the gathered trees over `c`: every shadow on the ground, then the two highest crowns over p.
inline float3 grow(thread Canopy &k, float3 c, float2 p, constant Biome &b, constant Scene &scene, uint seed,
                   thread float &cover) {
    if (k.count == 0) return c;
    float2 u = scene.sun.xy;
    float ground = 0.0;
    int first = -1, second = -1;
    float h1 = -1.0, h2 = -1.0, a1 = 0.0, a2 = 0.0;
    for (int i = 0; i < k.count; i++) {
        float2 q = p - k.at[i];
        ground = max(ground, shadowOf(q, k.shape[i], 0.0, treeSun(k.shape[i], k.reach, scene), u));
        float height;
        float a = fill(crownAt(q, k.shape[i], height), 0.18);
        if (a <= 0.0) continue;
        if (height > h1) {
            second = first; h2 = h1; a2 = a1;
            first = i; h1 = height; a1 = a;
        } else if (height > h2) {
            second = i; h2 = height; a2 = a;
        }
    }
    c = shade(c, ground * 0.85, scene);
    if (second >= 0) c = mix(c, crownColour(k, second, p, h2, b, scene, seed), a2);
    if (first >= 0) c = mix(c, crownColour(k, first, p, h1, b, scene, seed), a1);
    cover = max(cover, max(a1, a2));
    return c;
}

// The cells of a grid `spacing` apart that can hold a tree touching p or shading it: those round p, and as far
// towards the sun as a shadow reaches. At most five by five.
inline void window(float2 p, float spacing, float margin, float2 toward, thread int2 &lo, thread int2 &hi) {
    float2 a = min(p, p + toward) - margin, b = max(p, p + toward) + margin;
    lo = int2(floor(a / spacing));
    hi = int2(floor(b / spacing));
    // If that is too many, the far end towards the sun goes, never the cells round p.
    lo = select(lo, max(lo, hi - 4), toward < 0.0);
    hi = select(min(hi, lo + 4), hi, toward < 0.0);
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
    // Each place's brush runs its own way.
    float slant = 0.25 + 0.7 * hash11(int(seed), 9u);
    float strokes = vnoise(rotate(p, slant) * float2(1.0 / 1.4, 1.0 / 8.5), seed + 4u);
    float fine = vnoise(rotate(p, slant) * float2(1.0 / 0.6, 1.0 / 3.0), seed + 5u);
    c *= 1.0 + b.b.z * (0.16 * (strokes - 0.5) + 0.08 * (fine - 0.5));
    return c;
}

// Open grassland; where the place fences it, a patchwork of long paddocks, each put to its own use: pasture grazed a
// little differently from the next, rough tussock grass, wheat with the passes of the drill along it, stubble, and
// fresh-tilled ground. A fence is only a crisp change of tone, with a track beside some.
inline Land grassland(float2 p, constant Biome &b, uint seed) {
    Land l;
    l.color = openGround(p, b, seed);
    l.water = 0.0;
    l.sway = b.b.w * 0.7;
    l.herd = 1.0;
    l.road = 0.0;
    l.forest = 0.0;
    l.light = 0.0;
    l.lightID = 0.0;
    if (b.a.y > 300.0) {
        float width = b.a.y;
        float column = floor(p.x / width);
        float x = p.x - column * width;
        float run = width * (1.1 + 0.7 * hash11(int(column), seed + 50u));
        float y = p.y + hash11(int(column), seed + 51u) * run;
        float row = floor(y / run);
        y -= row * run;
        // Some paddocks are split down their length.
        int2 id = int2(int(column), int(row));
        float split = hash21(id, seed + 52u) < 0.4 ? width * (0.4 + 0.2 * hash21(id, seed + 53u)) : width;
        int2 paddock = int2(id.x * 2 + (x < split ? 0 : 1), id.y);
        float use = hash21(paddock, seed + 54u);
        float tone = hash21(paddock, seed + 55u);
        float3 c = l.color;
        float passes = 0.5 + 0.5 * sin(x * 6.283 / 24.0);
        if (use < 0.42) {
            c = mix(b.crop0.rgb, b.crop1.rgb, tone) * (0.94 + 0.12 * vnoise(p / 40.0, seed + 56u));
            c = mix(c, l.color, 0.35);
        } else if (use < 0.55) {
            // Tussocks: fine and uneven, turned off the lattice so no clump comes out square.
            c = b.ground.rgb * (0.86 + 0.28 * fbm(rotate(p, 0.6) / 2.6, 3, seed + 57u)) * (0.96 + 0.08 * tone);
            c = mix(c, b.groundDark.rgb * 1.1, smoothstep(0.52, 0.74, fbm(rotate(p, -0.45) / 11.0, 2, seed + 58u)) * 0.4);
        } else if (use < 0.74) {
            c = b.crop2.rgb * (0.95 + 0.08 * tone) * (1.0 + 0.035 * (passes - 0.5));
            l.herd = 0.0;
            l.sway = b.b.w;
        } else if (use < 0.88) {
            c = b.crop3.rgb * (0.95 + 0.08 * tone) * (1.0 + 0.05 * (passes - 0.5));
            l.herd = 0.0;
            l.sway = 0.1;
        } else {
            c = b.groundDark.rgb * (0.94 + 0.1 * tone) * (1.0 + 0.04 * sin(x * 6.283 / 3.0)) * (0.95 + 0.1 * vnoise(p / 12.0, seed + 59u));
            l.herd = 0.0;
            l.sway = 0.0;
        }
        // Where cattle walk the fence line, and the fence itself.
        float fence = min(min(x, width - x), min(y, run - y));
        fence = min(fence, split < width ? abs(x - split) : 1e3);
        c = mix(c, mix(c, b.ground.rgb * 1.05, 0.5), fill(fence - 2.5, 1.0) * step(use, 0.55) * 0.6);
        c = mix(c, c * 0.84, fill(fence - 0.35, 0.2));
        l.color = c;
        // A dirt track beside some fences.
        if (hash11(int(column), seed + 60u) < 0.45) {
            float track = fill(abs(x - 7.0) - 1.6, 0.4);
            l.color = mix(l.color, b.road.rgb * (0.97 + 0.06 * vnoise(p / 1.5, seed + 61u)), track);
            l.herd *= 1.0 - track;
        }
    }
    return l;
}

// One plot of the paddy grid: column bounds, row bounds and an id.
inline float jitteredEdge(int k, float jitter, uint seed) {
    return float(k) + (hash11(k, seed) - 0.5) * jitter;
}

// Rice paddies laid out as a consolidated grid: long plots side by side in districts that share their cross levees,
// each plot facing a gravel farm road at one end and a concrete channel at the other, with a wider road between
// blocks. Neighbouring plots are flooded, planted or still bare on different days, which is what the plain looks
// like in spring.
inline Land paddies(float2 p, constant Biome &b, uint seed) {
    float w = b.a.y;
    float cx = p.x / w;
    int k = int(floor(cx));
    float e0 = jitteredEdge(k, 0.08, seed);
    float e1 = jitteredEdge(k + 1, 0.08, seed);
    int col = k;
    if (cx < e0) { col = k - 1; e1 = e0; e0 = jitteredEdge(k - 1, 0.08, seed); }
    else if (cx >= e1) { col = k + 1; e0 = e1; e1 = jitteredEdge(k + 2, 0.08, seed); }

    int block = int(floor(float(col) / 5.0));
    int inBlock = col - block * 5;
    int district = int(floor(float(col) / 20.0));
    float len = w * (2.8 + 0.5 * hash11(district, seed + 1u));
    float ry = (p.y + hash11(district, seed + 2u) * len * 7.0) / len;
    float row = floor(ry);
    float along = ry - row;
    // Which end of the plot is nearer, and whether a road or a channel runs along it.
    float boundary = along < 0.5 ? row : row + 1.0;
    bool roadEnd = int(boundary) % 2 == 0;
    float rowDist = min(along, 1.0 - along) * len;
    float sideDist = min(cx - e0, e1 - cx) * w;
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
        // Ploughed or puddled mud, the furrows across the plot.
        c = mix(float3(0.55, 0.46, 0.36), b.groundDark.rgb, 0.15) * (0.92 + 0.12 * hash21(plot, seed + 12u));
        c *= 1.0 + 0.06 * sin(p.y * 2.4) * b.b.z;
        l.water = kind < b.b.x * 0.5 ? b.c.x * 0.4 : 0.0;
        l.sway = 0.0;
    } else if (h < 0.5) {
        // Flooded: the sky over silt, and no two plots alike, as each holds a different depth of water.
        c = mix(cropColor(b, h), float3(0.5, 0.49, 0.4), 0.14 + 0.3 * hash21(plot, seed + 13u));
        c = pigment(c, vnoise(p / 21.0, seed + 11u), 0.32);
        l.water = b.c.x;
        l.sway = 0.1;
    } else {
        c = cropColor(b, h);
        // Seedlings in rows, picked out as specks.
        float2 g = p / float2(1.15, 1.4);
        float speck = hash21(int2(floor(g)), seed + 5u);
        c *= 1.0 + 0.04 * (speck - 0.5) * (1.0 + b.b.z);
        l.water = b.c.x * 0.5;
        l.sway = b.b.w;
    }
    c *= 0.95 + 0.1 * hash21(plot, seed + 6u);

    // Grass bunds round every plot.
    float levee = b.a.z * 0.5;
    float edgeDist = min(sideDist, rowDist);
    float bund = fill(edgeDist - levee, 0.3);
    c = mix(c, b.hedge.rgb * (0.9 + 0.14 * vnoise(p / 1.5, seed + 9u)), bund);
    // The plot's water stands a little darker against the bund, where mud shows through it.
    c *= 1.0 - 0.15 * fill(edgeDist - levee - 1.6, 1.2) * (1.0 - bund) * step(0.3, l.water);
    // The road or the channel along the plot's end.
    float endDist = rowDist;
    if (roadEnd) {
        float track = fill(endDist - 1.8, 0.3);
        c = mix(c, b.road.rgb * (1.0 + 0.06 * vnoise(p / 1.2, seed + 8u)), track);
        bund = max(bund, track);
    } else {
        float concrete = fill(endDist - 1.1, 0.15);
        float channel = fill(endDist - 0.55, 0.12);
        c = mix(c, float3(0.78, 0.78, 0.75), concrete);
        c = mix(c, mix(b.water.rgb, b.shallows.rgb, 0.4), channel);
        l.water = mix(l.water, 1.0, channel);
        bund = max(bund, concrete);
    }
    // Between blocks, a wider farm road.
    if (inBlock == 0 && cx - e0 < 0.5) {
        float track = fill((cx - e0) * w - 2.6, 0.35);
        c = mix(c, b.road.rgb * (1.0 + 0.06 * vnoise(p / 1.2, seed + 8u)), track);
        bund = max(bund, track);
    }
    l.color = c;
    l.sway *= 1.0 - bund;
    l.water *= 1.0 - bund * (roadEnd ? 1.0 : 0.0);
    return l;
}

inline Land stripes(float2 p, constant Biome &b, uint seed) {
    float w = b.a.y;
    float blockLength = 280.0 + 140.0 * hash11(int(floor(p.x / 600.0)), seed + 3u);
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

inline float riverDistance(float2 p, constant Scene &scene, float2 wander) {
    float cx = riverX(p.y, scene, wander);
    float s = riverSlope(p.y, scene, wander);
    return (p.x - cx) / sqrt(1.0 + s * s);
}

inline float roadDistance(float2 p, constant Scene &scene, float2 wander) {
    float s = roadSlope(p.y, scene, wander);
    return (p.x - roadX(p.y, scene, wander)) / sqrt(1.0 + s * s);
}

// MARK: - What is already there

// Everything placed on the land gives way to what came before it: the river, the main road, the cross-roads, the
// railway, then lakes, ponds and landmarks, then houses and their paths, then trees. Each decides from its own position.

constant float crossroadSpacing = 1450.0;

// Which cross-road a stretch of the world holds and how far along y it runs at `x`. A cross-road is only built if it
// meets the main road on dry land, as a junction can't stand in a river.
inline float crossroadY(float2 p, constant Scene &scene, thread bool &built, float reach = 1e9) {
    float k = floor((p.y + scene.road.w) / crossroadSpacing);
    // Which one it is is counted from the world's origin, or it would shift or vanish as the reference stepped on.
    float which = k + scene.bends.w;
    built = hash11(int(which), 70u) < 0.55;
    float middle = (k + 0.5) * crossroadSpacing - scene.road.w;
    float line = middle + 40.0 * sin(p.x / 380.0 + which);
    // Further than `reach` from it, whether it was ever built makes no difference to the caller.
    if (built && abs(p.y - line) < reach) {
        float turned = landTurn(middle, scene);
        float2 wander = course(scene, turned);
        float y = middle + 40.0 * sin(roadX(middle, scene, wander) / 380.0 + which);
        float2 junction = float2(roadX(y, scene, wander), y);
        float width = mix(scene.legA.biome.d.z, scene.legB.biome.d.z, turned);
        built = width < 0.5 || abs(riverDistance(junction, scene, wander)) > width * 0.5 + 30.0;
    }
    return line;
}

// How far `at` lies from the middle of its stretch's cross-road, and how far `local` lies from the middle of the place's
// railway. These run for every house and tree and sit in the deepest part of the shader, where anything held across them
// costs memory for every thread, so they work from what is already to hand and hold nothing. Telling legA from legB by
// the address of `b`, or keeping a pointer to a leg, takes a launch from a second to over a minute, which is why the
// railway rides along in the Biome. A cross-road dropped for its junction still counts here, which costs a stretch of
// empty land at worst.
inline float crossGap(float2 at, constant Scene &scene) {
    float k = floor((at.y + scene.road.w) / crossroadSpacing);
    float which = k + scene.bends.w;
    if (hash11(int(which), 70u) >= 0.55) return 1e6;
    return abs(at.y - (k + 0.5) * crossroadSpacing + scene.road.w - 40.0 * sin(at.x / 380.0 + which));
}

// The same, for land with biome `b`: road() lays no cross-roads in pivot country, so nothing there keeps off them.
// Only what pivot country builds asks this way, its ponds, farmsteads and trees (the trees through keepouts), as
// each call costs GPU memory in the paths that inline it; it has no houses or road trees.
inline float crossGap(float2 at, constant Scene &scene, constant Biome &b) {
    return int(b.a.x) == layoutPivots ? 1e6 : crossGap(at, scene);
}

inline float railGap(float2 local, constant Biome &b) {
    if (b.railCurve.w < 0.5) return 1e6;
    float2 d = local - b.railLine.xy;
    float2 q = float2(dot(d, b.railLine.zw), dot(d, float2(-b.railLine.w, b.railLine.z)));
    return abs(q.y - b.railCurve.x * sin(q.x * b.railCurve.y + b.railCurve.z));
}

// How far a leg-local point is outside the strip a pivot must keep clear of: the main road and the railway.
inline float pivotClearance(float2 p, constant Leg &leg, constant Scene &scene, float2 wander) {
    float2 world = float2(p.x, p.y + leg.info.x);
    float clear = abs(roadDistance(world, scene, wander)) - leg.biome.e.x * 0.5 - 9.0;
    if (leg.rail.w > 0.5) {
        float along;
        clear = min(clear, abs(railSigned(p, leg.rail.xy, leg.rail.z, leg.railShape.xyz, along)) - 12.0);
    }
    return clear;
}

inline Land pivots(float2 p, constant Leg &leg, constant Scene &scene, uint seed, float2 wander) {
    constant Biome &b = leg.biome;
    float s = b.a.y;
    // The survey grid is laid from the road, which runs along one of its section lines.
    float2 grid = float2(b.l.y, 0.0);
    float2 g = floor((p - grid) / s);
    float2 center = (g + 0.5) * s + grid;
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
            // Counted round the whole circle, so the line where the angle wraps is not one more cut.
            float start = hash21(cell, seed + 4u);
            h = fract(h + floor(fract(angle / 6.283185 + start) * slices) * 0.37);
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
    float2 m = abs(fract((p - grid) / mile + 0.5) - 0.5) * mile;
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

inline bool clearOfWater(float2 world, constant Biome &b, constant Scene &scene, float riverHalf, float2 wander,
                         float r) {
    return (riverHalf <= 0.25 || abs(riverDistance(world, scene, wander)) > riverHalf + r + 5.0)
        && abs(roadDistance(world, scene, wander)) > b.e.x * 0.5 + r + 1.5;
}

// Where the pond of the cell round `local` lies, if it has one: its centre and radius.
inline bool pondSite(float2 local, constant Biome &b, uint seed, thread float2 &center, thread float &r) {
    if (b.e.z <= 0.0) return false;
    float size = max(b.k.w, 1.0);
    float spacing = 260.0 * size;
    float2 g = floor(local / spacing);
    int2 cell = int2(g);
    if (hash21(cell, seed + 80u) > b.e.z * 0.55) return false;
    r = (14.0 + 22.0 * hash21(cell, seed + 81u)) * size;
    center = g * spacing + r * 2.0 + hash22(cell, seed + 82u) * (spacing - r * 4.0);
    return true;
}

// Whether the pond of a cell at `center`, of radius `r`, is dug: not in the river, on a road or on the railway.
inline bool pondStands(float2 center, float r, float2 shift, constant Biome &b, constant Scene &scene, float2 wander) {
    float2 at = center + shift;
    if (b.d.z > 0.5 && abs(riverDistance(at, scene, wander)) < 90.0 + r) return false;
    float reach = r * 1.4 + 6.0;
    if (min(abs(roadDistance(at, scene, wander)), crossGap(at, scene, b)) < b.e.x * 0.5 + reach) return false;
    return railGap(center, b) >= reach;
}

// One house beside the road: house-local x points away from the road, so the porch faces it and the shed and the
// yard lamp stand behind; `size` is half its depth (x) and half its length along the road (y).
struct Plot {
    float2 center;
    float angle;
    float2 size;
    int id;
    float village;
    // Its way out to the road, in metres from its middle with x away from the road and y along it, square to the road and
    // not to the house, which stands a little askew: the door, where the path turns, the lane that reaches the road, and
    // how far off that is.
    float road;
    float door;
    float lane;
    float reach;
};

// How much the road at `y` runs through a village, 0 to 1. A place's `villages` sets how much of its road does: about a
// fifth at most, in short stretches, and next to none in the empty places.
inline float villageAt(float y, constant Biome &b, uint seed) {
    float from = 0.79 - b.i.x * 0.28;
    return smoothstep(from, from + 0.08, vnoise(float2(y / 1100.0, 0.5), seed + 70u)) * step(0.001, b.i.x);
}

// The house in slot `k` on one side of the road, in the row by the road (0) or behind it (1), if one stands there.
// Slots are 30 m long and a house at most 19 m, and the rows are set back far enough, so no two ever touch.
inline bool plot(thread Plot &h, float k, int row, float side, float2 world, float2 local, constant Biome &b,
                 constant Scene &scene, uint seed, float2 wander) {
    const float slot = 30.0;
    float yC = (k + 0.5 + 0.3 * (hash11(int(k), seed + 62u) - 0.5)) * slot;
    float village = villageAt(yC, b, seed);
    int id = (int(k) * 2 + (side > 0.0 ? 1 : 0)) * 2 + row;
    float chance = row == 0 ? mix(b.e.w * 0.33, 0.6, village) : 0.3 * village;
    if (hash11(id, seed + 60u) > chance) return false;
    float worldY = world.y + (yC - local.y);
    float2 along = normalize(float2(roadSlope(worldY, scene, wander), 1.0));
    float2 away = float2(along.y, -along.x) * side;
    float2 size = float2(4.2, 6.5) * (0.8 + 0.35 * hash11(id, seed + 65u)) * (b.i.z > 0.5 ? 1.15 : 1.0);
    float out = b.e.x * 0.5 + size.x + (row == 0 ? 3.0 + 11.0 * hash11(id, seed + 63u) : 32.0 + 16.0 * hash11(id, seed + 63u));
    h.center = float2(roadX(worldY, scene, wander), worldY) + away * out;
    if (b.d.z > 0.5 && abs(riverDistance(h.center, scene, wander)) < b.d.z * 0.5 * (1.0 + 0.55 * b.l.w) + b.i.w + 16.0 + size.y) return false;
    // Nor on a cross-road or the railway, with room for its yard.
    float room = length(size) + 7.0;
    float2 at = h.center - (world - local);
    if (crossGap(h.center, scene) < b.e.x * 0.45 + room || railGap(at, b) < room + 5.0) return false;
    // Nor in a pond.
    float2 pond;
    float pondRadius;
    if (pondSite(at, b, seed, pond, pondRadius) && length((at - pond) * float2(1.0, 1.25)) < pondRadius * 1.4 + 6.0 + size.y) return false;
    h.road = atan2(away.y, away.x);
    h.angle = h.road + (hash11(id, seed + 64u) - 0.5) * (0.12 + village * 0.12);
    h.door = size.y * (0.7 * hash11(id, seed + 430u) - 0.35);
    h.reach = out - b.e.x * 0.5 + 1.0;
    // The front row goes straight out to the road. The back row has the front row in the way, so it runs along its own
    // front to the line between two plots, which no house reaches, and shares a lane down it with the neighbour there.
    float between = (int(k) & 1) == 0 ? (k + 1.0) * slot : k * slot;
    h.lane = row == 0 ? h.door : (between - yC) * side;
    h.size = size;
    h.id = id;
    h.village = village;
    return true;
}

// How far `p`, in the frame of the plot's way out, lies from the middle of that way.
inline float pathGap(float2 p, Plot h) {
    float front = -h.size.x - 2.6;
    float2 turn = float2(front, 0.5 * (h.door + h.lane));
    float along = sdBox(p - turn, float2(0.0, 0.5 * abs(h.door - h.lane)));
    float outward = sdBox(p - float2(front - 0.5 * (h.reach - h.size.x - 2.6), h.lane), float2(0.5 * (h.reach - h.size.x - 2.6), 0.0));
    float door = sdBox(p - float2(-h.size.x - 1.3, h.door), float2(1.3, 0.0));
    return smin(smin(along, outward, 1.6), door, 1.2);
}

// Whether a crown of radius `r` at `world` keeps off every house, its shed and its yard.
inline bool clearOfHouses(float2 world, float2 local, float r, constant Biome &b, constant Scene &scene, uint seed,
                          float2 wander) {
    if (b.e.w <= 0.0 && b.i.x <= 0.0) return true;
    float rx = roadX(world.y, scene, wander);
    if (abs(world.x - rx) > b.e.x * 0.5 + 70.0 + r) return true;
    float side = world.x > rx ? 1.0 : -1.0;
    float k0 = floor(local.y / 30.0);
    for (int dk = -1; dk <= 1; dk++) {
        for (int row = 0; row < 2; row++) {
            Plot h;
            if (!plot(h, k0 + float(dk), row, side, world, local, b, scene, seed, wander)) continue;
            float2 d = rotate(world - h.center, -h.angle);
            if (sdBox(d - float2(2.5, 0.0), h.size + float2(4.0, 1.5)) < r) return false;
            if (pathGap(rotate(world - h.center, -h.road), h) < r + 1.0) return false;
        }
    }
    return true;
}

inline float landmarkCell(int kind) {
    return kind == markTubeWell ? 170.0 : kind == markWindmill ? 700.0 : kind == markKopje ? 420.0
         : kind == markFeedlot || kind == markKiln ? 1500.0 : kind == markCorral ? 1300.0 : 750.0;
}

inline float landmarkRadius(int kind) {
    return kind == markTubeWell ? 14.0 : kind == markWindmill ? 22.0 : kind == markKopje ? 55.0
         : kind == markFeedlot ? 260.0 : kind == markGrove ? 120.0 : kind == markBurn ? 200.0
         : kind == markLake ? 170.0 : kind == markCorral ? 150.0 : kind == markKiln ? 110.0
         : kind == markFarmstead ? 70.0 : 90.0;
}

// Where the landmark of the cell round `local` stands, if the cell has one.
inline bool landmarkSite(int kind, float density, float2 local, constant Biome &b, uint seed, thread float2 &center,
                         thread int2 &id2) {
    if (kind == markNone || density <= 0.0) return false;
    float cell = landmarkCell(kind), radius = landmarkRadius(kind);
    uint s = seed + uint(kind) * 131u;
    float2 g = floor(local / cell);
    id2 = int2(g);
    // Kopjes come in clusters, as granite outcrops do, with open plain between.
    if (kind == markKopje) density *= hash21(id2 / 3, s + 9u) < 0.35 ? 2.6 : 0.15;
    if (hash21(id2, s) > density) return false;
    center = g * cell + radius + 10.0 + hash22(id2, s + 1u) * max(cell - 2.0 * radius - 20.0, 0.0);
    if (kind == markFarmstead && int(b.a.x) == layoutPivots) {
        // Farmsteads sit in the dry corner in the middle of a section, where four circles meet, clear of its roads.
        float2 grid = float2(b.l.y, 0.0), mile = float2(b.a.y * 2.0);
        center = (floor((center - grid) / mile) + 0.5) * mile + grid;
    }
    return true;
}

// Whether a landmark whose cell holds one at `center` is built: not on the river, nor on the road.
inline bool landmarkStands(int kind, float2 centerWorld, float2 shift, constant Biome &b, constant Scene &scene,
                           float riverHalf, float2 wander, uint seed) {
    float radius = landmarkRadius(kind);
    // Of a place's two kinds, the second gives way to the first, in every cell of the first it could touch: the two kinds'
    // cells don't line up, so more than one may be in reach.
    if (kind == int(b.j.z) && b.j.y > 0.0) {
        int first = int(b.j.x);
        float2 at = centerWorld - shift, other;
        float size = landmarkCell(first), touch = landmarkRadius(first) + radius;
        int reach = int(ceil(touch / size));
        int2 cell;
        #pragma clang loop unroll(disable)
        for (int j = -reach; j <= reach; j++) {
            #pragma clang loop unroll(disable)
            for (int i = -reach; i <= reach; i++) {
                if (landmarkSite(first, b.j.y, at + float2(i, j) * size, b, seed - 17u, other, cell)
                    && length(at - other) < touch) return false;
            }
        }
    }
    if (riverHalf > 0.25 && abs(riverDistance(centerWorld, scene, wander)) < riverHalf + radius * 0.8 + 15.0) return false;
    float reach = radius * 0.95 + 6.0;
    // Where people live by the road it keeps clear of their homes too, front and back row.
    float homes = b.e.w > 0.0 || b.i.x > 0.0 ? 62.0 : 0.0;
    if (abs(roadDistance(centerWorld, scene, wander)) < b.e.x * 0.5 + reach + homes) return false;
    if (crossGap(centerWorld, scene, b) < b.e.x * 0.5 + reach) return false;
    return railGap(centerWorld - shift, b) >= reach + 4.0;
}

// How far outside a lake's shore `d` (from its centre) lies, as a share of its radius.
inline float lakeShore(float2 d, float radius, uint s) {
    return length(d * float2(1.0, 1.3)) / radius - 0.72 + 0.55 * (fbm(d / 45.0, 3, s + 19u) - 0.5);
}

// What a tree might have to keep clear of round a point: the road and its houses, the river, and the landmark of
// each kind whose cell the point is in, looked up once for all the trees round it.
struct Keepouts {
    bool road;
    bool river;
    bool crossNear;
    bool rail;
    int2 cell[2];
    bool standing[2];
    float2 center[2];
};

inline Keepouts keepouts(float2 world, float2 local, float span, constant Biome &b, constant Scene &scene,
                         uint seed, float riverHalf, float2 wander) {
    Keepouts k;
    k.road = abs(roadDistance(world, scene, wander)) < b.e.x * 0.5 + 75.0 + span;
    k.river = riverHalf > 0.25 && abs(riverDistance(world, scene, wander)) < riverHalf + b.i.w + 20.0 + span;
    k.crossNear = crossGap(world, scene, b) < b.e.x * 0.5 + 20.0 + span;
    k.rail = railGap(local, b) < 20.0 + span;
    for (int i = 0; i < 2; i++) {
        int kind = int(i == 0 ? b.j.x : b.j.z);
        float density = i == 0 ? b.j.y : b.j.w;
        k.standing[i] = landmarkSite(kind, density, local, b, seed + uint(i) * 17u, k.center[i], k.cell[i])
                     && landmarkStands(kind, k.center[i] + (world - local), world - local, b, scene, riverHalf, wander,
                                       seed + uint(i) * 17u);
    }
    return k;
}

inline bool clearOfLandmark(int kind, float density, float2 local, float2 shift, float r, constant Biome &b,
                            constant Scene &scene, uint seed, float riverHalf, float2 wander, int2 knownCell,
                            bool knownStanding, float2 knownCenter) {
    // Burns and corrals lie open on the land, so trees may stand round them.
    if (kind == markBurn || kind == markCorral || kind == markNone || density <= 0.0) return true;
    float2 center = knownCenter;
    bool standing = knownStanding;
    // Most trees share the cell of the point they are drawn for, whose landmark is already known.
    if (any(int2(floor(local / landmarkCell(kind))) != knownCell)) {
        int2 id;
        standing = landmarkSite(kind, density, local, b, seed, center, id)
                && landmarkStands(kind, center + shift, shift, b, scene, riverHalf, wander, seed);
    }
    if (!standing) return true;
    float radius = landmarkRadius(kind);
    if (length(local - center) > radius * 1.05 + r) return true;
    // Trees grow right down to a lake's shore.
    if (kind == markLake) return lakeShore(local - center, radius, seed + uint(kind) * 131u) > 0.06 + r / radius;
    return false;
}

// Whether a crown of radius `r` keeps off the landmarks, which bring their own trees, and off the ponds.
inline bool clearOfLandmarks(float2 local, float2 shift, float r, Keepouts near, constant Biome &b,
                             constant Scene &scene, uint seed, float riverHalf, float2 wander) {
    if (!clearOfLandmark(int(b.j.x), b.j.y, local, shift, r, b, scene, seed, riverHalf, wander, near.cell[0],
                         near.standing[0], near.center[0])) return false;
    if (!clearOfLandmark(int(b.j.z), b.j.w, local, shift, r, b, scene, seed + 17u, riverHalf, wander, near.cell[1],
                         near.standing[1], near.center[1])) return false;
    float2 pc;
    float pr;
    // A pond that was never dug leaves no bare patch among the trees.
    if (pondSite(local, b, seed, pc, pr) && length((local - pc) * float2(1.0, 1.25)) < pr * 1.4 + 6.0 + r
        && pondStands(pc, pr, shift, b, scene, wander)) return false;
    return true;
}

inline bool clearSpot(float2 at, float2 atWorld, float r, Keepouts near, constant Biome &b, constant Scene &scene,
                      uint seed, float riverHalf, float2 wander) {
    if (near.river && abs(riverDistance(atWorld, scene, wander)) < riverHalf + b.i.w + r + 7.0) return false;
    if (near.road) {
        if (abs(roadDistance(atWorld, scene, wander)) < b.e.x * 0.5 + r + 1.5) return false;
        if (!clearOfHouses(atWorld, at, r, b, scene, seed, wander)) return false;
    }
    if (near.crossNear && crossGap(atWorld, scene) < b.e.x * 0.45 + r + 1.5) return false;
    if (near.rail && railGap(at, b) < r + 2.5) return false;
    return clearOfLandmarks(at, atWorld - at, r, near, b, scene, seed, riverHalf, wander);
}

// Trees over the land: scattered, gathered into groves as much as the place likes, straight windbreaks along the
// survey lines or the paddock fences, and avenues along the road. None stands in the water, on the road or a
// house, or on a landmark.
inline void plantTrees(thread Canopy &k, thread float3 &c, float2 local, float2 world, constant Biome &b,
                       constant Scene &scene, uint seed, float riverHalf, float2 wander) {
    float2 u = scene.sun.xy;
    float2 toward = u * k.reach;
    float2 shift = world - local;
    float density = b.c.y;
    float size = b.c.z;
    if (density > 0.0) {
        float spacing = size * 2.6;
        float rMax = size * 0.6;
        int2 lo, hi;
        window(local, spacing, rMax * 2.0, toward, lo, hi);
        Keepouts near = keepouts(world, local, spacing * 2.5 + k.reach, b, scene, seed, riverHalf, wander);
        for (int y = lo.y; y <= hi.y; y++) {
            for (int x = lo.x; x <= hi.x; x++) {
                int2 cell = int2(x, y);
                float2 centre = (float2(cell) + 0.5) * spacing;
                float clump = smoothstep(0.5, 0.78, vnoise(centre / 240.0, seed + 41u));
                float chance = density * mix(1.0, 0.12 + 3.2 * clump, b.g.z);
                // In the thickest groves a cell holds a second tree, and crowns run together.
                for (int t = 0; t < 2; t++) {
                    if (hash21(cell, seed + 40u + uint(t) * 7u) >= chance - float(t)) continue;
                    uint ts = seed + 42u + uint(t) * 9u;
                    float r = size * 0.5 * (0.7 + 0.5 * hash21(cell, ts));
                    float2 at = float2(cell) * spacing + r * 0.4 + hash22(cell, ts + 1u) * max(spacing - r * 0.8, 0.0);
                    // Nothing stands in a planted circle: the arm sweeps all of it. The corners between circles are
                    // where a shelter tree is left.
                    if (int(b.a.x) == layoutPivots) {
                        float2 pivot = floor((at - float2(b.l.y, 0.0)) / b.a.y);
                        float2 pad = (pivot + 0.5) * b.a.y + float2(b.l.y, 0.0);
                        if (hash21(int2(pivot), seed + 1u) > b.b.x && length(at - pad) < b.a.y * 0.485 + r + 2.0) continue;
                    }
                    if (!clearSpot(at, at + shift, r, near, b, scene, seed, riverHalf, wander)) continue;
                    // Petals scattered round blossom trees.
                    if (b.d.y > 0.0 && b.blossom.w < 0.5) {
                        float close = 1.0 - smoothstep(r, r * 2.6, length(local - at));
                        c = mix(c, b.canopyLight.rgb * 1.05, petals(local, 0.22 * b.d.y * close, seed));
                    }
                    bool flat = b.l.z > 0.0;
                    plant(k, local, at, r, r * (flat ? b.l.z : 2.3 + 0.9 * hash21(cell, ts + 2u)), flat ? pine : broadleaf,
                          hash21(cell, ts + 3u), leaves, scene);
                }
            }
        }
    }

    // Windbreaks: straight lines of tall trees, along the fences where the land is fenced into paddocks.
    if (b.g.w > 0.0) {
        bool paddocks = int(b.a.x) == layoutGrassland && b.a.y > 300.0;
        float lineSpacing = paddocks ? b.a.y : 380.0;
        float stretch = paddocks ? b.a.y : 260.0;
        const float step = 7.0;
        float r0 = size * 0.4;
        float k0 = floor((local.x + min(toward.x, 0.0) - 14.0) / lineSpacing);
        float k1 = floor((local.x + max(toward.x, 0.0) + 14.0) / lineSpacing);
        Keepouts near = keepouts(world, local, k.reach + 20.0, b, scene, seed, riverHalf, wander);
        for (float kk = k0; kk <= min(k1, k0 + 1.0); kk += 1.0) {
            float lineX = paddocks ? kk * lineSpacing + 6.0 : (kk + 0.5) * lineSpacing + (hash11(int(kk), seed + 50u) - 0.5) * 140.0;
            if (hash11(int(kk), seed + 51u) >= b.g.w) continue;
            if (abs(local.x - lineX) > 14.0 + abs(toward.x)) continue;
            float j0 = floor((local.y + min(toward.y, 0.0) - r0 * 2.0) / step);
            float j1 = min(floor((local.y + max(toward.y, 0.0) + r0 * 2.0) / step), j0 + 6.0);
            for (float j = j0; j <= j1; j += 1.0) {
                float y = (j + 0.5) * step;
                if (hash21(int2(int(kk), int(floor(y / stretch))), seed + 52u) >= 0.65) continue;
                float jh = hash11(int(j) * 31 + int(kk), seed + 53u);
                float r = r0 * (0.8 + 0.4 * jh);
                float2 at = float2(lineX + (jh - 0.5) * 1.6, y);
                if (!clearSpot(at, at + shift, r, near, b, scene, seed, riverHalf, wander)) continue;
                plant(k, local, at, r, r * 3.4, broadleaf, fract(jh * 13.7), leaves, scene);
            }
        }
    }

    // Avenues: trees planted along both edges of the road for long stretches, crowns clear of the carriageway, with
    // the odd gap, and none where a house or a street lamp stands.
    if (b.i.y > 0.0) {
        const float spacing = 9.0;
        float r0 = size * 0.36;
        float halfRoad = b.e.x * 0.5;
        float rx = roadX(world.y, scene, wander);
        if (abs(world.x - rx) < halfRoad + r0 * 3.0 + 2.0 + length(toward)
            && (riverHalf <= 0.25 || abs(riverDistance(world, scene, wander)) > riverHalf + 14.0)) {
            float j0 = floor((local.y + min(toward.y, 0.0) - r0 * 1.5) / spacing);
            float j1 = min(floor((local.y + max(toward.y, 0.0) + r0 * 1.5) / spacing), j0 + 5.0);
            for (int side = 0; side < 2; side++) {
                float sign = side == 0 ? -1.0 : 1.0;
                for (float j = j0; j <= j1; j += 1.0) {
                    float y = (j + 0.5) * spacing;
                    if (hash11(int(floor(y / 240.0)) * 2 + side, seed + 56u) >= b.i.y) continue;
                    float jh = hash11(int(j) * 2 + side, seed + 57u);
                    if (jh < 0.12) continue;
                    float village = villageAt(y, b, seed);
                    if (village > 0.5 && b.h.y > 0.0 && abs(fract(y / 34.0) - 0.5) * 34.0 < 4.5) continue;
                    float r = r0 * (0.85 + 0.3 * jh);
                    float worldY = y + shift.y;
                    float2 along = normalize(float2(roadSlope(worldY, scene, wander), 1.0));
                    float2 at = float2(roadX(worldY, scene, wander), worldY) - shift
                              + float2(along.y, -along.x) * sign * (halfRoad + r + 1.2 + (jh - 0.5) * 0.6);
                    if (riverHalf > 0.25 && abs(riverDistance(at + shift, scene, wander)) < riverHalf + b.i.w + r + 8.0) continue;
                    if (crossGap(at + shift, scene) < halfRoad * 0.9 + r + 2.5) continue;
                    if (railGap(at, b) < r + 3.0) continue;
                    if (!clearOfHouses(at + shift, at, r, b, scene, seed, wander)) continue;
                    plant(k, local, at, r, r * 2.4, broadleaf, fract(jh * 9.1), leaves, scene);
                }
            }
        }
    }
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
        // A soft pool under each window, blurring as it goes, rather than a beam.
        float spread = 0.6 + 0.12 * max(out, 0.0);
        glow = lit * fill(across - spread, 0.55 + 0.42 * max(out, 0.0)) * exp(-max(out, 0.0) / 2.1)
             * smoothstep(-0.3, 0.2, out) * 0.62;
    }
    float2 porch = float2(-size.x - 0.7, size.y * 0.35);
    float r = length(d - porch);
    float hasPorch = step(0.3, hash11(k, seed + 402u));
    float pool = pow(1.0 + r * r / 9.0, -1.5) * (1.0 - smoothstep(6.0, 10.0, r));
    glow = max(glow, pool * 0.6 * hasPorch);
    glow = max(glow, fill(r - 0.25, 0.15) * hasPorch);
    // Half the farms keep a yard lamp on a pole in the yard behind the house.
    float2 yard = float2(size.x + 4.0, size.y * 0.5);
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

// One house, with the yard worn round it and a path out towards the road: its shadow, a roof of courses and weather
// (gabled or hipped, some with a wing behind and a chimney, or flat with a stair head and a water tank), and most with
// a shed. After dark, the light it spills on the ground. `d` is in house-local metres.
inline float3 house(float3 c, float2 d, float angle, float2 size, int k, constant Biome &b, constant Scene &scene,
                    uint seed, thread float &cover, thread float &light, thread float &lightID) {
    float2 sun = rotate(scene.sun.xy, -angle);
    float2 shadowOff = -sun * scene.sun.z * 5.5;
    if (dot(d, d) > 700.0 + dot(shadowOff, shadowOff) * 2.0) return c;
    float pick = hash11(k, seed + 430u);
    float bare = 1.0 - 0.6 * b.f.y;
    float weather = vnoise(d / float2(2.6, 1.7) + float(k % 64) * 3.7, seed + 431u);

    // Ground trodden pale round the door.
    float yard = fill(sdBox(d, size + float2(2.2, 1.6)) - 2.2 * weather, 1.8);
    c = mix(c, mix(c, b.road.rgb, 0.3), yard * 0.28 * bare);

    bool flat = b.i.z > 0.5;
    bool winged = !flat && pick < 0.55;
    float2 wing = d - float2(size.x + 1.4, size.y * 0.55);
    float2 wingSize = float2(1.9, 2.3);
    float shadow = fill(sweptBox(d, size, shadowOff), 0.55);
    if (winged) shadow = max(shadow, fill(sweptBox(wing, wingSize, shadowOff), 0.55));
    c = shade(c, shadow * 0.72, scene);

    float3 roof = roofColor(b, hash11(k, seed + 66u)) * (0.9 + 0.2 * hash11(k, seed + 68u));
    roof = mix(roof, float3(luma(roof)), 0.1 + 0.16 * hash11(k, seed + 432u));
    float3 face;
    float2 e = size - abs(d);
    if (flat) {
        // A parapet that shades the roof inside it on the sun's side, damp stains, and a stair head and a water tank.
        face = pigment(roof, weather, 0.6) * (1.0 - 0.12 * fill(abs(sdBox(d, size)) - 0.35, 0.15));
        face = shade(face, fill(sdBox(d + sun * 0.7, size - 0.35) * -1.0, 0.2) * 0.3, scene);
        float2 stair = d - size * float2(-0.42, 0.42 * (pick < 0.5 ? 1.0 : -1.0));
        face = shade(face, fill(sweptBox(stair, float2(1.1, 1.4), shadowOff * 0.3), 0.2) * 0.6, scene);
        face = mix(face, roof * 1.1, fill(sdBox(stair, float2(1.1, 1.4)), 0.12));
        face = mix(face, hash11(k, seed + 69u) < 0.5 ? float3(0.16, 0.16, 0.18) : float3(0.93, 0.93, 0.9),
                   fill(length(d - size * float2(0.45, 0.5)) - 0.75, 0.15));
    } else {
        // Each slope takes the sun as it faces, and a hipped roof slopes at its ends too. Rows of tiles run along the
        // slope, and weather lies across them.
        bool hipped = hash11(k, seed + 433u) < 0.35;
        bool end = hipped && e.y < e.x;
        float facing = end ? sign(d.y) * sun.y : sign(d.x) * sun.x;
        // The lower the sun, the more one slope catches it than the other; at the usual afternoon sun, as it always was.
        face = pigment(roof * (0.93 + 0.303 * cos(scene.sun.w) * facing), weather, 0.7);
        face *= 1.0 + 0.07 * sin((end ? e.y : e.x) * 6.5);
        float crest = hipped ? min(abs(e.x - e.y), max(abs(d.x), abs(d.y) - (size.y - size.x))) : abs(d.x);
        face = mix(face, roof * 0.62, fill(crest - 0.1, 0.08));
        face *= 1.0 - 0.2 * fill(min(e.x, e.y) - 0.22, 0.12);
        // Snow lies on the slopes, which still take the light, and a line of roof shows along the eaves.
        float snowed = b.f.y * 0.85 * smoothstep(0.1, 0.5, min(e.x, e.y) + 0.3 * weather);
        face = mix(face, b.snow.rgb * (0.9 + 0.17 * facing + 0.06 * weather), snowed);
        if (pick > 0.25) {
            // A chimney, with its shadow across the slope.
            float2 stack = d - size * float2(0.3 * sign(pick - 0.6), 0.75 * pick - 0.3);
            face = shade(face, fill(sweptBox(stack, float2(0.42, 0.5), shadowOff * 0.35), 0.15) * 0.65, scene);
            face = mix(face, float3(0.33, 0.27, 0.24), fill(sdBox(stack, float2(0.42, 0.5)), 0.1));
        }
    }
    if (flat) face = mix(face, b.snow.rgb * (0.9 + 0.1 * weather), b.f.y * 0.8);
    float a = fill(sdBox(d, size), 0.3);
    cover = max(cover, a);
    if (winged) {
        // Its ridge runs across the house's, so its slopes face along it.
        float3 slope = pigment(roof * (0.93 + 0.2 * sign(wing.y) * sun.y), weather, 0.7) * (1.0 + 0.07 * sin(wing.y * 6.5));
        slope = mix(slope, roof * 0.62, fill(abs(wing.y) - 0.09, 0.07));
        slope = mix(slope, b.snow.rgb * (0.9 + 0.17 * sign(wing.y) * sun.y + 0.06 * weather), b.f.y * 0.85);
        float w = fill(sdBox(wing, wingSize), 0.3);
        c = mix(c, slope, w * (1.0 - a));
        cover = max(cover, w);
    }
    c = mix(c, face, a);

    // Most have a shed out the back: corrugated, rust or grey, or roofed like the house.
    float shedCover = 0.0;
    if (pick < 0.9) {
        float2 shed = d - float2(size.x + 3.5, -size.y * 0.4);
        float2 shedSize = float2(1.5, 1.9) + 0.7 * hash11(k, seed + 434u);
        c = shade(c, fill(sweptBox(shed, shedSize, shadowOff * 0.6), 0.4) * 0.62, scene);
        shedCover = fill(sdBox(shed, shedSize), 0.25);
        float tint = hash11(k, seed + 435u);
        float3 tin = tint < 0.45 ? float3(0.52, 0.51, 0.5) : tint < 0.75 ? float3(0.5, 0.36, 0.28) : roof * 0.88;
        tin = pigment(tin * (1.0 + 0.09 * sin(shed.y * 11.0)), weather, 0.8) * (0.93 + 0.14 * step(0.0, shed.x * sun.x));
        c = mix(c, mix(tin, b.snow.rgb, b.f.y * 0.8), shedCover);
    }
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
                          float2 wander, thread float &light, thread float &lightID) {
    if (b.h.y <= 0.0 || b.i.x <= 0.0) return c;
    const float spacing = 34.0, height = 7.0;
    float roadHalf = b.e.x * 0.5;
    float j0 = floor(local.y / spacing);
    float pools = 0.0, head = 0.0, strongest = 0.0, chosen = 0.0;
    float2 shadow = -scene.sun.xy * scene.sun.z * height;
    for (int dj = -1; dj <= 1; dj++) {
        float j = j0 + float(dj);
        float y = (j + 0.5) * spacing;
        float village = villageAt(y, b, seed);
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
        pool *= 1.0 - smoothstep(13.0, 20.0, sqrt(r2) + 2.5 * (vnoise(local / 3.0, seed + 411u) - 0.5));
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
                     float2 wander, thread Canopy &trees, thread float &cover, thread float &light, thread float &lightID) {
    if (b.e.w <= 0.0 && b.i.x <= 0.0) return c;
    float rx0 = roadX(world.y, scene, wander);
    if (abs(world.x - rx0) > b.e.x * 0.5 + 95.0) return c;
    float side = world.x > rx0 ? 1.0 : -1.0;
    float k0 = floor(local.y / 30.0);
    for (int dk = -1; dk <= 1; dk++) {
        for (int row = 0; row < 2; row++) {
            Plot h;
            if (!plot(h, k0 + float(dk), row, side, world, local, b, scene, seed, wander)) continue;
            // Its way out comes first, under the house, and reaches further than the house looks.
            float path = fill(pathGap(rotate(world - h.center, -h.road), h) - 0.6, 0.35) * (1.0 - 0.6 * b.f.y);
            c = mix(c, mix(c, b.road.rgb, 0.72), path);
            c = house(c, rotate(world - h.center, -h.angle), h.angle, h.size, h.id, b, scene, seed, cover, light, lightID);
            // Where homesteads keep a windbreak, an L of dark evergreens behind and beside the house.
            if (b.l.x > 0.5 && hash11(h.id, seed + 71u) < 0.85) {
                for (int t = 0; t < 4; t++) {
                    float tr = 2.4 + 1.0 * hash11(h.id * 4 + t, seed + 76u);
                    float2 offset = t < 3 ? float2(h.size.x + 6.2 + tr, h.size.y * (0.9 - 0.9 * float(t)))
                                          : float2(h.size.x * 0.2, h.size.y + 2.0 + tr);
                    float2 at = h.center + rotate(offset, h.angle) - (world - local);
                    plant(trees, local, at, tr, tr * 3.4, broadleaf, hash11(h.id * 4 + t, seed + 77u), cedar, scene);
                }
                continue;
            }
            // A garden tree behind village houses, on the far side from the shed, short of the next row.
            if (h.village > 0.3 && hash11(h.id, seed + 71u) < 0.6) {
                float r = 2.4 + 1.4 * hash11(h.id, seed + 74u);
                float2 offset = float2(h.size.x + 3.6 + r + 1.0 * hash11(h.id, seed + 72u),
                                       h.size.y * (0.15 + 0.4 * hash11(h.id, seed + 73u)));
                float2 at = h.center + rotate(offset, h.angle) - (world - local);
                plant(trees, local, at, r, r * 2.5, broadleaf, hash11(h.id, seed + 75u), leaves, scene);
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
                       constant Scene &scene, uint seed, float2 wander, float riverHalf, thread Canopy &trees,
                       thread float &herd, thread float &water, thread float &cover, thread float &light,
                       thread float &lightID) {
    float2 center;
    int2 id2;
    if (!landmarkSite(kind, density, local, b, seed, center, id2)) return c;
    float radius = landmarkRadius(kind);
    uint s = seed + uint(kind) * 131u;
    int id = id2.x * 7919 + id2.y;
    float2 d = local - center;
    float bound = radius * 1.3 + trees.reach;
    if (dot(d, d) > bound * bound) return c;
    if (!landmarkStands(kind, world + (center - local), world - local, b, scene, riverHalf, wander, seed)) return c;
    float angle = hash21(id2, s + 2u) * 6.283;
    float2 r = rotate(d, -angle);

    if (kind == markKopje) {
        c = boulders(c, d, radius * (0.6 + 0.5 * hash21(id2, s + 3u)), id, b, scene, s, herd);
        for (int i = 0; i < 3; i++) {
            float2 at = (hash22(int2(id, i + 20), s + 4u) - 0.5) * radius * 1.4;
            float tr = 4.0 + 3.0 * hash11(id * 3 + i, s + 5u);
            plant(trees, local, center + at, tr, tr * 2.2, broadleaf, hash11(id * 3 + i, s + 6u), leaves, scene);
        }
    } else if (kind == markWaterPoint) {
        // Cattle trails fan out from the water, the ground trampled bare round it.
        // The trails stop short of the road's fences and the river's banks.
        float len = length(d);
        float fenced = smoothstep(b.e.x * 0.5 + 3.0, b.e.x * 0.5 + 9.0, abs(roadDistance(world, scene, wander)));
        if (riverHalf > 0.25) {
            fenced *= smoothstep(riverHalf + 4.0, riverHalf + 12.0, abs(riverDistance(world, scene, wander)));
        }
        float ragged = len + 9.0 * (fbm(d / 11.0, 2, s + 6u) - 0.5);
        float bare = (1.0 - smoothstep(18.0, 46.0, ragged)) * fenced;
        float3 dust = mix(float3(0.71, 0.62, 0.45), float3(0.62, 0.55, 0.40), vnoise(d / 3.0, s + 8u));
        c = mix(c, mix(c, dust, 0.6), smoothstep(30.0, 60.0, ragged) * (1.0 - smoothstep(60.0, 85.0, ragged)) * 0.5 * fenced);
        c = mix(c, dust, bare * 0.85);
        float a = atan2(d.y, d.x);
        float n = 9.0;
        float sector = floor(a / 6.283 * n);
        float trail = (sector + 0.5) * 6.283 / n + (hash11(int(sector) + id, s + 7u) - 0.5) * 0.4
                    + 0.05 * sin(len / 13.0 + sector);
        float across = len * abs(sin(a - trail));
        float reach = 90.0 + 50.0 * hash11(int(sector) + id, s + 9u);
        c = mix(c, float3(0.74, 0.66, 0.5), fill(across - 0.6, 0.4) * smoothstep(30.0, 40.0, len)
                * (1.0 - smoothstep(reach - 40.0, reach, len)) * 0.7 * fenced);
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
        // An estancia: the house and its sheds in a mown clearing, sheltered by eucalyptus planted in rows on three
        // sides and left open to the north, where the track comes in.
        float outer = radius * 0.72;
        float2 yard = float2(radius * 0.08, -radius * 0.02);
        float2 yardHalf = float2(radius * 0.36, radius * 0.27);
        float clearing = sdBox(r - yard, yardHalf);
        float shelter = sdBox(r, float2(outer)) + 10.0 * (vnoise(r / 18.0, s + 8u) - 0.5);
        float open = smoothstep(yard.y - 4.0, yard.y + 4.0, r.y) * fill(abs(r.x - yard.x) - yardHalf.x, 3.0);
        float litter = fill(shelter + 3.0, 2.0) * (1.0 - fill(clearing - 4.0, 4.0)) * (1.0 - open);
        c = mix(c, float3(0.43, 0.40, 0.31) * (0.9 + 0.2 * vnoise(r / 2.5, s + 10u)), litter * 0.75);
        c = mix(c, c * float3(1.06, 1.08, 0.94), fill(clearing, 2.0) * 0.6);
        herd *= 1.0 - fill(shelter - 4.0, 2.0);
        const float spacing = 5.5;
        float2 u = rotate(scene.sun.xy, -angle);
        int2 lo, hi;
        window(r, spacing, 8.0, u * trees.reach, lo, hi);
        for (int y = lo.y; y <= hi.y; y++) {
            for (int x = lo.x; x <= hi.x; x++) {
                int2 cell = int2(x, y);
                float2 at = (float2(cell) + 0.5) * spacing + (hash22(cell, s + 11u) - 0.5) * 1.2;
                bool open = at.y > yard.y && abs(at.x - yard.x) < yardHalf.x;
                if (open || sdBox(at - yard, yardHalf) < 3.0 || hash21(cell, s + 12u) > 0.93) continue;
                if (sdBox(at, float2(outer)) + 10.0 * (vnoise(at / 18.0, s + 8u) - 0.5) > -2.0) continue;
                float tr = 2.6 + 1.2 * hash21(cell, s + 13u);
                plant(trees, local, center + rotate(at, angle), tr, tr * (5.0 + 1.5 * hash21(cell, s + 14u)), pine,
                      hash21(cell, s + 15u), eucalyptus, scene);
            }
        }
        c = house(c, r - float2(radius * 0.18, radius * 0.05), angle, float2(5.0, 8.0), id, b, scene, s, cover, light,
                  lightID);
        float2 shed = r - float2(radius * 0.0, -radius * 0.14);
        float2 shedShadow = rotate(-scene.sun.xy, -angle) * scene.sun.z * 4.5;
        c = shade(c, fill(sweptBox(shed, float2(9.0, 5.0), shedShadow), 0.4) * 0.65, scene);
        c = mix(c, float3(0.72, 0.73, 0.74), fill(sdBox(shed, float2(9.0, 5.0)), 0.3));
        // A round corral of posts beside the sheds.
        float corral = abs(length(r - float2(-radius * 0.18, -radius * 0.12)) - 9.0);
        c = mix(c, float3(0.6, 0.52, 0.4), fill(length(r - float2(-radius * 0.18, -radius * 0.12)) - 9.0, 1.0) * 0.6);
        c = mix(c, float3(0.38, 0.32, 0.26), fill(corral - 0.2, 0.12));
    } else if (kind == markFarmstead) {
        // House, metal sheds and steel grain bins, sheltered by rows of dark cedar in an L to the north and west.
        float2 q = d;
        float2 westBar = float2(-radius * 0.55, 0.0), northBar = float2(0.0, radius * 0.55);
        float2 westHalf = float2(9.0, radius * 0.6), northHalf = float2(radius * 0.6, 9.0);
        const float spacing = 4.5;
        int2 lo, hi;
        window(q, spacing, 6.0, scene.sun.xy * trees.reach, lo, hi);
        for (int y = lo.y; y <= hi.y; y++) {
            for (int x = lo.x; x <= hi.x; x++) {
                int2 cell = int2(x, y);
                float2 at = (float2(cell) + 0.5) * spacing + (hash22(cell, s + 11u) - 0.5) * 1.0;
                if (min(sdBox(at - westBar, westHalf), sdBox(at - northBar, northHalf)) > 0.0) continue;
                if (hash21(cell, s + 12u) > 0.9) continue;
                float tr = 1.9 + 0.8 * hash21(cell, s + 13u);
                plant(trees, local, center + at, tr, tr * 4.2, spruce, hash21(cell, s + 14u), cedar, scene);
            }
        }
        c = house(c, q - float2(-10.0, 18.0), 0.0, float2(5.0, 7.5), id, b, scene, s, cover, light, lightID);
        float2 sunOff = -scene.sun.xy * scene.sun.z;
        for (int i = 0; i < 2; i++) {
            float2 shed = q - float2(14.0 + 8.0 * float(i), -8.0 - 22.0 * float(i));
            c = shade(c, fill(sweptBox(shed, float2(8.0, 15.0), sunOff * 6.0), 0.5) * 0.7, scene);
            c = mix(c, float3(0.80, 0.81, 0.82) * (0.94 + 0.08 * float(i)), fill(sdBox(shed, float2(8.0, 15.0)), 0.3));
        }
        for (int i = 0; i < 4; i++) {
            float2 bin = q - float2(-12.0 + 9.0 * float(i), -32.0);
            float br = 3.8;
            c = shade(c, fill(segmentDistance(bin, 0.0, sunOff * 9.0) - br, 0.6) * 0.7, scene);
            float lit = saturate(dot(normalize(bin + 1e-4), scene.sun.xy) * 0.5 + 0.5);
            c = mix(c, float3(0.70, 0.72, 0.74) * (0.8 + 0.35 * lit), fill(length(bin) - br, 0.25));
            c = mix(c, float3(0.9, 0.9, 0.9), fill(length(bin) - 0.6, 0.15));
        }
        herd *= 1.0 - fill(length(q) - radius, 4.0);
    } else if (kind == markTubeWell) {
        // A tiny brick room with a tank beside it and a big shade tree.
        float2 q = r;
        c = shade(c, fill(sweptBox(q, float2(1.8), -rotate(scene.sun.xy, -angle) * scene.sun.z * 3.0), 0.3) * 0.7, scene);
        c = mix(c, float3(0.83, 0.74, 0.62), fill(sdBox(q, float2(1.8)), 0.15));
        c = mix(c, float3(0.42, 0.55, 0.62), fill(sdBox(q - float2(3.4, 0.0), float2(1.2, 1.6)), 0.15));
        plant(trees, local, center + rotate(float2(-4.0, 3.5), angle), 4.5, 10.0, broadleaf, hash21(id2, s + 3u),
              leaves, scene);
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
        // A Venlo glasshouse: bay after bay of low glass ridges 4 m apart, one slope of each turned to the sun and the
        // other away from it, a gutter between each pair, whole blocks of it chalked white against the sun, and a round
        // heat tank and a boiler house at one end.
        float2 q = r;
        float2 extent = float2(radius * 0.8, radius * 0.5);
        float2 sun = rotate(scene.sun.xy, -angle);
        float2 away = -sun * scene.sun.z;
        c = shade(c, fill(sweptBox(q, extent, away * 5.0), 0.5) * 0.65, scene);
        float2 tank = q - float2(extent.x + 10.0, -extent.y * 0.45);
        float2 boiler = q - float2(extent.x + 9.0, -extent.y * 0.45 + 17.0);
        c = shade(c, fill(segmentDistance(tank, 0.0, away * 9.0) - 5.5, 0.5) * 0.65, scene);
        c = shade(c, fill(sweptBox(boiler, float2(5.0, 7.0), away * 5.0), 0.4) * 0.65, scene);
        float panel = fill(sdBox(q, extent), 0.3);
        if (panel > 0.0) {
            const float bay = 4.0;
            float span = q.x / bay;
            float f = fract(span) - 0.5;
            float elevation = max(scene.sun.w, 0.15);
            // Each slope is pitched 22 degrees, towards the gutter on its own side.
            float lit = 0.375 * sign(f) * sun.x * cos(elevation) + 0.927 * sin(elevation);
            int2 block = int2(int(floor(span / 9.0)), q.y > 0.0 ? 1 : 0);
            float chalked = step(0.55, hash21(block + id2 * 7, s + 14u));
            float3 glass = mix(float3(0.66, 0.77, 0.78), float3(0.9, 0.93, 0.92), chalked) * (0.74 + 0.36 * lit);
            glass *= 0.97 + 0.06 * vnoise(float2(floor(span), q.y / 30.0), s + 15u);
            // Roof vents propped open here and there along the ridges, the glazing bars, the ridge and the gutter.
            float vent = step(0.72, hash21(int2(int(floor(span)), int(floor(q.y / 7.0))), s + 16u))
                       * fill(abs(abs(f) - 0.14) * bay - 0.38, 0.1) * fill(abs(fract(q.y / 7.0) - 0.5) * 7.0 - 1.2, 0.15);
            glass *= 1.0 - 0.16 * vent;
            glass *= 1.0 - 0.05 * fill(abs(fract(q.y / 4.5) - 0.5) * 4.5 - 0.08, 0.08);
            glass = mix(glass, float3(0.95, 0.96, 0.96), fill(abs(f) * bay - 0.1, 0.08) * 0.6);
            glass = mix(glass, float3(0.36, 0.41, 0.42), fill((0.5 - abs(f)) * bay - 0.16, 0.1) * 0.8);
            // The path the trolleys run on, seen through the glass across the middle of every bay.
            glass = mix(glass, glass * 0.9 + 0.05, fill(abs(q.y) - 1.6, 0.3) * 0.7);
            c = mix(c, glass, panel);
        }
        float round = saturate(dot(normalize(tank + 1e-4), scene.sun.xy) * 0.5 + 0.5);
        c = mix(c, float3(0.74, 0.76, 0.77) * (0.82 + 0.3 * round), fill(length(tank) - 5.5, 0.25));
        c = mix(c, float3(0.86, 0.87, 0.87), fill(length(tank) - 0.7, 0.2));
        float shed = fill(sdBox(boiler, float2(5.0, 7.0)), 0.25);
        c = mix(c, float3(0.5, 0.52, 0.54) * (1.0 + 0.1 * sign(boiler.x) * sun.x), shed);
        float built = max(panel, max(shed, fill(length(tank) - 5.5, 0.25)));
        cover = max(cover, built);
        herd *= 1.0 - built;
    } else if (kind == markWindmill) {
        // A polder mill: an eight-sided thatched tower 12 m to the cap, standing in its own mown yard. The cap is turned
        // into the wind, with the sails before it turning in an upright plane square to the wind, so from above they
        // are a thin bar across it, and the tail pole runs down behind to the ground. Their shadow is the cross they
        // make, thrown out along the sun from the hub.
        float2 q = r;
        float2 sunLocal = rotate(scene.sun.xy, -angle);
        float2 toSun = sunLocal * scene.sun.z;
        float2 across = rotate(normalize(float2(-0.55, 1.3)), -angle);
        float2 downwind = float2(across.y, -across.x);
        float2 hub = -downwind * 2.8;
        float yard = length(q) - 11.0 + 3.0 * (vnoise(q / 5.0, s + 3u) - 0.5);
        c = mix(c, b.ground.rgb * (0.94 + 0.08 * vnoise(q / 2.0, s + 4u)), fill(yard, 1.2));
        float sailShadow = 1e9;
        for (int i = 0; i < 4; i++) {
            float turn = float(i) * 1.5708 + 0.4;
            float2 from = hub + across * cos(turn) * 1.5 - toSun * (12.0 + sin(turn) * 1.5);
            float2 to = hub + across * cos(turn) * 12.0 - toSun * (12.0 + sin(turn) * 12.0);
            sailShadow = min(sailShadow, segmentDistance(q, from, to) - 0.8);
        }
        // The tower narrows as it rises, and so does its shadow.
        float2 fall = -toSun * 12.0;
        float up = saturate(dot(q, fall) / max(dot(fall, fall), 1e-4));
        c = shade(c, fill(length(q - fall * up) - mix(4.2, 2.7, up), 0.5) * 0.7, scene);
        c = shade(c, fill(sailShadow, 0.4) * 0.55, scene);
        float around = atan2(q.y, q.x);
        float facet = floor(around / 0.7854 + 0.5) * 0.7854;
        float wall = length(q) * cos(around - facet) - 4.2;
        float elevation = max(scene.sun.w, 0.15);
        float lit = dot(float2(cos(facet), sin(facet)), sunLocal) * cos(elevation);
        float3 thatch = float3(0.40, 0.33, 0.27) * (0.82 + 0.3 * lit) * (0.95 + 0.1 * vnoise(q / 0.8, s + 5u));
        c = mix(c, thatch, fill(wall, 0.25));
        // The cap, longer along the wind than across it, and a shade paler on its sunward side.
        float2 capAt = float2(dot(q + downwind * 0.4, downwind), dot(q, across));
        float cap = length(capAt / float2(3.3, 2.3)) - 1.0;
        float3 capColour = float3(0.3, 0.26, 0.23) * (0.9 + 0.25 * saturate(dot(normalize(q + 1e-4), sunLocal)));
        c = mix(c, capColour, fill(cap * 2.3, 0.2));
        c = mix(c, float3(0.8, 0.79, 0.75), fill(segmentDistance(q, downwind * 2.0, downwind * 9.0) - 0.16, 0.14) * 0.85);
        c = mix(c, float3(0.9, 0.89, 0.85), fill(segmentDistance(q, hub - across * 12.0, hub + across * 12.0) - 0.42, 0.2) * 0.92);
        c = mix(c, float3(0.25, 0.22, 0.2), fill(length(q - hub) - 0.55, 0.15));
        cover = max(cover, fill(wall, 0.25));
        herd *= 1.0 - fill(yard, 1.2);
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
        float shape = lakeShore(d, radius, s);
        float wet = fill(shape, 0.02);
        // One body of colour under long slow washes, paling only in a thin ragged margin, and in the shade of its shore
        // on the sun's side, like the river.
        float frozen = b.f.z;
        float3 deep = frozen > 0.5 ? mix(b.snow.rgb, float3(0.72, 0.8, 0.88), 0.4) : b.water.rgb;
        deep = pigment(deep, vnoise(d / float2(46.0, 21.0), s + 21u), 0.5 * (1.0 - frozen));
        float margin = 0.035 * (0.6 + 0.8 * vnoise(d / 19.0, s + 22u));
        float3 lake = mix(deep, b.shallows.rgb, smoothstep(-margin, 0.0, shape) * (1.0 - frozen * 0.5));
        float shaded = fill(lakeShore(d + scene.sun.xy * scene.sun.z * 3.0, radius, s) * -1.0, 0.012);
        lake = shade(lake, shaded * 0.45 * (1.0 - frozen), scene);
        c = mix(c, b.sand.rgb, fill(shape - 0.05, 0.02) * (1.0 - b.f.y * 0.6));
        c = mix(c, lake, wet);
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

// Ponds, and on the pampa shallow lagunas: turbid water, a pale rim of salt and dried mud where the water has drawn
// back, and a ring of rushes round it.
inline float3 ponds(float3 c, float2 local, float2 world, constant Biome &b, constant Scene &scene, uint seed,
                    float2 wander, thread float &water, thread float &herd) {
    float2 center;
    float r;
    if (!pondSite(local, b, seed, center, r)) return c;
    float size = max(b.k.w, 1.0);
    float2 d = local - center;
    if (dot(d, d) > r * r * 4.0) return c;
    if (!pondStands(center, r, world - local, b, scene, wander)) return c;
    float shape = length(d * float2(1.0, 1.25)) / r - 1.0 + 0.45 * (fbm(local / (16.0 * size), 3, seed + 83u) - 0.5);
    float dist = shape * r;
    float3 deep = b.f.z > 0.5 ? mix(b.snow.rgb, b.shallows.rgb, 0.35) : b.water.rgb;
    float3 shallow = b.f.z > 0.5 ? b.snow.rgb : b.shallows.rgb;
    float3 pond = mix(pigment(deep, vnoise(local / 21.0, seed + 87u), 0.45 * (1.0 - b.f.z)), shallow, smoothstep(-r * 0.2, 0.0, dist));
    if (size > 1.5) {
        float rim = 5.0 + 0.12 * r * (0.6 + 0.8 * vnoise(d / 30.0, seed + 84u));
        float3 reeds = c * float3(0.78, 0.9, 0.7) * (0.9 + 0.2 * vnoise(local / 2.0, seed + 85u));
        c = mix(c, reeds, fill(abs(dist - rim - 4.0) - 3.0, 1.5) * 0.8);
        float3 salt = mix(float3(0.9, 0.88, 0.82), b.sand.rgb, 0.3 + 0.4 * vnoise(local / 9.0, seed + 86u));
        c = mix(c, salt, fill(dist - rim, 1.5));
        herd *= 1.0 - fill(dist - rim, 1.5);
    } else {
        c = mix(c, b.sand.rgb * 0.95, fill(dist - 2.2, 0.6) * (1.0 - b.f.y * 0.7));
    }
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

// A track out to the road from a farm, kiln, feedlot, estancia, water point or corral, which would otherwise stand in the
// middle of a field with no way to it: a pale rutted line straight to the main road along the line between two house
// plots, which no house reaches, so where there are homes it is their lane. In pivot country it runs down the quarter
// line between the circles to the section road. Where a river lies between, there is none rather than a ford.
inline float3 landmarkTrack(float3 c, int kind, float density, float2 local, float2 world, constant Biome &b,
                            constant Scene &scene, uint seed, float2 wander, float riverHalf, thread float &herd) {
    if (kind != markFarmstead && kind != markKiln && kind != markFeedlot && kind != markGrove
        && kind != markWaterPoint && kind != markCorral) return c;
    float2 shift = world - local;
    float d = 1e6;
    if (int(b.a.x) == layoutPivots) {
        float mile = b.a.y * 2.0;
        float2 grid = float2(b.l.y, 0.0);
        float2 middle = (floor((local - grid) / mile) + 0.5) * mile + grid;
        if (abs(local.x - middle.x) > 4.0 || local.y > middle.y) return c;
        float2 center;
        int2 id;
        if (!landmarkSite(kind, density, middle, b, seed, center, id) || length(center - middle) > 1.0) return c;
        if (!landmarkStands(kind, center + shift, shift, b, scene, riverHalf, wander, seed)) return c;
        d = abs(local.x - middle.x);
    } else {
        float cell = landmarkCell(kind);
        for (int i = -1; i <= 1; i++) {
            float2 center;
            int2 id;
            if (!landmarkSite(kind, density, local + float2(float(i) * cell, 0.0), b, seed, center, id)) continue;
            float lineY = round(center.y / 30.0) * 30.0;
            if (abs(local.y - lineY) > 4.0 && (abs(local.x - center.x) > 4.0 || (local.y - center.y) * (local.y - lineY) > 0.0)) {
                continue;
            }
            float2 centerWorld = center + shift;
            float rx = roadX(lineY + shift.y, scene, wander) - shift.x;
            // Each pixel looks for its landmark a cell either side, so a track runs only as far as that, whole or not at all.
            if (abs(rx - center.x) > cell) continue;
            if (riverHalf > 0.25) {
                float riverAt = riverX(lineY + shift.y, scene, wander) - shift.x;
                if ((riverAt - center.x) * (riverAt - rx) < 0.0) continue;
            }
            if (!landmarkStands(kind, centerWorld, shift, b, scene, riverHalf, wander, seed)) continue;
            // Out along the plot line to the road, and a short spur from the yard to it.
            float along = (local.x - center.x) * sign(rx - center.x);
            if (along >= 0.0 && along <= abs(rx - center.x)) d = min(d, abs(local.y - lineY));
            if (abs(local.x - center.x) < 4.0 && (local.y - center.y) * (local.y - lineY) <= 0.0) {
                d = min(d, abs(local.x - center.x));
            }
        }
    }
    if (d > 3.0) return c;
    // Two wheel ruts in a worn strip, paler where nothing grows.
    float worn = fill(d - 1.7, 0.5);
    float3 dirt = mix(c, b.road.rgb * (0.92 + 0.12 * vnoise(local / 1.3, seed + 81u)), 0.55);
    c = mix(c, dirt, worn);
    c = mix(c, c * 0.86, fill(abs(d - 0.75) - 0.22, 0.2) * worn);
    herd *= 1.0 - worn;
    return c;
}

// The crown of a hedge nearest `p`, as a share of its radius, with its radius, where `p` lies from its middle, and its
// tone.
inline float hedgeCrowns(float2 p, float crownSize, uint seed, thread float &radius, thread float2 &offset,
                         thread float &tone) {
    float2 g = floor(p / crownSize);
    float nearest = 1e9;
    radius = 1.0; offset = 0.0; tone = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            int2 cell = int2(g) + int2(i, j);
            float r = crownSize * (0.62 + 0.38 * hash21(cell, seed + 17u));
            float2 q = p - (float2(cell) + 0.15 + 0.7 * hash22(cell, seed + 18u)) * crownSize;
            float dist = length(q) / r;
            if (dist < nearest) { nearest = dist; radius = r; offset = q; tone = hash21(cell, seed + 19u); }
        }
    }
    return nearest;
}

// The oak nearest `p` among those standing out of the hedge: how far `p` is from its trunk as a share of its crown's
// radius, where `p` lies from the trunk, and its tone. `oaks` of the hedge's crowns are marked to be one, and of those
// only the ones whose trunk is in a hedge stand, each deciding that from where its own trunk is. So a crown is whole
// wherever it reaches out over the field, and its shadow is the shadow of that same tree. `shift` is from the leg's own
// metres to the world's.
inline float hedgeOak(float2 p, float2 shift, float crownSize, float oaks, constant Biome &b, constant Scene &scene,
                      uint seed, float riverHalf, float2 wander, thread float2 &offset, thread float &tone) {
    float2 g = floor(p / crownSize);
    float nearest = 1e9;
    offset = 0.0; tone = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            int2 cell = int2(g) + int2(i, j);
            float pick = hash21(cell, seed + 20u);
            if (pick >= oaks) continue;
            float2 trunk = (float2(cell) + 0.15 + 0.7 * hash22(cell, seed + 18u)) * crownSize;
            float dist = length(p - trunk) / (crownSize * 1.1);
            if (dist >= min(nearest, 1.04)) continue;
            if (voronoi(fieldSpace(trunk, b, seed), seed).border * b.a.y > crownSize * 0.5) continue;
            // Nor does one stand where its crown would hang over the road, the river or the railway.
            float reach = crownSize * 1.15;
            float2 at = trunk + shift;
            if (abs(roadDistance(at, scene, wander)) < b.e.x * 0.5 + reach) continue;
            if (riverHalf > 0.25 && abs(riverDistance(at, scene, wander)) < riverHalf + b.i.w + reach) continue;
            if (crossGap(at, scene) < b.e.x * 0.45 + reach || railGap(trunk, b) < reach + 2.0) continue;
            nearest = dist; offset = p - trunk; tone = pick / oaks;
        }
    }
    return nearest;
}

inline Land fields(float2 p, float2 world, constant Biome &b, constant Scene &scene, uint seed, float riverHalf,
                   float2 wander) {
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

    // Orchards: grass under rows of small trees in some fields, the rows turned with the field.
    if (hash21(v.cell, seed + 10u) < b.d.x && fallow >= b.b.x) {
        l.color = openGround(p, b, seed);
        const float spacing = 8.5;
        float rMax = b.c.z * 0.35;
        Canopy orchard = canopy(9.0);
        float2 u = rotate(scene.sun.xy, angle);
        int2 lo, hi;
        window(q, spacing, rMax * 2.0, u * 9.0, lo, hi);
        int foliage = b.blossom.w > 0.5 ? flowers : leaves;
        Keepouts near = keepouts(world, p, spacing * 2.5 + 9.0, b, scene, seed, riverHalf, wander);
        float2 shift = world - p;
        for (int y = lo.y; y <= hi.y; y++) {
            for (int x = lo.x; x <= hi.x; x++) {
                int2 cell = int2(x, y);
                if (hash21(cell, seed + 11u) > 0.88) continue;
                float2 centre = (float2(cell) + 0.5) * spacing + (hash22(cell, seed + 12u) - 0.5) * 1.6;
                float r = b.c.z * 0.3 * (0.85 + 0.3 * hash21(cell, seed + 13u));
                float2 at = rotate(centre, -angle);
                if (near.river && abs(riverDistance(at + shift, scene, wander)) < riverHalf + b.i.w + r + 5.0) continue;
                if (near.road && (abs(roadDistance(at + shift, scene, wander)) < b.e.x * 0.5 + r + 1.5
                                  || !clearOfHouses(at + shift, at, r, b, scene, seed, wander))) continue;
                if (near.crossNear && crossGap(at + shift, scene) < b.e.x * 0.45 + r + 1.5) continue;
                if (near.rail && railGap(at, b) < r + 2.5) continue;
                // Fallen petals in the grass round trees in flower.
                if (b.d.y > 0.0 && b.blossom.w > 0.5) {
                    float near = 1.0 - smoothstep(r, r * 2.4, length(p - at));
                    l.color = mix(l.color, b.blossomLight.rgb * 1.03, petals(p, 0.3 * b.d.y * near, seed));
                }
                plant(orchard, p, at, r, r * 2.2, broadleaf, hash21(cell, seed + 14u), foliage, scene);
            }
        }
        float trees = 0.0;
        l.color = grow(orchard, l.color, p, b, scene, seed, trees);
        l.sway = b.b.w * 0.3 * (1.0 - trees);
        l.herd = 0.0;
    }

    // Hedge shadow, sampled where the sun would see the hedge from.
    float2 toSun = scene.sun.xy * scene.sun.z * (2.5 + b.a.z * 0.45);
    Cells vs = voronoi(fieldSpace(p + toSun, b, seed), seed);
    Cells halfway = voronoi(fieldSpace(p + toSun * 0.5, b, seed), seed);
    float shadowEdge = min(vs.border * size - hedgeHalfWidth(p + toSun, b, seed),
                           halfway.border * size - hedgeHalfWidth(p + toSun * 0.5, b, seed));
    l.color = shade(l.color, fill(shadowEdge, 1.2) * 0.8, scene);

    // Here and there an oak stands out of the hedge, as in bocage: a round crown twice the width of the shrubs and
    // twice as tall, reaching out over the field. Its shadow is its crown's, thrown from 9 m up, far enough to run on
    // out of the hedge's own.
    float crownSize = 3.0 + b.a.z * 0.25;
    float oaks = b.c.w * 0.15;
    float oakRadius = crownSize * 1.1;
    if (oaks > 0.0) {
        float2 offset;
        float tone;
        float nearest = hedgeOak(p + scene.sun.xy * scene.sun.z * 9.0, world - p, crownSize, oaks, b, scene, seed, riverHalf, wander,
                                 offset, tone);
        l.color = shade(l.color, fill((nearest - 0.82) * oakRadius, 0.2 * oakRadius) * 0.8, scene);
    }

    if (border < hw + 2.5) {
        // The hedge from above: a line of tree crowns, each lit on its sunward side, dark in the gaps between them,
        // its edge bulging where a crown leans out.
        float radius, tone;
        float2 offset;
        float nearest = hedgeCrowns(p, crownSize, seed, radius, offset, tone);
        float elevation = max(scene.sun.w, 0.15);
        float3 sun = float3(scene.sun.xy * cos(elevation), sin(elevation));
        float3 n = normalize(float3(offset / radius, sqrt(saturate(1.0 - nearest * nearest)) * 1.2));
        float2 hp = rotate(offset, tone * 6.283) / radius * 2.4 + tone * 31.0;
        float clump = vnoise(hp, seed + 14u);
        float bump = vnoise(hp + scene.sun.xy * 0.3, seed + 14u) - clump;
        float3 hedge = mix(b.hedge.rgb * 0.6, mix(b.hedge.rgb, b.canopyLight.rgb, 0.35) * 1.15,
                           saturate(0.55 * dot(n, sun) + 0.15 + 1.4 * bump + 0.2 * (clump - 0.5)));
        hedge *= (0.9 + 0.2 * tone) * mix(0.55, 1.0, smoothstep(1.1, 0.75, nearest));
        hedge = mix(hedge, b.snow.rgb * 0.9, b.f.y * 0.5 * smoothstep(0.5, 0.75, clump));
        float bulge = (1.0 - saturate(nearest)) * 2.0 - 0.6;
        l.color = mix(l.color, hedge, fill(border - hw - bulge, 0.45));
        l.forest = fill(border - hw, 0.55);
        l.sway = mix(l.sway, 0.15, fill(border - hw, 0.55));
        l.herd = 0.0;
        l.water *= 1.0 - fill(border - hw, 0.55);
    }
    if (oaks > 0.0 && border < crownSize * 1.7) {
        // The oak itself, over the hedge and the field's edge: lit as any tree is, its outline as ragged.
        float2 at;
        float tone;
        float oak = hedgeOak(p, world - p, crownSize, oaks, b, scene, seed, riverHalf, wander, at, tone);
        float a = atan2(at.y, at.x);
        float lobes = 0.5 * sin(a * 3.0 + tone * 23.0) + 0.35 * sin(a * 5.0 + tone * 61.0) + 0.2 * sin(a * 11.0 + tone * 97.0);
        float there = fill((oak - 0.86 - 0.12 * lobes) * oakRadius, 0.25);
        if (there > 0.0) {
            float elevation = max(scene.sun.w, 0.15);
            float3 sun = float3(scene.sun.xy * cos(elevation), sin(elevation));
            float lit = dot(normalize(float3(at / oakRadius, sqrt(saturate(1.0 - oak * oak)) / 0.95)), sun);
            float2 lp = rotate(at, tone * 6.283) / oakRadius * 2.3 + tone * 37.0;
            float clump = vnoise(lp, seed + 21u);
            float bump = vnoise(lp + scene.sun.xy * 0.3, seed + 21u) - clump;
            float3 crown = mix(b.canopy.rgb, b.canopyLight.rgb, saturate(0.6 * lit + 0.08 + 2.3 * bump + 0.35 * (clump - 0.5)));
            crown *= 0.72 + 0.28 * smoothstep(0.22, 0.56, clump);
            crown *= 1.0 - 0.24 * smoothstep(0.6, 1.0, oak) * saturate(0.6 - lit);
            crown *= 0.84 + 0.32 * tone;
            crown = mix(crown, b.snow.rgb * (0.85 + 0.15 * saturate(lit)), b.f.y * 0.6 * smoothstep(0.45, 0.75, clump));
            l.color = mix(l.color, crown, there);
            l.forest = max(l.forest, there);
            l.sway = mix(l.sway, 0.15, there);
            l.herd *= 1.0 - there;
            l.water *= 1.0 - there;
        }
    }
    return l;
}

// MARK: - The river

// The river, painted before the trees are grown so that crowns hang over it and shadows fall across it. Everything
// here follows from the channel (see channelAt): on the outside of a bend a cut bank, steep and dark, with the pool
// under it; on the inside a bar of sand that shelves into the water with no hard line, dry and pale at the back where
// growth is taking hold; between bends a low grass bank and paler, broken water where the current crosses over.
// The water is laid in three flat washes by depth, each drying a little darker at its edge, with a few long strokes
// drawn out along the current. Everything along it is laid out in coordinates that survive the reference stepping on
// (see alongNoise), so it never shows a seam.
inline float3 river(float3 c, float2 p, constant Scene &scene, constant Biome &b, Channel ch, float width,
                    thread float &water, thread float &herd, thread float &sway) {
    float presence = saturate(width / 12.0);
    float levee = b.i.w * presence;
    float ad = abs(ch.d);
    // Metres beyond the top of the bank: negative in the channel, bar and all.
    float out = ad - ch.edge;
    if (out > 26.0 + levee) return c;
    float side = ch.d > 0.0 ? 1.0 : -1.0;
    float bars = b.l.w;
    float inner = saturate(ch.bend * side), outer = saturate(-ch.bend * side);
    // How much of a bar this bank carries: where it does, the water's edge is lost in the sand.
    float barred = smoothstep(0.08, 0.3, inner * bars);
    float2 rp = float2(ch.d, p.y);
    float3 sand = b.sand.rgb, snow = b.snow.rgb;
    float snowCover = b.f.y;
    float3 grass = b.ground.rgb * float3(0.86, 0.95, 0.76);
    // Whether this bank stands between the water and the sun, so that it shades the water and its face is dark.
    float2 outward = float2(1.0, -ch.slope) / sqrt(1.0 + ch.slope * ch.slope) * side;
    float sunward = dot(scene.sun.xy, outward);

    if (levee > 0.0) {
        // Grassy dykes either side, with a pale track along the crest, and grass between them and the river.
        // They are built straight, whatever the river does to its own banks between them.
        float beyond = ad - (side > 0.0 ? ch.right : ch.left) - 4.0;
        float3 dyke = b.ground.rgb * float3(0.92, 1.06, 0.86);
        dyke *= 0.95 + 0.1 * alongNoise(p, float2(3.0), 9u);
        dyke = mix(dyke, b.road.rgb, fill(abs(beyond - levee * 0.55) - 1.4, 0.4) * 0.8);
        dyke = mix(dyke, snow * (0.95 + 0.05 * alongNoise(p, float2(5.0), 10u)), snowCover * 0.9);
        c = mix(c, dyke, fill(beyond - levee, 1.2));
        // The dyke's landward slope in shade or in sun, depending on which way it faces.
        c = shade(c, fill(abs(beyond - levee - 1.0) - 1.0, 0.8) * 0.3 * saturate(0.5 - sunward), scene);
        herd *= 1.0 - fill(beyond - levee, 1.2);
        sway *= 1.0 - fill(beyond - levee, 1.2);
    }

    // Along the bank: a narrow lip of rough grass, and scrub in thickets (see the bushes below). A thicket is dense at
    // the bank and thins away from it, deep in one reach and gone in the next, where the field comes to the lip, and
    // thin along a cut bank, which the river is taking back. Behind a bar it runs deep, where the river has left
    // ground that nobody ploughs.
    float growth = mix(0.35, 1.0, saturate(b.n.x * 1.6));
    float reachOf = alongNoise(float2(side * 5.0, p.y), float2(1.0, 85.0), 14u);
    float deepest = (2.0 + (3.0 + 0.24 * width) * smoothstep(0.4, 0.85, reachOf) + 0.35 * width * inner * min(bars, 1.0))
                  * (1.0 - 0.6 * outer) * (levee > 0.0 ? 0.3 : 1.0);
    float thick = saturate(1.0 - out / deepest);
    thick *= thick * smoothstep(-1.5, 0.5, out) * presence;
    float3 rough = mix(grass, b.hedge.rgb, 0.35) * (0.9 + 0.16 * alongNoise(rp, float2(2.3, 2.9), 13u));
    rough = mix(rough, snow * 0.95, snowCover * 0.8);
    float lip = fill(out - 0.5 - 1.6 * alongNoise(float2(side * 11.0, p.y), float2(1.0, 9.0), 15u), 0.35)
              * smoothstep(-0.6, 0.0, out) * presence;
    c = mix(c, rough, lip * 0.85);
    herd *= 1.0 - lip;
    sway *= 1.0 - lip;

    // The channel's floor where it stands dry. On a bar: pale sand, damp and darker by the water, with a line or
    // two where the river stood at other heights, and grass and scrub taking hold at the back. Elsewhere a narrow
    // foot of mud under the bank.
    float inChannel = fill(out, 0.25);
    float rise = -ch.tilt;
    float grain = alongNoise(p, float2(1.6), 6u);
    float3 bar = sand * (0.95 + 0.07 * grain) * (0.95 + 0.1 * alongNoise(float2(side * 13.0, p.y), float2(1.0, 38.0), 16u));
    float wander1 = alongNoise(float2(side * 17.0, p.y), float2(1.0, 19.0), 17u);
    float wander2 = alongNoise(float2(side * 19.0, p.y), float2(1.0, 31.0), 29u);
    float line1 = fill(abs(rise - 0.3 - 0.16 * wander1) - 0.022, 0.02) * smoothstep(0.34, 0.5, wander2);
    float line2 = fill(abs(rise - 0.85 - 0.3 * wander2) - 0.03, 0.03) * smoothstep(0.4, 0.55, wander1);
    bar *= 1.0 - 0.14 * line1 - 0.1 * line2;
    float3 dampSand = sand * float3(0.74, 0.72, 0.68);
    bar = mix(bar, dampSand, 1.0 - smoothstep(-0.02, 0.16 + 0.1 * wander1, rise));
    // Growth at the back of the bar, thickest against the old bank and along the upper line.
    float back = smoothstep(-6.0 - 5.0 * wander2, -0.5, out);
    float taken = smoothstep(0.86 - 0.4 * back, 0.92 - 0.4 * back, 0.6 * alongNoise(rp, float2(5.0, 6.5), 30u)
                                                                   + 0.4 * alongNoise(rp, float2(2.2, 3.0), 18u));
    bar = mix(bar, rough * (0.94 + 0.14 * grain), taken * step(0.001, back));
    bar = mix(bar, snow * 0.96, snowCover * 0.85);
    float3 mud = mix(sand * 0.66, c * 0.6, 0.5);
    mud = mix(mud, snow * 0.9, snowCover * 0.6);
    c = mix(c, mix(mud, bar, barred), inChannel);

    float cutting = smoothstep(0.1, 0.5, outer);

    // The water. Shelf, body and pool, the edge of each wandering a little; over a bar it thins away into the sand.
    float3 deep = b.water.rgb;
    float3 shelf = mix(dampSand, b.shallows.rgb, 0.62);
    float3 pool = deep * float3(0.7, 0.76, 0.84);
    float uneven = alongNoise(float2(ch.t / 0.45, p.y), float2(1.0, 64.0), 19u);
    float dp = ch.depth * (0.86 + 0.28 * uneven);
    float3 w = mix(shelf, deep, smoothstep(0.42, 0.5, dp));
    w = mix(w, pool, smoothstep(1.55, 1.7, dp));
    w *= 1.0 - 0.07 * (smoothstep(0.42, 0.5, dp) * (1.0 - smoothstep(0.5, 0.72, dp))
                       + smoothstep(1.55, 1.7, dp) * (1.0 - smoothstep(1.7, 2.1, dp)));
    w = pigment(w, alongNoise(float2(ch.d / max(width * 0.6, 1.0), p.y), float2(1.0, 150.0), 5u), 0.3);

    // Where the current crosses over between bends the bed comes up, and the water over it is paler. It lies aslant
    // across the channel, as the current crosses, and thins away at either end. The frame pass sets glints riding on it.
    float crossing = (1.0 - smoothstep(0.08, 0.32, abs(ch.bend))) * min(bars, 1.0) * presence
                   * smoothstep(0.56, 0.8, alongNoise(float2(0.5, p.y + 0.9 * ch.d), float2(1.0, 60.0), 21u))
                   * smoothstep(0.25, 0.7, ch.depth);
    w = mix(w, shelf * 1.04, crossing * 0.45);

    // A few long strokes drawn out by the current, crowding to the outside of each bend as the current does.
    float lane = ch.t + 0.4 * ch.bend * (1.0 - ch.t * ch.t);
    float pale = smoothstep(0.68, 0.73, alongNoise(float2(lane / 0.09, p.y), float2(1.0, 46.0), 20u));
    float dark = smoothstep(0.7, 0.75, alongNoise(float2(lane / 0.06 + 31.0, p.y), float2(1.0, 27.0), 24u));
    float run = smoothstep(0.35, 0.8, ch.depth) * (0.35 + 0.65 * saturate((width - 8.0) / 22.0));
    w = mix(w, w * 1.07 + float3(0.035, 0.04, 0.045), pale * run * 0.7);
    w *= 1.0 - 0.08 * dark * run;

    // The bank on the sun's side shades the water under it: a hard-edged shadow as long as the bank is high.
    float height = mix(0.5, 1.7, smoothstep(0.1, 0.5, outer)) * (1.0 - barred);
    float cast = height * scene.sun.z * saturate(sunward * 3.0);
    w = shade(w, fill(-out - cast - 0.2, 0.25) * 0.6 * step(0.001, cast), scene);

    // Ice takes the still margins first and the pools last.
    float iced = b.f.z > 0.0 ? smoothstep(0.0, 0.3, b.f.z * 4.0 - ch.depth) : 0.0;
    float3 ice = mix(float3(0.86, 0.91, 0.96), float3(0.72, 0.81, 0.90), smoothstep(0.2, 0.9, uneven));
    w = mix(w, ice, iced);

    float inWater = inChannel * mix(smoothstep(0.07, 0.12, ch.depth), smoothstep(0.0, 0.34, ch.depth), barred);
    c = mix(c, w, inWater);

    // In the north a few stones stand out of the shallows where the current crosses, each with a pale crease of
    // water below it.
    if (int(b.a.x) == layoutTaiga && crossing > 0.0) {
        const float patch = 2048.0 / 512.0;
        int2 at = int2(floor(p / patch));
        int2 key = int2(at.x, ((at.y % 512) + 512) % 512);
        float h = hash21(key, 39u);
        if (h < 0.3 * crossing) {
            float r = 0.3 + 0.45 * hash21(key, 40u);
            float2 q = p - (float2(at) + 0.3 + 0.4 * hash22(key, 41u)) * patch;
            // The river runs south: the crease trails that way and a little with the bank's line.
            float2 down = q + float2(ch.slope, 1.0) * (r + 0.9);
            c = mix(c, c * 1.08 + 0.05, fill(length(down * float2(1.0, 0.45)) - r * 0.7, 0.2) * 0.6 * inWater);
            float stone = fill(length(q * float2(1.0, 0.8 + 0.4 * h)) - r, 0.1) * inWater;
            float3 rock = b.rock.rgb * (0.8 + 0.3 * saturate(0.5 + dot(q, scene.sun.xy) / r * 0.5));
            c = mix(c, mix(rock, snow, snowCover * 0.6), stone);
        }
    }

    // Now and then a tree has gone over where the river cut the bank from under it: its trunk lies out into the pool,
    // its head downstream, with a branch or two showing.
    if (b.n.x > 0.3 && cutting > 0.0) {
        const float stretchOf = 2048.0 / 24.0;
        float k = floor(p.y / stretchOf);
        int key = (((int(k) % 24) + 24) % 24) * 2 + (side > 0.0 ? 1 : 0);
        if (hash11(key, 42u) < 0.4) {
            float2 foot = float2(0.5, (k + 0.3 + 0.4 * hash11(key, 43u)) * stretchOf);
            float long_ = 5.0 + 4.0 * hash11(key, 44u);
            float2 q = float2(-out, p.y) - foot;
            float2 head = float2(long_ * 0.75, -long_ * 0.66);
            float trunk = segmentDistance(q, 0.0, head) - 0.24;
            float2 fork = head * 0.55;
            float twigs = min(segmentDistance(q, fork, fork + float2(0.4, -1.9)) - 0.1,
                              segmentDistance(q, head * 0.8, head * 0.8 + float2(1.6, -0.4)) - 0.1);
            float lying = fill(min(trunk, twigs), 0.1) * cutting * presence;
            float2 lee = -scene.sun.xy * min(scene.sun.z, 2.0) * 0.35;
            float2 qs = q - float2(lee.x * side, lee.y);
            c = shade(c, fill(segmentDistance(qs, 0.0, head) - 0.24, 0.15) * (1.0 - lying) * cutting * presence * 0.45, scene);
            c = mix(c, mix(float3(0.34, 0.27, 0.2), snow, snowCover * 0.5) * (0.85 + 0.3 * hash11(key, 45u)), lying);
        }
    }

    // Reeds stand in the quiet water along a bank where no trees shade it: beds with ragged edges, here and there,
    // never on the outside of a bend, where the current would have them out.
    float reedy = (1.0 - saturate(b.n.x * 2.0)) * presence * (1.0 - barred) * (1.0 - smoothstep(0.0, 0.25, outer));
    float bed = 0.0;
    if (reedy > 0.0) {
        float beds = alongNoise(float2(side * 37.0, p.y), float2(1.0, 26.0), 36u);
        float reach = (1.2 + 0.1 * width) * smoothstep(0.42, 0.7, beds) * (0.6 + 0.8 * alongNoise(rp, float2(1.6, 2.4), 37u));
        bed = fill(-out - reach, 0.25) * inChannel * reedy * step(0.001, reach);
        float3 reeds = mix(grass, float3(0.63, 0.6, 0.33), 0.4) * (0.82 + 0.3 * alongNoise(rp, float2(0.5, 0.9), 38u));
        reeds = mix(reeds, snow * 0.9, snowCover * 0.5);
        c = mix(c, reeds, bed);
        // Their shade on the water beside them.
        c = shade(c, fill(-out - reach - 0.5 * min(scene.sun.z, 2.0) * saturate(sunward * 3.0), 0.25) * (1.0 - bed)
                     * inWater * reedy * step(0.001, reach) * 0.4, scene);
    }
    water = max(water, inWater * (1.0 - iced) * (1.0 - bed));

    // Bushes, one to a patch of ground where the scrub is thick enough: round, lit from the sun's side, each with its
    // shadow. Where the scrub thins out a bush is a smaller bush, so none is ever cut through.
    float scrub = out > 0.0 ? thick * 0.8 * growth : barred * back * 0.5 * growth;
    if (scrub > 0.0) {
        const float patch = 2048.0 / 640.0;
        int2 here = int2(floor(p / patch));
        float cover = 0.0, towards = 0.0, tone = 0.0, shadow = 0.0;
        float2 away = -scene.sun.xy * min(scene.sun.z, 2.5);
        for (int by = -1; by <= 1; by++) {
            for (int bx = -1; bx <= 1; bx++) {
                int2 at = here + int2(bx, by);
                int2 key = int2(at.x, ((at.y % 640) + 640) % 640);
                float h = hash21(key, 33u);
                float grown = saturate((scrub - h) * 4.0);
                if (grown <= 0.0) continue;
                float r = (0.9 + 1.0 * hash21(key, 35u)) * (0.4 + 0.6 * grown);
                float2 q = p - (float2(at) + 0.2 + 0.6 * hash22(key, 34u)) * patch;
                float lobes = r * 0.13 * sin(atan2(q.y, q.x) * 3.0 + h * 40.0);
                float a = fill(length(q) - r - lobes, 0.12);
                if (a > cover) {
                    cover = a;
                    towards = dot(q, scene.sun.xy) / r;
                    tone = h;
                }
                shadow = max(shadow, fill(length(q - away * r * 0.7) - r * 0.95, 0.2));
            }
        }
        float3 leaf = (int(b.a.x) == layoutGrassland ? b.canopy.rgb : b.hedge.rgb)
                    * (0.78 + 0.3 * saturate(0.5 + 0.5 * towards)) * (0.86 + 0.28 * fract(tone * 9.7));
        leaf = mix(leaf, snow * 0.92, snowCover * 0.5 * saturate(0.6 + towards));
        c = shade(c, shadow * (1.0 - cover) * 0.5, scene);
        c = mix(c, leaf, cover);
        herd *= 1.0 - cover;
    }

    // The bank itself, where it is steep: bare earth below the lip, in shade or in sun as it faces, and a thin pale
    // line along a sunlit lip, as a painter leaves the paper showing.
    float steep = (1.0 - barred) * presence
                * smoothstep(0.42, 0.6, alongNoise(float2(side * 29.0, p.y), float2(1.0, 33.0), 31u) + 0.7 * cutting);
    float face = 0.35 + 1.2 * cutting;
    float lit = saturate(-sunward * 2.0);
    float3 earth = mix(sand * 0.58, b.groundDark.rgb * 0.5, 0.45) * mix(0.66, 1.02, lit);
    earth = mix(earth, snow * 0.85, snowCover * 0.5);
    c = mix(c, earth, fill(abs(out + face * 0.5) - face * 0.5, 0.18) * steep);
    c = mix(c, mix(c, float3(0.97, 0.95, 0.88), 0.5), fill(abs(out - 0.25) - 0.22, 0.15) * steep * cutting * lit * (1.0 - snowCover));

    herd *= 1.0 - fill(out - 1.0, 0.8);
    sway *= 1.0 - inChannel;
    return c;
}

// Trees along the river's banks, in runs with gaps between: big crowns at the lip of a cut bank, hanging over the
// water, smaller ones further back, and none on the bare sand of a bar, only behind it. They are placed along the
// river from where this point stands abreast of it, so they keep to the banks round every bend.
inline void bankTrees(thread Canopy &k, float2 local, float2 world, constant Biome &b, constant Scene &scene, uint seed,
                      Channel ch, float width, float2 wander) {
    float amount = b.n.x;
    if (amount <= 0.0 || width < 6.0) return;
    float size = clamp(b.c.z, 8.0, 12.0) * 0.5;
    if (abs(ch.d) > max(ch.left, ch.right) + size * 4.0 + 12.0 + k.reach) return;
    float stretch = sqrt(1.0 + ch.slope * ch.slope);
    float2 along = float2(ch.slope, 1.0);
    float2 across = float2(1.0, -ch.slope) / stretch;
    float foot = world.y + ch.d * ch.slope / stretch;
    float reachAlong = dot(scene.sun.xy * k.reach, along) / stretch;
    bool taiga = int(b.a.x) == layoutTaiga;
    // Forest stands three deep along a river and closer together; elsewhere a front rank and a few behind it.
    int rows = taiga ? 480 : 315;
    int ranks = taiga ? 3 : 2;
    float step = 2048.0 / float(rows);
    float j0 = floor((foot + (min(reachAlong, 0.0) - size * 1.3) / stretch) / step);
    float j1 = min(floor((foot + (max(reachAlong, 0.0) + size * 1.3) / stretch) / step), j0 + 6.0);
    float2 shift = world - local;
    // The railway is read here, once, and its gap worked out below as railGap does. Asking railGap itself for each
    // tree hung the GPU now and then: about two frames in five.
    float4 railLine = b.railLine, railCurve = b.railCurve;
    bool rail = railCurve.w > 0.5;
    // Neither loop unrolled, so there is one copy of what each tree asks of the road and the cross-roads.
    #pragma clang loop unroll(disable)
    for (float j = j0; j <= j1; j += 1.0) {
        int row = ((int(j) % rows) + rows) % rows;
        #pragma clang loop unroll(disable)
        for (int n = 0; n < ranks * 2; n++) {
            float side = n < ranks ? -1.0 : 1.0;
            int rank = n % ranks;
            int id = row * 6 + n;
            float h = hash11(id, 700u);
            float y = (j + 0.15 + 0.7 * hash11(id, 701u)) * step;
            // Runs of trees and gaps between them, each bank on its own, and clusters within a run.
            float thick = 0.6 * alongNoise(float2(side * 23.0, y), float2(1.0, 58.0), 23u)
                        + 0.4 * alongNoise(float2(side * 31.0 + float(rank), y), float2(1.0, 15.0), 32u);
            float outer = saturate(-ch.bend * side), inner = saturate(ch.bend * side);
            float chance = smoothstep(0.8 - 0.56 * amount, 0.94 - 0.56 * amount, thick + 0.2 * outer - 0.25 * inner * b.l.w)
                         * (rank == 0 ? 0.85 : taiga ? 0.8 : 0.5);
            // A tree near the edge of a run is a smaller tree, not half of one.
            float grown = saturate((chance - h) * 5.0);
            if (grown <= 0.0) continue;
            float pick = hash11(id, 702u);
            float r = size * (pick < 0.3 ? 0.4 : pick < 0.68 ? 0.66 : pick < 0.9 ? 0.95 : 1.3) * (0.85 + 0.3 * hash11(id, 703u))
                    * (0.45 + 0.55 * grown);
            if (taiga) r *= 0.58;
            float bank = (side > 0.0 ? ch.right : ch.left) + (1.0 + 0.035 * width) * smoothstep(0.1, 0.5, outer);
            float from = bank + r * (0.25 + 0.6 * hash11(id, 704u))
                       + float(rank) * (taiga ? 4.4 : r * 1.1 + 2.0 + 6.0 * hash11(id, 705u));
            float2 at = local + along * (y - foot) + across * (side * from - ch.d);
            if (abs(roadDistance(at + shift, scene, wander)) < b.e.x * 0.5 + r + 3.0) continue;
            if (crossGap(at + shift, scene, b) < r + 4.5) continue;
            if (rail) {
                float2 fromLine = at - railLine.xy;
                float2 q = float2(dot(fromLine, railLine.zw), dot(fromLine, float2(-railLine.w, railLine.z)));
                if (abs(q.y - railCurve.x * sin(q.x * railCurve.y + railCurve.z)) < r + 4.0) continue;
            }
            float tone = hash11(id, 706u);
            int kind = broadleaf, foliage = leaves;
            float tall = 2.3 + 0.9 * hash11(id, 707u);
            if (taiga) {
                float which = hash11(id, 708u);
                if (which < 0.3) { kind = spruce; foliage = conifer; r *= 0.85; tall = 8.0; }
                else if (which < 0.5) { kind = pine; tall = 6.6; }
                else { foliage = birch; tall = 5.0; }
            } else if (b.l.z > 0.0) {
                kind = pine; tall = b.l.z;
            }
            plant(k, local, at, r, r * tall, kind, tone, foliage, scene);
        }
    }
}

// MARK: - The whole ground for one leg

// Lapland: boreal forest of pine and spruce with birch about the wet ground, opened up by pale lichen heath where the
// ground is dry, by clear-cuts at every stage of regrowth, and by aapa mires: open fens of yellow-olive sedge crossed
// by long low strings of peat that curve with the slope, dark pools lying between them in the wettest middles.

// How wet the land is, from forest (low) through the mire's edge (0.6) to its pools (0.7). Cheap and smooth, so each
// tree can ask it where it stands and every point agrees on which trees there are.
inline float taigaWet(float2 p, uint seed) {
    // Each octave turned its own way, so no edge runs along the noise's lattice.
    return 0.55 * vnoise(rotate(p, 0.6) / 560.0, seed + 30u) + 0.3 * vnoise(rotate(p, -1.1) / 210.0, seed + 31u)
         + 0.15 * vnoise(rotate(p, 2.3) / 85.0, seed + 29u);
}

// Dry sandy ridges where lichen heath replaces the forest, 0 to 1.
inline float taigaDry(float2 p, uint seed) {
    return smoothstep(0.6, 0.72, 0.7 * vnoise(rotate(p, 1.9) / 330.0, seed + 32u) + 0.3 * vnoise(rotate(p, -0.4) / 120.0, seed + 28u));
}

// Forestry compartments, some clear-cut: 0 standing forest, then 1 freshly cut, 2 regrowing, 3 a young thicket.
inline int taigaCut(float2 p, uint seed, thread float &edge) {
    const float2 compartment = float2(240.0, 190.0);
    // Each forest's compartments run their own way.
    p = rotate(p, 0.15 + 0.6 * hash11(int(seed), 38u));
    float2 g = floor(p / compartment);
    int2 cell = int2(g);
    edge = 1e3;
    if (hash21(cell, seed + 33u) > 0.17) return 0;
    float2 extent = compartment * (0.25 + 0.17 * hash22(cell, seed + 34u));
    float2 centre = (g + 0.5) * compartment + (hash22(cell, seed + 35u) - 0.5) * (compartment * 0.5 - extent);
    // Felled to the line of the stand, which is nearly straight and never square: corners rounded off, edges that wander
    // a few metres with the ground.
    edge = sdBox(p - centre, extent - 14.0) - 14.0;
    if (abs(edge) < 8.0) edge += 9.0 * (vnoise(p / 26.0, seed + 26u) - 0.5);
    if (edge > 0.0) return 0;
    float stage = hash21(cell, seed + 36u);
    return stage < 0.35 ? 1 : stage < 0.7 ? 2 : 3;
}

inline Land taiga(float2 p, float2 world, constant Biome &b, constant Scene &scene, uint seed, float riverHalf,
                  float2 wander, thread Canopy &trees) {
    Land l;
    l.road = 0.0;
    l.light = 0.0;
    l.lightID = 0.0;
    float wet = taigaWet(p, seed);
    float mire = smoothstep(0.645, 0.665, wet + 0.05 * (fbm(p / 40.0, 2, seed + 37u) - 0.5));
    float dry = taigaDry(p, seed) * (1.0 - mire);

    // The forest floor: moss under the trees, pale lichen on the dry heath with patches of heather and crowberry.
    float3 moss = b.crop2.rgb * (0.9 + 0.12 * vnoise(rotate(p, 0.5) / 3.1, seed + 38u)
                                    + 0.08 * vnoise(rotate(p, -0.9) / 1.3, seed + 27u));
    moss = mix(moss, b.crop2.rgb * float3(1.1, 1.05, 0.85), smoothstep(0.55, 0.8, vnoise(p / 22.0, seed + 39u)) * 0.5);
    float3 lichen = b.crop0.rgb * (0.94 + 0.1 * vnoise(p / 2.2, seed + 40u));
    lichen = mix(lichen, b.crop2.rgb * 1.15, smoothstep(0.5, 0.78, fbm(p / 14.0, 2, seed + 41u)) * 0.55);
    float3 c = mix(moss, lichen, dry);

    // Clear-cuts: sharp-edged, harvester tracks across the fresh ones, a haze of young birch and pine on the older.
    float cutEdge;
    int cut = mire < 0.5 ? taigaCut(p, seed, cutEdge) : 0;
    if (cut > 0) {
        // A strip of forest is left standing along the river, as the law has it.
        float inside = fill(cutEdge, 1.2);
        if (riverHalf > 0.25) inside *= smoothstep(riverHalf + 24.0, riverHalf + 30.0, abs(riverDistance(world, scene, wander)));
        float3 slash = mix(float3(0.55, 0.49, 0.40), moss, 0.35) * (0.88 + 0.24 * fbm(rotate(p, -0.5) / 2.4, 2, seed + 42u));
        float tracks = fill(abs(fract(p.x / 16.0) - 0.5) * 16.0 - 1.2, 0.5);
        slash = mix(slash, slash * 0.8, tracks * 0.6);
        // Regrowth: grass and fireweed with saplings coming through it in clumps, never one flat green.
        float thicket = fbm(rotate(p, 0.9) / 2.6, 3, seed + 43u);
        float3 regrowth = mix(b.crop2.rgb * 1.18, b.hedge.rgb, 0.3) * (0.8 + 0.4 * thicket);
        regrowth = mix(regrowth, b.hedge.rgb * 0.82, smoothstep(0.55, 0.7, thicket) * 0.5);
        regrowth = mix(regrowth, slash, smoothstep(0.6, 0.8, fbm(p / 19.0, 2, seed + 25u)) * 0.45);
        c = mix(c, cut == 1 ? slash : cut == 2 ? regrowth : moss, inside);
    }

    // The mire. Strings of peat about 2 m wide and 11 m apart run along the slope's contours, which turn slowly across
    // it; each breaks off now and then. Towards the wet middle the hollows between them hold long dark pools.
    float turn = 0.4 + 1.6 * (vnoise(p / 900.0, seed + 44u) - 0.5);
    float2 w = rotate(p, turn);
    float ph = w.y / 11.0 + 2.2 * vnoise(float2(w.x / 150.0, w.y / 110.0), seed + 45u)
             + 1.1 * vnoise(rotate(w, 0.7) / float2(55.0, 35.0), seed + 46u)
             + 0.25 * vnoise(float2(w.x / 9.0, w.y / 7.0), seed + 43u);
    float f = fract(ph);
    float hollow = floor(ph);
    float strand = smoothstep(0.42, 0.55, vnoise(float2(w.x / 21.0, hollow * 3.1), seed + 47u));
    float peat = fill(abs(f - 0.5) - 0.07 - 0.06 * vnoise(w / 6.0, seed + 42u), 0.035) * strand;
    float core = smoothstep(0.69, 0.75, wet);
    float flark = smoothstep(0.42, 0.58, vnoise(float2(w.x / (18.0 + 30.0 * core), hollow * 1.7), seed + 48u));
    float pool = fill(min(f, 1.0 - f) - 0.1 - 0.12 * core, 0.03) * flark * smoothstep(0.0, 0.5, core);
    float3 sedge = b.crop1.rgb * (0.93 + 0.12 * vnoise(p / 4.0, seed + 49u));
    sedge = mix(sedge, sedge * float3(1.06, 0.93, 0.78), smoothstep(0.5, 0.8, vnoise(p / 26.0, seed + 50u)) * 0.5);
    // Wetter, greener sedge lawns towards the middle and right round the pools.
    sedge = mix(sedge, mix(sedge, b.crop2.rgb * 1.3, 0.3), core * 0.6);
    float3 strings = b.crop3.rgb * (0.85 + 0.3 * vnoise(p / 1.4, seed + 51u));
    sedge = mix(sedge, strings, peat);
    float3 water = mix(float3(0.2, 0.25, 0.24), mix(b.snow.rgb, float3(0.78, 0.84, 0.9), 0.3), b.f.z);
    water = mix(sedge * 0.75, water, smoothstep(0.0, 0.04, 0.1 + 0.12 * core - min(f, 1.0 - f)));
    sedge = mix(sedge, water, pool);
    c = mix(c, sedge, mire);
    l.water = pool * mire * (1.0 - b.f.z);

    // The trees, one per cell, each deciding from where it stands what grows there.
    const float spacing = 4.0;
    int2 lo, hi;
    window(p, spacing, 3.4, scene.sun.xy * trees.reach, lo, hi);
    Keepouts near = keepouts(world, p, spacing * 2.5 + trees.reach, b, scene, seed, riverHalf, wander);
    float2 shift = world - p;
    for (int y = lo.y; y <= hi.y; y++) {
        for (int x = lo.x; x <= hi.x; x++) {
            int2 cell = int2(x, y);
            // The cheapest questions first: no land is more wooded than 92 in 100 cells.
            float h = hash21(cell, seed + 53u);
            if (h >= 0.92) continue;
            float2 at = (float2(cell) + 0.15 + 0.7 * hash22(cell, seed + 52u)) * spacing;
            float tw = taigaWet(at, seed);
            if (tw >= 0.7) continue;
            float scale = 1.0;
            float chance;
            float dry = 0.0;
            float edge;
            int stage = tw < 0.65 ? taigaCut(at, seed, edge) : 0;
            if (stage > 0 && near.river && abs(riverDistance(at + shift, scene, wander)) < riverHalf + 27.0) stage = 0;
            if (tw > 0.65) { chance = 0.06; scale = 0.6; } // stunted pines out on the mire's drier edge
            else if (stage == 1) chance = 0.03;
            else if (stage == 2) chance = 0.0;
            else if (stage == 3) { chance = 0.92; scale = 0.6; }
            else {
                dry = taigaDry(at, seed);
                chance = mix(0.9, 0.18, dry) * (1.0 - smoothstep(0.62, 0.66, tw));
            }
            if (h >= chance) continue;
            float kindPick = hash21(cell, seed + 54u);
            int kind = pine, foliage = leaves;
            float r = scale * (1.6 + 1.0 * hash21(cell, seed + 55u));
            // Pines and spruces of 12 to 20 m, birches lower.
            float tall = 6.6;
            if (kindPick < 0.35 + 0.25 * smoothstep(0.5, 0.62, tw) - 0.3 * dry) {
                kind = spruce; foliage = conifer; r *= 0.85; tall = 8.0;
            } else if (kindPick > 0.86 - 0.25 * smoothstep(0.56, 0.64, tw)) {
                kind = broadleaf; foliage = birch; tall = 5.0;
            }
            if (!clearSpot(at, at + shift, r + 3.0, near, b, scene, seed, riverHalf, wander)) continue;
            plant(trees, p, at, r, r * tall, kind, hash21(cell, seed + 56u), foliage, scene);
        }
    }

    l.color = c;
    l.forest = 0.0;
    l.sway = mire * 0.35;
    l.herd = mire > 0.5 && pool < 0.3 ? 1.0 : dry > 0.5 ? 0.6 : 0.0;
    return l;
}

inline Land land(float2 world, constant Leg &leg, constant Scene &scene, float riverWidth, float2 wander,
                 Channel channel) {
    constant Biome &b = leg.biome;
    // What stands on the land keeps clear of the river at its widest.
    float riverHalf = riverWidth < 0.5 ? 0.0 : riverWidth * 0.5 + riverSpread(riverWidth * 0.5, b.l.w);
    uint seed = uint(leg.info.y);
    float2 local = float2(world.x, world.y - leg.info.x);
    int layout = int(b.a.x);
    // Lapland's forest gathers shadows from 16 m round, enough for its tallest pines at an afternoon sun. Further costs
    // GPU memory in lumps: 14 and 18 m each cost 3 to 4 MB, 16 nothing.
    Canopy trees = canopy(layout == layoutTaiga ? 16.0 : 18.0);
    Land l;
    if (layout == layoutPaddies) l = paddies(local, b, seed);
    else if (layout == layoutFields) l = fields(local, world, b, scene, seed, riverHalf, wander);
    else if (layout == layoutStripes) l = stripes(local, b, seed);
    else if (layout == layoutPivots) l = pivots(local, leg, scene, seed, wander);
    else if (layout == layoutTaiga) l = taiga(local, world, b, scene, seed, riverHalf, wander, trees);
    else l = grassland(local, b, seed);

    l.color = rocks(l.color, local, b, scene, seed, l.herd);
    float water = l.water;
    l.color = ponds(l.color, local, world, b, scene, seed, wander, water, l.herd);
    l.herd *= 1.0 - smoothstep(0.0, 0.5, water - l.water);
    l.water = water;
    float cover = 0.0;
    l.color = landmarkTrack(l.color, int(b.j.x), b.j.y, local, world, b, scene, seed, wander, riverHalf, l.herd);
    l.color = landmarkTrack(l.color, int(b.j.z), b.j.w, local, world, b, scene, seed + 17u, wander, riverHalf, l.herd);
    l.color = landmark(l.color, int(b.j.x), b.j.y, local, world, b, scene, seed, wander, riverHalf, trees, l.herd,
                       l.water, cover, l.light, l.lightID);
    l.color = landmark(l.color, int(b.j.z), b.j.w, local, world, b, scene, seed + 17u, wander, riverHalf, trees, l.herd,
                       l.water, cover, l.light, l.lightID);
    l.color = houses(l.color, local, world, b, scene, seed, wander, trees, cover, l.light, l.lightID);
    if (layout != layoutTaiga) plantTrees(trees, l.color, local, world, b, scene, seed, riverHalf, wander);

    // Snow settles on the open ground and the roofs, under the crowns, which carry their own.
    float snow = b.f.y * (1.0 - cover * 0.7) * (1.0 - l.forest * 0.8) * smoothstep(0.25, 0.6, fbm(local / 40.0, 3, seed + 95u) + 0.35);
    l.color = mix(l.color, b.snow.rgb * (0.94 + 0.06 * vnoise(local / 6.0, seed + 96u)), snow * (1.0 - l.water));

    if (riverWidth >= 0.5) {
        l.color = river(l.color, world, scene, b, channel, riverWidth, l.water, l.herd, l.sway);
        bankTrees(trees, local, world, b, scene, seed, channel, riverWidth, wander);
    }

    float roofs = cover;
    l.color = grow(trees, l.color, local, b, scene, seed, cover);
    l.light *= 1.0 - 0.75 * saturate(cover - roofs);
    l.sway *= 1.0 - cover;
    l.herd *= 1.0 - cover;
    l.water *= 1.0 - cover;
    l.cover = cover;

    // A broad wash, like paint laid on unevenly across the sheet.
    l.color *= 1.0 + 0.08 * (fbm(local / 340.0, 3, seed + 99u) - 0.5);

    // Paint finish: pigment turbulence at two scales.
    float t1 = vnoise(local / 60.0, seed + 97u);
    float t2 = vnoise(local / 6.5, seed + 98u);
    l.color = pigment(l.color, t1, 0.32);
    l.color = pigment(l.color, t2, 0.16);
    return l;
}

// MARK: - Road on top, continuous across legs

inline float3 road(float3 c, float2 p, constant Scene &scene, constant Biome &a, constant Biome &b, float m,
                   float riverHalf, float2 wander, Channel channel, thread float &onRoad, thread float &traffic,
                   thread float &water, thread float &herd) {
    float width = mix(a.e.x, b.e.x, m);
    float paved = mix(a.e.y, b.e.y, m);
    float3 surface = mix(a.road.rgb, b.road.rgb, m);
    float halfWidth = width * 0.5;
    float d = roadDistance(p, scene, wander);

    // A crossroad now and then.
    bool hasCross;
    float crossY = crossroadY(p, scene, hasCross, halfWidth + 20.0);
    // A cross-road is a narrow link road, 4 to 6 m; the survey grid of pivot country has section roads instead.
    hasCross = hasCross && int((m < 0.5 ? a : b).a.x) != layoutPivots;
    float crossHalf = clamp(halfWidth * 0.45, 2.0, 3.0);
    float dc = hasCross ? abs(p.y - crossY) - crossHalf : 1e6;

    // Roads meet in rounded corners.
    float dd = smin(abs(d) - halfWidth, dc, 3.0);
    if (dd > 5.0) return c;
    float onRiver = fill(abs(channel.d) - channel.edge - 3.0, 0.5) * riverPresence(riverHalf);
    float2 sunOff = scene.sun.xy * scene.sun.z * 3.0;
    // The bridge deck shades the water under it.
    float shadowD = min(abs(roadDistance(p + sunOff, scene, wander)) - halfWidth,
                        hasCross ? abs(p.y + sunOff.y - crossY) - crossHalf : 1e6);
    c = shade(c, fill(shadowD, 0.8) * onRiver * 0.9, scene);

    // How far across whichever road is nearest, and how far along it: laid out so that wear runs with the traffic.
    bool along = abs(d) - halfWidth < dc;
    float lat = along ? d : p.y - crossY;
    float run = along ? p.y : p.x;
    float wide = along ? halfWidth : crossHalf;
    float ragged = alongNoise(float2(lat > 0.0 ? 3.0 : 7.0, run), float2(1.0, 6.0), 72u) - 0.5;
    float edge = dd + ragged * mix(1.5, 0.35, paved);
    float streaks = alongNoise(float2(lat / 1.2, run), float2(1.0, 27.0), 73u);
    float blotch = alongNoise(float2(lat / 2.6, run), float2(1.0, 11.0), 71u);
    float across = abs(lat) / max(wide, 0.5);

    // Tarmac: greyed by age, the lanes polished by tyres, repaired in places, with faded paint down the middle and edges.
    // Where two roads meet nothing runs either way, so it is plain, with no paint across it.
    float meet = fill(abs(d) - halfWidth, 0.3) * fill(dc, 0.3);
    float3 worn = mix(surface, float3(0.37, 0.37, 0.38), 0.74);
    float3 tarmac = worn * (0.9 + 0.2 * blotch) * (1.0 + 0.1 * (streaks - 0.5));
    tarmac *= 1.0 - 0.07 * fill(abs(across - 0.5) - 0.17, 0.12);
    float mended = smoothstep(0.76, 0.8, alongNoise(float2(lat > 0.0 ? 11.0 : 13.0, run), float2(1.0, 9.0), 74u));
    tarmac *= 1.0 - 0.09 * mended * fill(abs(across - 0.5) - 0.24, 0.06);
    tarmac = mix(tarmac, worn * (0.95 + 0.1 * blotch), meet);
    float paint = (0.45 + 0.55 * streaks) * (1.0 - onRiver * 0.4) * (1.0 - meet);
    float dash = step(0.55, fract(run / alongSpacing(7.0))) * fill(abs(lat) - 0.14, 0.1);
    float kerbLine = fill(abs(abs(lat) - wide + 0.45) - 0.08, 0.07) * (along ? 1.0 : 0.0) * smoothstep(0.5, 2.5, dc);
    tarmac = mix(tarmac, float3(0.83, 0.82, 0.77), saturate(dash + kerbLine * 0.75) * paint);

    // A dirt road: two ruts, pale dust, and grass coming up along the crown.
    float ruts = fill(abs(abs(lat) - wide * 0.45) - 0.4, 0.3);
    float3 dirt = surface * (0.9 + 0.2 * blotch) * (1.0 - 0.17 * ruts * (0.6 + 0.8 * streaks));
    float3 grass = mix(a.ground.rgb, b.ground.rgb, m);
    dirt = mix(dirt, grass * 0.92, fill(abs(lat) - 0.3 - 0.5 * streaks, 0.3) * smoothstep(0.35, 0.7, blotch) * 0.6);
    float3 r = mix(dirt, tarmac, paved);

    // In snow the wheels keep the lanes clear and the rest lies packed, deepest along the edges.
    float3 snow = mix(a.snow.rgb, b.snow.rgb, m);
    float snowCover = mix(a.f.y, b.f.y, m);
    r = mix(r, snow * (0.92 + 0.08 * blotch), snowCover * (0.3 + 0.55 * smoothstep(0.62, 1.0, across)
                                                           + 0.3 * smoothstep(0.26, 0.05, across)) * (0.75 + 0.5 * streaks));

    // Every road over water is a bridge: a parapet down each side, whichever road it is.
    float rail = fill(abs(abs(lat) - wide - 0.4) - 0.35, 0.2) * onRiver * step(abs(lat), wide + 1.2);
    float3 railColor = float3(0.66, 0.65, 0.62) * (0.92 + 0.14 * blotch);

    // A gravelled verge fading into the land, and the shallow ditch beyond it.
    float a2 = fill(edge, 0.4);
    float verge = fill(edge - mix(1.5, 0.9, paved), 0.8) * (1.0 - a2) * (1.0 - onRiver);
    c = shade(c, fill(abs(edge - 3.3) - 0.7, 0.8) * 0.1 * (1.0 - onRiver), scene);
    c = mix(c, mix(c, surface * (0.72 + 0.25 * blotch), mix(0.6, 0.34, paved)), verge * (1.0 - 0.7 * snowCover));
    c = mix(c, r, a2);
    c = mix(c, railColor, rail);
    onRoad = max(onRoad, fill(min(abs(d) - halfWidth, dc), 0.5) * (1.0 - onRiver));
    // Where cars are drawn: the carriageway, bridges included, and the verges their shadows fall on.
    traffic = fill(abs(d) - halfWidth - mix(2.5, 0.3, onRiver), 0.3);
    water *= 1.0 - a2;
    herd *= 1.0 - fill(dd - 1.0, 0.5);
    return c;
}

// MARK: - Railways


// The track bed, painted once: ballast, sleepers drawn wider apart than real ones so they never shimmer
// at this scale, rails, overhead masts with their shadows, and a steel deck where it crosses the river.
inline float3 railway(float3 c, float2 world, constant Leg &leg, constant Scene &scene, float texel,
                      float riverHalf, Channel channel, thread float &herd, thread float &water) {
    if (leg.rail.w < 0.5) return c;
    float2 local = float2(world.x, world.y - leg.info.x);
    float along;
    float d = railSigned(local, leg.rail.xy, leg.rail.z, leg.railShape.xyz, along);
    float ad = abs(d);
    if (ad > 10.0) return c;
    float fw = max(texel * 0.7, 0.12);
    float onRiver = fill(abs(channel.d) - channel.edge - 2.5, 0.6) * riverPresence(riverHalf);
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

// The railway crosses roads on a bridge of its own: a deck with a low parapet each side, standing a few metres up and
// throwing its shadow across the road. Traffic passes underneath, so where the deck is no car is drawn.
inline float3 railBridge(float3 c, float2 world, constant Leg &leg, constant Scene &scene, float onRoad, float texel,
                         thread float &traffic) {
    if (leg.rail.w < 0.5 || onRoad < 0.01) return c;
    float2 local = float2(world.x, world.y - leg.info.x);
    float along;
    float2 lift = scene.sun.xy * scene.sun.z * 5.5;
    float under = abs(railSigned(local + lift, leg.rail.xy, leg.rail.z, leg.railShape.xyz, along));
    c = shade(c, fill(under - 4.2, 0.4) * onRoad * 0.75, scene);
    float ad = abs(railSigned(local, leg.rail.xy, leg.rail.z, leg.railShape.xyz, along));
    if (ad > 5.0) return c;
    float deck = fill(ad - 4.2, max(0.15, texel * 0.6)) * onRoad;
    c = mix(c, float3(0.6, 0.59, 0.57), deck);
    c = mix(c, float3(0.74, 0.73, 0.7), fill(abs(ad - 3.95) - 0.25, max(0.08, texel * 0.6)) * onRoad);
    traffic *= 1.0 - deck;
    return railOverRoad(c, world, leg, onRoad, texel);
}

fragment GroundOut ground(VertexOut in [[stage_in]],
                          constant GroundParams &params [[buffer(0)]],
                          constant Scene &scene [[buffer(1)]]) {
    float texel = params.texel.x;
    float2 world = params.origin.zw + (in.position.xy - params.origin.xy) * texel;

    // How far the land has turned from leg A into leg B here.
    float m = landTurn(world.y, scene);
    // In flight the two places simply meet. A Fly To's new place spreads in organic patches, like wet paint creeping across
    // the sheet: inside the soft edge both places are painted and blended; elsewhere only one is.
    float blend = m;
    if (scene.morph.z >= 0.0) {
        float threshold = patchThreshold(world, scene);
        blend = smoothstep(threshold - 0.05, threshold + 0.05, m);
    }

    float2 wander = course(scene, m);
    float widthA = scene.legA.biome.d.z, widthB = scene.legB.biome.d.z;
    float width = riverWidth(scene, m);
    float riverHalf = width * 0.5;
    float shownA = widthA < 0.5 ? 0.0 : width, shownB = widthB < 0.5 ? 0.0 : width;
    Channel channel = channelAt(world, scene, wander, width, mix(scene.legA.biome.l.w, scene.legB.biome.l.w, m));
    // Between a place with a river and one without, the river is painted over in the same creeping patches as
    // the land, rather than narrowing to a point in the middle of a field.
    float riverShown = 1.0;
    if ((widthA < 0.5) != (widthB < 0.5)) riverShown = widthA >= 0.5 ? 1.0 - blend : blend;
    // Each place shown here is painted from the one call, in a loop of one or two, so the shader holds a single copy
    // of everything land() works with. Every copy costs memory for each thread the GPU can run at once, hundreds of
    // megabytes in all.
    int first = blend >= 1.0 ? 1 : 0, last = blend <= 0.0 ? 0 : 1;
    Land a, b;
    // Never unrolled, or the copies come back.
    #pragma clang loop unroll(disable)
#ifndef OUTBOUND_SLOW_GPU
    for (int i = first; i <= last; i++) {
        Land painted = land(world, i == 0 ? scene.legA : scene.legB, scene, i == 0 ? shownA : shownB, wander, channel);
#else
    // Development builds only, with OUTBOUND_SLOW_GPU=n: each place is painted n times over, a hair apart so none of
    // it can be skipped, to stand in for a GPU n times slower.
    for (int k = 0; k < (last - first + 1) * OUTBOUND_SLOW_GPU; k++) {
        int i = first + k % (last - first + 1);
        Land painted = land(world + float2(0.0, float(k) * 1e-7), i == 0 ? scene.legA : scene.legB, scene,
                            i == 0 ? shownA : shownB, wander, channel);
#endif
        if (i == 0) a = painted; else b = painted;
    }
    Land l = first == 1 ? b : a;
    if (first != last) {
        l = a;
        l.color = mix(a.color, b.color, blend);
        l.water = mix(a.water, b.water, blend);
        l.sway = mix(a.sway, b.sway, blend);
        l.herd = mix(a.herd, b.herd, blend);
        l.road = mix(a.road, b.road, blend);
        l.light = mix(a.light, b.light, blend);
        l.cover = mix(a.cover, b.cover, blend);
        // The lamp whose light this mostly is, which needn't be the place with most of the land here.
        l.lightID = b.light * blend > a.light * (1.0 - blend) ? b.lightID : a.lightID;
        // A darker tide line where the two paints meet.
        l.color *= 1.0 - 0.12 * (1.0 - abs(blend * 2.0 - 1.0));
    }

    float onRoad = l.road;
    float water = l.water;
    float herd = l.herd;
    float3 c = l.color;
    // Bridges only where the river is still painted.
    float crossingHalf = riverShown > 0.5 ? riverHalf : 0.0;
    constant Leg &railLeg = blend > 0.5 ? scene.legB : scene.legA;
    c = railway(c, world, railLeg, scene, texel, crossingHalf, channel, herd, water);
    float traffic = 0.0;
    c = road(c, world, scene, scene.legA.biome, scene.legB.biome, m, crossingHalf, wander, channel, onRoad, traffic, water, herd);
    c = railBridge(c, world, railLeg, scene, onRoad, texel, traffic);

    GroundOut out;
    out.color = float4(saturate(c), packGround(water, l.sway, traffic > 0.5 && l.cover < 0.5, herd > 0.5));
    out.night = float4(saturate(l.light * (1.0 - water * 0.8)), l.lightID, 0.0, 0.0);
    return out;
}

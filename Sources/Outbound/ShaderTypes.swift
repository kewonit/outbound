import OutboundCore
import simd

// These mirror the structs at the top of Shaders/Common.metal field for field. Every field is a
// float4 so Swift and Metal can never disagree about padding.

struct BiomeGPU {
    var ground, groundDark, crop0, crop1, crop2, crop3, hedge, water, shallows, sand, road, canopy,
        canopyLight, rock, snow, animalColor: SIMD4<Float>
    /// layout, fieldSize, hedgeWidth, warp
    var a: SIMD4<Float>
    /// fallow, patchiness, strokes, sway
    var b: SIMD4<Float>
    /// flooded, trees, treeSize, hedgeTrees
    var c: SIMD4<Float>
    /// orchards, petals, riverWidth, riverWander
    var d: SIMD4<Float>
    /// roadWidth, paved, ponds, houses
    var e: SIMD4<Float>
    /// rocks, snowCover, frozen, animal
    var f: SIMD4<Float>
    /// herds, cars, clumping, treeLines
    var g: SIMD4<Float>
    /// drives on the left, street lights, boats, boat kind
    var h: SIMD4<Float>
    var lamp: SIMD4<Float>
    var roof0, roof1, roof2, animalPatches: SIMD4<Float>
    /// villages, road trees, flat roofs, levees
    var i: SIMD4<Float>
    /// first landmark, its density, second landmark, its density
    var j: SIMD4<Float>
    /// dry river, sodium lamps, lamps off late, unused
    var k: SIMD4<Float>

    init(_ b: Biome) {
        func c(_ v: SIMD3<Float>) -> SIMD4<Float> { SIMD4(v, 1) }
        ground = c(b.ground); groundDark = c(b.groundDark)
        crop0 = c(b.crops.0); crop1 = c(b.crops.1); crop2 = c(b.crops.2); crop3 = c(b.crops.3)
        hedge = c(b.hedge); water = c(b.water); shallows = c(b.shallows); sand = c(b.sand); road = c(b.road)
        canopy = c(b.canopy); canopyLight = c(b.canopyLight); rock = c(b.rock); snow = c(b.snow)
        animalColor = c(b.animalColor)
        a = SIMD4(Float(b.layout.rawValue), b.fieldSize, b.hedgeWidth, b.warp)
        self.b = SIMD4(b.fallow, b.patchiness, b.strokes, b.sway)
        self.c = SIMD4(b.flooded, b.trees, b.treeSize, b.hedgeTrees)
        d = SIMD4(b.orchards, b.petals, b.riverWidth, b.riverWander)
        e = SIMD4(b.roadWidth, b.paved, b.ponds, b.houses)
        f = SIMD4(b.rocks, b.snowCover, b.frozen, Float(b.animal.rawValue))
        g = SIMD4(b.herds, b.cars, b.clumping, b.treeLines)
        h = SIMD4(b.drivesLeft ? 1 : 0, b.streetLights, b.boats, Float(b.boat.rawValue))
        lamp = SIMD4(b.lampColor, 1)
        roof0 = c(b.roofs.0); roof1 = c(b.roofs.1); roof2 = c(b.roofs.2)
        animalPatches = SIMD4(b.animalPatches ?? .zero, b.animalPatches == nil ? 0 : 1)
        i = SIMD4(b.villages, b.roadTrees, b.flatRoofs ? 1 : 0, b.levees)
        j = SIMD4(Float(b.landmarks.0.rawValue), b.landmarks.1, Float(b.landmarks.2.rawValue), b.landmarks.3)
        k = SIMD4(b.riverDry, b.sodiumLamps, b.lampsOffLate ? 1 : 0, 0)
    }
}

struct LegGPU {
    var biome: BiomeGPU
    /// start (world y relative to the frame's reference), seed, index, unused
    var info: SIMD4<Float>
    /// railway origin (leg-local x, y), angle, present
    var rail: SIMD4<Float>
    /// railway wiggle amplitude, wavelength, phase, electrified
    var railShape: SIMD4<Float>
}

/// The train passing on screen, if any.
struct TrainGPU {
    /// rail origin (x, y relative to the reference), angle, active
    var rail: SIMD4<Float>
    /// wiggle amplitude, wavelength, phase, unused
    var shape: SIMD4<Float>
    /// nose position along the rail, direction, car length, cars
    var run: SIMD4<Float>
    /// locomotives, kind (0 passenger, 1 freight), unused, unused
    var info: SIMD4<Float>
    var body, stripe, roof, locomotive: SIMD4<Float>

    static let none = TrainGPU(rail: .zero, shape: .zero, run: .zero, info: .zero, body: .zero, stripe: .zero,
                               roof: .zero, locomotive: .zero)
}

/// Shared by every pass in a frame.
struct SceneGPU {
    /// four river phases at the reference y
    var river: SIMD4<Float>
    /// river base x, road offset from the river, road phase, crossroad phase
    var road: SIMD4<Float>
    /// direction towards the sun (x, y), shadow length per metre of height, sun elevation in radians
    var sun: SIMD4<Float>
    /// light colour and strength
    var light: SIMD4<Float>
    /// boundary (world y where leg B starts), morph length, sweep progress (-1 when flying), sweep wave length
    var morph: SIMD4<Float>
    /// seconds wrapped hourly, seconds wrapped every two hours, car phase 0...1, night 0...1
    var time: SIMD4<Float>
    /// hour of the day where the scene is, the hour the sun sets there, boat phase 0...1, unused
    var clock: SIMD4<Float>
    var train: TrainGPU
    var legA: LegGPU
    var legB: LegGPU
}

/// One rectangle of the ground cache being painted.
struct GroundGPU {
    /// texture origin (x, y), world origin of that texel corner (x, y relative to the reference)
    var origin: SIMD4<Float>
    /// metres per texel, unused...
    var texel: SIMD4<Float>
}

struct CloudsGPU {
    /// cloud-space origin of the bottom-left pixel (x, y), metres per pixel, cover
    var origin: SIMD4<Float>
    /// sun offset for lighting (x, y), ground shadow offset (x, y)
    var offsets: SIMD4<Float>
    /// view height in pixels, unused...
    var view: SIMD4<Float>
}

/// One batch of instanced animals, for one leg.
struct AnimalsGPU {
    /// first cell x, y, cells across, cell spacing
    var grid: SIMD4<Float>
    /// leg start (y relative to the reference), lowest and highest world y drawn, unused
    var leg: SIMD4<Float>
    /// herd drift x, y, unused, unused
    var drift: SIMD4<Float>
}

struct CompositeGPU {
    /// view width and height in pixels, metres per pixel, cache texels per pixel
    var view: SIMD4<Float>
    /// world x and y (relative to the reference) of the bottom-left pixel corner, gust-space origin (x, y)
    var world: SIMD4<Float>
    /// cache texel coordinate of the bottom-left pixel corner, wrapped (x, y), cache size (w, h)
    var cache: SIMD4<Float>
    /// bird position in view pixels (x, y), heading radians, bank -1...1
    var bird: SIMD4<Float>
    /// wing spread 0...1, bird altitude in metres, bird scale in pixels, bird visibility
    var wings: SIMD4<Float>
    /// paper grain strength, edge vignette strength, debug, unused
    var finish: SIMD4<Float>
    /// cloud-space offset of the view's corner from the cloud texture's corner (x, y), metres per cloud pixel
    var clouds: SIMD4<Float>
    /// flock leader in view pixels (x, y), heading, visible
    var flock: SIMD4<Float>
    /// formation, birds, half wingspan in pixels, shadow offset in pixels per unit of sun shadow length
    var flockShape: SIMD4<Float>
    /// colour, seconds since the flock appeared
    var flockLook: SIMD4<Float>
}

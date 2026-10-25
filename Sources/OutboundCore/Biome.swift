import simd

/// Everything the ground shader needs to paint one kind of landscape. Colours are sRGB, lengths are metres.
public struct Biome: Sendable {
    public enum Layout: Int, Sendable {
        /// Open ground with soft patches, like the pampas or the savanna.
        case grassland
        /// Long staggered rice plots with levees and irrigation canals.
        case paddies
        /// Rounded fields between hedgerows.
        case fields
        /// Parallel bulb strips divided by ditches.
        case stripes
        /// Centre-pivot circles on a square section grid.
        case pivots
        /// Pine heath on pale lichen, with patterned bogs, as in Lapland.
        case taiga
    }

    public enum Animal: Int, Sendable {
        case none, cattle, zebra, wildebeest, sheep, reindeer, gazelle
    }

    public var layout: Layout

    public var ground: SIMD3<Float>
    public var groundDark: SIMD3<Float>
    /// Field fills, picked per field by hash.
    public var crops: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    /// Hedgerows between fields, or levees between paddies.
    public var hedge: SIMD3<Float>
    public var water: SIMD3<Float>
    public var shallows: SIMD3<Float>
    public var sand: SIMD3<Float>
    public var road: SIMD3<Float>
    public var canopy: SIMD3<Float>
    public var canopyLight: SIMD3<Float>
    public var rock: SIMD3<Float>
    public var snow: SIMD3<Float>

    public var fieldSize: Float = 160
    public var hedgeWidth: Float = 7
    /// How much field borders wander, 0 for surveyed straight lines.
    public var warp: Float = 0.5
    /// Share of fields left as plain ground.
    public var fallow: Float = 0.1
    public var patchiness: Float = 0.5
    /// Strength of the brush strokes in crops and grass.
    public var strokes: Float = 0.5
    /// How strongly fields catch the wind, 0 for short grass, 1 for tall flowering crops.
    public var sway: Float = 0.5
    /// How much fields reflect the sky, for flooded paddies.
    public var flooded: Float = 0

    public var trees: Float = 0.3
    public var treeSize: Float = 9
    public var hedgeTrees: Float = 0.3
    /// 0 scatters trees evenly, 1 gathers them into groves.
    public var clumping: Float = 0.6
    /// Chance of a straight windbreak line of trees along a survey line.
    public var treeLines: Float = 0
    public var orchards: Float = 0
    /// Petals or blossom flecks drifting on the ground near trees.
    public var petals: Float = 0

    public var riverWidth: Float = 34
    public var riverWander: Float = 90
    public var roadWidth: Float = 9
    public var paved: Float = 1
    public var ponds: Float = 0.2
    public var houses: Float = 0.3
    public var rocks: Float = 0
    public var snowCover: Float = 0
    public var frozen: Float = 0

    /// Traffic keeps left, as in Japan and India.
    public var drivesLeft = false
    /// How fully village streets are lit, 0 for none to 1 for a lamp on every pole.
    public var streetLights: Float = 0.5
    /// The colour of the newer LED street lamps.
    public var lampColor: SIMD3<Float> = Biome.rgb(0xffe0b8)
    /// The share of older sodium lamps still glowing orange among the LED ones, 0 to 1.
    public var sodiumLamps: Float = 0.3
    /// Village lamps go off from midnight until five, as in much of rural France.
    public var lampsOffLate = false
    /// Boats on the river, 0 to 1.
    public var boats: Float = 0
    public var boat: Boat = .rowing

    public enum Boat: Int, Sendable {
        /// Small open boats, wooden or painted.
        case rowing
        /// Long canal barges.
        case barge
        /// Hippos wallowing instead of boats.
        case hippos
    }

    /// Roof colours, picked per house.
    public var roofs: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = (Biome.rgb(0xcc543d), Biome.rgb(0xad664c), Biome.rgb(0x6b8099))
    /// Flat roofs with water tanks, as in Punjab, instead of pitched ones.
    public var flatRoofs = false
    /// How often the road runs through a village rather than open country, 0 to 1.
    public var villages: Float = 0.3
    /// Avenues of trees along the road, 0 to 1.
    public var roadTrees: Float = 0
    /// Grassy dykes either side of the river, in metres.
    public var levees: Float = 0
    /// 1 for a river that is mostly a dry sand bed with a trickle down the middle.
    public var riverDry: Float = 0
    /// Landmarks scattered across the land, with how many per square kilometre or so.
    public var landmarks: (Landmark, Float, Landmark, Float) = (.none, 0, .none, 0)

    public enum Landmark: Int, Sendable {
        case none
        /// Rounded granite outcrops ringed with green, as on the Serengeti plains.
        case kopje
        /// A windmill pump and round tank with a trampled ring and cattle trails fanning out.
        case waterPoint
        /// An estancia in its dark grove of eucalyptus.
        case grove
        /// House, sheds and steel grain bins behind an L of cedar windbreak.
        case farmstead
        /// A tube-well hut with its tank and shade tree.
        case tubeWell
        /// A brick kiln with its tall chimney and drying yards.
        case kiln
        /// Glasshouses that glint in the sun.
        case glasshouse
        /// A polder windmill by a ditch.
        case windmill
        /// Rows of cattle pens.
        case feedlot
        /// A charred patch of burnt grass greening at the edges.
        case burn
        /// A dark lake with sandy shallows.
        case lake
        /// A round reindeer corral with funnel fences.
        case corral
    }

    public var animal: Animal = .none
    public var herds: Float = 0
    public var animalColor: SIMD3<Float> = Biome.rgb(0x6b3e26)
    /// Patches on the coat, as on Normande or Hereford cattle; nil for plain coats.
    public var animalPatches: SIMD3<Float>?
    public var cars: Float = 0.3

    public init(layout: Layout, ground: SIMD3<Float>, groundDark: SIMD3<Float>,
                crops: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), hedge: SIMD3<Float>,
                water: SIMD3<Float> = Biome.rgb(0x2f6cc0), shallows: SIMD3<Float> = Biome.rgb(0x5b9be0),
                sand: SIMD3<Float> = Biome.rgb(0xd9c48f), road: SIMD3<Float> = Biome.rgb(0xc4bdb0),
                canopy: SIMD3<Float> = Biome.rgb(0x2f6b3a), canopyLight: SIMD3<Float> = Biome.rgb(0x4f8f4a),
                rock: SIMD3<Float> = Biome.rgb(0x9d9c94), snow: SIMD3<Float> = Biome.rgb(0xf4f6f8)) {
        self.layout = layout
        self.ground = ground
        self.groundDark = groundDark
        self.crops = crops
        self.hedge = hedge
        self.water = water
        self.shallows = shallows
        self.sand = sand
        self.road = road
        self.canopy = canopy
        self.canopyLight = canopyLight
        self.rock = rock
        self.snow = snow
    }

    public static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
    }
}

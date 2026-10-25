import Foundation

public struct Season: Sendable {
    /// Calendar months (1 to 12) this season covers at the place.
    public let months: Set<Int>
    /// "Late winter · mustard in flower"
    public let line: String
    public let biome: Biome
}

public struct Place: Sendable, Identifiable {
    public let id: String
    /// "Punjab, India"
    public let name: String
    public let anchor: Coordinate
    public let seasons: [Season]
    /// The season the place is best known for, shown when seasons follow the calendar is off.
    public let signature: Int
    public var railway: Railway?

    /// What is happening at the place on this date.
    public func season(on date: Date, calendar: Calendar = .current) -> Season {
        let month = calendar.component(.month, from: date)
        return seasons.first { $0.months.contains(month) } ?? seasons[signature]
    }

    public var signatureSeason: Season { seasons[signature] }
}

extension Place {
    /// In flying order, so neighbours look different from each other.
    public static let all: [Place] = [punjab, niigata, serengeti, normandy, lisse, pampa, lapland, kansas]

    public static func named(_ id: String) -> Place? {
        all.first { $0.id == id }
    }
}

private func rgb(_ hex: UInt32) -> SIMD3<Float> { Biome.rgb(hex) }

private extension Biome {
    func with(_ change: (inout Biome) -> Void) -> Biome {
        var copy = self
        change(&copy)
        return copy
    }
}

// MARK: - Punjab: rounded fields between dark hedgerow bands

private let punjabBase: Biome = {
    var b = Biome(layout: .fields, ground: rgb(0x8fbf45), groundDark: rgb(0x5f9a35),
                  crops: (rgb(0xf3cf1d), rgb(0xf6dc3c), rgb(0xe9bd12), rgb(0x9cc845)), hedge: rgb(0x2f7c34),
                  water: rgb(0x2e68c4), shallows: rgb(0x4f8fe0), road: rgb(0xc7c1b4), canopy: rgb(0x2c6a3b),
                  canopyLight: rgb(0x3f8a45))
    b.fieldSize = 190; b.hedgeWidth = 9; b.warp = 0.55; b.fallow = 0.06; b.sway = 0.9; b.strokes = 0.6
    b.trees = 0.2; b.treeSize = 10; b.hedgeTrees = 0.35; b.clumping = 0.85; b.houses = 0.35; b.ponds = 0.25
    b.riverWidth = 34; b.riverWander = 60; b.roadWidth = 12; b.paved = 1
    b.animal = .cattle; b.herds = 0.15; b.animalColor = rgb(0x3d3530); b.cars = 0.25
    // Smaller rounded fields between narrow bunds dotted with trees, compact brick villages with flat roofs and
    // water tanks, tube-well huts and the odd brick kiln; traffic keeps left.
    b.fieldSize = 125; b.hedgeWidth = 5; b.hedgeTrees = 0.7
    b.villages = 0.6; b.flatRoofs = true; b.roadTrees = 0.35
    b.roofs = (rgb(0xd8c4a0), rgb(0xe0b0a8), rgb(0xeeeae2))
    b.drivesLeft = true; b.streetLights = 0.25; b.lampColor = rgb(0xff9a30)
    b.landmarks = (.tubeWell, 0.35, .kiln, 0.25)
    b.boats = 0.05
    return b
}()

private let punjab = Place(
    id: "punjab", name: "Punjab, India", anchor: Coordinate(latitude: 30.838, longitude: 76.189),
    seasons: [
        Season(months: [1, 2, 3], line: "Late winter · mustard in flower", biome: punjabBase),
        Season(months: [4, 5], line: "Spring · wheat turning gold", biome: punjabBase.with {
            $0.crops = (rgb(0xe2b23a), rgb(0xd9a62f), rgb(0xc9a15a), rgb(0xe8c35a))
            $0.ground = rgb(0xb7a35a); $0.sway = 0.8
        }),
        Season(months: [6, 7, 8, 9], line: "Monsoon · young rice in flooded fields", biome: punjabBase.with {
            $0.crops = (rgb(0x5fae4a), rgb(0x76c05a), rgb(0x4f9f60), rgb(0x8ccf62))
            $0.flooded = 0.45; $0.ground = rgb(0x6aa944); $0.riverWidth = 44; $0.ponds = 0.45; $0.sway = 0.5
        }),
        Season(months: [10, 11, 12], line: "Autumn · rice harvest and new wheat", biome: punjabBase.with {
            // Stubble, a few burnt fields, fresh-sown wheat on dark tilled soil.
            $0.crops = (rgb(0xcdb576), rgb(0x3a3430), rgb(0x7a6048), rgb(0x9cc860))
            $0.ground = rgb(0x9ab656); $0.sway = 0.4
        })
    ],
    signature: 0,
    railway: Railway(kind: .passenger, body: rgb(0x33549e), stripe: rgb(0xe6d9b3), roof: rgb(0x5c6370), locomotive: rgb(0xa82924),
                     cars: 18, carLength: 23, locomotives: 1, speed: 27, electrified: true, chance: 0.7))

// MARK: - Niigata: flooded rice paddies and sakura

private let niigataBase: Biome = {
    var b = Biome(layout: .paddies, ground: rgb(0x6fb08a), groundDark: rgb(0x4d9a78),
                  crops: (rgb(0x5aa8e6), rgb(0x76bcf0), rgb(0x41a07c), rgb(0x5fbf8c)), hedge: rgb(0xdcd3b6),
                  water: rgb(0x2b63b3), shallows: rgb(0x4686d2), sand: rgb(0xd8c79a), road: rgb(0xbfb9b0),
                  canopy: rgb(0xf0a3b6), canopyLight: rgb(0xf9c8d5))
    b.fieldSize = 34; b.hedgeWidth = 2.6; b.warp = 0.08; b.fallow = 0.05; b.flooded = 0.8; b.sway = 0.3
    b.strokes = 0.35; b.trees = 0.11; b.treeSize = 13; b.hedgeTrees = 0; b.clumping = 0.15; b.petals = 0.8
    b.riverWidth = 42; b.riverWander = 18; b.roadWidth = 8; b.paved = 1; b.houses = 0.15; b.ponds = 0.1
    b.cars = 0.2
    // Sakura along the lanes and dykes rather than in the fields, villages of dark tile and coloured metal roofs,
    // a wide river between grassy dykes, white LED street lights; traffic keeps left.
    b.trees = 0.03; b.roadTrees = 0.55; b.villages = 0.55; b.levees = 18
    b.roofs = (rgb(0x4a4e55), rgb(0x3e5a80), rgb(0x7a3a3a))
    b.riverWidth = 60; b.roadWidth = 7
    b.drivesLeft = true; b.streetLights = 0.7; b.lampColor = rgb(0xffd4a6)
    b.boats = 0.25
    b.landmarks = (.glasshouse, 0.08, .none, 0)
    return b
}()

private let niigata = Place(
    id: "niigata", name: "Niigata, Japan", anchor: Coordinate(latitude: 37.935, longitude: 139.398),
    seasons: [
        Season(months: [4, 5], line: "Spring · sakura over flooded paddies", biome: niigataBase),
        Season(months: [6, 7, 8], line: "Summer · rice in full green", biome: niigataBase.with {
            $0.crops = (rgb(0x4fa85a), rgb(0x67b95e), rgb(0x3f9a55), rgb(0x7cc76a))
            $0.flooded = 0.15; $0.canopy = rgb(0x2f6f3c); $0.canopyLight = rgb(0x4b9148); $0.petals = 0
            $0.sway = 0.7
        }),
        Season(months: [9, 10], line: "Autumn · rice harvest", biome: niigataBase.with {
            $0.crops = (rgb(0xe0b84e), rgb(0xd3a640), rgb(0xb59a6a), rgb(0xe8c766))
            $0.flooded = 0.05; $0.canopy = rgb(0xc8693a); $0.canopyLight = rgb(0xe08a4a); $0.petals = 0
            $0.hedge = rgb(0xcfc39e); $0.sway = 0.6
        }),
        Season(months: [11, 12, 1, 2, 3], line: "Winter · snow over the paddies", biome: niigataBase.with {
            $0.crops = (rgb(0xeef2f6), rgb(0xe4eaf1), rgb(0xd9e2ec), rgb(0xf3f5f8))
            $0.flooded = 0.1; $0.snowCover = 0.85; $0.canopy = rgb(0x6a5a52); $0.canopyLight = rgb(0x8a7a70)
            $0.petals = 0; $0.hedge = rgb(0xc9cdd2); $0.sway = 0; $0.cars = 0.1
        })
    ],
    signature: 0,
    railway: Railway(kind: .passenger, body: rgb(0xcbcfd4), stripe: rgb(0xedb72e), roof: rgb(0x9ea1a6), locomotive: rgb(0xcbcfd4),
                     cars: 4, carLength: 20, locomotives: 0, speed: 26, electrified: true, chance: 0.75))

// MARK: - Serengeti: open savanna, herds and acacias

private let serengetiBase: Biome = {
    var b = Biome(layout: .grassland, ground: rgb(0xe0ad48), groundDark: rgb(0xc58f34),
                  crops: (rgb(0xd9a443), rgb(0xe7bb5c), rgb(0xc99a3e), rgb(0xb98a38)), hedge: rgb(0xa77a33),
                  water: rgb(0x3d8f8a), shallows: rgb(0x5fb3a8), sand: rgb(0xc9a46a), road: rgb(0xb7774a),
                  canopy: rgb(0x55803a), canopyLight: rgb(0x77a04a))
    b.patchiness = 0.85; b.strokes = 0.45; b.sway = 0.6; b.trees = 0.035; b.treeSize = 17; b.hedgeTrees = 0
    b.clumping = 0.1
    b.riverWidth = 26; b.riverWander = 70; b.roadWidth = 6; b.paved = 0; b.houses = 0; b.ponds = 0.35
    b.animal = .zebra; b.herds = 0.6; b.animalColor = rgb(0xf2efe8); b.cars = 0.04
    // Granite kopjes ringed with green, burn scars, olive-brown seasonal water with hippos, and through the dry
    // season mostly gazelles: the great herds are up north until December.
    b.animal = .gazelle; b.herds = 0.3; b.animalColor = rgb(0xc49a5c)
    b.water = rgb(0x5f6b48); b.shallows = rgb(0x7a7a52); b.riverWidth = 16
    b.canopy = rgb(0x5d7a36); b.canopyLight = rgb(0x7f9a48); b.treeSize = 16; b.trees = 0.045
    b.rock = rgb(0xb9ab98)
    b.landmarks = (.kopje, 0.4, .burn, 0.22)
    b.villages = 0; b.streetLights = 0
    b.boats = 0.5; b.boat = .hippos
    return b
}()

private let serengeti = Place(
    id: "serengeti", name: "Serengeti, Tanzania", anchor: Coordinate(latitude: -2.542, longitude: 35.063),
    seasons: [
        Season(months: [6, 7, 8, 9, 10], line: "Dry season · long grass", biome: serengetiBase),
        Season(months: [11, 12], line: "Short rains · the herds arrive", biome: serengetiBase.with {
            $0.ground = rgb(0xa9b84e); $0.groundDark = rgb(0x86a03e)
            $0.crops = (rgb(0xb7b552), rgb(0x9fb04a), rgb(0xcfb257), rgb(0x8ea845))
            $0.animal = .zebra; $0.animalColor = rgb(0xf2efe8); $0.herds = 0.6; $0.landmarks = (.kopje, 0.4, .none, 0)
        }),
        Season(months: [1, 2, 3], line: "Calving season · wildebeest on short grass", biome: serengetiBase.with {
            $0.ground = rgb(0x93b84a); $0.groundDark = rgb(0x76a03c)
            $0.crops = (rgb(0x8fb64a), rgb(0xa5c25a), rgb(0x7ea842), rgb(0xb3c763))
            $0.animal = .wildebeest; $0.animalColor = rgb(0x4a4038); $0.herds = 0.95; $0.sway = 0.3
            $0.landmarks = (.kopje, 0.4, .none, 0)
        }),
        Season(months: [4, 5], line: "Long rains · lush plains", biome: serengetiBase.with {
            $0.ground = rgb(0x6fa840); $0.groundDark = rgb(0x568f35)
            $0.crops = (rgb(0x6fa840), rgb(0x86b84c), rgb(0x5e9a3a), rgb(0x9cc45a))
            $0.ponds = 0.6; $0.riverWidth = 26; $0.herds = 0.4; $0.animal = .wildebeest; $0.animalColor = rgb(0x4a4038)
            $0.landmarks = (.kopje, 0.4, .none, 0)
        })
    ],
    signature: 0)

// MARK: - La Pampa: endless grass, cattle and dirt roads

private let pampaBase: Biome = {
    var b = Biome(layout: .grassland, ground: rgb(0x8cc43f), groundDark: rgb(0x6da634),
                  crops: (rgb(0x86bf3c), rgb(0x9ccc48), rgb(0x76b236), rgb(0xa6d054)), hedge: rgb(0x5f9330),
                  water: rgb(0x2e70c8), shallows: rgb(0x4e93e0), sand: rgb(0xd6c08e), road: rgb(0xb88b5c),
                  canopy: rgb(0x2f6a33), canopyLight: rgb(0x4a8a3e))
    b.patchiness = 0.6; b.strokes = 0.55; b.sway = 0.35; b.trees = 0.02; b.treeSize = 12; b.hedgeTrees = 0
    b.clumping = 0.7; b.treeLines = 0.35
    b.riverWidth = 32; b.riverWander = 22; b.roadWidth = 6; b.paved = 0; b.houses = 0.06; b.ponds = 0.12
    b.animal = .cattle; b.herds = 0.6; b.animalColor = rgb(0x6b3e26); b.cars = 0.12
    // Kilometre-wide paddocks, a windmill and round tank in each with cattle trails fanning out, estancias in
    // dark eucalyptus groves, black Angus, and only a thin reedy creek for a river.
    b.fieldSize = 900; b.animalColor = rgb(0x1e1b1a); b.herds = 0.48
    b.riverWidth = 9; b.levees = 0
    b.landmarks = (.waterPoint, 0.55, .grove, 0.3)
    b.villages = 0.05; b.houses = 0.03; b.streetLights = 0
    b.roofs = (rgb(0xc65a3e), rgb(0x9a9c9e), rgb(0xe6e2da))
    return b
}()

private let pampa = Place(
    id: "pampa", name: "La Pampa, Argentina", anchor: Coordinate(latitude: -36.842, longitude: -64.037),
    seasons: [
        Season(months: [9, 10, 11], line: "Spring · open grassland", biome: pampaBase),
        Season(months: [12, 1, 2], line: "Summer · sunflowers beside the pasture", biome: pampaBase.with {
            $0.layout = .fields; $0.fieldSize = 420; $0.hedgeWidth = 4; $0.warp = 0.1; $0.fallow = 0.45
            $0.crops = (rgb(0xf2c522), rgb(0x8cc43f), rgb(0xe9b81c), rgb(0x9ccc48)); $0.hedge = rgb(0x6e9a3a)
            $0.sway = 0.7
        }),
        Season(months: [3, 4, 5], line: "Autumn · golden pasture", biome: pampaBase.with {
            $0.ground = rgb(0xc2b25a); $0.groundDark = rgb(0xa49548)
            $0.crops = (rgb(0xc7b55e), rgb(0xd4c06a), rgb(0xb3a24f), rgb(0xa8b356))
        }),
        Season(months: [6, 7, 8], line: "Winter · frost on the pasture", biome: pampaBase.with {
            $0.ground = rgb(0xa9b58f); $0.groundDark = rgb(0x8d9c78)
            $0.crops = (rgb(0xb3bf9c), rgb(0xc4ccae), rgb(0x9fae86), rgb(0xd0d6c0)); $0.sway = 0.1
        })
    ],
    signature: 0,
    railway: Railway(kind: .freight, body: rgb(0xa6a29a), stripe: rgb(0x9c4a38), roof: rgb(0x9a968e), locomotive: rgb(0xb84d33),
                     cars: 40, carLength: 16, locomotives: 2, speed: 15, electrified: false, chance: 0.35))

// MARK: - Lapland: fells, spruce and rocky outcrops

private let laplandBase: Biome = {
    var b = Biome(layout: .fields, ground: rgb(0x79b04a), groundDark: rgb(0x2f6a2e),
                  crops: (rgb(0x86bd4f), rgb(0x9cc95c), rgb(0x6fa944), rgb(0xb4d06a)), hedge: rgb(0x2c662c),
                  water: rgb(0x2a63b0), shallows: rgb(0x4a86d0), sand: rgb(0xcdbf98), road: rgb(0xb9b3a8),
                  canopy: rgb(0x2b5a33), canopyLight: rgb(0x3f7a44), rock: rgb(0x9a9890))
    b.fieldSize = 260; b.hedgeWidth = 26; b.warp = 0.8; b.fallow = 0.2; b.strokes = 0.5; b.sway = 0.25
    b.trees = 0.22; b.treeSize = 8; b.hedgeTrees = 0.8; b.clumping = 0.9; b.rocks = 0.45; b.houses = 0.05; b.ponds = 0.3
    b.riverWidth = 40; b.riverWander = 40; b.roadWidth = 7; b.paved = 1
    b.animal = .reindeer; b.herds = 0.2; b.animalColor = rgb(0x6b5a4a); b.cars = 0.06
    // Pine heath on pale reindeer lichen broken by patterned bogs, dark lakes, reindeer corrals, red houses with
    // dark metal roofs, cold white lamps.
    b.layout = .taiga
    b.crops = (rgb(0xd6d4c0), rgb(0x8aaa5a), rgb(0x7a8a4a), rgb(0x9a8a5a))
    b.canopy = rgb(0x3d5a3a); b.canopyLight = rgb(0x5a7a4a); b.hedgeTrees = 0.55; b.trees = 0.02
    b.roofs = (rgb(0x3a3a3e), rgb(0x7a2a22), rgb(0x2a2a2e))
    b.villages = 0.1; b.streetLights = 0.6; b.lampColor = rgb(0xffd4a6)
    b.landmarks = (.lake, 0.35, .corral, 0.15)
    b.boats = 0.1
    return b
}()

private let lapland = Place(
    id: "lapland", name: "Lapland, Finland", anchor: Coordinate(latitude: 67.126, longitude: 26.827),
    seasons: [
        Season(months: [6, 7, 8], line: "Summer · midnight sun on the fells", biome: laplandBase),
        Season(months: [9], line: "Autumn · ruska colours on the fells", biome: laplandBase.with {
            // Crimson ground layer, ochre bogs and gold birches against dark pine on pale lichen.
            $0.crops = (rgb(0xd2cdb0), rgb(0xc88a3a), rgb(0xb8402a), rgb(0xc8702a))
            $0.canopyLight = rgb(0xe0b040)
        }),
        Season(months: [10, 11, 12, 1, 2, 3, 4], line: "Winter · snow on the fells", biome: laplandBase.with {
            $0.crops = (rgb(0xf1f4f7), rgb(0xe6ecf2), rgb(0xdce4ec), rgb(0xd6dde6)); $0.ground = rgb(0xeef2f6)
            $0.snowCover = 0.9; $0.frozen = 0.85; $0.sway = 0; $0.rock = rgb(0x8c8f96)
            $0.herds = 0.35; $0.boats = 0
        }),
        Season(months: [5], line: "Spring · snowmelt on the fells", biome: laplandBase.with {
            $0.crops = (rgb(0xb7b07a), rgb(0x9aa86a), rgb(0xe9edf1), rgb(0x8a7a5a)); $0.snowCover = 0.35
            $0.frozen = 0.2
        })
    ],
    signature: 0,
    railway: Railway(kind: .passenger, body: rgb(0xeceeee), stripe: rgb(0x008c4d), roof: rgb(0x9a9ca0), locomotive: rgb(0x008c4d),
                     cars: 5, carLength: 26, locomotives: 1, speed: 25, electrified: true, chance: 0.4))

// MARK: - Normandy: bocage hedgerows and orchards

private let normandyBase: Biome = {
    var b = Biome(layout: .fields, ground: rgb(0x8cc74e), groundDark: rgb(0x3f8a3a),
                  crops: (rgb(0x92cc52), rgb(0xb7d95e), rgb(0xd7d44a), rgb(0x7cbd4a)), hedge: rgb(0x2e6e34),
                  water: rgb(0x2d64bd), shallows: rgb(0x4d8bd8), road: rgb(0xbfbab2), canopy: rgb(0xf3e6ea),
                  canopyLight: rgb(0xfbf4f6))
    b.fieldSize = 150; b.hedgeWidth = 8; b.warp = 0.6; b.fallow = 0.1; b.sway = 0.5
    b.trees = 0.08; b.treeSize = 8; b.hedgeTrees = 0.6; b.clumping = 0.7; b.orchards = 0.22; b.petals = 0.4; b.houses = 0.3
    b.riverWidth = 34; b.riverWander = 140; b.roadWidth = 8; b.paved = 1; b.ponds = 0.2
    b.animal = .cattle; b.herds = 0.3; b.animalColor = rgb(0xece7de); b.cars = 0.25
    // Larger bocage fields with hedges full of oaks, hedged lanes, Normande cows white with brown patches, farms
    // under slate, old tile or thatch.
    b.fieldSize = 210; b.hedgeTrees = 0.7; b.roadTrees = 0.3; b.villages = 0.35
    b.roofs = (rgb(0x5d636b), rgb(0x9a5a42), rgb(0x8a7a5a))
    b.animalColor = rgb(0xf0ebe2); b.animalPatches = rgb(0x8a4a2a); b.herds = 0.35
    b.riverWidth = 22; b.streetLights = 0.45; b.lampColor = rgb(0xffbb6e)
    b.boats = 0.3
    return b
}()

private let normandy = Place(
    id: "normandy", name: "Normandy, France", anchor: Coordinate(latitude: 48.948, longitude: -0.148),
    seasons: [
        Season(months: [4, 5], line: "Spring · apple blossom and new grass", biome: normandyBase),
        Season(months: [6, 7, 8], line: "Summer · wheat, flax and pasture", biome: normandyBase.with {
            $0.crops = (rgb(0xe3c252), rgb(0x86a9de), rgb(0x8cc74e), rgb(0xd6b84a)); $0.petals = 0
            $0.canopy = rgb(0x2f6b38); $0.canopyLight = rgb(0x4d8e45); $0.sway = 0.8
        }),
        Season(months: [9, 10, 11], line: "Autumn · apple harvest", biome: normandyBase.with {
            $0.crops = (rgb(0x86b84c), rgb(0xa9744a), rgb(0xc9a24a), rgb(0x6fa642)); $0.petals = 0
            $0.canopy = rgb(0x5f7a35); $0.canopyLight = rgb(0xc9873a); $0.hedge = rgb(0x4a6a2f)
        }),
        Season(months: [12, 1, 2, 3], line: "Winter · bare hedgerows", biome: normandyBase.with {
            $0.crops = (rgb(0x7fa65a), rgb(0x9a7a56), rgb(0x8a9d62), rgb(0xa08868)); $0.petals = 0
            $0.canopy = rgb(0x6d5c4f); $0.canopyLight = rgb(0x8a7866); $0.hedge = rgb(0x5a5a45); $0.sway = 0.2
            $0.ground = rgb(0x7f9f5a)
        })
    ],
    signature: 0,
    railway: Railway(kind: .passenger, body: rgb(0xebebed), stripe: rgb(0x295cad), roof: rgb(0x9a9ca2), locomotive: rgb(0xebebed),
                     cars: 4, carLength: 22, locomotives: 0, speed: 30, electrified: true, chance: 0.6))

// MARK: - Lisse: bulb fields in stripes

private let lisseBase: Biome = {
    var b = Biome(layout: .stripes, ground: rgb(0x7fb352), groundDark: rgb(0x5c9443),
                  crops: (rgb(0xe3392f), rgb(0xf6cd2f), rgb(0xef7fa8), rgb(0x8f58b8)), hedge: rgb(0x6e9a4a),
                  water: rgb(0x355f9c), shallows: rgb(0x4f7fbf), sand: rgb(0x9fb27a), road: rgb(0xb9b4ac),
                  canopy: rgb(0x2f6635), canopyLight: rgb(0x4a8a44))
    b.fieldSize = 22; b.hedgeWidth = 3; b.warp = 0.03; b.fallow = 0.18; b.strokes = 0.3; b.sway = 0.4
    b.trees = 0.03; b.treeSize = 8; b.hedgeTrees = 0.1; b.houses = 0.25; b.ponds = 0
    b.riverWidth = 18; b.riverWander = 8; b.roadWidth = 7; b.paved = 1; b.cars = 0.3
    // Tree-lined lanes, brick villages under orange pantile, glasshouses and the odd polder mill, bright LED lamps,
    // and boats on the canals. Many beds are already topped, leaving green stripes.
    b.fallow = 0.3; b.roadTrees = 0.6; b.villages = 0.5
    b.roofs = (rgb(0xb5523a), rgb(0x3a3a3e), rgb(0x8a4a3a))
    b.streetLights = 0.8; b.lampColor = rgb(0xffc98a)
    b.landmarks = (.glasshouse, 0.25, .windmill, 0.18)
    b.boats = 0.5
    return b
}()

private let lisse = Place(
    id: "lisse", name: "Lisse, Netherlands", anchor: Coordinate(latitude: 52.258, longitude: 4.558),
    seasons: [
        Season(months: [4, 5], line: "Spring · tulips in bloom", biome: lisseBase),
        Season(months: [6, 7, 8, 9], line: "Summer · bulbs lifted, fields resting", biome: lisseBase.with {
            $0.crops = (rgb(0x86b85a), rgb(0xb5a77c), rgb(0x9cc46a), rgb(0xc2b48a)); $0.fallow = 0.3
        }),
        Season(months: [10, 11, 12, 1, 2, 3], line: "Winter · new bulbs under straw", biome: lisseBase.with {
            $0.crops = (rgb(0xc9aa6a), rgb(0xb89a5e), rgb(0x8c6f50), rgb(0xd2b878)); $0.fallow = 0.15
            $0.ground = rgb(0x8aa86a); $0.hedge = rgb(0x7a8f5a); $0.sway = 0.1
        })
    ],
    signature: 0,
    railway: Railway(kind: .passenger, body: rgb(0xfac91a), stripe: rgb(0x1a338c), roof: rgb(0x8c8e94), locomotive: rgb(0xfac91a),
                     cars: 6, carLength: 26, locomotives: 0, speed: 34, electrified: true, chance: 0.9))

// MARK: - Kansas: centre pivots on the section grid

private let kansasBase: Biome = {
    var b = Biome(layout: .pivots, ground: rgb(0xd6c08a), groundDark: rgb(0xc2aa72),
                  crops: (rgb(0x5f9e3e), rgb(0x76ad45), rgb(0xd9b24a), rgb(0x4e8f3a)), hedge: rgb(0xc8b893),
                  water: rgb(0x3c6fae), shallows: rgb(0x5a8fcc), sand: rgb(0xd2bf92), road: rgb(0xcbbd9e),
                  canopy: rgb(0x4a6e35), canopyLight: rgb(0x6a8f45))
    b.fieldSize = 270; b.hedgeWidth = 6; b.warp = 0; b.fallow = 0.12; b.strokes = 0.5; b.sway = 0.6
    b.trees = 0.015; b.treeSize = 10; b.hedgeTrees = 0.05; b.clumping = 0.95; b.houses = 0.08
    b.ponds = 0.05
    b.riverWidth = 16; b.riverWander = 120; b.roadWidth = 7; b.paved = 0; b.cars = 0.08
    b.animal = .cattle; b.herds = 0.08; b.animalColor = rgb(0x2e2622)
    // Bigger circles with their sprinkler arms, farmsteads behind cedar windbreaks with grain bins, the odd feedlot,
    // and the Arkansas a dry sand bed most of the year.
    b.fieldSize = 420; b.houses = 0; b.villages = 0; b.streetLights = 0
    b.landmarks = (.farmstead, 0.45, .feedlot, 0.1)
    b.riverDry = 1; b.riverWidth = 60; b.sand = rgb(0xd8c9a0)
    b.animalColor = rgb(0x1e1b1a)
    return b
}()

private let kansas = Place(
    id: "kansas", name: "Kansas, United States", anchor: Coordinate(latitude: 37.689, longitude: -100.851),
    seasons: [
        Season(months: [6, 7, 8], line: "Summer · corn under the pivots", biome: kansasBase),
        Season(months: [9, 10, 11], line: "Autumn · sorghum and harvest circles", biome: kansasBase.with {
            $0.crops = (rgb(0xc9a46a), rgb(0xa0522d), rgb(0xc9a046), rgb(0x8a7a5a))
        }),
        Season(months: [12, 1, 2], line: "Winter · green wheat in the circles", biome: kansasBase.with {
            $0.crops = (rgb(0x7a9e4a), rgb(0xc4ad80), rgb(0x8aa654), rgb(0xb59b70)); $0.ground = rgb(0xcdbb92)
            $0.sway = 0.1
        }),
        Season(months: [3, 4, 5], line: "Spring · wheat greening", biome: kansasBase.with {
            $0.crops = (rgb(0x7cb24a), rgb(0x92c05a), rgb(0xb5a46a), rgb(0x6aa542))
        })
    ],
    signature: 0,
    railway: Railway(kind: .freight, body: rgb(0xb8b8b3), stripe: rgb(0x8c6b54), roof: rgb(0xa8a8a2), locomotive: rgb(0xf27319),
                     cars: 100, carLength: 16, locomotives: 3, speed: 20, electrified: false, chance: 0.55))

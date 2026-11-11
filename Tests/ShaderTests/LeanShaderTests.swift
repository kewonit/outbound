import Foundation
import Metal
import Testing
@testable import Outbound
@testable import OutboundCore

/// The frame's shaders come in lean copies, each without parts most frames have no use for. Whichever copies draw a
/// frame, it has to come out the same picture.
@MainActor
@Suite(.serialized)
struct LeanShaderTests {
    static let width = 720, height = 450

    /// A frame of `place` at `seconds` into a flight, and at `hour` if given, drawn with the lean copies or without.
    private func frame(_ place: Place, seconds: Double, hour: Double? = nil, lean: Bool, gpu: GPU,
                       prepare: (World) -> Void = { _ in }) throws -> [UInt8] {
        let date = Date(timeIntervalSince1970: 1_782_907_200)
        let world = World(place: place, time: 0, date: date, light: .alwaysDay)
        let area = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        if let hour {
            var calendar = Calendar.current
            calendar.timeZone = .current
            let clock = calendar.startOfDay(for: date).addingTimeInterval(hour * 3600)
            world.now = { clock }
            world.light = .yourTime
        } else {
            world.now = { date }
        }
        world.home = area
        world.desktop = area
        world.centreRiver(on: area)
        world.advance(to: seconds)
        prepare(world)
        let renderer = ViewRenderer(gpu: gpu)
        renderer.waitsForPieces = true
        renderer.leanShaders = lean
        renderer.configure(frame: area, scale: 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat,
                                                                  width: Self.width, height: Self.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(gpu.device.makeTexture(descriptor: descriptor))
        let commands = try #require(gpu.queue.makeCommandBuffer())
        renderer.encode(world: world, into: target, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.error == nil)
        var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        target.getBytes(&bytes, bytesPerRow: Self.width * 4,
                        from: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0)
        return bytes
    }

    /// The most any channel differs by, and how many bytes differ at all.
    private func difference(_ a: [UInt8], _ b: [UInt8]) -> (worst: Int, count: Int) {
        var worst = 0, count = 0
        for i in a.indices where a[i] != b[i] {
            worst = max(worst, abs(Int(a[i]) - Int(b[i])))
            count += 1
        }
        return (worst, count)
    }

    @Test(arguments: Place.all.map(\.id))
    func leanCopiesPaintTheSamePicture(_ id: String) throws {
        let gpu = try GPU(leanNow: true)
        let place = try #require(Place.named(id))
        for hour in [nil, 23.0] as [Double?] {
            let whole = try frame(place, seconds: 30, hour: hour, lean: false, gpu: gpu)
            let lean = try frame(place, seconds: 30, hour: hour, lean: true, gpu: gpu)
            let differs = difference(whole, lean)
            // Fast maths may round a stray pixel the other way in another copy of a shader, and no more than that.
            #expect(differs.worst <= 1, "\(id) at \(hour.map { "\($0)" } ?? "noon")")
            #expect(differs.count <= whole.count / 1000, "\(id) at \(hour.map { "\($0)" } ?? "noon")")
            // And the picture is of something: a frame that came out blank would match itself too.
            #expect(Set(whole).count > 32)
        }
    }

    @Test func theSamePictureWithATrainAFlockOrAFlyTo() throws {
        let gpu = try GPU(leanNow: true)
        let first = try #require(Place.named("normandy"))
        // Flown on, two seconds at a time as the app would, until each is in view.
        func until(_ found: @escaping (World) -> Bool) -> (World) -> Void {
            { world in
                var time = world.time
                while time < 7200, !found(world) {
                    time += 2
                    world.advance(to: time)
                }
            }
        }
        let cases: [(String, (World) -> Void)] = [
            ("train", until { $0.trainPassing }),
            ("flock", until { $0.flock != nil }),
            ("band", until { $0.handoverPassing }),
            ("fly to", { world in
                let bottom = world.camera.y + Double(world.desktop.minY) * World.metresPerPoint - 50
                world.journey.fly(to: Place.all[1], from: bottom, time: world.time)
                world.advance(to: world.time + 0.8)
            })
        ]
        for (name, prepare) in cases {
            let whole = try frame(first, seconds: 30, lean: false, gpu: gpu, prepare: prepare)
            let lean = try frame(first, seconds: 30, lean: true, gpu: gpu, prepare: prepare)
            let differs = difference(whole, lean)
            #expect(differs.worst <= 1, "\(name)")
            #expect(differs.count <= whole.count / 1000, "\(name)")
        }
    }

    @Test func leanCopiesCompileByThemselves() async throws {
        // As the app makes them: nothing waits, and each takes its place once it is there.
        let gpu = try GPU()
        func ready() -> Bool {
            let lean = gpu.shaders.pipelines.lean
            return lean.viewByDay != nil && lean.viewAfterDark != nil && lean.skyPlain != nil && lean.skyBand != nil
                && lean.skyAround != nil && lean.skyBandAround != nil && lean.skyBird != nil
        }
        for _ in 0..<400 where !ready() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(ready())
    }

    @Test func theBirdsBoxHoldsTheBirdAndItsShadows() throws {
        let width = 3024, height = 1964
        let wings = SIMD4<Float>(0.5, 14, 54, 1)
        let reach = 54 * Float(1.6).squareRoot()
        for sun in [SIMD4<Float>(0.6, 0.8, 1.2, 0.7), SIMD4(-1, 0, 6, 0.2), SIMD4(0, -1, 0.3, 1.2)] {
            for bird in [SIMD2<Float>(1500, 900), SIMD2(20, 30), SIMD2(3000, 1950), SIMD2(-60, 400)] {
                let box = ViewRenderer.birdBox(bird: SIMD4(bird.x, bird.y, 0, 0), wings: wings, sun: sun,
                                               metresPerPixel: 0.225, width: width, height: height)
                let fall = SIMD2(sun.x, sun.y) * wings.y / 0.225
                for centre in [bird, bird - fall * sun.z, bird - fall * 0.35] {
                    // Every pixel of the circle that is on the target is inside the box, counted from the top left.
                    let left = max(Int((centre.x - reach).rounded(.down)), 0)
                    let right = min(Int((centre.x + reach).rounded(.up)), width)
                    let top = max(height - Int((centre.y + reach).rounded(.up)), 0)
                    let bottom = min(height - Int((centre.y - reach).rounded(.down)), height)
                    guard right > left, bottom > top else { continue }
                    let found = try #require(box)
                    #expect(found.x0 <= left && found.x1 >= right && found.y0 <= top && found.y1 >= bottom)
                }
                if let box {
                    #expect(box.x0 >= 0 && box.y0 >= 0 && box.x1 <= width && box.y1 <= height)
                    #expect(box.x1 > box.x0 && box.y1 > box.y0)
                }
            }
        }
        // Nowhere near the target, there is no box at all, nor for numbers that are none.
        #expect(ViewRenderer.birdBox(bird: SIMD4(-900, -900, 0, 0), wings: wings, sun: SIMD4(0, 1, 0.1, 1),
                                     metresPerPixel: 0.225, width: width, height: height) == nil)
        #expect(ViewRenderer.birdBox(bird: SIMD4(.nan, 100, 0, 0), wings: wings, sun: SIMD4(0, 1, 1, 1),
                                     metresPerPixel: 0.225, width: width, height: height) == nil)
    }
}
